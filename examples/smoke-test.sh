#!/usr/bin/env bash
# Create an Agent37 sandbox, run a command, serve a file over HTTPS, then delete it.
#
# Requires a server-side AGENT37_API_KEY in the environment.
#   AGENT37_API_KEY=sk_live_... ./examples/smoke-test.sh
#
# Optional: AGENT37_TEMPLATE (default agent37-base), AGENT37_REGION (us),
# AGENT37_PORT (8000), KEEP=1 to keep the instance and print its delete command.

set -euo pipefail

: "${AGENT37_API_KEY:?set AGENT37_API_KEY to a server-side Agent37 key}"

TEMPLATE=${AGENT37_TEMPLATE:-agent37-base}
REGION=${AGENT37_REGION:-us}
PORT=${AGENT37_PORT:-8000}
API_BASE=${AGENT37_API_BASE:-https://api.agent37.com}
EXEC_BASE=${AGENT37_EXEC_BASE:-https://sandbox.agent37.app}
API_BASE=${API_BASE%/}
EXEC_BASE=${EXEC_BASE%/}
KEEP=${KEEP:-0}
INSTANCE_ID=''

command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

# Keep the key out of curl's argv, where another local user could read it.
api_curl() {
	curl --fail-with-body -sS \
		--config <(printf 'header = "Authorization: Bearer %s"\n' "$AGENT37_API_KEY") "$@"
}

instance_curl() {
	curl --fail-with-body -sS \
		--config <(printf 'header = "X-Agent37-Key: %s"\n' "$AGENT37_API_KEY") "$@"
}

cleanup() {
	[ -n "$INSTANCE_ID" ] || return 0
	if [ "$KEEP" = 1 ]; then
		echo
		echo "kept instance $INSTANCE_ID"
		echo "delete it when finished:"
		printf '  curl -X DELETE "%s/v1/instances/%s" -H "Authorization: Bearer $AGENT37_API_KEY"\n' \
			"$API_BASE" "$INSTANCE_ID"
		return 0
	fi
	echo "deleting instance $INSTANCE_ID"
	api_curl -X DELETE "$API_BASE/v1/instances/$INSTANCE_ID" >/dev/null ||
		echo "warning: delete failed; remove $INSTANCE_ID by hand" >&2
}
trap cleanup EXIT

echo "creating a $TEMPLATE instance in $REGION"
created=$(api_curl -X POST "$API_BASE/v1/instances" \
	-H 'Content-Type: application/json' \
	-d "$(jq -cn --arg template "$TEMPLATE" --arg region "$REGION" \
		'{template: $template, region: $region}')")
INSTANCE_ID=$(printf '%s' "$created" | jq -er '.id')
echo "instance: $INSTANCE_ID"

echo "running a command"
result=$(instance_curl -X POST "$EXEC_BASE/v1/instances/$INSTANCE_ID/exec" \
	-H 'Content-Type: application/json' \
	-d '{"command": "uname -s && echo agent37-smoke-test"}')
printf '%s' "$result" | jq -r '.stdout' | sed 's/^/  /'
[ "$(printf '%s' "$result" | jq -r '.exit_code')" = 0 ] || {
	echo "command failed" >&2
	exit 1
}

echo "serving a file on port $PORT"
instance_curl -X POST "$EXEC_BASE/v1/instances/$INSTANCE_ID/exec" \
	-H 'Content-Type: application/json' \
	-d "$(jq -cn --arg port "$PORT" '{
		command: ("mkdir -p /tmp/agent37-smoke && printf \"hello from agent37\\n\" > /tmp/agent37-smoke/index.html && nohup python3 -m http.server " + $port + " --bind 0.0.0.0 --directory /tmp/agent37-smoke > /tmp/agent37-smoke/server.log 2>&1 &")
	}')" >/dev/null

url="https://$INSTANCE_ID-$PORT.agent37.app"
echo "fetching $url"
body=''
for _ in 1 2 3 4 5 6 7 8 9 10; do
	if body=$(instance_curl "$url" 2>/dev/null); then
		break
	fi
	sleep 1
done
[ -n "$body" ] || {
	echo "the service did not answer at $url" >&2
	exit 1
}
echo "  $body"
