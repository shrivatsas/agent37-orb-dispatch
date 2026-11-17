#!/usr/bin/env bash
# Amp self-hosted orb dispatch on Agent37.
#
# Amp runs this program once per job with ORB_OPERATION=spawn|pause|delete.
# Each orb maps to one Agent37 instance, found by its metadata.amp_orb_id.
#
# MIT License. See LICENSE.

set -euo pipefail

CONFIG=${AGENT37_DISPATCH_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/agent37-orb-dispatch/env}
if [ -r "$CONFIG" ]; then
	set -a
	# shellcheck disable=SC1090
	. "$CONFIG"
	set +a
fi

: "${AGENT37_API_KEY:?AGENT37_API_KEY is required}"
: "${AGENT37_TEMPLATE:?AGENT37_TEMPLATE is required}"
: "${ORB_OPERATION:?ORB_OPERATION is required}"
: "${ORB_ID:?ORB_ID is required}"

API_BASE=${AGENT37_API_BASE:-https://api.agent37.com}
EXEC_BASE=${AGENT37_EXEC_BASE:-https://sandbox.agent37.app}
REGION=${AGENT37_REGION:-us}
INSTANCE_TYPE=${AGENT37_TYPE:-default}
BOOTSTRAP_LOG=${AGENT37_BOOTSTRAP_LOG:-/home/user/.amp-bootstrap.log}
BUDGET_SECONDS=${AGENT37_BUDGET_SECONDS:-270}
POLL_SECONDS=${AGENT37_POLL_SECONDS:-2}
API_TIMEOUT=${AGENT37_API_TIMEOUT:-30}
API_BASE=${API_BASE%/}
EXEC_BASE=${EXEC_BASE%/}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/agent37-dispatch.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
BODY=$TMP/body
CURL_ERR=$TMP/curl.err
HTTP_STATUS=000

log() {
	printf '%s agent37-dispatch %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${ORB_OPERATION:-?}" "$*" >&2
}

die() {
	log "error: $*"
	exit 1
}

case "$AGENT37_API_KEY" in
*[[:space:]]*) die "AGENT37_API_KEY must not contain whitespace; paste only the key" ;;
esac

require_int() {
	case "$2" in
	'' | *[!0-9]*) die "$1 must be an integer (got '$2')" ;;
	esac
}

require_int AGENT37_BUDGET_SECONDS "$BUDGET_SECONDS"
require_int AGENT37_POLL_SECONDS "$POLL_SECONDS"
require_int AGENT37_API_TIMEOUT "$API_TIMEOUT"

DEADLINE=$(( $(date +%s) + BUDGET_SECONDS ))

remaining() {
	local left=$(( DEADLINE - $(date +%s) ))
	printf '%s' "$(( left > 0 ? left : 0 ))"
}

request() { # method url auth [data]
	local method=$1 url=$2 auth=$3 data=${4-}
	local args=(-sS -o "$BODY" -w '%{http_code}' -X "$method" "$url" -H "$auth" --max-time "$API_TIMEOUT")
	[ -n "$data" ] && args+=(-H 'Content-Type: application/json' --data "$data")
	if ! HTTP_STATUS=$(curl "${args[@]}" 2>"$CURL_ERR"); then
		HTTP_STATUS=000
		cat "$CURL_ERR" >"$BODY" 2>/dev/null || : >"$BODY"
	fi
}

api() {
	request "$1" "$API_BASE$2" "Authorization: Bearer $AGENT37_API_KEY" "${3-}"
}

exec_api() {
	request POST "$EXEC_BASE/v1/instances/$1/exec" "X-Agent37-Key: $AGENT37_API_KEY" "$2"
}

error_code() {
	jq -r 'if (.error | type) == "object" then (.error.code // "")
		elif (.error | type) == "string" then .error
		else "" end' "$BODY" 2>/dev/null || true
}

error_text() {
	jq -r '.error.message // .error // empty' "$BODY" 2>/dev/null | head -c 400 || true
}

retryable() {
	case "$1" in
	try_again | no_capacity | capacity_unavailable | rate_limited | provisioning_failed | \
		upstream_unreachable | internal_error | wake_timeout | wake_failed | \
		host_mesh_not_ready | instance_saturated)
		return 0
		;;
	esac
	case "$HTTP_STATUS" in
	409 | 429 | 500 | 502 | 503 | 504) return 0 ;;
	esac
	return 1
}

call() { # description command [args...]
	local what=$1
	shift
	local attempt=1 delay=2 code
	while :; do
		"$@" || true
		case "$HTTP_STATUS" in
		2*) return 0 ;;
		esac
		code=$(error_code)
		if [ "$attempt" -ge 5 ] || ! retryable "$code"; then
			die "$what failed: HTTP $HTTP_STATUS ${code} $(error_text)"
		fi
		[ "$(remaining)" -gt 0 ] || die "$what failed: time budget exhausted"
		log "$what: HTTP $HTTP_STATUS ${code}; retrying in ${delay}s"
		sleep "$delay"
		delay=$(( delay * 2 ))
		attempt=$(( attempt + 1 ))
	done
}

