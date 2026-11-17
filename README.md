# agent37-orb-dispatch

An MIT-licensed dispatch program for [Amp](https://ampcode.com) self-hosted orbs on
[Agent 37](https://www.agent37.com). Amp runs it once per orb job; it maps each orb to one
Agent37 instance.

This is an independent implementation of Amp's published dispatch contract against Agent37's
public API. It is not a fork of, and shares no code with, `XYenon/agent37-orb-provider`.

## How it works

`amp orb provider` runs `dispatch.sh` once per job with:

| Variable | Meaning |
| --- | --- |
| `ORB_OPERATION` | `spawn`, `pause`, or `delete` |
| `ORB_ID` | The orb's id, `amp-<thread id>` |
| `ORB_TOKEN` | `spawn` only: credential for `amp orb bootstrap` |
| `AMP_URL` | `spawn` only: Amp server when it is not `ampcode.com` |
| `ORB_TYPE` | `spawn` only: the orb type picked in Amp |
| `ORB_IMAGE`, `ORB_SNAPSHOT_ID` | Unused; the template chooses the image and Agent37 keeps the disk |

`dispatch.sh` keeps one Agent37 instance per orb, matched by `metadata.amp_orb_id`:

- **spawn** — find or create the instance, start it if stopped, wait for `running`, then run
  `amp orb bootstrap` in the background with `ORB_TOKEN` (and `AMP_URL`).
- **pause** — stop the instance. The disk is kept, so the next spawn resumes the same machine.
- **delete** — delete the instance and its disk.

## Requirements

- An Agent37 workspace and API key (`sk_live_...`).
- An Amp self-hosted provider token (`aop_live_...`) from **Amp Settings → Orbs**.
- A small always-on Linux host with a systemd **user** manager, `bash`, `curl`, and `jq`.
- The Amp CLI at `~/.local/bin/amp`.
- An Agent37 workspace template that runs Amp's orb image.

## 1. Register the template

Agent37 creates instances from templates, not raw image references. Register Amp's official
image once. The entrypoint keeps the container alive, because the image's default command exits
in a detached container:

```bash
export AGENT37_API_KEY=sk_live_...
curl --fail-with-body -sS -X POST https://api.agent37.com/v1/templates \
  -H "Authorization: Bearer $AGENT37_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "amp-orb",
    "image_ref": "us-central1-docker.pkg.dev/amp-prod-0/amp-orb/amp-orb:latest",
    "entrypoint": ["sleep", "infinity"]
  }'
```

Registration copies the image into Agent37's private storage and pins it by digest, so a later
push to the tag does not change this template. Re-register, or `PATCH /v1/templates/amp-orb`,
to move it forward.

## 2. Create the provider and install

Create the provider from the CLI on the host that will run it:

```bash
amp orb provider create <name>              # personal
amp orb provider create --workspace <name>  # workspace
```

That saves the provider token for this user, so the env file needs only the Agent37 key and
template. If you prefer the web UI, use **Settings → Orbs → Add Provider** (personal) or
**Workspace Settings → Orbs → Add Orb Provider**, then paste the `aop_live_…` token into
`AMP_ORB_PROVIDER_TOKEN` in the env file.

Then install:

```bash
git clone https://github.com/shrivatsas/agent37-orb-dispatch.git
cd agent37-orb-dispatch
./install.sh
```

`install.sh` writes `~/.config/agent37-orb-dispatch/env` (mode `0600`) and installs the systemd
user unit. It also enables `loginctl` linger when it can, so the provider keeps running after you
log out; if it warns, run `sudo loginctl enable-linger $USER`. Fill in the two tokens, then start
it:

```bash
$EDITOR ~/.config/agent37-orb-dispatch/env
systemctl --user enable --now agent37-orb-dispatch.service
journalctl --user -u agent37-orb-dispatch -f
```

Select the provider in Amp's thread composer under **Self-Hosted**, or:

```bash
amp -ox "hello from Agent37" --orb-provider <provider-name>
```

## Configuration

| Variable | Required | Default | Meaning |
| --- | --- | --- | --- |
| `AMP_ORB_PROVIDER_TOKEN` | yes | — | Amp provider token, read by `amp orb provider` |
| `AGENT37_API_KEY` | yes | — | Agent37 workspace key |
| `AGENT37_TEMPLATE` | yes | — | Template name, e.g. `amp-orb` |
| `AGENT37_REGION` | no | `us` | `us`, `eu`, or `ap-south` |
| `AGENT37_TYPE` | no | `default` | `default`, `performance`, or `vm` |
| `AGENT37_CPU` / `AGENT37_MEMORY` / `AGENT37_DISK` | no | template default | Set all three or none |
| `AGENT37_TEMPLATE_<ORB_TYPE>` | no | — | Template override for one Amp orb type |
| `AGENT37_BOOTSTRAP_LOG` | no | `/home/user/.amp-bootstrap.log` | Where the orb writes bootstrap output |
| `AGENT37_BUDGET_SECONDS` | no | `270` | Wall-clock budget per job (Amp allows five minutes) |
| `AGENT37_POLL_SECONDS` | no | `2` | Status poll interval |
| `AGENT37_API_TIMEOUT` | no | `30` | Per-request timeout |

`ORB_TYPE` is the name configured on the provider in Amp. For example, with
`AGENT37_TEMPLATE_GPU=amp-orb-gpu`, an orb started with type `gpu` uses that template.

## Smoke test

`examples/smoke-test.sh` exercises the same API calls the provider relies on: it creates a
sandbox, runs a command, serves a file over HTTPS, and deletes the instance.

```bash
AGENT37_API_KEY=sk_live_... AGENT37_TEMPLATE=amp-orb ./examples/smoke-test.sh
```

`KEEP=1` keeps the instance and prints its delete command.

## Notes

- **CLI install.** The official orb image ships `/usr/local/bin/amp` as a symlink to
  `~/.amp/bin/amp`, which is installed at runtime. The dispatch script installs the Amp CLI on
  the first spawn if it is missing; the instance disk keeps it, so later spawns skip the
  download.
- **Disk, not snapshots.** Agent37's `stop` keeps the instance's disk, so `pause` does not save
  a snapshot and `ORB_SNAPSHOT_ID` is ignored. The instance keeps its id, so a later spawn
  starts the same machine.
- **Image.** `ORB_IMAGE` is ignored; the Agent37 template decides the image.
- **Budget.** Amp gives each job five minutes. The default 270-second budget leaves room to
  report a failure before Amp's own timeout.
- **Failure.** A `failed` instance is deleted and recreated on the next spawn.

## Security

`~/.config/agent37-orb-dispatch/env` holds both credentials; it is written `0600` in a `0700`
directory. The host is privileged: it can receive orb jobs and control Agent37 instances.
`dispatch.sh` sends the key in an HTTP header from the environment; the smoke test keeps it out
of `curl`'s argv.

## License

MIT. See [LICENSE](LICENSE).
