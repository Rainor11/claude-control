#!/bin/bash
# tests/dept-requests.test.sh — заявки руководителя (spawn/mission/планёрка/sleep) +
# исполнители: worker-only турникет, канонический detail↔request рендер (anti-forge),
# рендер-смок dept-spawn-exec с фейковым claude-auto. Никаких боевых карточек оператору
# (claude-auto-request мокается PATH-соседкой в SANDBOX, как в tests/dept-approve.test.sh).
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DEPT_HOME="$(mktemp -d)"
export DEPT_POLICY_DIR="$(mktemp -d)"
printf '# правила v1\n' > "$DEPT_POLICY_DIR/policy-v1.md"

DL="$DIR/bin/dept-ledger"

fail() { echo "FAIL: $1"; exit 1; }

# sandbox-копия bin — обёртки (dept-*-request) зовут dept-approve/dept-request-render по
# СВОЕМУ $BINDIR (соседний каталог), значит мок claude-auto-request тоже должен быть
# соседом ИМЕННО в этой копии (dept-approve зовёт "$BINDIR/claude-auto-request" — PATH-мок
# не сработает). Тот же приём, что в tests/dept-approve.test.sh.
SANDBOX="$(mktemp -d)"
cp "$DIR/bin/dept-ledger" "$DIR/bin/dept-approve" "$DIR/bin/dept-request-render" \
   "$DIR/bin/dept-spawn-request" "$DIR/bin/dept-mission-request" \
   "$DIR/bin/dept-planerka-request" "$DIR/bin/dept-sleep-request" "$SANDBOX/"
cat > "$SANDBOX/claude-auto-request" <<'EOF'
#!/bin/bash
echo "RQ_CALLED $*" >> "$MOCK_LOG"
EOF
chmod +x "$SANDBOX/claude-auto-request"
export MOCK_LOG="$SANDBOX/log"

export CLAUDE_CONTROL_DIR="$(mktemp -d)"
mkdir -p "$CLAUDE_CONTROL_DIR/workers"
jq -n '{workers:{}}' > "$CLAUDE_CONTROL_DIR/autonomous.json"

# ---- 1) не-руководитель отвергается --------------------------------------------------
"$DL" registry-set test-mk --role мк --client x >/dev/null
out1="$(DEPT_APPROVE_TEST_ACTOR=test-mk "$SANDBOX/dept-spawn-request" --client тест --name mk-test --asana-gid 1234567 2>&1)" \
  && fail "не-руководитель (роль мк) подал заявку worker_spawn"
echo "$out1" | grep -q 'только Руководитель' || fail "отказ не-руководителю без пояснения про роль"

# ---- 2) руководитель проходит турникет (policy-ack → заявка) -------------------------
"$DL" registry-set test-head --role руководитель >/dev/null
out2a="$(DEPT_APPROVE_TEST_ACTOR=test-head "$SANDBOX/dept-spawn-request" --client тест --name mk-test --asana-gid 1234567 2>&1)" \
  && fail "заявка руководителя прошла БЕЗ policy-ack"
echo "$out2a" | grep -q 'policy-ack' || fail "отказ без policy-ack без инструкции"
"$DL" policy-ack --version v1 --actor test-head >/dev/null
out2b="$(DEPT_APPROVE_TEST_ACTOR=test-head "$SANDBOX/dept-spawn-request" --client тест --name mk-test --asana-gid 1234567 --note 'смок-заметка')" \
  || fail "заявка руководителя не прошла ПОСЛЕ policy-ack"
eid2="$(echo "$out2b" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).event_id))')"
"$DL" list --kind approval --status open | grep -q worker_spawn || fail "approval worker_spawn не открыт"
"$DL" list --kind approval --event-id "$eid2" | jq -e '.data.request.asana_gid=="1234567" and .data.request.client=="тест" and .data.request.note=="смок-заметка"' >/dev/null \
  || fail "data.request заявки worker_spawn неполный/неверный"
grep -q 'RQ_CALLED --action dept-approval' "$MOCK_LOG" || fail "карточка оператору не построена через claude-auto-request"
grep -q -- '--request-json' "$MOCK_LOG" && fail "claude-auto-request получил --request-json (не должен — карточка строится из ledger detail)"

