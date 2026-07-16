#!/bin/bash
# tests/claude-auto-mission-update.test.sh — I-1 (ревью фазы 3): шов mission_change.
# cmd_mission_update пишет CLAUDE.md воркера + копию миссии ДО cmd_rebase; hard-die
# ребейза (STALE-гард) раньше ронял весь скрипт rc=1 → dept-mission-exec трактовал
# как полный провал (exec_failed), хотя миссия УЖЕ на диске и молча вступит при
# следующем старте. Теперь: rebase в субшелле, hard-провал → спецкод rc=4
# («миссия записана, rebase добить»), dept-mission-exec на rc=4 → успех с partial-note.
#
# Всё в изолированных tmp (CLAUDE_CONTROL_DIR/DEPT_HOME/HOME override — cmd_rebase ищет
# транскрипт в $HOME/.claude/projects); боевой флот/ledger не трогается, tmux не нужен
# (worker_busy: нет tmux-сессии → не busy). Паттерн — tests/claude-auto-spawn.test.sh.
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
CA="$DIR/bin/claude-auto"
ME="$DIR/bin/dept-mission-exec"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

export CLAUDE_CONTROL_DIR="$TMP/cc"
export DEPT_HOME="$TMP/dept"
export HOME="$TMP/home"   # изолирует ~/.claude/projects (поиск транскрипта STALE-гардом)
# Герметичность от ambient env: чужой CLAUDE_AUTO_STALE_SECONDS (>7200 или мусор) сломал бы
# STALE-имитацию — тест ушёл бы ДАЛЬШЕ гарда, в spec_rmw + systemctl start РЕАЛЬНОГО юнита
# claude-auto@w1 на хосте; чужой CLAUDE_AUTO_BIN подменил бы claude-auto в dept-mission-exec.
export CLAUDE_AUTO_STALE_SECONDS=1800
unset CLAUDE_AUTO_BIN

# ---- фикстура воркера + STALE-имитация -------------------------------------------------
# STALE по cmd_rebase (~1025): транскрипт $HOME/.claude/projects/*/<sid>.jsonl СВЕЖИЙ,
# memory-файлы в brain_path (timeline.md) старше на > CLAUDE_AUTO_STALE_SECONDS (1800с).
sid="11111111-2222-3333-4444-555555555555"
mkdir -p "$CLAUDE_CONTROL_DIR/workers/w1/state" "$TMP/cwd" "$TMP/brainpath" "$HOME/.claude/projects/-proj"
printf '{"session_id":"%s","cwd":"%s","seeded":true}\n' "$sid" "$TMP/cwd" > "$CLAUDE_CONTROL_DIR/workers/w1/spec.json"
printf '{"workers":{"w1":{"state":"active","brain_path":"%s"}}}\n' "$TMP/brainpath" > "$CLAUDE_CONTROL_DIR/autonomous.json"
touch "$HOME/.claude/projects/-proj/$sid.jsonl"        # транскрипт активен «сейчас»
touch -d '2 hours ago' "$TMP/brainpath/timeline.md"    # память курировалась 2ч назад (7200 > 1800)
echo "новая миссия w1 (смок rc=4)" > "$TMP/mission.md"

# ---- 1) claude-auto mission-update: STALE hard-die ребейза → rc=4, миссия записана ------
out="$("$CA" mission-update w1 --mission-file "$TMP/mission.md" --reason 'смок rc=4' 2>&1)"; rc=$?
[ "$rc" -eq 4 ] || fail "ожидался rc=4 (миссия записана, rebase упал hard), получен rc=$rc: $out"
grep -q 'новая миссия w1 (смок rc=4)' "$CLAUDE_CONTROL_DIR/workers/w1/CLAUDE.md" \
  || fail "миссия не записана в CLAUDE.md воркера"
grep -q 'новая миссия w1 (смок rc=4)' "$DEPT_HOME/missions/w1.md" \
  || fail "аудит-копия миссии не записана в \$DEPT_HOME/missions/w1.md"
