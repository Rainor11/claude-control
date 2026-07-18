#!/bin/bash
# asana-comments adapter: new-comment window + ebid marker (regression), EDIT
# detection via content fingerprints, first-poll migration silence, anti-loop
# (no new dedup keys on a quiet tick), self-ledger suppression, --author filter,
# legacy byte-compat (no EB_ASANA_EMIT_ID -> no markers, no fingerprint state),
# fetch fail-open.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
AC="${AC_OVERRIDE:-$DIR/channels/event-bridge/adapters/asana-comments}"
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
        s = re.match(r"^/tasks/(\d+)/stories$", path)
        if s: data = {"data": fix.get("stories", {}).get(s.group(1), []), "next_page": None}
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
export ASANA_COMMENTS_API_BASE="http://127.0.0.1:$(cat "$WORK/port")"
export ASANA_COMMENTS_ENV_FILE="$ENVF"
export EB_ASANA_EMIT_ID=1

STATE="$WORK/state"; mkdir -p "$STATE"
run() { "$AC" --task 4242 --state-dir "$STATE" "$@"; }
FPR="$STATE/.asana-comments-4242.fingerprints"

# dedup keys exactly as event-bridge-watch computes them: marker id -> g:<id>,
# else sha256(visible)[:32]
keys() {
  local l k
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    case "$l" in
      $'\x1e'ebid=*$'\x1e'*) k="${l#$'\x1e'ebid=}"; printf 'g:%s\n' "${k%%$'\x1e'*}" ;;
      *) printf '%s' "$l" | sha256sum | cut -c1-32 ;;
    esac
  done
}

o1='{"gid":"101","type":"comment","created_at":"2020-01-01T00:00:00.000Z","created_by":{"gid":"777","name":"Автор"},"text":"старый коммент"}'
s1='{"gid":"555","type":"system","created_at":"2020-01-02T00:00:00.000Z","created_by":{"gid":"777","name":"Автор"},"text":"assigned"}'

# 1) first run: write-once ts-baseline only, silent
echo "{\"stories\":{\"4242\":[$o1,$s1]}}" > "$FIX"
out="$(run)"
[ -z "$out" ] || { echo "FAIL: first run must be silent, got: $out"; exit 1; }
[ -f "$STATE/.asana-comments-4242.baseline" ] || { echo 'FAIL: no ts-baseline after first run'; exit 1; }

# 2) second run: pre-baseline comment stays silent; fingerprints registered
#    silently (migration semantics: existing history is NEVER replayed as edits)
out="$(run)"
[ -z "$out" ] || { echo "FAIL: pre-baseline history emitted: $out"; exit 1; }
[ -f "$FPR" ] || { echo 'FAIL: fingerprints not initialized on first fetch'; exit 1; }
grep -q '^101	' "$FPR" || { echo 'FAIL: pre-baseline comment not fingerprinted'; exit 1; }
grep -q '^555	' "$FPR" && { echo 'FAIL: system story fingerprinted'; exit 1; }

# 3) new comment -> exactly 1 marked line, key g:<gid>; replay is byte-identical
n1='{"gid":"9001","type":"comment","created_at":"2999-01-01T00:00:00.000Z","created_by":{"gid":"888","name":"Вова"},"text":"привет от Вовы"}'
echo "{\"stories\":{\"4242\":[$o1,$s1,$n1]}}" > "$FIX"
out="$(run)"
[ "$(printf '%s\n' "$out" | wc -l)" = 1 ] || { echo "FAIL: expected 1 line, got: $out"; exit 1; }
[ "$(printf '%s\n' "$out" | keys)" = "g:9001" ] || { echo "FAIL: bad new-comment key: $(printf '%s\n' "$out" | keys)"; exit 1; }
echo "$out" | grep -q '\[edited\]' && { echo 'FAIL: new comment tagged as edited'; exit 1; }
out2="$(run)"
[ "$out" = "$out2" ] || { echo 'FAIL: quiet replay not byte-identical'; exit 1; }
grep -q '^9001	' "$FPR" || { echo 'FAIL: new comment not fingerprinted'; exit 1; }

