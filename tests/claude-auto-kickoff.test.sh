#!/bin/bash
# tests/claude-auto-kickoff.test.sh — стартовое сообщение (kickoff) доставляется РОВНО ОДИН РАЗ.
#
# Инцидент 20.07 (mws-ariadna): при переводе воркера в отдел одна пересборка дала ДВА
# одинаковых стартовых сообщения. В журнале ровно один rebase — проблема в ДОСТАВКЕ:
# session-inject не успевал увидеть начало хода на холодной сессии (MCP-серверы), возвращал
# ненулевой код, и цикл доставки печатал тот же текст ещё раз. Для найма это опаснее, чем для
# пересборки: стартовое сообщение новичка просит наполнить папку клиента из Asana — повтор
# означает двойной ingest.
#
# Контракт: повтор делается ТОЛЬКО если предыдущая попытка действительно не доставила.
# Механическое доказательство доставки — транскрипт сессии (он создаётся на первом ходе, а
# session_id у rebase/spawn всегда новый), а не код возврата инжектора.
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bootstrap.sh"
CA="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/claude-auto"
CC="$CLAUDE_CONTROL_TEST_ROOT"
fail() { echo "FAIL: $*"; exit 1; }

W="$CC/workers/kick1"
mkdir -p "$W/state" "$CC/stubs" "$CC/transcripts"
printf '{"session_id":"sid-старый","cwd":"/tmp","permission_mode":"acceptEdits","seeded":true}\n' > "$W/spec.json"
echo '{"workers":{"kick1":{"state":"active"}}}' > "$CC/autonomous.json"
export XDG_RUNTIME_DIR="$CC"           # локи session-inject — в песочницу, не к боевому флоту
export CLAUDE_AUTO_TEST_TRANSCRIPTS_DIR="$CC/transcripts"
export CLAUDE_AUTO_KICKOFF_ATTEMPTS=3  # короче боевых десяти — тест не должен идти минуту
export CLAUDE_AUTO_KICKOFF_RETRY_PAUSE=2
export INJECT_LOG="$CC/inject-calls.log"
export WORKER_SPEC="$W/spec.json"

