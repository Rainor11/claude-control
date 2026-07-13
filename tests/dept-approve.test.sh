#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DEPT_HOME="$(mktemp -d)"
export DEPT_POLICY_DIR="$(mktemp -d)"
printf '# правила v1\n' > "$DEPT_POLICY_DIR/policy-v1.md"
CLAUDE_AUTO_NAME=mk-prodmash "$DIR/bin/dept-ledger" policy-ack --version v1 >/dev/null
MOCKBIN="$(mktemp -d)"
cat > "$MOCKBIN/claude-auto-ask" <<'EOF'
#!/bin/bash
echo "ASK_CALLED $*" >> "$MOCK_LOG"
EOF
chmod +x "$MOCKBIN/claude-auto-ask"
export MOCK_LOG="$MOCKBIN/log" PATH="$MOCKBIN:$PATH"

out="$(CLAUDE_AUTO_NAME=mk-prodmash "$DIR/bin/dept-approve" --kind-of outgoing --summary 'письмо в Продмаш')"
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
if CLAUDE_AUTO_NAME=mk-prodmash "$DIR/bin/dept-approve" --kind-of outgoing --summary 'x' 2>/dev/null; then
  echo 'FAIL: ошибка уведомления оператора проглочена'; exit 1
fi

# восстановить рабочий mock ask — иначе follow-up проверки ниже (detail) упадут
# на этапе уведомления оператора, а не на проверяемом policy-турникете/detail
cat > "$MOCKBIN/claude-auto-ask" <<'EOF'
#!/bin/bash
echo "ASK_CALLED $*" >> "$MOCK_LOG"
EOF
chmod +x "$MOCKBIN/claude-auto-ask"

# без идентичности воркера dept-approve не работает вовсе
if env -u CLAUDE_AUTO_NAME "$DIR/bin/dept-approve" --kind-of other --summary 'x' 2>/dev/null; then
  echo 'FAIL: dept-approve сработал вне воркера'; exit 1
fi

# policy-турникет: воркер без ack получает отказ с инструкцией
if out2="$(CLAUDE_AUTO_NAME=mk-noack "$DIR/bin/dept-approve" --kind-of outgoing --summary 'x' 2>&1)"; then
  echo 'FAIL: dept-approve открыл аппрув без policy-ack'; exit 1
fi
echo "$out2" | grep -q 'policy-ack --version v1' || { echo 'FAIL: в отказе нет инструкции policy-ack'; exit 1; }
"$DIR/bin/dept-ledger" list --kind approval --status open | grep -q 'mk-noack' && { echo 'FAIL: approval от mk-noack всё же открыт'; exit 1; }

# --detail доезжает до ledger
CLAUDE_AUTO_NAME=mk-prodmash "$DIR/bin/dept-approve" --kind-of outgoing --summary 'с деталями' --detail 'полный текст' >/dev/null
"$DIR/bin/dept-ledger" list --kind approval --filter 'summary=с деталями' | grep -q 'полный текст' || { echo 'FAIL: detail не записан'; exit 1; }
echo PASS
