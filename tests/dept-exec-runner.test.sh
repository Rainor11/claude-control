#!/bin/bash
# tests/dept-exec-runner.test.sh — Task 11-fix: end-to-end смок дедупа исполнения долгих
# заявок диспетчером в ИЗОЛИРОВАННОМ tmp DEPT_HOME (боевой флот/таймер НЕ трогает).
#
# Доказывает баг-фикс напрямую: два тика dept-dispatcher подряд (второй запускается ПОКА
# detached-раннер первого ещё выполняется) → ровно ОДИН раннер стартует и дописывает
# executed, второй тик видит заявку уже НЕ approved и пропускает. Плюс recovery-детект:
# искусственно состаренная executing-заявка → алерт, дедуп повторного алерта маркер-файлом.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $1"; exit 1; }

# ---- sandbox bin: копии + фейковый исполнитель (whitelist-имя dept-sleep-exec) ----------
SANDBOX="$(mktemp -d)"
cp "$DIR/bin/dept-ledger" "$DIR/bin/dept-dispatcher" "$DIR/bin/dept-exec-runner" "$SANDBOX/"
cat > "$SANDBOX/dept-sleep-exec" <<'EOF'
#!/bin/bash
# фейковый исполнитель заявки sleep: спит N секунд (даёт второму тику время догнать
# первый ДО завершения раннера), потом сообщает успех.
sleep "${FAKE_EXEC_SLEEP:-3}"
echo "фейк-исполнитель: усыпил бы воркера ($*)"
exit 0
EOF
chmod +x "$SANDBOX"/*

DEPT_HOME="$(mktemp -d)"
export DEPT_HOME
CLAUDE_CONTROL_DIR="$(mktemp -d)"
export CLAUDE_CONTROL_DIR
mkdir -p "$CLAUDE_CONTROL_DIR/workers"
CLAUDE_AUTO_HOME="$CLAUDE_CONTROL_DIR"
export CLAUDE_AUTO_HOME
node -e 'require("fs").writeFileSync(process.env.CLAUDE_CONTROL_DIR + "/autonomous.json", JSON.stringify({workers:{}}))'

NOTIFY_LOG="$DEPT_HOME/notify.log"
TELEGRAM_NOTIFY="$SANDBOX/fake-notify.sh"
export TELEGRAM_NOTIFY
cat > "$TELEGRAM_NOTIFY" <<EOF
#!/bin/bash
echo "\$*" >> "$NOTIFY_LOG"
EOF
chmod +x "$TELEGRAM_NOTIFY"

DL="$SANDBOX/dept-ledger"
DISPATCHER="$SANDBOX/dept-dispatcher"

"$DL" registry-set dept-head --role руководитель >/dev/null

# ================================================================================
# Часть 1: дедуп — два тика подряд, второй ПОКА раннер первого ещё выполняется
# ================================================================================
a="$("$DL" approval-open --kind-of sleep --summary "смок sleep" --actor dept-head)"
eid="$(node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).event_id))' <<<"$a")"
"$DL" approval-resolve "$eid" --status approved --actor operator >/dev/null

FAKE_EXEC_SLEEP=3 out1="$(FAKE_EXEC_SLEEP=3 "$DISPATCHER" tick 2>&1)"
echo "$out1" | grep -q "раннер запущен detached" || fail "тик 1 не запустил раннер: $out1"

# тик 2 — СРАЗУ, пока раннер тика 1 ещё спит 3с (проверено ниже: раннер завершится позже)
out2="$("$DISPATCHER" tick 2>&1)"
echo "$out2" | grep -qE "0 заявок approved|пропущено" || true # заявка уже не approved → выборка пуста, это и есть дедуп
echo "$out2" | grep -q "раннер запущен detached" && fail "тик 2 запустил ВТОРОЙ раннер — дедуп не сработал: $out2"

# ждём завершения detached-раннера тика 1 (до 10с, опрашиваем effective status)
executed=""
for i in $(seq 1 20); do
  st="$("$DL" list --kind approval --status executed | grep -c "$eid" || true)"
  if [ "$st" -ge 1 ]; then executed=1; break; fi
  sleep 0.5
done
[ -n "$executed" ] || fail "заявка НЕ дошла до executed за 10с — раннер тика 1 не отработал"

# ровно одно executing-событие и ровно одно executed-событие на эту заявку (дедуп доказан)
exec_ing_count="$("$DL" list --kind approval_status | grep -c "\"ref\":\"$eid\".*\"status\":\"executing\"" || true)"
exec_ed_count="$("$DL" list --kind approval_status | grep -c "\"ref\":\"$eid\".*\"status\":\"executed\"" || true)"
[ "$exec_ing_count" -eq 1 ] || fail "ожидалось ровно 1 событие executing, получено $exec_ing_count"
[ "$exec_ed_count" -eq 1 ] || fail "ожидалось ровно 1 событие executed (один раннер), получено $exec_ed_count"

# ровно один runner-<id>.log (второй раннер не создавал свой лог)
runner_logs="$(find "$DEPT_HOME" -maxdepth 1 -name "runner-${eid}.log" | wc -l)"
[ "$runner_logs" -eq 1 ] || fail "ожидался 1 runner-лог, найдено $runner_logs"

echo "OK: два тика подряд → один раннер, заявка executed, дедуп подтверждён"

# ================================================================================
# Часть 2: recovery-детект — искусственно состаренная executing-заявка → алерт + дедуп алерта
# ================================================================================
b="$("$DL" approval-open --kind-of planerka --summary "смок stuck" --actor dept-head)"
eid2="$(node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).event_id))' <<<"$b")"
"$DL" approval-resolve "$eid2" --status approved --actor operator >/dev/null
"$DL" approval-exec "$eid2" --status executing --actor dispatcher >/dev/null # раннер "умер" сразу после — статус так и остался executing

# состарить ТОЛЬКО событие executing этой заявки на 30 мин назад (> DEPT_EXEC_MAX_MIN=20 дефолт)
led="$DEPT_HOME/events.jsonl"
old_ts="$(node -e 'console.log(new Date(Date.now()-30*60000).toISOString())')"
node -e '
const fs = require("fs");
const eid2 = process.argv[1], oldTs = process.argv[2], f = process.argv[3];
const lines = fs.readFileSync(f, "utf8").split("\n").filter(Boolean).map((l) => {
  const e = JSON.parse(l);
  if (e.kind === "approval_status" && e.data.ref === eid2 && e.data.status === "executing") e.ts = oldTs;
  return JSON.stringify(e);
});
fs.writeFileSync(f, lines.join("\n") + "\n");
' "$eid2" "$old_ts" "$led"

out3="$("$DISPATCHER" tick 2>&1)"
echo "$out3" | grep -q "1 заявок approved" && fail "заявка kind=planerka не должна попасть в approved-выборку (эффективный статус executing): $out3"
grep -q "зависла в executing" "$NOTIFY_LOG" || fail "recovery-алерт НЕ отправлен: $(cat "$NOTIFY_LOG")"
[ -f "$DEPT_HOME/exec-stuck-${eid2}" ] || fail "маркер-файл зависшей заявки не создан"

alert_count_before="$(grep -c "зависла в executing" "$NOTIFY_LOG")"
"$DISPATCHER" tick >/dev/null 2>&1
alert_count_after="$(grep -c "зависла в executing" "$NOTIFY_LOG")"
[ "$alert_count_after" -eq "$alert_count_before" ] || fail "повторный тик заспамил алертом зависшей заявки ($alert_count_before → $alert_count_after)"

echo "OK: recovery-детект зависшей executing-заявки — алерт отправлен один раз (дедуп маркер-файлом)"

rm -rf "$SANDBOX" "$DEPT_HOME" "$CLAUDE_CONTROL_DIR"
echo "ALL OK: tests/dept-exec-runner.test.sh"