echo "$out" | grep -q 'миссия ЗАПИСАНА' || fail "в stdout нет явного «миссия записана, вступит позже»: $out"
echo "$out" | grep -q 'STALE' || fail "в выводе нет причины hard-провала (STALE): $out"
# die случился ДО spec_rmw — session_id НЕ переписан (сессия воркера не тронута)
jq -e --arg s "$sid" '.session_id == $s' "$CLAUDE_CONTROL_DIR/workers/w1/spec.json" >/dev/null \
  || fail "rebase успел переписать session_id — hard-die должен случаться ДО пересборки сессии"
echo "OK: mission-update — rc=4, миссия на диске, сессия не тронута"

# ---- 2) dept-mission-exec: rc=4 от mission-update → exit 0 с partial-note ---------------
# Реальная цепочка (не мок): тот же STALE-фикстур, dept-mission-exec зовёт настоящий
# claude-auto mission-update → rc=4 → успех заявки с partial-note (раннер положит
# хвост stdout в approval-exec executed --note).
out3="$("$ME" --worker w1 --mission-file "$TMP/mission.md" --reason 'смок exec rc=4' 2>&1)"; rc3=$?
[ "$rc3" -eq 0 ] || fail "dept-mission-exec на rc=4 должен вернуть 0 (executed с note), получен rc=$rc3: $out3"
echo "$out3" | grep -q 'partial: миссия записана' || fail "нет partial-note в stdout dept-mission-exec: $out3"
echo "$out3" | grep -q 'mission-exec complete: w1' || fail "нет маркера успеха mission-exec: $out3"
echo "OK: dept-mission-exec — rc=4 → executed с явной partial-note"

# ---- 3) dept-mission-exec: прочие hard-коды (rc=1) по-прежнему полный провал ------------
FAKE_CA="$TMP/fake-ca-rc1"
printf '#!/bin/bash\necho "boom"\nexit 1\n' > "$FAKE_CA"; chmod +x "$FAKE_CA"
out4="$(CLAUDE_AUTO_BIN="$FAKE_CA" "$ME" --worker w1 --mission-file "$TMP/mission.md" --reason 'смок rc=1' 2>&1)"; rc4=$?
[ "$rc4" -ne 0 ] || fail "dept-mission-exec на rc=1 обязан падать (exec_failed), а вернул 0: $out4"
echo "$out4" | grep -q 'rc=1' || fail "нет rc в сообщении об ошибке: $out4"
echo "OK: dept-mission-exec — rc=1 остаётся полным провалом"

# ---- 4) rc=3 (busy) → отложенный rebase падает hard → partial-успех, НЕ exec_failed -----
# Багхант 16.07: миссия применена ДО ретраев — hard-провал ретрая раньше делал die →
# exec_failed (та же ложь аудита, что чинил I-1 на прямом пути). MISSION_RETRY_SLEEP=0 —
# тест-шов (зеркало PLANERKA_RETRY_SLEEP).
FAKE_CA_BUSY="$TMP/fake-ca-busy"
cat > "$FAKE_CA_BUSY" <<'EOF'
#!/bin/bash
case "$1" in
  mission-update) echo "мок: миссия записана, rebase ОТЛОЖЕН (busy)"; exit 3 ;;
  rebase)         echo "мок: rebase hard-fail (STALE)"; exit 1 ;;
  *)              echo "мок: неожиданный вызов $1"; exit 9 ;;
esac
EOF
chmod +x "$FAKE_CA_BUSY"
out5="$(CLAUDE_AUTO_BIN="$FAKE_CA_BUSY" MISSION_RETRY_SLEEP=0 "$ME" --worker w1 --mission-file "$TMP/mission.md" --reason 'смок busy→hard' 2>&1)"; rc5=$?
[ "$rc5" -eq 0 ] || fail "dept-mission-exec на busy→hard-rebase должен вернуть 0 (partial), получен rc=$rc5: $out5"
echo "$out5" | grep -q 'partial: миссия записана' || fail "нет partial-note в busy→hard пути: $out5"
echo "OK: dept-mission-exec — busy→hard-rebase = partial-успех, не exec_failed"

echo "PASS claude-auto-mission-update (I-1: rc=4 шов mission_change)"
