#!/bin/bash
# tests/event-bridge-startup.test.sh — стартовая отсрочка датчиков (задача «гонка на старте»).
#
# Инцидент: event-bridge-watch поднимается ВМЕСТЕ с сессией и стучится в неё через 5-10 секунд,
# пока claude ещё разворачивает контекст из --resume (сессии 265k-431k токенов). session-inject
# падает с «submit not confirmed within 8s», воркеру засчитывается неудача и включается
# лестница отсрочек 300/900/1800/3600. Замерено на живом: cctv-collect — session_created
# 21.07 09:00:29, первая неудача 09:00:39, ровно 10 секунд.
#
# Здесь проверяется контракт: пока tmux-сессия младше EB_STARTUP_GRACE секунд, датчики НЕ
# инжектят вовсе (и, как следствие, не тратят попытку и не двигают backoff). Возраст берётся
# из `tmux display -p '#{session_created}'` — от создания СЕССИИ, а не от старта watcher'а:
# watcher может подняться позже (перехват flock при rebase), и отсчёт от него был бы неверным.
set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bootstrap.sh"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*"; exit 1; }

SANDBOX="$CLAUDE_CONTROL_TEST_ROOT/sandbox"
BIN="$SANDBOX/bin"
mkdir -p "$BIN"
ln -sfn "$DIR/lib" "$SANDBOX/lib"
cp "$DIR/bin/event-bridge-watch" "$BIN/"

name="probe-worker"
home="$CLAUDE_CONTROL_TEST_ROOT/workers/$name"
mkdir -p "$home/state" "$home/logs"
cat > "$home/event-bridge.config.json" <<'EOF'
{"probes":[{"name":"t","source":"probe","interval_sec":1,"timeout_sec":5,"cmd":"echo событие-1"}]}
EOF

export MOCK_LOG="$SANDBOX/inject.log"
: > "$MOCK_LOG"

# Фейковый session-inject: только фиксирует факт вызова. Настоящий здесь непригоден — ему
# нужен живой TUI; контракт «звали или нет» этого достаточно.
cat > "$BIN/session-inject" <<'EOF'
#!/bin/bash
echo "INJECT $*" >> "$MOCK_LOG"
exit 0
EOF
chmod +x "$BIN/session-inject"

# Фейковый tmux: has-session жив ровно TMUX_ALIVE_TICKS раз (дальше watcher штатно выходит,
# тест не висит), display -p отдаёт подставной session_created из $FAKE_CREATED.
cat > "$BIN/tmux" <<'EOF'
#!/bin/bash
args="$*"
case "$args" in
  *has-session*)
    n=0; [ -f "$TMUX_TICKS_FILE" ] && n="$(cat "$TMUX_TICKS_FILE")"
    n=$(( n + 1 )); echo "$n" > "$TMUX_TICKS_FILE"
    [ "$n" -le "${TMUX_ALIVE_TICKS:-3}" ] || exit 1
    exit 0 ;;
  *display*session_created*) echo "$FAKE_CREATED"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$BIN/tmux"

export PATH="$BIN:$PATH"
export TMUX_TICKS_FILE="$SANDBOX/ticks"
export EVENT_BRIDGE_TICK=1
export TMUX_ALIVE_TICKS=3

run_watch() {
  : > "$MOCK_LOG"; rm -f "$TMUX_TICKS_FILE"
  rm -f "$home/state"/*.seen "$home/state"/*.dead 2>/dev/null || true
  timeout 30 "$BIN/event-bridge-watch" "$name" >/dev/null 2>&1 || true
}

# 1) Сессия только что создана — датчик не инжектит (окно разворачивания контекста).
FAKE_CREATED="$(date +%s)" run_watch
grep -q INJECT "$MOCK_LOG" && fail "инжект в молодую сессию — стартовая отсрочка не работает"

# 2) Сессия давно жива — обычная доставка, отсрочка не мешает штатной работе.
FAKE_CREATED="$(( $(date +%s) - 3600 ))" run_watch
grep -q INJECT "$MOCK_LOG" || fail "в прогретую сессию событие не доставлено"

# 3) Порог настраивается: с EB_STARTUP_GRACE=0 отсрочки нет вовсе.
EB_STARTUP_GRACE=0 FAKE_CREATED="$(date +%s)" run_watch
grep -q INJECT "$MOCK_LOG" || fail "EB_STARTUP_GRACE=0 обязан отключать отсрочку"

echo "PASS: tests/event-bridge-startup.test.sh"
