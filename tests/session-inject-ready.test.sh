#!/bin/bash
# tests/session-inject-ready.test.sh — --await-ready: не печатать в ПОЛУСОБРАННЫЙ TUI.
#
# Поймано вживую 20.07 (mws-ariadna): пересборка воркера дала ДВА одинаковых стартовых
# сообщения при одном rebase. Механика — вызывающий ждал только появления tmux-сессии, то
# есть «терминал поднялся», а не «Claude готов принимать ввод»: вставка уходила в ещё
# грузящуюся сессию (подключение MCP-серверов), ход стартовал позже окна подтверждения,
# session-inject возвращал провал, и цикл доставки печатал текст второй раз.
#
# Контракт: с --await-ready N инжектор НЕ трогает панель, пока на экране нет признака
# готовности (рамка ввода/строка режима/идущий ход), но и не отменяет доставку, если признак
# так и не появился за N секунд (fail-open — худший случай равен прежнему поведению).
set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bootstrap.sh"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*"; exit 1; }

SANDBOX="$CLAUDE_CONTROL_TEST_ROOT/sandbox-ready"
BIN="$SANDBOX/bin"
mkdir -p "$BIN"
cp "$DIR/bin/session-inject" "$BIN/"

MSG="Стартовое сообщение воркера"
export SANDBOX MSG
export ENTER_FLAG="$SANDBOX/enter-pressed"
export READY_FLAG="$SANDBOX/tui-ready"
export CAPTURES="$SANDBOX/capture-count"
export TYPED_EARLY="$SANDBOX/typed-early"

# Экран ГРУЗЯЩЕЙСЯ сессии: tmux-окно уже есть, рамки ввода и строки режима ещё нет.
cat > "$SANDBOX/loading.txt" <<'EOF'
  ✻ Claude Code
  Connecting to MCP servers…
EOF

# Готовый TUI с payload в поле ввода.
cat > "$SANDBOX/before.txt" <<EOF
  предыдущий вывод воркера
──────────────────────────────────────── mws-ariadna ──
❯ $MSG
────────────────────────────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to cycle)
EOF

# После Enter: payload уехал в транскрипт, поле ввода пустое.
cat > "$SANDBOX/after.txt" <<EOF
  предыдущий вывод воркера

❯ $MSG

✽ Doodling… (2s)
──────────────────────────────────────── mws-ariadna ──
❯
────────────────────────────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to cycle)
EOF

# Фейковый tmux. Готовность наступает с 3-го capture-pane. Любая печать (load-buffer/
# paste-buffer/send-keys) ДО готовности отмечается флагом — это и есть нарушение контракта.
cat > "$BIN/tmux" <<'EOF'
#!/bin/bash
args="$*"
case "$args" in
  *has-session*) exit 0 ;;
  *list-panes*) echo "1 %0"; exit 0 ;;
  *capture-pane*)
    n=$(( $(cat "$CAPTURES" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$CAPTURES"
    if [ "${READY_AT:-3}" != "never" ] && [ "$n" -ge "${READY_AT:-3}" ]; then : > "$READY_FLAG"; fi
    if [ -f "$ENTER_FLAG" ]; then cat "$SANDBOX/after.txt"
    elif [ -f "$READY_FLAG" ]; then cat "$SANDBOX/before.txt"
    else cat "$SANDBOX/loading.txt"; fi
    exit 0 ;;
  *load-buffer*|*paste-buffer*|*send-keys*)
    [ -f "$READY_FLAG" ] || : > "$TYPED_EARLY"
    case "$args" in *send-keys*Enter*) : > "$ENTER_FLAG" ;; esac
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$BIN/tmux"
export PATH="$BIN:$PATH"

reset_state() { rm -f "$ENTER_FLAG" "$READY_FLAG" "$CAPTURES" "$TYPED_EARLY"; }

# ---------------------------------------------------------------------------------------
# 1. Сессия грузится: инжектор ЖДЁТ готовности и только потом печатает.
# ---------------------------------------------------------------------------------------
reset_state
set +e
READY_AT=3 "$BIN/session-inject" --await-ready 20 --confirm-timeout 3 --timeout 20 \
  claude-mws-ariadna "$MSG" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "готовый TUI: доставка обязана пройти (rc=$rc)"
[ -f "$TYPED_EARLY" ] && fail "инжектор напечатал в НЕГОТОВЫЙ TUI — ровно та вставка, что даёт дубль стартового сообщения"

# ---------------------------------------------------------------------------------------
# 2. Признак готовности так и не появился → fail-open: печатаем как раньше, доставка идёт.
#    (Ошибка в паттерне готовности обязана стоить ожидания, а не потери доставки.)
# ---------------------------------------------------------------------------------------
reset_state
set +e
out2="$(READY_AT=never "$BIN/session-inject" --await-ready 2 --confirm-timeout 3 --timeout 20 \
  claude-mws-ariadna "$MSG" 2>&1)"
rc2=$?
set -e
[ "$rc2" -eq 0 ] || fail "fail-open сломан: без признака готовности доставка отменилась (rc=$rc2): $out2"
command grep -q "fail-open" <<<"$out2" || fail "нет предупреждения о fail-open — молчаливое ожидание не отладить: $out2"

# ---------------------------------------------------------------------------------------
# 3. Без --await-ready поведение прежнее: печатаем сразу, готовности не ждём (флот из 20+
#    воркеров не должен получить новую задержку на каждом событии датчика).
# ---------------------------------------------------------------------------------------
reset_state
set +e
READY_AT=never "$BIN/session-inject" --confirm-timeout 3 --timeout 20 claude-mws-ariadna "$MSG" >/dev/null 2>&1
rc3=$?
set -e
[ "$rc3" -eq 0 ] || fail "дефолтный путь (без --await-ready) обязан работать как раньше (rc=$rc3)"
[ -f "$TYPED_EARLY" ] || fail "без --await-ready инжектор обязан печатать не дожидаясь признака готовности"

# ---------------------------------------------------------------------------------------
# 4. Нечисловой параметр — явная ошибка вызова (exit 2), а не «доставлено»/зависание.
# ---------------------------------------------------------------------------------------
reset_state
set +e
"$BIN/session-inject" --await-ready abc claude-mws-ariadna "$MSG" >/dev/null 2>&1; rc4=$?
"$BIN/session-inject" --confirm-timeout 10s claude-mws-ariadna "$MSG" >/dev/null 2>&1; rc5=$?
set -e
[ "$rc4" -eq 2 ] || fail "--await-ready abc: ожидался exit 2, получен $rc4"
[ "$rc5" -eq 2 ] || fail "--confirm-timeout 10s: ожидался exit 2, получен $rc5"

echo "PASS: tests/session-inject-ready.test.sh"