# ---- 3) занятое имя отвергается -------------------------------------------------------
mkdir -p "$CLAUDE_CONTROL_DIR/workers/mk-busy"
out3="$(DEPT_APPROVE_TEST_ACTOR=test-head "$SANDBOX/dept-spawn-request" --client тест --name mk-busy --asana-gid 7654321 2>&1)" \
  && fail "заявка с занятым именем прошла"
echo "$out3" | grep -q 'занято' || fail "отказ по занятому имени без пояснения"

# ---- 4) dept-spawn-exec: рендер-часть с фейковым claude-auto (реальный bin/, не SANDBOX —
#         скрипту нужен REPO=bin/.. с настоящими examples/department/*.template.*) ----------
RENDER_DEPT_HOME="$(mktemp -d)"
BRAIN_CLIENTS_TEST="$(mktemp -d)"
cat > "$BRAIN_CLIENTS_TEST/_template.md" <<'EOF'
---
title: <Название клиента>
type: client
slug: <slug>
created: YYYY-MM-DD
---
# <Название клиента>

## Кратко
EOF
FAKE_CA_LOG="$(mktemp)"
FAKE_CA="$(mktemp -d)/fake-claude-auto"
cat > "$FAKE_CA" <<EOF
#!/bin/bash
echo "CA_CALLED \$*" >> "$FAKE_CA_LOG"
exit 0
EOF
chmod +x "$FAKE_CA"

CLAUDE_AUTO_BIN="$FAKE_CA" DEPT_HOME="$RENDER_DEPT_HOME" BRAIN_CLIENTS="$BRAIN_CLIENTS_TEST" \
  "$DIR/bin/dept-spawn-exec" --client rendertest --name mk-render --asana-gid 1112223 \
  --asana-url 'https://app.asana.com/0/0/1112223' --note 'клиент любит скорость' \
  || fail "dept-spawn-exec (прямые флаги) упал"

[ -f "$BRAIN_CLIENTS_TEST/rendertest/CLAUDE.md" ] || fail "скелет CLAUDE.md не создан"
[ -f "$BRAIN_CLIENTS_TEST/rendertest/timeline.md" ] || fail "скелет timeline.md не создан"
[ -f "$BRAIN_CLIENTS_TEST/rendertest/decisions.md" ] || fail "скелет decisions.md не создан"
grep -q '{{' "$RENDER_DEPT_HOME/missions/mk-render.md" && fail "плейсхолдеры остались в missions/mk-render.md"
grep -q '{{' "$RENDER_DEPT_HOME/render/mk-render.bounds.json" && fail "плейсхолдеры остались в bounds.json"
grep -q '{{' "$RENDER_DEPT_HOME/render/mk-render.probes.json" && fail "плейсхолдеры остались в probes.json"
grep -q '{{' "$RENDER_DEPT_HOME/render/mk-render.kickoff.md" && fail "плейсхолдеры остались в kickoff.md"
jq -e . "$RENDER_DEPT_HOME/render/mk-render.bounds.json" >/dev/null || fail "bounds.json — не валидный JSON после рендера"
jq -e . "$RENDER_DEPT_HOME/render/mk-render.probes.json" >/dev/null || fail "probes.json — не валидный JSON после рендера"
grep -q 'клиент любит скорость' "$RENDER_DEPT_HOME/missions/mk-render.md" || fail "note руководителя не попал в миссию"
grep -q -- '--name mk-render' "$FAKE_CA_LOG" || fail "fake claude-auto не получил --name"
grep -q -- '--cwd' "$FAKE_CA_LOG" || fail "fake claude-auto не получил --cwd"
grep -q -- '--kickoff-file' "$FAKE_CA_LOG" || fail "fake claude-auto не получил --kickoff-file"

# повторный прогон (идемпотентность bootstrap): скелет НЕ пересоздаётся, шаблоны
# перерендериваются без ошибок, fake claude-auto вызывается снова без падения
CLAUDE_AUTO_BIN="$FAKE_CA" DEPT_HOME="$RENDER_DEPT_HOME" BRAIN_CLIENTS="$BRAIN_CLIENTS_TEST" \
  "$DIR/bin/dept-spawn-exec" --client rendertest --name mk-render --asana-gid 1112223 \
  --asana-url 'https://app.asana.com/0/0/1112223' --note 'клиент любит скорость' \
  || fail "повторный dept-spawn-exec (идемпотентность) упал"
