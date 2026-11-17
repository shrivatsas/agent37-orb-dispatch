#!/usr/bin/env python3
"""Contract test for dispatch.sh against a mock Agent37 API."""

import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DISPATCH = ROOT / "dispatch.sh"


class State:
    def __init__(self):
        self.instances = {}
        self.creates = []
        self.execs = []
        self.next_id = 1
        self.lock = threading.Lock()

    def reset(self):
        with self.lock:
            self.instances.clear()
            self.creates.clear()
            self.execs.clear()
            self.next_id = 1


STATE = State()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def _send(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        return json.loads(raw or b"{}")

    def do_GET(self):
        if self.path == "/v1/instances":
            with STATE.lock:
                self._send(200, {"data": list(STATE.instances.values())})
            return
        parts = self.path.strip("/").split("/")
        if len(parts) == 3 and parts[:2] == ["v1", "instances"]:
            with STATE.lock:
                inst = STATE.instances.get(parts[2])
            if inst is None:
                self._send(404, {"error": {"code": "not_found", "message": "no instance"}})
            else:
                self._send(200, inst)
            return
        self._send(404, {"error": {"code": "not_found", "message": "unknown path"}})

    def do_POST(self):
        body = self._body()
        if self.path == "/v1/instances":
            with STATE.lock:
                STATE.creates.append(body)
                iid = f"inst{STATE.next_id:04d}"
                STATE.next_id += 1
                inst = {
                    "id": iid,
                    "status": "running",
                    "metadata": body.get("metadata"),
                    "template": body.get("template"),
                    "created": 1,
                }
                STATE.instances[iid] = inst
            self._send(201, inst)
            return

        parts = self.path.strip("/").split("/")
        if len(parts) == 4 and parts[:2] == ["v1", "instances"]:
            iid, action = parts[2], parts[3]
            with STATE.lock:
                inst = STATE.instances.get(iid)
                if inst is not None and action == "start":
                    inst["status"] = "running"
                elif inst is not None and action == "stop":
                    inst["status"] = "stopped"
                elif inst is not None and action == "exec":
                    STATE.execs.append({"id": iid, **body})
            if inst is None:
                self._send(404, {"error": {"code": "not_found", "message": "no instance"}})
            elif action in ("start", "stop"):
                self._send(200, {"id": iid, "status": inst["status"]})
            elif action == "exec":
                if body.get("background"):
                    self._send(200, {"pid": 4321})
                else:
                    self._send(
                        200,
                        {"exit_code": 0, "stdout": "Linux\n", "stderr": "", "truncated": False},
                    )
            else:
                self._send(404, {"error": {"code": "not_found", "message": "unknown action"}})
            return
        self._send(404, {"error": {"code": "not_found", "message": "unknown path"}})

    def do_DELETE(self):
        parts = self.path.strip("/").split("/")
        if len(parts) == 3 and parts[:2] == ["v1", "instances"]:
            iid = parts[2]
            with STATE.lock:
                existed = STATE.instances.pop(iid, None) is not None
            if existed:
                self._send(200, {"id": iid, "deleted": True})
            else:
                self._send(404, {"error": {"code": "not_found", "message": "gone"}})
            return
        self._send(404, {"error": {"code": "not_found", "message": "unknown path"}})


def start_server():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def run(op, port, extra=None):
    env = {
        **os.environ,
        "AGENT37_DISPATCH_CONFIG": "/dev/null",
        "AGENT37_API_KEY": "test-key",
        "AGENT37_TEMPLATE": "amp-orb",
        "AGENT37_API_BASE": f"http://127.0.0.1:{port}",
        "AGENT37_EXEC_BASE": f"http://127.0.0.1:{port}",
        "AGENT37_BOOTSTRAP_LOG": "/tmp/agent37-test-bootstrap.log",
        "AGENT37_POLL_SECONDS": "1",
        "ORB_OPERATION": op,
        "ORB_ID": "amp-T-test",
    }
    if op == "spawn":
        env["ORB_TOKEN"] = "orb-token"
    if extra:
        env.update(extra)
    result = subprocess.run(["bash", str(DISPATCH)], env=env, capture_output=True, text=True)
    if result.returncode != 0:
        raise AssertionError(f"{op} failed:\n{result.stdout}\n{result.stderr}")
    return result


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    server = start_server()
    port = server.server_address[1]
    try:
        STATE.reset()
        run("spawn", port)
        check(len(STATE.instances) == 1, "spawn should create one instance")
        check(len(STATE.creates) == 1, "spawn should POST one create")
        create = STATE.creates[0]
        check(create["metadata"]["amp_orb_id"] == "amp-T-test", "create must tag the orb id")
        check(create["template"] == "amp-orb", "create must use AGENT37_TEMPLATE")
        check(create.get("auto_sleep") is False, "create must disable auto-sleep")
        bootstrap = STATE.execs[0]
        check(bootstrap.get("background") is True, "bootstrap must run in the background")
        check("amp orb bootstrap" in bootstrap["command"], "bootstrap command missing")
        check("orb-token" in bootstrap["command"], "bootstrap command must carry ORB_TOKEN")

        run("spawn", port)
        check(len(STATE.creates) == 1, "a second spawn must reuse the instance")
        check(len(STATE.instances) == 1, "a second spawn must not create a duplicate")

        run("pause", port)
        check(STATE.instances["inst0001"]["status"] == "stopped", "pause must stop the instance")
        run("pause", port)
        check(STATE.instances["inst0001"]["status"] == "stopped", "pause must be idempotent")

        run("delete", port)
        check(not STATE.instances, "delete must remove the instance")
        run("delete", port)
        check(not STATE.instances, "delete must be idempotent")

        STATE.reset()
        run("spawn", port, {"ORB_TYPE": "gpu", "AGENT37_TEMPLATE_GPU": "amp-orb-gpu"})
        check(STATE.creates[0]["template"] == "amp-orb-gpu", "ORB_TYPE must select its template")

        print("ok: spawn, pause, delete, idempotency, orb type mapping")
    finally:
        server.shutdown()


if __name__ == "__main__":
    try:
        main()
    except AssertionError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
