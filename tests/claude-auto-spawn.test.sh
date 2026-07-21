#!/bin/bash
# tests/claude-auto-spawn.test.sh — смок claude-auto spawn/adopt (dry-run + зарезервированные
# имена). T6: переведён на песочницу раннера. Было `CLAUDE_CONTROL_DIR="$(mktemp -d)/cc"` —
# путь СНАРУЖИ тестового корня, из-за чего резолвер T1 законно отказывал («утечка боевого
# окружения в тест»). Стало: корень задаёт раннер (CLAUDE_CONTROL_TEST_ROOT), тест его не
# переопределяет вовсе, а рабочие файлы кладёт в scratch/ внутри той же песочницы — раннер
# уберёт её сам, свой trap не нужен.
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bootstrap.sh"
CA="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/claude-auto"
# CC — то, что claude-auto получит от резолвера для профиля control_only под маркером.
CC="$CLAUDE_CONTROL_TEST_ROOT"
TMP="$CLAUDE_CONTROL_TEST_ROOT/scratch"
mkdir -p "$TMP/cwd"
echo "тестовая миссия" > "$TMP/mission.md"
printf '{"allow":["Bash(/bin/true:*)"],"deny":["Bash(curl:*)"]}' > "$TMP/bounds.json"

out="$("$CA" spawn --name p3-dry --cwd "$TMP/cwd" --mission-file "$TMP/mission.md" --bounds-file "$TMP/bounds.json" --dry-run)" || { echo "FAIL: dry-run упал"; exit 1; }
echo "$out" | grep -q '"origin_id": null'  || { echo "FAIL: нет origin_id null"; exit 1; }
echo "$out" | grep -q '"spawned": true'    || { echo "FAIL: нет spawned"; exit 1; }
echo "$out" | grep -q 'тестовая миссия'    || { echo "FAIL: миссия не в CLAUDE.md"; exit 1; }
[ -e "$CC/workers/p3-dry" ] && { echo "FAIL: dry-run создал файлы"; exit 1; }
# отказ без mission-file
"$CA" spawn --name p3-x --cwd "$TMP/cwd" --dry-run 2>/dev/null && { echo "FAIL: без миссии должен падать"; exit 1; }

# M6 (Codex-аудит): 'watchdog' зарезервировано системой — сторож пишет actor=watchdog в
# журнал (bin/dept-liveness-request, claude-auto-liveness), и dept-dispatcher/dept-inbox
# доверяют этой строке как признаку подлинности заявки liveness_restart. Воркер, реально
# названный 'watchdog', прошёл бы callerWorkerName() как ГЕНУИННЫЙ watchdog — не подделка.
wd_out="$("$CA" spawn --name watchdog --cwd "$TMP/cwd" --mission-file "$TMP/mission.md" --dry-run 2>&1)" \
  && { echo "FAIL: spawn --name watchdog прошёл (имя обязано быть зарезервировано)"; exit 1; }
echo "$wd_out" | command grep -q 'reserved' || { echo "FAIL: spawn --name watchdog отказал без пояснения про reserved: $wd_out"; exit 1; }
[ -e "$CC/workers/watchdog" ] && { echo "FAIL: spawn --name watchdog создал файлы несмотря на отказ"; exit 1; }

# adopt: тот же гейт, тот же список RESERVED_WORKER_NAMES — дохнет ДО обращения к origin-сессии
# (не нужен реальный --session, чек стоит раньше в файле, см. bin/claude-auto cmd_adopt).
wd_adopt_out="$("$CA" adopt --session nonexistent-fake-session --cwd "$TMP/cwd" --name watchdog 2>&1)" \
  && { echo "FAIL: adopt --name watchdog прошёл (имя обязано быть зарезервировано)"; exit 1; }
echo "$wd_adopt_out" | command grep -q 'reserved' || { echo "FAIL: adopt --name watchdog отказал без пояснения про reserved: $wd_adopt_out"; exit 1; }

echo "PASS claude-auto-spawn"