[ "$(grep -c 'CA_CALLED' "$FAKE_CA_LOG")" = "2" ] || fail "fake claude-auto должен быть вызван дважды (bootstrap идемпотентен, а не no-op)"

# ---- 5) dept-sleep-request: не-мк отвергается; валидная заявка проходит --------------
"$DL" registry-set test-notmk --role тп >/dev/null
out5a="$(DEPT_APPROVE_TEST_ACTOR=test-head "$SANDBOX/dept-sleep-request" --worker test-notmk --reason 'x' 2>&1)" \
  && fail "усыпление не-МК прошло"
echo "$out5a" | grep -q 'только МК' || fail "отказ по роли без пояснения (усыпить можно только МК)"

"$DL" registry-set test-worker --role мк --client тест >/dev/null
mkdir -p "$CLAUDE_CONTROL_DIR/workers/test-worker"
jq '.workers["test-worker"] = {state:"active"}' "$CLAUDE_CONTROL_DIR/autonomous.json" > "$CLAUDE_CONTROL_DIR/autonomous.json.tmp" \
  && mv "$CLAUDE_CONTROL_DIR/autonomous.json.tmp" "$CLAUDE_CONTROL_DIR/autonomous.json"
out5b="$(DEPT_APPROVE_TEST_ACTOR=test-head "$SANDBOX/dept-sleep-request" --worker test-worker --reason 'проект на паузе')" \
  || fail "валидная заявка sleep не прошла"
sleep_eid="$(echo "$out5b" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).event_id))')"
"$DL" list --kind approval --event-id "$sleep_eid" | jq -e '.data.kind_of=="sleep" and .data.request.worker=="test-worker" and .data.request.reason=="проект на паузе"' >/dev/null \
  || fail "approval sleep не содержит корректный request.worker/reason"

# не-существующий воркер отвергается
out5c="$(DEPT_APPROVE_TEST_ACTOR=test-head "$SANDBOX/dept-sleep-request" --worker mk-no-such --reason 'x' 2>&1)" \
  && fail "усыпление несуществующего воркера прошло"
echo "$out5c" | grep -q 'не найден' || fail "отказ по несуществующему воркеру без пояснения"

