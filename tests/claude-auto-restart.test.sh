#!/bin/bash
# tests/claude-auto-restart.test.sh — cmd_restart: машинный контракт DEFERRED (exit 3 при
# busy — потребители: RC-сторож claude-auto-liveness и кнопка бота wl:rstc) и сериализация
# с session-inject (flock на ТОТ ЖЕ per-target lock-файл: busy-check + stop — одна
# критическая секция, injector под локом не даст убить tmux под печатающейся вставкой).
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bootstrap.sh"
CA="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/claude-auto"
CC="$CLAUDE_CONTROL_TEST_ROOT"

fail() { echo "FAIL: $1"; exit 1; }

W="$CC/workers/rst1"
mkdir -p "$W/state" "$CC/stubs"
printf '{"session_id":"s-1","cwd":"/tmp","permission_mode":"acceptEdits","seeded":false}\n' > "$W/spec.json"
echo '{"workers":{"rst1":{"state":"active"}}}' > "$CC/autonomous.json"
# Лок-файл session-inject живёт в ${XDG_RUNTIME_DIR:-/tmp} — уводим в песочницу, чтобы
# тест не трогал боевые локи (и боевой флот — тестовые).
export XDG_RUNTIME_DIR="$CC"

# ---------------------------------------------------------------------------------------
# 1. Незнакомый воркер → die (exit 1).
# ---------------------------------------------------------------------------------------
"$CA" restart no-such >/dev/null 2>&1 && fail "restart несуществующего обязан падать"
rc=$?; [ "$rc" -eq 1 ] || fail "restart несуществующего: ожидался exit 1, получен $rc"

# ---------------------------------------------------------------------------------------
# 2. busy (ход идёт / промпт открыт) → DEFERRED, exit 3, stop/start НЕ вызваны.
# ---------------------------------------------------------------------------------------
cat > "$CC/stubs/tmux-busy" <<'EOF'
#!/bin/bash
for a in "$@"; do
  case "$a" in
    has-session) exit 0 ;;
    capture-pane) echo "  126 tokens · esc to interrupt"; exit 0 ;;
  esac
done
exit 0
EOF
chmod +x "$CC/stubs/tmux-busy"
: > "$STUB_LOG"
out="$(TMUX_BIN="$CC/stubs/tmux-busy" "$CA" restart rst1 2>&1)"
rc=$?
[ "$rc" -eq 3 ] || fail "busy → ожидался exit 3 (DEFERRED), получен $rc: $out"
grep -q "DEFERRED" <<<"$out" || fail "busy-ответ обязан содержать DEFERRED: $out"
grep -q "disable" "$STUB_LOG" && fail "busy: cmd_stop не должен был вызываться: $(cat "$STUB_LOG")"
[ "$(jq -r '.workers.rst1.state' "$CC/autonomous.json")" = "active" ] || fail "busy: state не должен меняться"

# ---------------------------------------------------------------------------------------
# 3. Лок session-inject занят (доставка события в процессе) → DEFERRED, exit 3.
#    flock -w 5 в cmd_restart не дожидается — держим лок дольше.
# ---------------------------------------------------------------------------------------
lock="$XDG_RUNTIME_DIR/.session-inject.claude-rst1.lock"
(
  exec 9>"$lock"
  flock 9
  sleep 20
) &
holder=$!
# дождаться, пока держатель реально возьмёт лок (иначе гонка с flock -w 5)
for _ in $(seq 1 50); do
  flock -n "$lock" -c true 2>/dev/null || break
  sleep 0.1
done
: > "$STUB_LOG"
out="$("$CA" restart rst1 2>&1)"
rc=$?
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
[ "$rc" -eq 3 ] || fail "занятый лок → ожидался exit 3, получен $rc: $out"
grep -q "disable" "$STUB_LOG" && fail "занятый лок: cmd_stop не должен был вызываться"

# ---------------------------------------------------------------------------------------
# 3b. Не-active воркер (спит/остановлен) → exit 4, НЕ будим (restart не отменяет решение
#     оператора; разбудить — это start).
# ---------------------------------------------------------------------------------------
jq '.workers.rst1.state = "sleeping"' "$CC/autonomous.json" > "$CC/autonomous.json.tmp" \
  && mv "$CC/autonomous.json.tmp" "$CC/autonomous.json"
: > "$STUB_LOG"
out="$("$CA" restart rst1 2>&1)"
rc=$?
[ "$rc" -eq 4 ] || fail "sleeping → ожидался exit 4, получен $rc: $out"
grep -qE 'disable|enable' "$STUB_LOG" && fail "sleeping: никакие systemctl-действия недопустимы: $(cat "$STUB_LOG")"
[ "$(jq -r '.workers.rst1.state' "$CC/autonomous.json")" = "sleeping" ] || fail "sleeping: state не должен меняться"
jq '.workers.rst1.state = "active"' "$CC/autonomous.json" > "$CC/autonomous.json.tmp" \
  && mv "$CC/autonomous.json.tmp" "$CC/autonomous.json"

# ---------------------------------------------------------------------------------------
# 4. idle → exit 0: stop (disable --now + kill-session) затем start (enable --now),
#    финальный state=active. Дефолтные заглушки раннера: has-session=0, capture-pane пуст.
# ---------------------------------------------------------------------------------------
: > "$STUB_LOG"
out="$("$CA" restart rst1 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "idle → ожидался exit 0, получен $rc: $out"
grep -q $'disable\t--now\tclaude-auto@rst1.service' "$STUB_LOG" || fail "нет disable --now в: $(cat "$STUB_LOG")"
grep -q $'kill-session' "$STUB_LOG" || fail "нет tmux kill-session в: $(cat "$STUB_LOG")"
grep -q $'enable\t--now\tclaude-auto@rst1.service' "$STUB_LOG" || fail "нет enable --now в: $(cat "$STUB_LOG")"
# порядок: stop раньше start
d_line="$(grep -n 'disable' "$STUB_LOG" | head -1 | cut -d: -f1)"
e_line="$(grep -n 'enable' "$STUB_LOG" | grep -v disable | head -1 | cut -d: -f1)"
[ -n "$d_line" ] && [ -n "$e_line" ] && [ "$d_line" -lt "$e_line" ] || fail "stop обязан идти раньше start: $(cat "$STUB_LOG")"
[ "$(jq -r '.workers.rst1.state' "$CC/autonomous.json")" = "active" ] || fail "после restart state обязан быть active"

echo "OK: claude-auto-restart"
