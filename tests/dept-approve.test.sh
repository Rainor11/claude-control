#!/bin/bash
# tests/dept-approve.test.sh — dept-approve: worker-only турникет, policy-ack, передача
# карточки оператору, строгий парсер.
#
# T6, ДВЕ независимые причины падения под границей — вылечены обе:
#   1. `export DEPT_HOME="$(mktemp -d)"` — корень СНАРУЖИ тестового корня (резолвер T1
#      законно отказывал). Убрано: под маркером корень задаёт раннер, dept_only резолвится
#      в <корень>/department.
#   2. bin-копии лежали ПЛОСКО в "$(mktemp -d)" — `require('../lib/runtime-root.js')` из
#      dept-ledger искал /tmp/lib/… (MODULE_NOT_FOUND). Теперь песочница ПОВТОРЯЕТ раскладку
#      репозитория: <sandbox>/bin/<копии> + <sandbox>/lib → симлинк на настоящий lib/, тот же
#      относительный путь ../lib резолвится корректно (ровно как в install-раскладке).
set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bootstrap.sh"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEPT_POLICY_DIR="$CLAUDE_CONTROL_TEST_ROOT/policy"
mkdir -p "$DEPT_POLICY_DIR"
printf '# правила v1\n' > "$DEPT_POLICY_DIR/policy-v1.md"
CLAUDE_AUTO_NAME=mk-prodmash "$DIR/bin/dept-ledger" policy-ack --version v1 >/dev/null

# sandbox-копия bin, чтобы подменить claude-auto-request по соседству с dept-approve —
# dept-approve зовёт его по абсолютному пути $BINDIR/claude-auto-request, PATH-мок не сработает.
SANDBOX="$CLAUDE_CONTROL_TEST_ROOT/sandbox/bin"
mkdir -p "$SANDBOX"
ln -sfn "$DIR/lib" "$CLAUDE_CONTROL_TEST_ROOT/sandbox/lib"
cp "$DIR/bin/dept-ledger" "$DIR/bin/dept-approve" "$SANDBOX/"
cat > "$SANDBOX/claude-auto-request" <<'EOF'
#!/bin/bash
echo "RQ_CALLED $*" >> "$MOCK_LOG"
EOF
chmod +x "$SANDBOX/claude-auto-request"
export MOCK_LOG="$SANDBOX/log"

out="$(DEPT_APPROVE_TEST_ACTOR=mk-prodmash "$SANDBOX/dept-approve" --kind-of outgoing --summary 'письмо в Продмаш')"
eid="$(echo "$out" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).event_id))')"
grep -q 'RQ_CALLED --action dept-approval --event-id evt_' "$MOCK_LOG" || { echo 'FAIL: claude-auto-request не вызван с dept-approval'; exit 1; }
grep -q "$eid" "$MOCK_LOG" || { echo 'FAIL: event_id не передан оператору'; exit 1; }
"$DIR/bin/dept-ledger" list --kind approval --status open | grep -q "$eid" || { echo 'FAIL: approval не открыт'; exit 1; }

# сценарий отказа канала: request падает → dept-approve обязан выйти с ошибкой
cat > "$SANDBOX/claude-auto-request" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$SANDBOX/claude-auto-request"
if DEPT_APPROVE_TEST_ACTOR=mk-prodmash "$SANDBOX/dept-approve" --kind-of outgoing --summary 'x' 2>/dev/null; then
  echo 'FAIL: ошибка уведомления оператора проглочена'; exit 1
fi

# восстановить рабочий mock request — иначе follow-up проверки ниже (detail) упадут
# на этапе передачи запроса оператору, а не на проверяемом policy-турникете/detail
cat > "$SANDBOX/claude-auto-request" <<'EOF'
#!/bin/bash
echo "RQ_CALLED $*" >> "$MOCK_LOG"
EOF
chmod +x "$SANDBOX/claude-auto-request"

