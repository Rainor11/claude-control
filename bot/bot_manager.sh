#!/usr/bin/env bash
# bot_manager.sh — lifecycle wrapper for the rnr-workers-bot systemd user service.
set -u
SVC="rnr-workers-bot"
case "${1:-}" in
  start)   systemctl --user enable --now "$SVC" && echo "started $SVC" ;;
  stop)    systemctl --user disable --now "$SVC" 2>/dev/null || true; systemctl --user stop "$SVC" 2>/dev/null || true; echo "stopped $SVC" ;;
  restart) systemctl --user restart "$SVC" && echo "restarted $SVC" ;;
  status)  systemctl --user --no-pager status "$SVC" ;;
  logs)    journalctl --user -u "$SVC" -n 80 --no-pager ;;
  follow)  journalctl --user -u "$SVC" -f ;;
  *) echo "usage: bot_manager.sh {start|stop|restart|status|logs|follow}" >&2; exit 2 ;;
esac
