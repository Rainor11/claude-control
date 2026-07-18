#!/bin/bash
# tests/dept-exec-runner.test.sh — Task 11-fix: end-to-end смок дедупа исполнения долгих
# заявок диспетчером в ИЗОЛИРОВАННОМ tmp DEPT_HOME (боевой флот/таймер НЕ трогает).
# ТРЕБУЕТ живую systemd user session: раннер запускается реальным systemd-run
# transient-юнитом (P3-CRITICAL-2) — заодно e2e-доказательство, что раннер переживает
# завершение тика (в CI без systemd --user тест не годен).
#
# Доказывает баг-фикс напрямую: два тика dept-dispatcher подряд (второй запускается ПОКА
# раннер первого ещё выполняется в своём юните) → ровно ОДИН раннер стартует и дописывает
# executed, второй тик видит заявку уже НЕ approved и пропускает. Плюс recovery-детект:
# искусственно состаренная executing-заявка → алерт, дедуп повторного алерта маркер-файлом.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $1"; exit 1; }

# ---- sandbox bin: копии + фейковый исполнитель (whitelist-имя dept-sleep-exec) ----------
SANDBOX="$(mktemp -d)"
cp "$DIR/bin/dept-ledger" "$DIR/bin/dept-dispatcher" "$DIR/bin/dept-exec-runner" "$DIR/bin/dept-memory-freshness" "$SANDBOX/"
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
echo "$out1" | grep -q "раннер запущен transient-юнитом" || fail "тик 1 не запустил раннер: $out1"

# тик 2 — СРАЗУ, пока раннер тика 1 ещё спит 3с (проверено ниже: раннер завершится позже)
out2="$("$DISPATCHER" tick 2>&1)"
echo "$out2" | grep -qE "0 заявок approved|пропущено" || true # заявка уже не approved → выборка пуста, это и есть дедуп
echo "$out2" | grep -q "раннер запущен transient-юнитом" && fail "тик 2 запустил ВТОРОЙ раннер — дедуп не сработал: $out2"

# ждём завершения раннера тика 1 (до 10с, опрашиваем effective status)
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

# Фидбэк оператора 16.07: ✅-алерт раннера обязан нести человеческий контекст заявки
# (summary + from из ledger), а не голый event_id — алерт читается без похода в ledger.
# Notify пишется сразу ПОСЛЕ approval-exec executed — даём до 5с на гонку записи лога.
human_ok=""
for i in $(seq 1 10); do
  if grep -q "✅ Исполнено: смок sleep — заявка dept-head ($eid)" "$NOTIFY_LOG" 2>/dev/null; then human_ok=1; break; fi
  sleep 0.5
done
[ -n "$human_ok" ] || fail "✅-алерт раннера без человеческого контекста (summary/from): $(cat "$NOTIFY_LOG" 2>/dev/null)"

echo "OK: два тика подряд → один раннер, заявка executed, дедуп подтверждён, алерт очеловечен"

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
# Фидбэк оператора 16.07: recovery-алерт тоже очеловечен — summary + from + event_id.
grep -q "смок stuck — заявка dept-head ($eid2)" "$NOTIFY_LOG" \
  || fail "recovery-алерт без человеческого контекста (summary/from): $(cat "$NOTIFY_LOG")"
[ -f "$DEPT_HOME/exec-stuck-${eid2}" ] || fail "маркер-файл зависшей заявки не создан"

alert_count_before="$(grep -c "зависла в executing" "$NOTIFY_LOG")"
"$DISPATCHER" tick >/dev/null 2>&1
alert_count_after="$(grep -c "зависла в executing" "$NOTIFY_LOG")"
[ "$alert_count_after" -eq "$alert_count_before" ] || fail "повторный тик заспамил алертом зависшей заявки ($alert_count_before → $alert_count_after)"

echo "OK: recovery-детект зависшей executing-заявки — алерт отправлен один раз (дедуп маркер-файлом)"

# ================================================================================
# Часть 3 (Minor 1): числовая защита DEPT_EXEC_RUNNER_TIMEOUT_MS — мусор → дефолт, НЕ 0
# ================================================================================
# 'timeout 0s' ОТКЛЮЧАЕТ таймаут → зависший executor крутился бы вечно. Проверяем, что
# мусорное значение падает в дефолт 900000 (900.000s в логе раннера), а не в 0.
c="$("$DL" approval-open --kind-of sleep --summary "смок timeout-guard" --actor dept-head)"
eid3="$(node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).event_id))' <<<"$c")"
"$DL" approval-resolve "$eid3" --status approved --actor operator >/dev/null
"$DL" approval-exec "$eid3" --status executing --actor dispatcher >/dev/null
# фейковый быстрый executor (whitelist-имя dept-sleep-exec уже есть в SANDBOX, спит 0с при FAKE_EXEC_SLEEP=0)
FAKE_EXEC_SLEEP=0 DEPT_EXEC_RUNNER_TIMEOUT_MS="15min" \
  "$SANDBOX/dept-exec-runner" --approval "$eid3" --executor "$SANDBOX/dept-sleep-exec" >/dev/null 2>&1 || true