# без идентичности воркера dept-approve не работает вовсе: ни настоящего /proc-предка
# (resolve_name — эта сессия теста не воркер), ни тестового bypass'а
if env -u DEPT_APPROVE_TEST_ACTOR "$SANDBOX/dept-approve" --kind-of other --summary 'x' 2>/dev/null; then
  echo 'FAIL: dept-approve сработал вне воркера'; exit 1
fi

# policy-турникет: воркер без ack получает отказ с инструкцией
if out2="$(DEPT_APPROVE_TEST_ACTOR=mk-noack "$SANDBOX/dept-approve" --kind-of outgoing --summary 'x' 2>&1)"; then
  echo 'FAIL: dept-approve открыл аппрув без policy-ack'; exit 1
fi
echo "$out2" | grep -q 'policy-ack --version v1' || { echo 'FAIL: в отказе нет инструкции policy-ack'; exit 1; }
"$DIR/bin/dept-ledger" list --kind approval --status open | grep -q 'mk-noack' && { echo 'FAIL: approval от mk-noack всё же открыт'; exit 1; }

# --detail доезжает до ledger
DEPT_APPROVE_TEST_ACTOR=mk-prodmash "$SANDBOX/dept-approve" --kind-of outgoing --summary 'с деталями' --detail 'полный текст' >/dev/null
"$DIR/bin/dept-ledger" list --kind approval --filter 'summary=с деталями' | grep -q 'полный текст' || { echo 'FAIL: detail не записан'; exit 1; }

# request получает и --event-id, и --detail, когда он задан
out3="$(DEPT_APPROVE_TEST_ACTOR=mk-prodmash "$SANDBOX/dept-approve" --kind-of outgoing --summary 'с деталями и запросом' --detail 'деталь для бота')"
eid3="$(echo "$out3" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).event_id))')"
grep -q "RQ_CALLED --action dept-approval --event-id $eid3 --summary с деталями и запросом --detail деталь для бота" "$MOCK_LOG" \
  || { echo 'FAIL: claude-auto-request не получил --detail вместе с --event-id/--summary'; exit 1; }

# summary длиннее 400 символов — пре-валидация ДО открытия аппрува в ledger (иначе orphan-open:
# claude-auto-request отвергает >400 уже ПОСЛЕ записи в ledger)
long_summary="$(printf 'A%.0s' $(seq 1 401))"
if DEPT_APPROVE_TEST_ACTOR=mk-prodmash "$SANDBOX/dept-approve" --kind-of outgoing --summary "$long_summary" 2>/dev/null; then
  echo 'FAIL: dept-approve принял summary длиннее 400 символов'; exit 1
fi
"$DIR/bin/dept-ledger" list --kind approval --filter "summary=$long_summary" | grep -q . && { echo 'FAIL: аппрув с длинным summary всё же создан в ledger'; exit 1; }

# строгий парсер (p2#5): посторонний флаг завершает работу ненулевым кодом с явной ошибкой
if out4="$(DEPT_APPROVE_TEST_ACTOR=mk-prodmash "$SANDBOX/dept-approve" --kind-of outgoing --summary 'x' --actor whoever 2>&1)"; then
  echo 'FAIL: dept-approve принял посторонний флаг --actor'; exit 1
fi
echo "$out4" | grep -q 'unknown arg' || { echo 'FAIL: в отказе нет unknown arg'; exit 1; }

# --request-json доезжает до ledger как data.request (и НЕ передаётся claude-auto-request)
: > "$MOCK_LOG"
out5="$(DEPT_APPROVE_TEST_ACTOR=mk-prodmash "$SANDBOX/dept-approve" --kind-of worker_spawn --summary 'заявка с request-json' --request-json '{"name":"mk-test","client":"тест"}')"
eid5="$(echo "$out5" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).event_id))')"
"$DIR/bin/dept-ledger" list --kind approval --event-id "$eid5" | jq -e '.data.request.name=="mk-test" and .data.request.client=="тест"' >/dev/null \
  || { echo 'FAIL: --request-json не записан в data.request'; exit 1; }
grep -q -- '--request-json' "$MOCK_LOG" && { echo 'FAIL: claude-auto-request получил --request-json (карточка строится из ledger, request не должен утекать)'; exit 1; }

echo PASS
