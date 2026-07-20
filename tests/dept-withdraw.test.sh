#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DEPT_HOME="$(mktemp -d)"
export DEPT_POLICY_DIR="$(mktemp -d)"
printf '# правила v1\n' > "$DEPT_POLICY_DIR/policy-v1.md"
fail() { echo "FAIL: $*"; exit 1; }

SANDBOX="$(mktemp -d)"
cp "$DIR/bin/dept-withdraw" "$SANDBOX/"
export MOCK_LOG="$SANDBOX/log"

# ФЕЙКОВЫЙ dept-ledger: настоящий здесь непригоден — approval-withdraw требует /proc-сессии
# воркера, а шва для неё нет намеренно (R16). Логика допуска покрыта unit-тестами
# authorizeWithdraw; здесь проверяем ТОЛЬКО контракт обёртки: порядок шагов и fail-closed.
cat > "$SANDBOX/dept-ledger" <<'EOF'
#!/bin/bash
echo "LEDGER $*" >> "$MOCK_LOG"
[ "${LEDGER_FAIL:-}" = "1" ] && exit 1
exit 0
EOF
chmod +x "$SANDBOX/dept-ledger"

cat > "$SANDBOX/fake-rnr-db.py" <<'EOF'
import os, sys
open(os.environ['MOCK_LOG'], 'a').write('RNR_DB ' + ' '.join(sys.argv[1:]) + '\n')
sys.exit(3 if os.environ.get('RNR_FAIL') == '1' else 0)
EOF
export RNR_DB_BIN="$SANDBOX/fake-rnr-db.py"
eid="evt_1784200000000_aaaa"

# 1) вне сессии воркера — отказ
if env -u DEPT_APPROVE_TEST_ACTOR "$SANDBOX/dept-withdraw" --event-id "$eid" --reason x 2>/dev/null; then
  fail "dept-withdraw сработал вне воркера"
fi

# 2) без --reason — отказ (оператор должен видеть причину на погашенной карточке)
if DEPT_APPROVE_TEST_ACTOR=mk-a "$SANDBOX/dept-withdraw" --event-id "$eid" 2>/dev/null; then
  fail "dept-withdraw прошёл без --reason"
fi

# 3) ПОРЯДОК: карточка гасится ПЕРВОЙ, журнал — вторым (R14)
: > "$MOCK_LOG"
DEPT_APPROVE_TEST_ACTOR=mk-a "$SANDBOX/dept-withdraw" --event-id "$eid" --reason 'оператор решил в чате' >/dev/null \
  || fail "happy path упал"
command grep -q "RNR_DB withdraw-approval" "$MOCK_LOG" || fail "карточка не гасилась"
command grep -q "LEDGER approval-withdraw" "$MOCK_LOG" || fail "журнал не писался"
first="$(head -1 "$MOCK_LOG")"
case "$first" in
  RNR_DB*) ;;
  *) fail "порядок нарушен: первым шёл '$first', ожидался RNR_DB (иначе ledger withdrawn + живая карточка → оператор жмёт ✅ на отозванном)" ;;
esac

# 4) провал гашения карточки → в журнал НИЧЕГО не пишем (fail-closed)
: > "$MOCK_LOG"
if RNR_FAIL=1 DEPT_APPROVE_TEST_ACTOR=mk-a \
  "$SANDBOX/dept-withdraw" --event-id "$eid" --reason x 2>/dev/null; then
  fail "dept-withdraw проглотил провал гашения карточки"
fi
command grep -q "LEDGER" "$MOCK_LOG" \
  && fail "журнал разъехался с ботом: ledger вызван при непогашенной карточке"

# 5) ОТСУТСТВУЮЩИЙ rnr_db.py → fail-closed, а не «пропустить шаг и писать в ledger»
: > "$MOCK_LOG"
if RNR_DB_BIN=/nonexistent/rnr_db.py DEPT_APPROVE_TEST_ACTOR=mk-a \
  "$SANDBOX/dept-withdraw" --event-id "$eid" --reason x 2>/dev/null; then
  fail "dept-withdraw прошёл без доступного rnr_db.py (Codex важное №2: fail-open создаёт ledger withdrawn + живую карточку)"
fi
command grep -q "LEDGER" "$MOCK_LOG" && fail "ledger вызван при недоступном rnr_db.py"

# 6) M2: --event-id / --reason как ПОСЛЕДНИЙ аргумент без значения — die, не hang и не
# "unbound variable". Регрессия: "${2:-}" сама по себе не спасает — "shift 2" при $#=1
# молча проваливается и while крутится навечно без явного "shift 2 || shift".
m2err="$SANDBOX/m2-err"
if timeout 5 "$SANDBOX/dept-withdraw" --event-id 2>"$m2err"; then
  fail "dept-withdraw прошёл с --event-id без значения"
fi
rc=$?
[ "$rc" -ne 124 ] || fail "dept-withdraw завис на --event-id без значения (regression M2)"
command grep -q 'usage: dept-withdraw' "$m2err" || fail "нет внятного usage-die на --event-id без значения: $(cat "$m2err")"

if timeout 5 "$SANDBOX/dept-withdraw" --event-id "$eid" --reason 2>"$m2err"; then
  fail "dept-withdraw прошёл с --reason без значения"
fi
rc=$?
[ "$rc" -ne 124 ] || fail "dept-withdraw завис на --reason без значения (regression M2)"
command grep -q -- '--reason обязателен' "$m2err" || fail "нет внятного die на --reason без значения: $(cat "$m2err")"

echo PASS
