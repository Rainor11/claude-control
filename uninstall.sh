#!/usr/bin/env bash
# uninstall.sh: remove launchd/systemd units and bin/ scripts installed by
# install.sh. Leaves ~/.claude-control/ alone by default (user data —
# projects.yaml, logs); pass --purge to remove it too.
#
#   ./uninstall.sh                 Use default paths and labels.
#   ./uninstall.sh --prefix DIR    Same as install.sh.
#   ./uninstall.sh --label LABEL   Same as install.sh.
#   ./uninstall.sh --purge         Also delete ~/.claude-control/.
set -euo pipefail

PREFIX="$HOME/.local"
PURGE=0
LABEL=""   # filled in per-platform below if not given

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --label)  LABEL="$2"; shift 2 ;;
    --purge)  PURGE=1; shift ;;
    -h|--help)
      sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

PLATFORM="$(uname -s)"
case "$PLATFORM" in
  Darwin) : "${LABEL:=com.${USER}.claude-control}" ;;
  Linux)  : "${LABEL:=claude-control}" ;;
  *)      echo "Unsupported platform: $PLATFORM" >&2; exit 1 ;;
esac

BIN_DIR="$PREFIX/bin"
CONTROL_DIR="$HOME/.claude-control"
WATCHDOG_LABEL="${LABEL}-watchdog"

say() { echo "==> $*"; }

case "$PLATFORM" in
  Darwin)
    LAUNCHD_DIR="$HOME/Library/LaunchAgents"
    remove_unit() {
      local label="$1"
      local plist="$LAUNCHD_DIR/${label}.plist"
      if launchctl print "gui/$UID/$label" >/dev/null 2>&1; then
        say "Bootout $label"
        launchctl bootout "gui/$UID/$label" || true
      fi
      if [[ -e "$plist" ]]; then
        say "Remove $plist"
        rm -f "$plist"
      fi
    }
    remove_unit "$WATCHDOG_LABEL"
    remove_unit "$LABEL"
    ;;

  Linux)
    SYSTEMD_DIR="$HOME/.config/systemd/user"
    remove_unit() {
      local unit="$1"   # full unit name, e.g. claude-control-watchdog.timer
      local path="$SYSTEMD_DIR/$unit"
      systemctl --user disable --now "$unit" >/dev/null 2>&1 || true
      if [[ -e "$path" ]]; then
        say "Remove $path"
        rm -f "$path"
      fi
    }
    remove_unit "${WATCHDOG_LABEL}.timer"
    remove_unit "${WATCHDOG_LABEL}.service"
    remove_unit "${LABEL}.service"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    ;;
esac

for script in claude-rc claude-control-session claude-control-watchdog; do
  target="$BIN_DIR/$script"
  if [[ -e "$target" || -L "$target" ]]; then
    say "Remove $target"
    rm -f "$target"
  fi
done

if [[ $PURGE -eq 1 ]]; then
  if [[ -d "$CONTROL_DIR" ]]; then
    say "Purge $CONTROL_DIR"
    rm -rf "$CONTROL_DIR"
  fi
  # The optional env-file used by the Linux systemd service lives outside
  # CONTROL_DIR (it's referenced as %h/.config/claude-control/env in the unit
  # template), so handle it explicitly under --purge.
  if [[ -d "$HOME/.config/claude-control" ]]; then
    say "Purge $HOME/.config/claude-control"
    rm -rf "$HOME/.config/claude-control"
  fi
else
  say "Leaving $CONTROL_DIR in place (use --purge to remove)."
fi

say "Done."