# ---- 6) сверка detail↔request: подмена data.detail в ledger → dept-sleep-exec отказывает --
SLEEP_EID="$sleep_eid" node -e '
const fs = require("fs");
const file = process.env.DEPT_HOME + "/events.jsonl";
const lines = fs.readFileSync(file, "utf8").trim().split("\n").map((l) => JSON.parse(l));
const eid = process.env.SLEEP_EID;
let found = false;
for (const e of lines) if (e.event_id === eid) { e.data.detail = "подделанный detail — не соответствует request"; found = true; }
if (!found) throw new Error("event не найден для подмены detail");
fs.writeFileSync(file, lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
'
"$DL" approval-resolve "$sleep_eid" --status approved --actor operator >/dev/null
out6="$("$DIR/bin/dept-sleep-exec" --approval "$sleep_eid" 2>&1)" && fail "dept-sleep-exec исполнил заявку с подделанным detail"
echo "$out6" | grep -q 'detail ≠ request' || fail "нет anti-forge сообщения 'detail ≠ request'"
# воркер НЕ тронут (state остаётся active — подделанная заявка не усыпила его)
[ "$(jq -r '.workers["test-worker"].state' "$CLAUDE_CONTROL_DIR/autonomous.json")" = "active" ] \
  || fail "подделанная заявка всё же изменила state воркера"

# ---- доп.смок: dept-mission-request / dept-planerka-request (kind_of + request корректны) --
out_m="$(printf 'новая миссия для теста' | DEPT_APPROVE_TEST_ACTOR=test-head "$SANDBOX/dept-mission-request" --worker mk-render --reason 'тестовая смена курса')" \
  || fail "dept-mission-request не прошёл"
eid_m="$(echo "$out_m" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).event_id))')"
"$DL" list --kind approval --event-id "$eid_m" | jq -e '.data.kind_of=="mission_change" and .data.request.mission_text=="новая миссия для теста" and .data.request.worker=="mk-render"' >/dev/null \
  || fail "approval mission_change содержит неверный request"

out_p="$(DEPT_APPROVE_TEST_ACTOR=test-head "$SANDBOX/dept-planerka-request" --reason 'еженедельная синхронизация')" \
  || fail "dept-planerka-request не прошёл"
eid_p="$(echo "$out_p" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).event_id))')"
"$DL" list --kind approval --event-id "$eid_p" | jq -e '.data.kind_of=="planerka" and .data.request.reason=="еженедельная синхронизация"' >/dev/null \
  || fail "approval planerka содержит неверный request"

# ---- 7) dept-sleep-exec: идемпотентность (уже спит → no-op) --------------------------
jq '.workers["test-worker"].state = "sleeping"' "$CLAUDE_CONTROL_DIR/autonomous.json" > "$CLAUDE_CONTROL_DIR/autonomous.json.tmp" \
  && mv "$CLAUDE_CONTROL_DIR/autonomous.json.tmp" "$CLAUDE_CONTROL_DIR/autonomous.json"
out7="$(CLAUDE_AUTO_BIN=/bin/false "$DIR/bin/dept-sleep-exec" --worker test-worker --reason 'x')" \
  || fail "dept-sleep-exec на уже-спящем воркере должен вернуть exit 0 (no-op)"
echo "$out7" | grep -q 'уже спит' || fail "нет сообщения об идемпотентном no-op (уже спит)"

# ---- 8) dept-planerka-exec: busy-воркер ОТКЛАДЫВАЕТСЯ (короткий ретрай), а не блокирует --
# (fixup Task 8: раньше висел до 20 мин на busy-воркере → SIGTERM под dispatcher-timeout.
# Теперь ≤3 попытки × RETRY_SLEEP, затем в «отложенные»). Изолированный DEPT_HOME/CONTROL_DIR
# + мок claude-auto (rc=3 для busy) + мок notify. PLANERKA_RETRY_SLEEP=0 — тест не должен ждать.
PL_DEPT="$(mktemp -d)"
PL_CTRL="$(mktemp -d)"
mkdir -p "$PL_CTRL/workers"
DEPT_HOME="$PL_DEPT" "$DL" registry-set mk-ok-p --role мк --client c1 >/dev/null
DEPT_HOME="$PL_DEPT" "$DL" registry-set mk-busy-p --role мк --client c2 >/dev/null
DEPT_HOME="$PL_DEPT" "$DL" registry-set mk-sleep-p --role мк --client c3 >/dev/null
jq -n '{workers:{"mk-ok-p":{state:"active"},"mk-busy-p":{state:"active"},"mk-sleep-p":{state:"sleeping"}}}' \
  > "$PL_CTRL/autonomous.json"

PL_CA="$(mktemp -d)/fake-ca-planerka"
cat > "$PL_CA" <<'EOF'
#!/bin/bash
# rebase <worker> --reason <r> : busy-воркер всегда rc=3 (занят), остальные rc=0
[ "$1" = "rebase" ] && [ "$2" = "mk-busy-p" ] && exit 3
exit 0
EOF
chmod +x "$PL_CA"
export PL_NOTIFY_LOG="$(mktemp)"
PL_NOTIFY="$(mktemp -d)/fake-notify"
cat > "$PL_NOTIFY" <<'EOF'
#!/bin/bash
echo "NOTIFY $*" >> "$PL_NOTIFY_LOG"
EOF
chmod +x "$PL_NOTIFY"

pl_start=$(date +%s)
out8="$(DEPT_HOME="$PL_DEPT" CLAUDE_CONTROL_DIR="$PL_CTRL" CLAUDE_AUTO_BIN="$PL_CA" \
  TELEGRAM_NOTIFY="$PL_NOTIFY" PLANERKA_RETRY_SLEEP=0 \
  "$DIR/bin/dept-planerka-exec" --reason 'смок планёрки')" \
  || fail "dept-planerka-exec упал"
pl_end=$(date +%s)
[ $((pl_end - pl_start)) -lt 30 ] || fail "dept-planerka-exec висел >30с (должен откладывать busy, а не ждать)"
echo "$out8" | grep -q 'ребейзнуты:.*mk-ok-p' || fail "mk-ok-p не в ребейзнутых"
echo "$out8" | grep -qE 'отложены \(busy[^)]*\):.*mk-busy-p' || fail "mk-busy-p не в отложенных (busy)"
echo "$out8" | grep -q 'спят:.*mk-sleep-p' || fail "mk-sleep-p не в спящих"
grep -q 'NOTIFY' "$PL_NOTIFY_LOG" || fail "TG-сводка планёрки не отправлена (мок notify не вызван)"

echo PASS
