#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DEPT_HOME="$(mktemp -d)"
MOCKBIN="$(mktemp -d)"
cat > "$MOCKBIN/claude-auto-ask" <<'EOF'
#!/bin/bash
echo "ASK_CALLED $*" >> "$MOCK_LOG"
EOF
chmod +x "$MOCKBIN/claude-auto-ask"
export MOCK_LOG="$MOCKBIN/log" PATH="$MOCKBIN:$PATH"

out="$("$DIR/bin/dept-approve" --kind-of outgoing --summary 'письмо в Продмаш' --actor mk-prodmash)"
eid="$(echo "$out" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).event_id))')"
grep -q 'ASK_CALLED' "$MOCK_LOG" || { echo 'FAIL: claude-auto-ask не вызван'; exit 1; }
grep -q "$eid" "$MOCK_LOG" || { echo 'FAIL: event_id не передан оператору'; exit 1; }
"$DIR/bin/dept-ledger" list --kind approval --status open | grep -q "$eid" || { echo 'FAIL: approval не открыт'; exit 1; }

# сценарий отказа канала: ask падает → dept-approve обязан выйти с ошибкой
cat > "$MOCKBIN/claude-auto-ask" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$MOCKBIN/claude-auto-ask"
if "$DIR/bin/dept-approve" --kind-of outgoing --summary 'x' --actor mk-x 2>/dev/null; then
  echo 'FAIL: ошибка уведомления оператора проглочена'; exit 1
fi
echo PASS