find_instance() {
	call "list instances" api GET /v1/instances
	jq -r --arg id "$ORB_ID" '
		[ .data[]? | select((.metadata.amp_orb_id // "") == $id) ]
		| sort_by(.created // 0) | last | .id // empty
	' "$BODY"
}

status_of() {
	call "get instance $1" api GET "/v1/instances/$1"
	jq -r '.status // empty' "$BODY"
}

wait_for() { # id target...
	local id=$1
	shift
	local status target
	while :; do
		status=$(status_of "$id")
		for target in "$@"; do
			if [ "$status" = "$target" ]; then
				printf '%s' "$status"
				return 0
			fi
		done
		if [ "$status" = failed ]; then
			die "instance $id is failed: $(jq -r '.status_reason.message // empty' "$BODY" 2>/dev/null)"
		fi
		[ "$(remaining)" -gt 0 ] || die "timed out waiting for instance $id to become $* (last: $status)"
		sleep "$POLL_SECONDS"
	done
}

template_for_orb() {
	local template=$AGENT37_TEMPLATE
	if [ -n "${ORB_TYPE:-}" ]; then
		local key
		key="AGENT37_TEMPLATE_$(printf '%s' "$ORB_TYPE" | tr '[:lower:].-' '[:upper:]__')"
		local override=${!key:-}
		[ -n "$override" ] && template=$override
	fi
	printf '%s' "$template"
}

create_body() {
	local template=$1 resources='{}'
	if [ -n "${AGENT37_CPU:-}" ] || [ -n "${AGENT37_MEMORY:-}" ] || [ -n "${AGENT37_DISK:-}" ]; then
		if [ -z "${AGENT37_CPU:-}" ] || [ -z "${AGENT37_MEMORY:-}" ] || [ -z "${AGENT37_DISK:-}" ]; then
			die "set AGENT37_CPU, AGENT37_MEMORY and AGENT37_DISK together, or none of them"
		fi
		resources=$(jq -cn --arg cpu "$AGENT37_CPU" --arg memory "$AGENT37_MEMORY" --arg disk "$AGENT37_DISK" \
			'{cpu: ($cpu | tonumber), memory: ($memory | tonumber), disk: ($disk | tonumber)}')
	fi
	jq -cn \
		--arg template "$template" \
		--arg region "$REGION" \
		--arg type "$INSTANCE_TYPE" \
		--arg id "$ORB_ID" \
		--arg name "amp-$ORB_ID" \
		--argjson resources "$resources" '
		{
			template: $template,
			type: $type,
			region: $region,
			name: $name,
			metadata: {amp_orb_id: $id},
			auto_sleep: false
		}
		+ (if $resources == {} then {} else {resources: $resources} end)
	'
}

ensure_instance() {
	local id
	id=$(find_instance)
	if [ -n "$id" ]; then
		printf '%s' "$id"
		return 0
	fi
	local body attempt=1 delay=2 code
	body=$(create_body "$(template_for_orb)")
	while :; do
		api POST /v1/instances "$body"
		case "$HTTP_STATUS" in
		2*)
			jq -r '.id // empty' "$BODY"
			return 0
			;;
		esac
		code=$(error_code)
		if [ "$attempt" -ge 5 ] || ! retryable "$code"; then
			die "create instance failed: HTTP $HTTP_STATUS ${code} $(error_text)"
		fi
		[ "$(remaining)" -gt 0 ] || die "create instance failed: time budget exhausted"
		log "create instance: HTTP $HTTP_STATUS ${code}; checking for an existing instance in ${delay}s"
		sleep "$delay"
		delay=$(( delay * 2 ))
		attempt=$(( attempt + 1 ))
		id=$(find_instance)
		if [ -n "$id" ]; then
			printf '%s' "$id"
			return 0
		fi
	done
}

ensure_running() {
	local id=$1 status
	status=$(status_of "$id")
	case "$status" in
	running)
		return 0
		;;
	stopped | sleeping)
		call "start instance $id" api POST "/v1/instances/$id/start"
		wait_for "$id" running >/dev/null
		;;
	starting | waking | provisioning | restarting | updating)
		wait_for "$id" running >/dev/null
		;;
	stopping)
		wait_for "$id" stopped >/dev/null
		call "start instance $id" api POST "/v1/instances/$id/start"
		wait_for "$id" running >/dev/null
		;;
	failed)
		die "instance $id is failed: $(jq -r '.status_reason.message // empty' "$BODY" 2>/dev/null)"
		;;
	*)
		die "instance $id has unexpected status '$status'"
		;;
	esac
}

