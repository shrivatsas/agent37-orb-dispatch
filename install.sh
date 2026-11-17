#!/usr/bin/env bash
# Install or remove the dispatch program and its systemd user unit.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
UNIT=agent37-orb-dispatch.service
CONFIG_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/agent37-orb-dispatch
DATA_DIR=$HOME/.local/share/agent37-orb-dispatch
UNIT_DIR=$HOME/.config/systemd/user
ACTION=${1:-install}
USER_NAME=$(id -un)

need() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "$1 is required" >&2
		exit 1
	}
}

case "$ACTION" in
install | uninstall) ;;
*)
	echo "usage: $0 [install|uninstall]" >&2
	exit 1
	;;
esac

need systemctl
systemctl --user show-environment >/dev/null 2>&1 || {
	echo "the systemd user manager is not available" >&2
	exit 1
}

if [ "$ACTION" = uninstall ]; then
	systemctl --user disable --now "$UNIT" 2>/dev/null || true
	rm -f "$UNIT_DIR/$UNIT" "$DATA_DIR/dispatch.sh"
	systemctl --user daemon-reload
	echo "removed $UNIT and $DATA_DIR/dispatch.sh"
	echo "configuration kept in $CONFIG_DIR/env"
	exit 0
fi

need curl
need jq
[ -x "$HOME/.local/bin/amp" ] || {
	echo "install the Amp CLI at $HOME/.local/bin/amp first" >&2
	exit 1
}

install -d -m 700 "$CONFIG_DIR"
install -d -m 755 "$DATA_DIR" "$UNIT_DIR"
if [ ! -f "$CONFIG_DIR/env" ]; then
	install -m 600 "$HERE/env.example" "$CONFIG_DIR/env"
	echo "wrote $CONFIG_DIR/env"
fi
install -m 755 "$HERE/dispatch.sh" "$DATA_DIR/dispatch.sh"
install -m 644 "$HERE/$UNIT" "$UNIT_DIR/$UNIT"
systemctl --user daemon-reload

# Keep the user service running after logout; without linger it stops with the session.
if command -v loginctl >/dev/null 2>&1; then
	if [ "$(loginctl show-user "$USER_NAME" -p Linger --value 2>/dev/null || true)" != yes ]; then
		loginctl enable-linger "$USER_NAME" 2>/dev/null ||
			echo "warning: could not enable linger; the service stops when you log out" >&2
	fi
fi

if grep -q 'REPLACE_WITH' "$CONFIG_DIR/env"; then
	echo
	echo "edit $CONFIG_DIR/env, then start the provider:"
	echo "  systemctl --user enable --now $UNIT"
else
	systemctl --user enable --now "$UNIT"
	echo "enabled and started $UNIT"
fi
