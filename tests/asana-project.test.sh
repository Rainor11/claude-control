#!/bin/bash
# asana-project adapter: snapshot-diff, journal replay, self-ledger suppression,
# two-crawl gone confirmation, events filter, corrupt-snapshot fail-closed.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
AP="$DIR/channels/event-bridge/adapters/asana-project"
WORK="$(mktemp -d)"
SRV_PID=""
trap '[ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; rm -rf "$WORK"' EXIT

FIX="$WORK/fixture.json"
ENVF="$WORK/env"; echo 'ASANA_ACCESS_TOKEN=test-token' > "$ENVF"

# --- mock Asana API: serves the CURRENT content of fixture.json (single page) ---
python3 - "$FIX" "$WORK/port" <<'PY' &
import http.server, json, re, socketserver, sys, urllib.parse
fix_path, port_path = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        try:
            with open(fix_path) as f: fix = json.load(f)
        except Exception:
            fix = {}
        path = urllib.parse.urlparse(self.path).path
        m = re.match(r"^/projects/(\d+)/tasks$", path)
        s = re.match(r"^/tasks/(\d+)/stories$", path)
        if m: data = {"data": fix.get("tasks", []), "next_page": None}
        elif s: data = {"data": fix.get("stories", {}).get(s.group(1), []), "next_page": None}
        else:
            self.send_response(404); self.end_headers(); return
        body = json.dumps(data).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
class S(socketserver.TCPServer): allow_reuse_address = True
with S(("127.0.0.1", 0), H) as srv:
    with open(port_path, "w") as f: f.write(str(srv.server_address[1]))
    srv.serve_forever()
PY
SRV_PID=$!
for _ in $(seq 1 50); do [ -s "$WORK/port" ] && break; sleep 0.1; done
[ -s "$WORK/port" ] || { echo 'FAIL: mock server did not start'; exit 1; }
export ASANA_PROJECT_API_BASE="http://127.0.0.1:$(cat "$WORK/port")"
export ASANA_PROJECT_ENV_FILE="$ENVF"

STATE="$WORK/state"; mkdir -p "$STATE"
run() { "$AP" --project 4242 --state-dir "$STATE" "$@"; }

t1='{"gid":"101","name":"Первая задача","completed":false,"due_on":null,"due_at":null,"modified_at":"2026-01-01T00:00:00.000Z","created_at":"2026-01-01T00:00:00.000Z","assignee":{"name":"Вова"}}'

# 1) first run: baseline, silent
echo "{\"tasks\":[$t1]}" > "$FIX"
out="$(run)"
[ -z "$out" ] || { echo "FAIL: first run must be silent, got: $out"; exit 1; }
[ -f "$STATE/.asana-project-4242.snapshot.json" ] || { echo 'FAIL: no snapshot after baseline'; exit 1; }

# 2) new task -> task_new with ebid marker; second run replays SAME line (journal)
t2='{"gid":"102","name":"Вторая задача","completed":false,"due_on":"2026-08-01","due_at":null,"modified_at":"2026-01-02T00:00:00.000Z","created_at":"2026-01-02T00:00:00.000Z","assignee":null}'
echo "{\"tasks\":[$t1,$t2]}" > "$FIX"
out="$(run)"
echo "$out" | grep -q 'Новая задача «Вторая задача» (task=102' || { echo "FAIL: no task_new: $out"; exit 1; }
[ "$(printf '%s\n' "$out" | wc -l)" = 1 ] || { echo "FAIL: expected exactly 1 event line: $out"; exit 1; }
printf '%s' "$out" | od -An -c | head -1 | grep -q '^ *036' || { echo 'FAIL: no leading \x1e ebid marker'; exit 1; }
out2="$(run)"
[ "$out" = "$out2" ] || { echo "FAIL: journal replay not byte-identical"; exit 1; }

# 3) due change + completion flip
t1c='{"gid":"101","name":"Первая задача","completed":true,"due_on":"2026-09-01","due_at":null,"modified_at":"2026-01-03T00:00:00.000Z","created_at":"2026-01-01T00:00:00.000Z","assignee":{"name":"Вова"}}'
echo "{\"tasks\":[$t1c,$t2]}" > "$FIX"
out="$(run)"
echo "$out" | grep -q 'Срок задачи «Первая задача» (task=101): нет → 2026-09-01' || { echo "FAIL: no due event: $out"; exit 1; }
echo "$out" | grep -q 'Задача «Первая задача» (task=101) закрыта' || { echo "FAIL: no completed event: $out"; exit 1; }

# 4) new comment (modified_at advanced) -> emitted once; self-comment suppressed
t2c='{"gid":"102","name":"Вторая задача","completed":false,"due_on":"2026-08-01","due_at":null,"modified_at":"2026-01-04T00:00:00.000Z","created_at":"2026-01-02T00:00:00.000Z","assignee":null}'
cat > "$FIX" <<EOF
{"tasks":[$t1c,$t2c],
 "stories":{"102":[
   {"gid":"9001","type":"comment","created_at":"2999-01-01T00:00:00.000Z","created_by":{"name":"Вова"},"text":"внешний коммент"},
   {"gid":"9002","type":"comment","created_at":"2999-01-01T00:00:01.000Z","created_by":{"name":"Максим"},"text":"мой собственный"},
   {"gid":"9003","type":"system","created_at":"2999-01-01T00:00:02.000Z","created_by":{"name":"x"},"text":"system story"}]}}