# 4) EDIT of a PRE-BASELINE comment -> exactly one [edited] line, content-versioned key
o1e='{"gid":"101","type":"comment","created_at":"2020-01-01T00:00:00.000Z","created_by":{"gid":"777","name":"Автор"},"text":"старый коммент (правлено)"}'
echo "{\"stories\":{\"4242\":[$o1e,$s1,$n1]}}" > "$FIX"
out="$(run)"
ecnt="$(printf '%s\n' "$out" | grep -c '\[edited\]' || true)"
[ "$ecnt" = 1 ] || { echo "FAIL: expected 1 [edited] line, got $ecnt: $out"; exit 1; }
echo "$out" | grep -q '\[edited\] Автор: старый коммент (правлено)' || { echo "FAIL: edited line lacks new text: $out"; exit 1; }
ekey="$(printf '%s\n' "$out" | keys | grep '^g:101@e' || true)"
printf '%s' "$ekey" | grep -qE '^g:101@e[0-9a-f]{32}$' || { echo "FAIL: bad edit key: $ekey"; exit 1; }

# 5) anti-loop: quiet tick emits NO keys beyond the previous tick's set
out2="$(run)"
[ "$out" = "$out2" ] || { echo 'FAIL: same edit re-fires with a different line/key'; exit 1; }

# 6) second edit of the SAME story -> a NEW content-versioned key
o1e2='{"gid":"101","type":"comment","created_at":"2020-01-01T00:00:00.000Z","created_by":{"gid":"777","name":"Автор"},"text":"старый коммент (правлено дважды)"}'
echo "{\"stories\":{\"4242\":[$o1e2,$s1,$n1]}}" > "$FIX"
out2="$(run)"
ekey2="$(printf '%s\n' "$out2" | keys | grep '^g:101@e' || true)"
printf '%s' "$ekey2" | grep -qE '^g:101@e[0-9a-f]{32}$' || { echo "FAIL: bad 2nd edit key: $ekey2"; exit 1; }
[ "$ekey" != "$ekey2" ] || { echo 'FAIL: 2nd edit reuses 1st edit key (would be deduped)'; exit 1; }

# 7) edit of a POST-BASELINE comment: [edited] fires; new-comment line keeps its
#    ORIGINAL g:<gid> key (bridge has it in .seen -> no double-wake)
n1e='{"gid":"9001","type":"comment","created_at":"2999-01-01T00:00:00.000Z","created_by":{"gid":"888","name":"Вова"},"text":"привет (v2)"}'
echo "{\"stories\":{\"4242\":[$o1e2,$s1,$n1e]}}" > "$FIX"
out="$(run)"
printf '%s\n' "$out" | keys | grep -qx 'g:9001' || { echo "FAIL: new-comment key mutated on edit: $out"; exit 1; }
printf '%s\n' "$out" | keys | grep -qE '^g:9001@e[0-9a-f]{32}$' || { echo "FAIL: no edit key for post-baseline comment: $out"; exit 1; }
printf '%s\n' "$out" | grep '\[edited\]' | grep -q 'привет (v2)' || { echo "FAIL: edited line lacks v2 text: $out"; exit 1; }

# 8) self-ledger: edits of the worker's OWN comments never fire
sc='{"gid":"9002","type":"comment","created_at":"2999-01-02T00:00:00.000Z","created_by":{"gid":"777","name":"Максим"},"text":"мой собственный"}'
printf '9002\n' > "$STATE/.asana-self-stories"
echo "{\"stories\":{\"4242\":[$o1e2,$s1,$n1e,$sc]}}" > "$FIX"
run >/dev/null   # register 9002
sce='{"gid":"9002","type":"comment","created_at":"2999-01-02T00:00:00.000Z","created_by":{"gid":"777","name":"Максим"},"text":"мой собственный (правлено)"}'
echo "{\"stories\":{\"4242\":[$o1e2,$s1,$n1e,$sce]}}" > "$FIX"
out="$(run)"
echo "$out" | grep -q 'мой собственный' && { echo "FAIL: self-comment edit not suppressed: $out"; exit 1; }

