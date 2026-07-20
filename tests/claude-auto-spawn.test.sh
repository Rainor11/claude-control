#!/bin/bash
set -u
CA=/opt/projects/active/claude-control/bin/claude-auto
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export CLAUDE_CONTROL_DIR="$TMP/cc"
mkdir -p "$TMP/cwd"
echo "тестовая миссия" > "$TMP/mission.md"
printf '{"allow":["Bash(/bin/true:*)"],"deny":["Bash(curl:*)"]}' > "$TMP/bounds.json"

out="$("$CA" spawn --name p3-dry --cwd "$TMP/cwd" --mission-file "$TMP/mission.md" --bounds-file "$TMP/bounds.json" --dry-run)" || { echo "FAIL: dry-run упал"; exit 1; }
echo "$out" | grep -q '"origin_id": null'  || { echo "FAIL: нет origin_id null"; exit 1; }
echo "$out" | grep -q '"spawned": true'    || { echo "FAIL: нет spawned"; exit 1; }
echo "$out" | grep -q 'тестовая миссия'    || { echo "FAIL: миссия не в CLAUDE.md"; exit 1; }
[ -e "$TMP/cc/workers/p3-dry" ] && { echo "FAIL: dry-run создал файлы"; exit 1; }
# отказ без mission-file
"$CA" spawn --name p3-x --cwd "$TMP/cwd" --dry-run 2>/dev/null && { echo "FAIL: без миссии должен падать"; exit 1; }

# M6 (Codex-аудит): 'watchdog' зарезервировано системой — сторож пишет actor=watchdog в
# журнал (bin/dept-liveness-request, claude-auto-liveness), и dept-dispatcher/dept-inbox
# доверяют этой строке как признаку подлинности заявки liveness_restart. Воркер, реально
# названный 'watchdog', прошёл бы callerWorkerName() как ГЕНУИННЫЙ watchdog — не подделка.
wd_out="$("$CA" spawn --name watchdog --cwd "$TMP/cwd" --mission-file "$TMP/mission.md" --dry-run 2>&1)" \
  && { echo "FAIL: spawn --name watchdog прошёл (имя обязано быть зарезервировано)"; exit 1; }
echo "$wd_out" | command grep -q 'reserved' || { echo "FAIL: spawn --name watchdog отказал без пояснения про reserved: $wd_out"; exit 1; }
[ -e "$TMP/cc/workers/watchdog" ] && { echo "FAIL: spawn --name watchdog создал файлы несмотря на отказ"; exit 1; }

# adopt: тот же гейт, тот же список RESERVED_WORKER_NAMES — дохнет ДО обращения к origin-сессии
# (не нужен реальный --session, чек стоит раньше в файле, см. bin/claude-auto cmd_adopt).
wd_adopt_out="$("$CA" adopt --session nonexistent-fake-session --cwd "$TMP/cwd" --name watchdog 2>&1)" \
  && { echo "FAIL: adopt --name watchdog прошёл (имя обязано быть зарезервировано)"; exit 1; }
echo "$wd_adopt_out" | command grep -q 'reserved' || { echo "FAIL: adopt --name watchdog отказал без пояснения про reserved: $wd_adopt_out"; exit 1; }

echo "PASS claude-auto-spawn"