# Заглушка инжектора: имитирует ЛОЖНЫЙ ПРОВАЛ — текст доставлен (ход записан в транскрипт
# ровно так, как это делает Claude: файл по session_id из спека), но код возврата ненулевой.
cat > "$CC/stubs/inject-false-negative" <<'EOF'
#!/bin/bash
{ printf 'call'; for a in "$@"; do printf '\t%s' "$a"; done; printf '\n'; } >> "$INJECT_LOG"
sid="$(jq -r '.session_id' "$WORKER_SPEC")"
mkdir -p "$CLAUDE_AUTO_TEST_TRANSCRIPTS_DIR/-tmp"
printf '{"type":"user","message":%s}\n' "$(printf '%s' "${!#}" | jq -Rs .)" \
  >> "$CLAUDE_AUTO_TEST_TRANSCRIPTS_DIR/-tmp/$sid.jsonl"
exit 1
EOF

# Заглушка инжектора: доставки НЕТ вовсе (транскрипт пуст) — честный провал.
cat > "$CC/stubs/inject-never" <<'EOF'
#!/bin/bash
{ printf 'call'; for a in "$@"; do printf '\t%s' "$a"; done; printf '\n'; } >> "$INJECT_LOG"
exit 1
EOF

# Заглушка инжектора: rc=4 — у хоста протух логин, в панель НИЧЕГО не напечатано.
cat > "$CC/stubs/inject-auth" <<'EOF'
#!/bin/bash
{ printf 'call'; for a in "$@"; do printf '\t%s' "$a"; done; printf '\n'; } >> "$INJECT_LOG"
exit 4
EOF
chmod +x "$CC/stubs/inject-false-negative" "$CC/stubs/inject-never" "$CC/stubs/inject-auth"

calls() { command grep -c '^call' "$INJECT_LOG" 2>/dev/null || echo 0; }

# ---------------------------------------------------------------------------------------
# 1. ЛОЖНЫЙ ПРОВАЛ (тот самый баг): инжектор вернул ошибку, но ход реально начался.
#    Повтора быть НЕ должно, доставка обязана быть засчитана.
# ---------------------------------------------------------------------------------------
: > "$INJECT_LOG"
out="$(CLAUDE_AUTO_TEST_INJECT_BIN="$CC/stubs/inject-false-negative" "$CA" rebase kick1 --reason "тест" 2>&1)" \
  || fail "rebase упал: $out"
n="$(calls)"
[ "$n" -eq 1 ] || fail "ложный провал: стартовое сообщение напечатано $n раз(а) вместо одного — дубль жив: $out"
command grep -q 'kickoff delivered=true' <<<"$out" || fail "доставка не засчитана, хотя ход записан в транскрипт: $out"
command grep -q 'подтверждена по транскрипту' <<<"$out" || fail "нет следа механической проверки доставки: $out"

# Маркер kickoff-id обязан быть и в тексте (страховка получателя от дубля), и в транскрипте.
command grep -q 'kickoff-id: ' "$INJECT_LOG" || fail "в стартовом сообщении нет маркера kickoff-id: $(cat "$INJECT_LOG")"

# ---------------------------------------------------------------------------------------
# 2. ЧЕСТНЫЙ ПРОВАЛ: доставки не было — повторы обязаны идти (иначе воркер останется без
#    стартового контекста и мы это молча проглотим).
#    Проверка «ВНИМАНИЕ» здесь заодно держит РЕГРЕССИЮ по stderr: `exec 8>файл 2>/dev/null`
#    без команды глушил stderr всего процесса claude-auto после первой же записи спека, и
#    предупреждение о недоставленном kickoff не доходило до оператора вовсе (см. spec_rmw).
# ---------------------------------------------------------------------------------------
: > "$INJECT_LOG"
out2="$(CLAUDE_AUTO_TEST_INJECT_BIN="$CC/stubs/inject-never" "$CA" rebase kick1 --reason "тест2" 2>&1)" \
  || fail "rebase упал: $out2"
n2="$(calls)"
[ "$n2" -eq 3 ] || fail "честный провал: ожидалось 3 попытки (CLAUDE_AUTO_KICKOFF_ATTEMPTS), получено $n2"
command grep -q 'kickoff delivered=false' <<<"$out2" || fail "недоставленный kickoff обязан быть виден как delivered=false: $out2"
command grep -q 'ВНИМАНИЕ' <<<"$out2" || fail "нет предупреждения оператору о недоставленном kickoff: $out2"

# ---------------------------------------------------------------------------------------
# 3. rc=4 (протух логин хоста): в панель ничего не напечатано и не будет — долбиться
#    десять раз бессмысленно, выходим с первой попытки и говорим оператору про /login.
# ---------------------------------------------------------------------------------------
: > "$INJECT_LOG"
out3="$(CLAUDE_AUTO_TEST_INJECT_BIN="$CC/stubs/inject-auth" "$CA" rebase kick1 --reason "тест3" 2>&1)" \
  || fail "rebase упал: $out3"
n3="$(calls)"
[ "$n3" -eq 1 ] || fail "auth-blocked: ожидалась 1 попытка, получено $n3"
command grep -q 'логин' <<<"$out3" || fail "нет объяснения про протухший логин: $out3"

# ---------------------------------------------------------------------------------------
# 3a. ЩЕЛЬ МЕЖДУ ПРОВЕРКОЙ И ПОВТОРОМ (находка Codex 23.07). Инжектор вернул провал, ход в
#     сессии ИДЁТ, а маркер в транскрипт ещё не записан. Наивная реализация проверила бы
#     транскрипт (пусто) и напечатала текст второй раз ПОВЕРХ идущего хода — тот самый дубль.
#     Контракт: пока сессия занята, повтора нет; маркер, появившийся за время хода, засчитан.
# ---------------------------------------------------------------------------------------
: > "$INJECT_LOG"
export BUSY_UNTIL_FLAG="$CC/busy-cleared"
export LATE_MARKER_SPEC="$W/spec.json"
rm -f "$BUSY_UNTIL_FLAG"
# Инжектор: НИЧЕГО не пишет в транскрипт и возвращает провал; вместо этого «оставляет
# сессию занятой» — маркер запишется только когда tmux-заглушка отдаст idle.
cat > "$CC/stubs/inject-late" <<'EOF'
#!/bin/bash
{ printf 'call'; for a in "$@"; do printf '\t%s' "$a"; done; printf '\n'; } >> "$INJECT_LOG"
printf '%s\n' "${!#}" > "$CC_LATE_PAYLOAD"
exit 1
EOF
chmod +x "$CC/stubs/inject-late"
export CC_LATE_PAYLOAD="$CC/late-payload.txt"
# tmux-заглушка: 1-й capture — предстартовая проверка самого rebase (обязан быть idle, иначе
# пересборка вообще откладывается); 2-3-й — «идёт ход» (наш kickoff стартовал позже окна
# подтверждения); дальше сессия свободна, и ровно в этот момент в транскрипт попадает маркер
# из payload'а — как это и делает настоящий Claude, дописывающий пользовательский ход.
cat > "$CC/stubs/tmux-busy-then-idle" <<'EOF'
#!/bin/bash
for a in "$@"; do
  case "$a" in
    has-session) exit 0 ;;
    capture-pane)
      n=$(( $(cat "$CC/busy-count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$CC/busy-count"
      if [ "$n" -ge 2 ] && [ "$n" -le 3 ]; then echo "  126 tokens · esc to interrupt"; exit 0; fi
      [ "$n" -eq 1 ] && exit 0
      sid="$(jq -r '.session_id' "$LATE_MARKER_SPEC")"
      mkdir -p "$CLAUDE_AUTO_TEST_TRANSCRIPTS_DIR/-tmp"
      printf '{"type":"user","message":%s}\n' "$(jq -Rs . < "$CC_LATE_PAYLOAD")" \
        >> "$CLAUDE_AUTO_TEST_TRANSCRIPTS_DIR/-tmp/$sid.jsonl"
      exit 0 ;;
  esac
done
exit 0
EOF
chmod +x "$CC/stubs/tmux-busy-then-idle"
rm -f "$CC/busy-count"
export CC   # заглушке tmux нужен путь песочницы; отдельным export, а не префиксом команды
out3a="$(CLAUDE_AUTO_TEST_INJECT_BIN="$CC/stubs/inject-late" TMUX_BIN="$CC/stubs/tmux-busy-then-idle" \
  "$CA" rebase kick1 --reason "тест3a" 2>&1)" || fail "rebase упал: $out3a"
n3a="$(calls)"
[ "$n3a" -eq 1 ] || fail "щель TOCTOU: текст напечатан $n3a раз(а) — повтор ушёл поверх идущего хода"
command grep -q 'подтверждена по транскрипту' <<<"$out3a" || fail "поздний маркер не засчитан как доставка: $out3a"

# ---------------------------------------------------------------------------------------
# 4. Общий бюджет времени: пересборку по заявке dept-exec-runner убивает по `timeout 15m`.
#    Доставка обязана сдаться САМА и сказать об этом, а не попасть под SIGKILL посреди
#    вставки (после которого непонятно, доставлено сообщение или нет).
# ---------------------------------------------------------------------------------------
: > "$INJECT_LOG"
out4="$(CLAUDE_AUTO_KICKOFF_DEADLINE=1 CLAUDE_AUTO_TEST_INJECT_BIN="$CC/stubs/inject-never" \
  "$CA" rebase kick1 --reason "тест4" 2>&1)" || fail "rebase упал: $out4"
n4="$(calls)"
[ "$n4" -eq 1 ] || fail "бюджет доставки не соблюдён: ожидалась 1 попытка, получено $n4"
command grep -q 'бюджет' <<<"$out4" || fail "нет следа исчерпанного бюджета доставки: $out4"

# ---------------------------------------------------------------------------------------
# 5. Шов подмены инжектора работает ТОЛЬКО под тестовым маркером — иначе это дыра в бою.
#    Проверяем на самом резолвере: без CLAUDE_CONTROL_TEST_ROOT переменная игнорируется.
# ---------------------------------------------------------------------------------------
command grep -q 'CLAUDE_AUTO_TEST_INJECT_BIN' "$CA" || fail "шов исчез из claude-auto"
command grep -A3 'CLAUDE_AUTO_TEST_INJECT_BIN' "$CA" | command grep -q '_process_control_test_root' \
  || command grep -B8 'CLAUDE_AUTO_TEST_INJECT_BIN' "$CA" | command grep -q '_process_control_test_root' \
  || fail "шов подмены инжектора не гейтирован тестовым маркером — в бою его можно подменить переменной окружения"

# ---------------------------------------------------------------------------------------
# 6. РЕПОЗИТОРНЫЙ ЛИНТ на тот самый капкан. `exec N>файл 2>/dev/null` БЕЗ команды глушит
#    stderr всего процесса навсегда — и это не теория: так пропадало предупреждение о
#    недоставленном kickoff (bin/claude-auto) и все die-сообщения после взятия лока
#    (bin/claude-auto-self-probes: воркер получал пустой отказ с кодом 1). Лечится обёрткой
#    в фигурные скобки. Проверяем ВЕСЬ bin/, чтобы капкан не вернулся новым файлом.
# ---------------------------------------------------------------------------------------
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bad="$(command grep -rn 'exec [0-9]*>' "$REPO/bin" 2>/dev/null \
  | command grep '2>/dev/null' \
  | command grep -v '{ exec' \
  | command grep -vE ':[0-9]+:[[:space:]]*#' || true)"   # строки-комментарии (описывают сам капкан) — не код
[ -z "$bad" ] || fail "exec-перенаправление без фигурных скобок глушит stderr всего процесса:
$bad"

echo "PASS claude-auto-kickoff"