grep -q "timeout=900.000s" "$DEPT_HOME/runner-${eid3}.log" \
  || fail "мусорный TIMEOUT_MS не упал в дефолт: $(grep '=== dept-exec-runner' "$DEPT_HOME/runner-${eid3}.log" 2>/dev/null)"
grep -q "timeout=0.000s" "$DEPT_HOME/runner-${eid3}.log" \
  && fail "мусорный TIMEOUT_MS дал timeout=0 (таймаут ОТКЛЮЧЁН — footgun не закрыт)"
# контроль: валидное значение проходит как есть
d="$("$DL" approval-open --kind-of sleep --summary "смок timeout-valid" --actor dept-head)"
eid4="$(node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).event_id))' <<<"$d")"
"$DL" approval-resolve "$eid4" --status approved --actor operator >/dev/null
"$DL" approval-exec "$eid4" --status executing --actor dispatcher >/dev/null
FAKE_EXEC_SLEEP=0 DEPT_EXEC_RUNNER_TIMEOUT_MS=5000 \
  "$SANDBOX/dept-exec-runner" --approval "$eid4" --executor "$SANDBOX/dept-sleep-exec" >/dev/null 2>&1 || true
grep -q "timeout=5.000s" "$DEPT_HOME/runner-${eid4}.log" \
  || fail "валидный TIMEOUT_MS=5000 не дал timeout=5.000s: $(grep '=== dept-exec-runner' "$DEPT_HOME/runner-${eid4}.log" 2>/dev/null)"
echo "OK: числовая защита TIMEOUT_MS — мусор → дефолт 900.000s, валидное значение проходит"

# ================================================================================
# Часть 4 (Minor 4): диспетчер ПЕРЕЖИВАЕТ краш-старт раннера (unhandled spawn 'error')
# ================================================================================
# Регресс на self-review-находку: spawn() шлёт ENOENT асинхронно событием 'error'; без
# слушателя необработанное событие роняло ВЕСЬ процесс dispatcher. Подменяем dept-exec-runner
# на НЕсуществующий путь через переименование — диспетчер обязан пометить executing, поймать
# 'error', заалертить и ЗАВЕРШИТЬ тик штатно (обязанность 3 отрабатывает), не упасть.
mv "$SANDBOX/dept-exec-runner" "$SANDBOX/dept-exec-runner.bak" # раннера больше нет по ожидаемому пути
e="$("$DL" approval-open --kind-of sleep --summary "смок spawn-crash" --actor dept-head)"
eid5="$(node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).event_id))' <<<"$e")"
"$DL" approval-resolve "$eid5" --status approved --actor operator >/dev/null
: > "$NOTIFY_LOG" # очистим лог нотификаций для чистой проверки
set +e
out_crash="$("$DISPATCHER" tick 2>&1)"; crash_rc=$?
set -e
[ "$crash_rc" -eq 0 ] || fail "диспетчер УПАЛ (rc=$crash_rc) на краш-старте раннера — unhandled 'error' не пойман: $out_crash"
echo "$out_crash" | grep -q "tick complete" || fail "тик не завершился штатно (обязанность 3 не отработала?) при краше раннера: $out_crash"
# заявка помечена executing (шаг 1 прошёл ДО неудачного spawn)
"$DL" list --kind approval --status executing | grep -q "$eid5" || fail "заявка не помечена executing до попытки spawn"
# алерт о незапустившемся раннере (событие 'error' обработано, не уронило процесс)
grep -q "раннер НЕ запустился" "$NOTIFY_LOG" || fail "нет алерта о незапустившемся раннере: $(cat "$NOTIFY_LOG")"
mv "$SANDBOX/dept-exec-runner.bak" "$SANDBOX/dept-exec-runner" # вернуть на место
echo "OK: диспетчер переживает краш-старт раннера (spawn 'error' пойман, тик завершён, алерт отправлен)"

rm -rf "$SANDBOX" "$DEPT_HOME" "$CLAUDE_CONTROL_DIR"
echo "ALL OK: tests/dept-exec-runner.test.sh"
