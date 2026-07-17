#!/bin/bash
# claude-auto integration for the asana-project adapter: set-probes
# normalization (--state-dir forcing), duplicate-project rejection, sleep
# baseline warning, rename .seen migration, removal state cleanup.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
CA="$DIR/bin/claude-auto"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_CONTROL_DIR="$TMP/cc"
W="$TMP/cc/workers/testw"
mkdir -p "$W/state" "$W/logs"
echo '{"workers":{"testw":{"state":"stopped"}}}' > "$TMP/cc/autonomous.json"
echo '{"session_id":"x","cwd":"/tmp","permission_mode":"auto"}' > "$W/spec.json"
STATE="$W/state"

# 1) normalization: canonical adapter path + forced per-worker --state-dir
cat > "$TMP/p1.json" <<'EOF'
{"probes":[{"name":"proj-a","source":"asana","interval_sec":900,"timeout_sec":120,
  "cmd":["asana-project","--project","111","--state-dir","/evil"]}]}
EOF
"$CA" set-probes testw "$TMP/p1.json" >/dev/null
jq -e --arg sd "$STATE" '.probes[0].cmd | (.[0] | endswith("/adapters/asana-project")) and (index("--state-dir") != null) and (.[index("--state-dir")+1] == $sd)' \
  "$W/event-bridge.config.json" >/dev/null || { echo 'FAIL: normalization broken'; exit 1; }

# 2) duplicate project rejected (operator path)
cat > "$TMP/p2.json" <<'EOF'
{"probes":[
 {"name":"proj-a","source":"asana","interval_sec":900,"cmd":["asana-project","--project","111"]},
 {"name":"proj-b","source":"asana","interval_sec":900,"cmd":["asana-project","--project","111"]}]}
EOF
"$CA" set-probes testw "$TMP/p2.json" >/dev/null 2>&1 && { echo 'FAIL: duplicate project accepted'; exit 1; }
# 2b) repeated --project must not bypass the guard (adapter is last-wins)
cat > "$TMP/p2b.json" <<'EOF'
{"probes":[
 {"name":"proj-a","source":"asana","interval_sec":900,"cmd":["asana-project","--project","111","--project","222"]},
 {"name":"proj-b","source":"asana","interval_sec":900,"cmd":["asana-project","--project","222"]}]}
EOF
"$CA" set-probes testw "$TMP/p2b.json" >/dev/null 2>&1 && { echo 'FAIL: repeated --project bypassed dup guard'; exit 1; }
# ...but two DIFFERENT projects are fine
cat > "$TMP/p3.json" <<'EOF'
{"probes":[
 {"name":"proj-a","source":"asana","interval_sec":900,"cmd":["asana-project","--project","111"]},
 {"name":"proj-c","source":"asana","interval_sec":900,"cmd":["asana-project","--project","222"]}]}
EOF
"$CA" set-probes testw "$TMP/p3.json" >/dev/null || { echo 'FAIL: two different projects rejected'; exit 1; }

# 3) sleep warning: fires without snapshot, silent with it
warn="$("$CA" sleep testw 2>&1 | grep -c 'ВНИМАНИЕ' || true)"
[ "$warn" = 2 ] || { echo "FAIL: expected 2 baseline warnings (both projects), got $warn"; exit 1; }
touch "$STATE/.asana-project-111.snapshot.json" "$STATE/.asana-project-222.snapshot.json"
warn="$("$CA" sleep testw 2>&1 | grep -c 'ВНИМАНИЕ' || true)"
[ "$warn" = 0 ] || { echo "FAIL: warning with snapshot present"; exit 1; }

# 4) RENAME: .seen migrates to the successor, project state survives
printf 'g:one\ng:two\n' > "$STATE/proj-a.seen"
printf 'g:two\ng:three\n' > "$STATE/proj-renamed.seen.pre"  # will become successor's existing seen
cat > "$TMP/p4.json" <<'EOF'
{"probes":[
 {"name":"proj-renamed","source":"asana","interval_sec":900,"cmd":["asana-project","--project","111"]},
 {"name":"proj-c","source":"asana","interval_sec":900,"cmd":["asana-project","--project","222"]}]}
EOF
mv "$STATE/proj-renamed.seen.pre" "$STATE/proj-renamed.seen"
"$CA" set-probes testw "$TMP/p4.json" >/dev/null
[ -f "$STATE/proj-a.seen" ] && { echo 'FAIL: old .seen not removed after rename'; exit 1; }
for k in g:one g:two g:three; do
  grep -qxF "$k" "$STATE/proj-renamed.seen" || { echo "FAIL: $k lost in .seen migration"; exit 1; }
done
[ "$(sort "$STATE/proj-renamed.seen" | uniq -d | wc -l)" = 0 ] || { echo 'FAIL: dup lines after merge'; exit 1; }
[ -f "$STATE/.asana-project-111.snapshot.json" ] || { echo 'FAIL: project state dropped on rename'; exit 1; }

# 4b) ident COLLISION on rename: "proj.renamed" -> "proj_renamed" share ident
# proj_renamed; cleanup must NOT delete the successor's .seen
cat > "$TMP/p4b.json" <<'EOF'
{"probes":[
 {"name":"proj.renamed","source":"asana","interval_sec":900,"cmd":["asana-project","--project","111"]},
 {"name":"proj-c","source":"asana","interval_sec":900,"cmd":["asana-project","--project","222"]}]}
EOF
"$CA" set-probes testw "$TMP/p4b.json" >/dev/null   # rename proj-renamed -> proj.renamed (same ident is NOT the case here)
printf 'g:keepme\n' > "$STATE/proj_renamed.seen"
cat > "$TMP/p4c.json" <<'EOF'
{"probes":[
 {"name":"proj_renamed","source":"asana","interval_sec":900,"cmd":["asana-project","--project","111"]},
 {"name":"proj-c","source":"asana","interval_sec":900,"cmd":["asana-project","--project","222"]}]}
EOF
"$CA" set-probes testw "$TMP/p4c.json" >/dev/null   # "proj.renamed" removed, "proj_renamed" added — SAME ident
grep -qxF 'g:keepme' "$STATE/proj_renamed.seen" 2>/dev/null || { echo 'FAIL: ident collision wiped successor .seen'; exit 1; }
[ -f "$STATE/.asana-project-111.snapshot.json" ] || { echo 'FAIL: project state dropped on ident-collision rename'; exit 1; }
# restore the plain two-probe config for step 5
"$CA" set-probes testw "$TMP/p4.json" >/dev/null

# 5) full removal: per-project state cleaned (no survivors), incl.
# dispatcher-lastrun; the .lock is deliberately KEPT (single-flight inode)
touch "$STATE/.asana-project-111.journal.jsonl" "$STATE/.dispatcher-lastrun-proj-renamed" \
      "$STATE/.asana-project-111.lock"
echo '{"probes":[]}' > "$TMP/p5.json"
"$CA" set-probes testw "$TMP/p5.json" >/dev/null
leftovers="$(ls -A "$STATE" | grep -E 'asana-project-(111|222)|proj-renamed|proj-c' | grep -v '\.lock$' || true)"
[ -z "$leftovers" ] || { echo "FAIL: state leftovers after removal: $leftovers"; exit 1; }
[ -f "$STATE/.asana-project-111.lock" ] || { echo 'FAIL: lock must survive cleanup (single-flight inode)'; exit 1; }

echo "OK: asana-project claude-auto integration tests passed"
