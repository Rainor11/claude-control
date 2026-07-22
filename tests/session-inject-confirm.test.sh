#!/bin/bash
# tests/session-inject-confirm.test.sh — подтверждение сабмита на ТЯЖЁЛОЙ сессии.
#
# Поймано вживую 21.07 при отправке задачи Руководителю (сессия 242.9k токенов): сообщение
# было доставлено (ход начался, воркер его обрабатывал), а session-inject вернул провал —
# «submit not confirmed within 8s — no turn started». Busy-хинт появляется ПОЗЖЕ 8 секунд,
# когда TUI разворачивает большой контекст.
#
# Цена такого ложного провала выше, чем кажется: event-bridge-watch не пишет событие в .seen,
# и следующая попытка доставит его ПОВТОРНО (в коде уже описан прецедент 26 дублей одного
# ответа), а лестница отсрочек тем временем едет на здоровой сессии.
#
# Контракт: сабмит подтверждён и тогда, когда payload ушёл из поля ввода и виден ВЫШЕ него
# (то есть уехал в транскрипт) — даже если busy-хинт ещё не показался.
set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bootstrap.sh"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*"; exit 1; }

SANDBOX="$CLAUDE_CONTROL_TEST_ROOT/sandbox"
BIN="$SANDBOX/bin"
mkdir -p "$BIN"
ln -sfn "$DIR/lib" "$SANDBOX/lib"
cp "$DIR/bin/session-inject" "$BIN/"

MSG="Норма из proposal legion2 применена"
export SANDBOX MSG
export ENTER_FLAG="$SANDBOX/enter-pressed"

# Экран ДО Enter: payload лежит в поле ввода (последние строки — зона ввода).
cat > "$SANDBOX/before.txt" <<EOF
  предыдущий вывод воркера
✻ Sautéed for 39s

──────────────────────────────────────── dept-head ──
❯ $MSG
──────────────────────────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to cycle)
EOF

# Экран ПОСЛЕ Enter: payload уехал в транскрипт, поле ввода пустое, busy-хинта ЕЩЁ НЕТ
# (ровно тот кадр, на котором старый код объявлял «no turn started»).
cat > "$SANDBOX/after.txt" <<EOF
  предыдущий вывод воркера

❯ $MSG

✽ Doodling… (2s)
──────────────────────────────────────── dept-head ──
❯
──────────────────────────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to cycle)
EOF

cat > "$BIN/tmux" <<'EOF'
#!/bin/bash
args="$*"
case "$args" in
  *has-session*) exit 0 ;;
  *list-panes*) echo "1 %0"; exit 0 ;;
  *capture-pane*)
    if [ -f "$ENTER_FLAG" ]; then cat "$SANDBOX/after.txt"; else cat "$SANDBOX/before.txt"; fi
    exit 0 ;;
  *send-keys*Enter*) : > "$ENTER_FLAG"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$BIN/tmux"
export PATH="$BIN:$PATH"

# 1) Тяжёлая сессия: busy-хинт не успел появиться, но payload уехал в транскрипт → успех.
rm -f "$ENTER_FLAG"
set +e
INJECT_CONFIRM_TIMEOUT=3 "$BIN/session-inject" --timeout 5 claude-dept-head "$MSG" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "доставленное сообщение объявлено недоставленным (rc=$rc) — ложный провал жив"

# 2) Enter потерялся: payload так и остался в поле ввода → честный провал, а не «доставлено».
cp "$SANDBOX/before.txt" "$SANDBOX/after.txt"
rm -f "$ENTER_FLAG"
set +e
INJECT_CONFIRM_TIMEOUT=3 "$BIN/session-inject" --timeout 5 claude-dept-head "$MSG" >/dev/null 2>&1
rc2=$?
set -e
[ "$rc2" -ne 0 ] || fail "неотправленный payload засчитан как доставленный — это потеря события"

echo "PASS: tests/session-inject-confirm.test.sh"

# 3) МНОГОСТРОЧНЫЙ payload (а event-bridge шлёт именно такие: обрамление + строка события)
#    всё ещё лежит в поле ввода — Enter потерялся. Якорь по ПЕРВОЙ строке payload уехал бы
#    выше зоны ввода и дал ложное «доставлено», а это потеря события: watcher записал бы его
#    в .seen и никогда не переслал.
MULTI="[event-bridge | source=asana | probe=deal]
Первая строка события клиента
вторая строка
третья строка
четвёртая строка
пятая строка"
cat > "$SANDBOX/before.txt" <<EOF
  предыдущий вывод воркера
──────────────────────────────────────── dept-head ──
❯ $MULTI
──────────────────────────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to cycle)
EOF
cp "$SANDBOX/before.txt" "$SANDBOX/after.txt"
rm -f "$ENTER_FLAG"
set +e
INJECT_CONFIRM_TIMEOUT=3 "$BIN/session-inject" --timeout 5 claude-dept-head "$MULTI" >/dev/null 2>&1
rc3=$?
set -e
[ "$rc3" -ne 0 ] || fail "многострочный payload в поле ввода засчитан доставленным — событие будет потеряно"

echo "PASS: tests/session-inject-confirm.test.sh (multiline)"

# 4) ОДНА длинная строка, которую терминал перенёс на много визуальных строк: её НАЧАЛО ушло
#    выше зоны ввода, но payload всё ещё не отправлен. Якорь по началу строки дал бы ложное
#    «доставлено» — а это молчаливая потеря события.
LONG="[event-bridge | source=asana | probe=deal] Дмитрий Иванов: очень длинный комментарий про то как всё работает и что надо поправить в приложении на следующей неделе КОНЕЦ комментария клиента"
cat > "$SANDBOX/before.txt" <<EOF
  предыдущий вывод воркера
──────────────────────────────────────── dept-head ──
❯ [event-bridge | source=asana | probe=deal] Дмитрий
  Иванов: очень длинный комментарий про то как всё
  работает и что надо поправить в приложении на
  следующей неделе КОНЕЦ комментария клиента
──────────────────────────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to cycle)
EOF
cp "$SANDBOX/before.txt" "$SANDBOX/after.txt"
rm -f "$ENTER_FLAG"
set +e
INJECT_CONFIRM_TIMEOUT=3 "$BIN/session-inject" --timeout 5 claude-dept-head "$LONG" >/dev/null 2>&1
rc4=$?
set -e
[ "$rc4" -ne 0 ] || fail "перенесённая длинная строка засчитана доставленной — событие будет потеряно"

echo "PASS: tests/session-inject-confirm.test.sh (wrapped long line)"