EOF
printf '9002\n' > "$STATE/.asana-self-stories"
out="$(run)"
echo "$out" | grep -q 'Новый коммент в «Вторая задача» (task=102) от Вова: внешний коммент' || { echo "FAIL: no comment event: $out"; exit 1; }
echo "$out" | grep -q 'мой собственный' && { echo 'FAIL: self-comment not suppressed'; exit 1; }
echo "$out" | grep -q 'system story' && { echo 'FAIL: non-comment story emitted'; exit 1; }
cnt="$(printf '%s\n' "$out" | grep -c 'Новый коммент')"
[ "$cnt" = 1 ] || { echo "FAIL: expected 1 comment event, got $cnt"; exit 1; }
out2="$(run)"
cnt2="$(printf '%s\n' "$out2" | grep -c 'Новый коммент')"
[ "$cnt2" = 1 ] || { echo "FAIL: comment re-emitted as NEW on second run ($cnt2)"; exit 1; }

# 5) gone: needs TWO consecutive missing crawls
echo "{\"tasks\":[$t1c]}" > "$FIX"
out="$(run)"
echo "$out" | grep -q 'task=102) пропала' && { echo 'FAIL: gone fired on FIRST miss'; exit 1; }
out="$(run)"
echo "$out" | grep -q 'Задача «Вторая задача» (task=102) пропала' || { echo "FAIL: no gone after 2nd miss: $out"; exit 1; }

# 6) self-created task suppressed (fresh ledger entry), ancient entry NOT suppressed
t8='{"gid":"888","name":"Задача воркера","completed":false,"due_on":null,"due_at":null,"modified_at":"2026-01-05T00:00:00.000Z","created_at":"2026-01-05T00:00:00.000Z","assignee":null}'
t9='{"gid":"999","name":"Задача из древнего леджера","completed":false,"due_on":null,"due_at":null,"modified_at":"2026-01-05T00:00:00.000Z","created_at":"2026-01-05T00:00:00.000Z","assignee":null}'
printf '%s\t888\n1000\t999\n' "$(date +%s)" > "$STATE/.asana-self-tasks"
echo "{\"tasks\":[$t1c,$t8,$t9]}" > "$FIX"
out="$(run)"
echo "$out" | grep -q 'task=888' && { echo 'FAIL: self-created task not suppressed'; exit 1; }
echo "$out" | grep -q 'Новая задача «Задача из древнего леджера» (task=999' || { echo "FAIL: expired ledger entry still suppresses: $out"; exit 1; }

# 7) --events filter: comments only (fresh state dir)
STATE2="$WORK/state2"; mkdir -p "$STATE2"
echo '{"tasks":[]}' > "$FIX"
"$AP" --project 4242 --state-dir "$STATE2" --events comments >/dev/null
cat > "$FIX" <<EOF
{"tasks":[{"gid":"201","name":"Тихая задача","completed":false,"due_on":null,"due_at":null,"modified_at":"2026-01-06T00:00:00.000Z","created_at":"2026-01-06T00:00:00.000Z","assignee":null}],
 "stories":{"201":[{"gid":"9100","type":"comment","created_at":"2999-01-01T00:00:00.000Z","created_by":{"name":"Иван"},"text":"привет"}]}}
EOF
out="$("$AP" --project 4242 --state-dir "$STATE2" --events comments)"
echo "$out" | grep -q 'Новая задача' && { echo 'FAIL: task_new leaked through --events comments'; exit 1; }
echo "$out" | grep -q 'Новый коммент в «Тихая задача» (task=201) от Иван: привет' || { echo "FAIL: comment lost with --events comments: $out"; exit 1; }

# 8) corrupt snapshot: fail closed — no output, file untouched
cp "$STATE/.asana-project-4242.snapshot.json" "$WORK/snap.bak"
echo 'NOT JSON' > "$STATE/.asana-project-4242.snapshot.json"
out="$(run)"
[ -z "$out" ] || { echo "FAIL: corrupt snapshot must silence output, got: $out"; exit 1; }
[ "$(cat "$STATE/.asana-project-4242.snapshot.json")" = 'NOT JSON' ] || { echo 'FAIL: corrupt snapshot was overwritten'; exit 1; }
cp "$WORK/snap.bak" "$STATE/.asana-project-4242.snapshot.json"

# 8b) corrupt journal: fail closed — no output, journal preserved
cp "$STATE/.asana-project-4242.journal.jsonl" "$WORK/journal.bak"
echo 'NOT JSON' > "$STATE/.asana-project-4242.journal.jsonl"
out="$(run)"
[ -z "$out" ] || { echo "FAIL: corrupt journal must silence output, got: $out"; exit 1; }
[ "$(cat "$STATE/.asana-project-4242.journal.jsonl")" = 'NOT JSON' ] || { echo 'FAIL: corrupt journal was overwritten'; exit 1; }
cp "$WORK/journal.bak" "$STATE/.asana-project-4242.journal.jsonl"

# 9) replay expiry: a journal this old is pruned -> silent
out="$(run --replay-hours 0.0001)" || true
sleep 1
out="$(run --replay-hours 0.0001)"
[ -z "$out" ] || { echo "FAIL: expired journal still replays: $out"; exit 1; }

# 10) arg validation
"$AP" --project abc --state-dir "$STATE" 2>/dev/null && { echo 'FAIL: non-numeric project accepted'; exit 1; }
"$AP" --project 4242 --state-dir "$STATE" --events bogus 2>/dev/null && { echo 'FAIL: bogus --events accepted'; exit 1; }
"$AP" --project 4242 --state-dir "$STATE" --request-budget 9999 2>/dev/null && { echo 'FAIL: oversized budget accepted'; exit 1; }

echo "OK: asana-project adapter tests passed"
