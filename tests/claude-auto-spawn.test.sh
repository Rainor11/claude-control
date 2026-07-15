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
echo "PASS claude-auto-spawn"
