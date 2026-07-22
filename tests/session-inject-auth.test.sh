#!/bin/bash
# tests/session-inject-auth.test.sh — контракт «auth-blocked» (rc=4).
#
# Инцидент 21.07: пока на хосте был протухший логин, event-bridge продолжал долбиться в
# мёртвые сессии. Каждая неудача двигала лестницу отсрочек, и после шести попыток события
# уезжали в карантин НАВСЕГДА — так у Архивариуса потерялись два handoff'а от Руководителя
# (state/.deadletter-dept-bus.log, 00:15:31Z и 00:25:39Z).
#
# Контракт: увидев auth-маркер на экране ДО любого ввода, session-inject выходит с кодом 4 и
# НИЧЕГО не печатает в pane; event-bridge-watch на rc=4 не засчитывает неудачу и не карантинит.
# Код 4 отделён от общего rc=1 намеренно: после paste+Enter результат неопределён (payload мог
# уйти), и «прощать» такую неудачу нельзя — повтор продублировал бы событие воркеру.
set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bootstrap.sh"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*"; exit 1; }

SANDBOX="$CLAUDE_CONTROL_TEST_ROOT/sandbox"
BIN="$SANDBOX/bin"
mkdir -p "$BIN"
ln -sfn "$DIR/lib" "$SANDBOX/lib"
cp "$DIR/bin/session-inject" "$DIR/bin/event-bridge-watch" "$BIN/"

export MOCK_LOG="$SANDBOX/tmux.log"
export SCREEN_FILE="$SANDBOX/screen.txt"
cat > "$SCREEN_FILE" <<'EOF'
⏺ Login expired · Please run /login

──────────────────────────────── dept-archivist ──
❯
──────────────────────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to cycle)
EOF

# Фейковый tmux: отдаёт наш экран в capture-pane и логирует ВСЕ вызовы, чтобы тест мог
# доказать, что ввода (load-buffer/paste-buffer/send-keys) не было вовсе.
cat > "$BIN/tmux" <<'EOF'
#!/bin/bash
args="$*"
echo "TMUX $args" >> "$MOCK_LOG"
case "$args" in
  *has-session*) exit 0 ;;
  *list-panes*) echo "1 %0"; exit 0 ;;
  *capture-pane*) cat "$SCREEN_FILE"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$BIN/tmux"
export PATH="$BIN:$PATH"

# 1) session-inject: auth-маркер на экране → rc=4, ни одного ввода в pane
: > "$MOCK_LOG"
set +e
"$BIN/session-inject" --timeout 5 claude-probe-worker "тестовое сообщение" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 4 ] || fail "ожидался rc=4 (auth-blocked), получен rc=$rc"
grep -qE 'load-buffer|paste-buffer|send-keys' "$MOCK_LOG" && fail "в pane что-то вводили при мёртвом логине"

# 2) экран без auth-маркера — прежнее поведение (rc≠4), контракт не задет
printf '❯\n  ⏵⏵ auto mode on\n' > "$SCREEN_FILE"
: > "$MOCK_LOG"
set +e
"$BIN/session-inject" --timeout 5 claude-probe-worker "тестовое сообщение" >/dev/null 2>&1
rc2=$?
set -e
[ "$rc2" -ne 4 ] || fail "rc=4 на здоровом экране — ложное auth-срабатывание"

# 3) event-bridge-watch: rc=4 не двигает лестницу отсрочек и не карантинит событие
name="probe-worker"
home="$CLAUDE_CONTROL_TEST_ROOT/workers/$name"
mkdir -p "$home/state" "$home/logs"
cat > "$home/event-bridge.config.json" <<'EOF'
{"probes":[{"name":"t","source":"probe","interval_sec":1,"timeout_sec":5,"cmd":"echo событие-1"}]}
EOF
cat > "$BIN/session-inject" <<'EOF'
#!/bin/bash
exit 4
EOF
chmod +x "$BIN/session-inject"
cat > "$BIN/tmux" <<'EOF'
#!/bin/bash
case "$*" in
  *has-session*)
    n=0; [ -f "$TMUX_TICKS_FILE" ] && n="$(cat "$TMUX_TICKS_FILE")"
    n=$(( n + 1 )); echo "$n" > "$TMUX_TICKS_FILE"
    [ "$n" -le 3 ] || exit 1
    exit 0 ;;
  *display*session_created*) echo "$(( $(date +%s) - 3600 ))"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$BIN/tmux"