# 9) --author filter applies to edits too (fresh state dir)
STATE2="$WORK/state2"; mkdir -p "$STATE2"
a7='{"gid":"301","type":"comment","created_at":"2020-01-01T00:00:00.000Z","created_by":{"gid":"777","name":"Семёрка"},"text":"от 777"}'
a8='{"gid":"302","type":"comment","created_at":"2020-01-01T00:00:00.000Z","created_by":{"gid":"888","name":"Восьмёрка"},"text":"от 888"}'
echo "{\"stories\":{\"4242\":[$a7,$a8]}}" > "$FIX"
"$AC" --task 4242 --author 777 --state-dir "$STATE2" >/dev/null
"$AC" --task 4242 --author 777 --state-dir "$STATE2" >/dev/null
a7e='{"gid":"301","type":"comment","created_at":"2020-01-01T00:00:00.000Z","created_by":{"gid":"777","name":"Семёрка"},"text":"от 777 (правлено)"}'
a8e='{"gid":"302","type":"comment","created_at":"2020-01-01T00:00:00.000Z","created_by":{"gid":"888","name":"Восьмёрка"},"text":"от 888 (правлено)"}'
echo "{\"stories\":{\"4242\":[$a7e,$a8e]}}" > "$FIX"
out="$("$AC" --task 4242 --author 777 --state-dir "$STATE2")"
echo "$out" | grep -q 'от 777 (правлено)' || { echo "FAIL: watched author edit missed: $out"; exit 1; }
echo "$out" | grep -q 'от 888' && { echo "FAIL: other author edit emitted: $out"; exit 1; }

# 10) legacy mode (no EB_ASANA_EMIT_ID): byte-compat — no markers, no [edited],
#     no fingerprint state ever written
STATE3="$WORK/state3"; mkdir -p "$STATE3"
echo "{\"stories\":{\"4242\":[$o1,$n1]}}" > "$FIX"
env -u EB_ASANA_EMIT_ID "$AC" --task 4242 --state-dir "$STATE3" >/dev/null
out="$(env -u EB_ASANA_EMIT_ID "$AC" --task 4242 --state-dir "$STATE3")"
[ "$out" = "[asana 2999-01-01T00:00:00.000Z] Вова: привет от Вовы" ] || { echo "FAIL: legacy output changed: $(printf '%s' "$out" | cat -A)"; exit 1; }
[ -f "$STATE3/.asana-comments-4242.fingerprints" ] && { echo 'FAIL: legacy run wrote fingerprints'; exit 1; }

# 11) migration on a task WITH history incl. old edits: first marker-aware fetch
#     registers silently — zero [edited] lines
STATE4="$WORK/state4"; mkdir -p "$STATE4"
echo '2020-06-01T00:00:00.000Z' > "$STATE4/.asana-comments-4242.baseline"
echo "{\"stories\":{\"4242\":[$o1e2,$s1,$n1e]}}" > "$FIX"
out="$("$AC" --task 4242 --state-dir "$STATE4")"
printf '%s\n' "$out" | grep -q '\[edited\]' && { echo "FAIL: migration replayed history as edits: $out"; exit 1; }
[ -f "$STATE4/.asana-comments-4242.fingerprints" ] || { echo 'FAIL: migration did not initialize fingerprints'; exit 1; }

# 12) fetch failure: fail-open — rc=0, no output, fingerprints untouched
cp "$FPR" "$WORK/fpr.bak"
out="$(ASANA_COMMENTS_API_BASE="http://127.0.0.1:1" run)" || { echo 'FAIL: fetch failure must exit 0'; exit 1; }
[ -z "$out" ] || { echo "FAIL: fetch failure emitted: $out"; exit 1; }
cmp -s "$FPR" "$WORK/fpr.bak" || { echo 'FAIL: fetch failure mutated fingerprints'; exit 1; }

echo "OK: asana-comments adapter tests passed"
