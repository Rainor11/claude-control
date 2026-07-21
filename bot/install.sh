#!/usr/bin/env bash
# install.sh — set up the @RnR_Workers bot: venv + deps + a systemd USER unit.
# Idempotent. Does NOT auto-start (the bot needs RNR_WORKERS_BOT_TOKEN in
# /home/rainor/server/.env first). After the token is added, start with:
#   ./bot_manager.sh start
set -euo pipefail

BOT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV="$BOT_DIR/venv"
UNIT_DIR="$HOME/.config/systemd/user"
# T5: корень рантайма — через единый резолвер (lib/runtime-root.sh, задача T1). Без маркера
# CLAUDE_CONTROL_TEST_ROOT возвращает ту же строку, что прежний inline-дефолт; под маркером —
# fail-closed на корень песочницы (иначе прогон установщика создал бы LOGDIR и вписал бы
# боевой CONTROL_DIR в unit-файл). bot/ — подкаталог репозитория, поэтому ../lib верен всегда.
# shellcheck disable=SC1091
. "$BOT_DIR/../lib/runtime-root.sh"
CONTROL_DIR="$(resolve_runtime_root control_only)" || exit 1
LOGDIR="$CONTROL_DIR/rnr-bot"
PROXY="${RNR_HTTPS_PROXY:-http://127.0.0.1:1081}"

mkdir -p "$LOGDIR" "$UNIT_DIR"

# 1) venv + deps
if [ ! -x "$VENV/bin/python" ]; then
  echo "creating venv at $VENV"
  python3 -m venv "$VENV"
fi
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet -r "$BOT_DIR/requirements.txt"

# 2) systemd user unit (generated here — single source of truth, no template drift)
cat > "$UNIT_DIR/rnr-workers-bot.service" <<EOF
[Unit]
Description=RnR Workers Telegram bot (claude-control two-way worker channel)
PartOf=default.target

[Service]
Type=simple
ExecStart=$VENV/bin/python $BOT_DIR/rnr_workers_bot.py
Restart=always
RestartSec=10
# Telegram API needs the sing-box proxy (RU egress is blocked direct).
Environment=HTTPS_PROXY=$PROXY
Environment=CLAUDE_CONTROL_DIR=$CONTROL_DIR
StandardOutput=append:$LOGDIR/bot.log
StandardError=append:$LOGDIR/bot.err

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
echo "✅ installed rnr-workers-bot.service"
echo "   venv : $VENV"
echo "   unit : $UNIT_DIR/rnr-workers-bot.service"
echo "   logs : $LOGDIR/bot.log"
echo
echo "NEXT (after RNR_WORKERS_BOT_TOKEN is in /home/rainor/server/.env and you pressed /start to the bot):"
echo "   $BOT_DIR/bot_manager.sh start"