export TMUX_TICKS_FILE="$SANDBOX/ticks"
EVENT_BRIDGE_TICK=1 timeout 30 "$BIN/event-bridge-watch" "$name" >/dev/null 2>&1 || true

log="$home/logs/event-bridge.log"
grep -q "fail 1/" "$log" && fail "rc=4 засчитан как неудача доставки — лестница отсрочек поехала"
grep -q "QUARANTINED" "$log" && fail "rc=4 отправил событие в карантин"
[ -s "$home/state/t.dead" ] && fail "событие записано в .dead при мёртвом логине"
[ -s "$home/state/t.seen" ] && fail "недоставленное событие помечено как доставленное"
grep -qi "auth" "$log" || fail "в логе нет следа auth-blocked — оператору нечем объяснить паузу"

echo "PASS: tests/session-inject-auth.test.sh"

# 4) Маркер ВНУТРИ текста (воркер обсуждает инцидент / событие процитировало ошибку) — НЕ
#    auth-blocked. Иначе такой текст «отравляет» pane: мы перестаём печатать, экран поэтому
#    не меняется, маркер не уходит — и доставка воркеру блокируется навсегда.
cat > "$BIN/session-inject" <<'EOF2'
placeholder
EOF2
cp "$DIR/bin/session-inject" "$BIN/session-inject"
cat > "$BIN/tmux" <<'EOF2'
#!/bin/bash
echo "TMUX $*" >> "$MOCK_LOG"
case "$*" in
  *has-session*) exit 0 ;;
  *list-panes*) echo "1 %0"; exit 0 ;;
  *capture-pane*) cat "$SCREEN_FILE"; exit 0 ;;
esac
exit 0
EOF2
chmod +x "$BIN/tmux"
cat > "$SCREEN_FILE" <<'EOF2'
⏺ Разобрал инцидент: на экранах висело "Login expired · Please run /login", сторож молчал.
──────────────────────────────── dept-head ──
❯
──────────────────────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to cycle)
EOF2
set +e
INJECT_CONFIRM_TIMEOUT=2 "$BIN/session-inject" --timeout 4 claude-probe-worker "тестовое сообщение" >/dev/null 2>&1
rc4=$?
set -e
[ "$rc4" -ne 4 ] || fail "цитата ошибки в тексте воркера заблокировала доставку — это вечный дедлок"

echo "PASS: tests/session-inject-auth.test.sh (quote is not auth-blocked)"

# 5) Fail-open: если «auth-blocked» держится дольше EB_AUTH_MAX, экранному маркеру больше не
#    верим и возвращаемся к обычной лестнице. Иначе застрявший/ложный маркер глушил бы
#    доставку этому воркеру навсегда (мы не печатаем → экран не меняется → маркер не уходит).
name2="probe-worker2"
home2="$CLAUDE_CONTROL_TEST_ROOT/workers/$name2"
mkdir -p "$home2/state" "$home2/logs"
cat > "$home2/event-bridge.config.json" <<'EOF2'
{"probes":[{"name":"t","source":"probe","interval_sec":1,"timeout_sec":5,"cmd":"echo событие-2"}]}
EOF2
cat > "$BIN/session-inject" <<'EOF2'
#!/bin/bash
exit 4
EOF2
chmod +x "$BIN/session-inject"
rm -f "$TMUX_TICKS_FILE"
cat > "$BIN/tmux" <<'EOF2'
#!/bin/bash
case "$*" in
  *has-session*)
    n=0; [ -f "$TMUX_TICKS_FILE" ] && n="$(cat "$TMUX_TICKS_FILE")"
    n=$(( n + 1 )); echo "$n" > "$TMUX_TICKS_FILE"
    [ "$n" -le 3 ] || exit 1
    exit 0 ;;
  *display*session_created*) echo "$(( $(date +%s) - 3600 ))"; exit 0 ;;
esac
exit 0
EOF2
chmod +x "$BIN/tmux"
EB_AUTH_MAX=0 EVENT_BRIDGE_TICK=1 timeout 30 "$BIN/event-bridge-watch" "$name2" >/dev/null 2>&1 || true
log2="$home2/logs/event-bridge.log"
grep -q "перестаю доверять" "$log2" || fail "fail-open не сработал — застрявший маркер глушил бы воркера вечно"
grep -q "fail 1/" "$log2" || fail "после fail-open событие не пошло по обычной лестнице"

echo "PASS: tests/session-inject-auth.test.sh (fail-open)"