shell_quote() {
	printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

bootstrap_command() {
	local cmd
	cmd="export HOME=/home/user
export USER=user
export PATH=/home/user/.local/bin:/usr/local/bin:\$PATH
export ORB_TOKEN=$(shell_quote "$ORB_TOKEN")"
	if [ -n "${AMP_URL:-}" ]; then
		cmd="$cmd
export AMP_URL=$(shell_quote "$AMP_URL")"
	fi
	cmd="$cmd
exec > $(shell_quote "$BOOTSTRAP_LOG") 2>&1
if ! command -v amp >/dev/null 2>&1; then
  echo \"amp not found in PATH=\$PATH\"
  exit 127
fi
exec amp orb bootstrap"
	printf '%s' "$cmd"
}

start_bootstrap() {
	local id=$1 body pid cmd digest name
	cmd=$(bootstrap_command)
	# Agent37 remembers an exec name for 5 minutes; a new ORB_TOKEN changes the
	# command, so hash the command into the name instead of reusing one.
	digest=$(printf '%s' "$cmd" | cksum | cut -d' ' -f1)
	name="amp-bootstrap-$ORB_ID-$digest"
	body=$(jq -cn --arg command "$cmd" --arg name "$name" \
		'{command: $command, background: true, name: $name}')
	call "start bootstrap on $id" exec_api "$id" "$body"
	pid=$(jq -r '.pid // empty' "$BODY")
	[ -n "$pid" ] || die "bootstrap did not start: $(head -c 400 "$BODY")"

	sleep 1
	exec_api "$id" "$(jq -cn --arg c "kill -0 $pid" '{command: $c}')"
	if [ "$HTTP_STATUS" != 200 ] || [ "$(jq -r '.exit_code // 1' "$BODY")" != 0 ]; then
		exec_api "$id" "$(jq -cn --arg c "tail -n 40 $(shell_quote "$BOOTSTRAP_LOG")" '{command: $c}')"
		die "bootstrap exited early: $(jq -r '.stdout // .stderr // empty' "$BODY" | head -c 800)"
	fi
	log "bootstrap running (pid $pid)"
}

spawn() {
	[ -n "${ORB_TOKEN:-}" ] || die "ORB_TOKEN is not set for spawn"
	local id status
	id=$(ensure_instance)
	status=$(status_of "$id")
	if [ "$status" = failed ]; then
		log "instance $id is failed; deleting it and recreating"
		api DELETE "/v1/instances/$id"
		case "$HTTP_STATUS" in
		2* | 404) ;;
		*) die "delete failed instance $id failed: HTTP $HTTP_STATUS $(error_text)" ;;
		esac
		id=$(ensure_instance)
	fi
	log "instance $id"
	ensure_running "$id"
	start_bootstrap "$id"
}

pause() {
	local id status
	id=$(find_instance)
	if [ -z "$id" ]; then
		log "no instance; nothing to pause"
		return 0
	fi
	status=$(status_of "$id")
	case "$status" in
	stopped | deleting | deleted)
		log "instance $id is already $status"
		return 0
		;;
	stopping)
		wait_for "$id" stopped >/dev/null
		return 0
		;;
	failed)
		log "instance $id is failed; leaving it in place"
		return 0
		;;
	esac
	api POST "/v1/instances/$id/stop"
	case "$HTTP_STATUS" in
	2*)
		wait_for "$id" stopped >/dev/null
		;;
	400)
		# A sleeper parked in cold storage cannot be stopped; wake it first.
		if [ "$(error_code)" = invalid_request ] && [ "$status" = sleeping ]; then
			call "start instance $id" api POST "/v1/instances/$id/start"
			wait_for "$id" running >/dev/null
			call "stop instance $id" api POST "/v1/instances/$id/stop"
			wait_for "$id" stopped >/dev/null
		else
			die "stop instance $id failed: HTTP $HTTP_STATUS $(error_text)"
		fi
		;;
	*)
		die "stop instance $id failed: HTTP $HTTP_STATUS $(error_text)"
		;;
	esac
	log "instance $id stopped"
}

delete() {
	local id
	id=$(find_instance)
	if [ -z "$id" ]; then
		log "no instance; nothing to delete"
		return 0
	fi
	api DELETE "/v1/instances/$id"
	case "$HTTP_STATUS" in
	2*) log "instance $id deleted" ;;
	404) log "instance $id was already gone" ;;
	*) die "delete instance $id failed: HTTP $HTTP_STATUS $(error_text)" ;;
	esac
}

case "$ORB_OPERATION" in
spawn) spawn ;;
pause) pause ;;
delete) delete ;;
*) die "ORB_OPERATION must be spawn, pause or delete (got '$ORB_OPERATION')" ;;
esac
