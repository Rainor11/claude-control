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

# --- dept-planerka-exec: рассылка policy_refresh вместо ребейза (фаза 4) ---
# Было: exec звал claude-auto rebase по флоту, busy → ретраи, STALE → 🔴-сегмент.
# Стало: exec шлёт policy_refresh активным, спящих пропускает, claude-auto не зовёт вовсе.
PL_DEPT="$(mktemp -d)"; PL_CTRL="$(mktemp -d)"; PL_POL="$(mktemp -d)"
printf '# правила v9\n' > "$PL_POL/policy-v9.md"
mkdir -p "$PL_CTRL/workers"
DL_PL() { DEPT_HOME="$PL_DEPT" DEPT_POLICY_DIR="$PL_POL" "$DIR/bin/dept-ledger" "$@"; }
DL_PL registry-set dept-head   --role руководитель >/dev/null
DL_PL registry-set mk-act-p    --role мк --client cli-a >/dev/null
DL_PL registry-set mk-sleep-p  --role мк --client cli-b >/dev/null
DL_PL registry-set dept-tp-p   --role тп >/dev/null
DL_PL registry-set legacy-p    --role legacy >/dev/null
jq -n '{workers:{"dept-head":{state:"active"},"mk-act-p":{state:"active"},"mk-sleep-p":{state:"sleeping"},"dept-tp-p":{state:"active"},"legacy-p":{state:"active"}}}' \
  > "$PL_CTRL/autonomous.json"

# claude-auto НЕ должен быть вызван вообще — мок падает, если его позвали
PL_CA="$(mktemp -d)/fake-ca-planerka"
cat > "$PL_CA" <<'EOF'
#!/bin/bash
echo "CLAUDE_AUTO_CALLED $*" >> "$MOCK_LOG"
exit 99
EOF
chmod +x "$PL_CA"
export PL_NOTIFY_LOG="$(mktemp)"; PL_NOTIFY="$(mktemp -d)/fake-notify"
cat > "$PL_NOTIFY" <<'EOF'
#!/bin/bash
echo "NOTIFY $*" >> "$PL_NOTIFY_LOG"
EOF
chmod +x "$PL_NOTIFY"

pl_start="$(date +%s)"
out8="$(DEPT_HOME="$PL_DEPT" DEPT_POLICY_DIR="$PL_POL" CLAUDE_CONTROL_DIR="$PL_CTRL" \
  CLAUDE_AUTO_BIN="$PL_CA" MOCK_LOG="$MOCK_LOG" TELEGRAM_NOTIFY="$PL_NOTIFY" \
  "$DIR/bin/dept-planerka-exec" --reason 'смок рассылки')" \
  || fail "dept-planerka-exec упал: $out8"
pl_end="$(date +%s)"

[ $((pl_end - pl_start)) -lt 15 ] || fail "рассылка висела >15с (не должна ничего ждать)"
command grep -q 'CLAUDE_AUTO_CALLED' "$MOCK_LOG" && fail "claude-auto вызван — планёрка больше НЕ ребейзит"

# policy_refresh ушёл активным штабным и МК, но не спящему и не legacy
for w in dept-head mk-act-p dept-tp-p; do
  DL_PL list --kind message --filter "to=$w" --status queued \
    | jq -e 'select(.data.type=="policy_refresh")' >/dev/null \
    || fail "$w не получил policy_refresh"
done
DL_PL list --kind message --filter 'to=mk-sleep-p' --status queued | command grep -q . \
  && fail "спящему mk-sleep-p ушло сообщение (решение оператора №2: спящих не будим)"
DL_PL list --kind message --filter 'to=legacy-p' --status queued | command grep -q . \
  && fail "legacy-воркеру ушло сообщение (роли отдела: руководитель/мк/архивариус/тп)"

# отправитель — Руководитель (заявка его), а не operator/dispatcher
DL_PL list --kind message --filter 'to=mk-act-p' --status queued \
  | jq -e 'select(.data.from=="dept-head")' >/dev/null \
  || fail "отправитель рассылки не dept-head"

# сводка: разослано / спят / версия правил
echo "$out8" | command grep -q 'разослано' || fail "в сводке нет сегмента «разослано»: $out8"
echo "$out8" | command grep -q 'v9'        || fail "в сводке нет версии правил: $out8"
echo "$out8" | command grep -q 'mk-sleep-p' || fail "спящий не отмечен в сводке: $out8"
command grep -q 'NOTIFY' "$PL_NOTIFY_LOG"  || fail "TG-сводка не отправлена"

# КАПЫ АДАПТЕРА (R3): subject ≤200, body ≤300 — иначе инструкция молча обрежется
body_len="$(DL_PL list --kind message --filter 'to=mk-act-p' --status queued | jq -r '.data.body' | wc -m)"
subj_len="$(DL_PL list --kind message --filter 'to=mk-act-p' --status queued | jq -r '.data.subject' | wc -m)"
[ "$body_len" -le 300 ] || fail "body рассылки $body_len симв. > 300 — адаптер шины обрежет инструкцию"
[ "$subj_len" -le 200 ] || fail "subject рассылки $subj_len симв. > 200 — адаптер шины обрежет"

# длинный reason не должен ломать кап body
DL_PL registry-set mk-long-p --role мк --client cli-c >/dev/null
jq '.workers["mk-long-p"] = {state:"active"}' "$PL_CTRL/autonomous.json" > "$PL_CTRL/a.tmp" && mv "$PL_CTRL/a.tmp" "$PL_CTRL/autonomous.json"
long_reason="$(printf 'о%.0s' $(seq 1 400))"
DEPT_HOME="$PL_DEPT" DEPT_POLICY_DIR="$PL_POL" CLAUDE_CONTROL_DIR="$PL_CTRL" \
  TELEGRAM_NOTIFY="$PL_NOTIFY" "$DIR/bin/dept-planerka-exec" --reason "$long_reason" >/dev/null \
  || fail "exec упал на длинном reason"
long_len="$(DL_PL list --kind message --filter 'to=mk-long-p' --status queued | jq -r '.data.body' | head -1 | wc -m)"
[ "$long_len" -le 300 ] || fail "reason 400 симв. пробил кап body ($long_len > 300)"
echo "  planerka-exec: рассылка OK"

# ---- 8) dept-liveness-request / dept-request-render liveness_restart (T2 сторож-кнопки) ---
# dept-liveness-request НЕ worker-only (сторож — systemd, не сессия) — не нужен
# DEPT_APPROVE_TEST_ACTOR/SANDBOX-копия, зовём реальный bin/ напрямую. Карточка — мок
# rnr_db.py (RNR_DB_BIN), той же схемой, что tests/dept-withdraw.test.sh мокает dept-withdraw.
LIV_ENV_FILE="$(mktemp)"
printf 'TELEGRAM_CHAT_ID=999999999\n' > "$LIV_ENV_FILE"
export CLAUDE_AUTO_OPERATOR_ENV="$LIV_ENV_FILE"

export LIV_RNR_LOG="$(mktemp)"
LIV_RNR_DB="$(mktemp -d)/fake-rnr-db.py"
cat > "$LIV_RNR_DB" <<'EOF'
import os, sys
open(os.environ['LIV_RNR_LOG'], 'a').write(' '.join(sys.argv[1:]) + '\n')
sys.exit(3 if os.environ.get('LIV_RNR_FAIL') == '1' else 0)
EOF
export RNR_DB_BIN="$LIV_RNR_DB"

"$DL" registry-set test-liveness-w --role мк --client тест >/dev/null
mkdir -p "$CLAUDE_CONTROL_DIR/workers/test-liveness-w"
jq '.workers["test-liveness-w"] = {state:"active"}' "$CLAUDE_CONTROL_DIR/autonomous.json" > "$CLAUDE_CONTROL_DIR/autonomous.json.tmp" \
  && mv "$CLAUDE_CONTROL_DIR/autonomous.json.tmp" "$CLAUDE_CONTROL_DIR/autonomous.json"

# 8a) рендер: текст содержит воркера/минуты, без анлицизма "resume" (policy v10 п.3.8)
liv_req='{"worker":"test-liveness-w","frozen_min":"12","transcript_min":"9"}'
liv_detail="$("$DIR/bin/dept-request-render" liveness_restart "$liv_req")" || fail "рендер liveness_restart упал"
echo "$liv_detail" | command grep -q 'test-liveness-w' || fail "рендер liveness_restart не содержит имя воркера"
echo "$liv_detail" | command grep -q '12 мин' || fail "рендер liveness_restart не содержит frozen_min"
echo "$liv_detail" | command grep -q '9 мин' || fail "рендер liveness_restart не содержит transcript_min"
echo "$liv_detail" | command grep -qi 'resume' && fail "рендер liveness_restart содержит англицизм 'resume' (policy v10 п.3.8)"

# отсутствующее поле → die (капчено через переменную, НЕ прямым pipe из падающей команды —
# pipefail сделал бы exit-код пайпа неотличимым от grep-результата)
render_bad="$("$DIR/bin/dept-request-render" liveness_restart '{"worker":"w"}' 2>&1)" \
  && fail "рендер liveness_restart не отказал на неполный request"
echo "$render_bad" | command grep -q 'требует поля' || fail "рендер liveness_restart отказал без пояснения про обязательные поля"

# 8b) dept-liveness-request: несуществующий воркер → отказ, ledger не тронут.
# Источник истины существования — autonomous.json (контракт сторожа), НЕ реестр отдела
# (/bug 19.07: registry-гейт ложно отвергал active воркеров вне registry.json).
out8a="$("$DIR/bin/dept-liveness-request" --worker no-such-worker --frozen-min 5 --transcript-min 5 2>&1)" \
  && fail "dept-liveness-request прошёл для несуществующего воркера"
echo "$out8a" | command grep -q 'не найден в autonomous.json' || fail "отказ по несуществующему воркеру без пояснения"

# воркер есть, но не active → отказ
"$DL" registry-set test-liveness-sleepy --role мк --client тест >/dev/null
mkdir -p "$CLAUDE_CONTROL_DIR/workers/test-liveness-sleepy"
jq '.workers["test-liveness-sleepy"] = {state:"sleeping"}' "$CLAUDE_CONTROL_DIR/autonomous.json" > "$CLAUDE_CONTROL_DIR/autonomous.json.tmp" \
  && mv "$CLAUDE_CONTROL_DIR/autonomous.json.tmp" "$CLAUDE_CONTROL_DIR/autonomous.json"
out8b="$("$DIR/bin/dept-liveness-request" --worker test-liveness-sleepy --frozen-min 5 --transcript-min 5 2>&1)" \
  && fail "dept-liveness-request прошёл для не-active воркера"
echo "$out8b" | command grep -q 'не active' || fail "отказ по не-active воркеру без пояснения"

# 8c) happy path: заявка открывается actor=watchdog, карточка "отправляется" (мок rnr_db.py)
: > "$LIV_RNR_LOG"
out8c="$("$DIR/bin/dept-liveness-request" --worker test-liveness-w --frozen-min 12 --transcript-min 9)" \
  || fail "dept-liveness-request (валидный воркер) упал"
liv_eid="$(echo "$out8c" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).event_id))')"
"$DL" list --kind approval --event-id "$liv_eid" \
  | jq -e '.data.kind_of=="liveness_restart" and .data.from=="watchdog" and .data.request.worker=="test-liveness-w" and .data.request.frozen_min=="12" and .data.request.transcript_min=="9"' >/dev/null \
  || fail "approval liveness_restart содержит неверные kind_of/from/request"
command grep -q 'insert-approval' "$LIV_RNR_LOG" || fail "карточка не отправлена через rnr_db.py insert-approval"
command grep -q -- '--worker watchdog' "$LIV_RNR_LOG" || fail "карточка не помечена worker=watchdog"
command grep -q -- "--arg-value $liv_eid" "$LIV_RNR_LOG" || fail "карточка не ссылается на event_id заявки"

# 8c2 (T2 F2): rnr_db.py insert-approval ВСЕГДА возвращает rc=3 (симулирует qid-коллизию,
# LIV_RNR_FAIL=1) → retry-ветка должна РЕАЛЬНО сработать 5 раз (до фикса F2 rc захватывался
# ПОСЛЕ `fi`, где bash отдаёт exit-код if-compound'а, а не упавшего условия — он всегда 0,
# поэтому [ "$rc" = 3 ] никогда не срабатывал: цикл умирал на первой же попытке с ложным
# "db error rc=0"). Итог фикса: 5 честных попыток, "не смог выделить уникальный qid",
# ненулевой exit, карточка НЕ построена; заявка в ledger (открыта РЕАЛЬНЫМ approval-open
# до вызова мока) остаётся open — fail-closed направление, заявка не теряется.
: > "$LIV_RNR_LOG"
out8c2="$(LIV_RNR_FAIL=1 "$DIR/bin/dept-liveness-request" --worker test-liveness-w --frozen-min 7 --transcript-min 4 2>&1)" \
  && fail "dept-liveness-request прошёл успешно, хотя rnr_db.py insert-approval всегда падает (LIV_RNR_FAIL=1)"
echo "$out8c2" | command grep -q 'не смог выделить уникальный qid' \
  || fail "нет честного сообщения об исчерпанных retry (регресс F2: rc после fi всегда 0 давал ложный 'db error rc=0' на первой попытке)"
liv_attempts="$(command grep -c 'insert-approval' "$LIV_RNR_LOG" || true)"
[ "$liv_attempts" = "5" ] || fail "retry-ветка qid-коллизии не отработала 5 раз (attempts=$liv_attempts) — мёртвая ветка F2 не ожила"
liv_eid_fail="$(echo "$out8c2" | command grep -oE 'evt_[0-9]+_[a-z0-9]+' | head -1)"
[ -n "$liv_eid_fail" ] || fail "не удалось извлечь event_id заявки из сообщения об ошибке"
liv_fail_row="$("$DL" list --kind approval --event-id "$liv_eid_fail" --status open)"
[ -n "$liv_fail_row" ] || fail "заявка $liv_eid_fail должна остаться open в ledger при провале доставки карточки (fail-closed)"

# карточку отправить нечем (rnr_db.py недоступен) → dept-liveness-request FAIL-CLOSED
# (заявка в ledger уже открыта — увидит её reminder диспетчера, но вызывающий обязан
# узнать о провале доставки карточки сразу, exit 1)
out8d="$(RNR_DB_BIN=/nonexistent/rnr_db.py "$DIR/bin/dept-liveness-request" --worker test-liveness-w --frozen-min 3 --transcript-min 3 2>&1)" \
  && fail "dept-liveness-request прошёл без доступного rnr_db.py"
echo "$out8d" | command grep -q 'карточку отправить нечем' || fail "нет fail-closed сообщения при недоступном rnr_db.py"

# ---- 9) anti-forge: подмена data.detail → dept-liveness-exec отказывает ДО systemctl ------
LIV_EID="$liv_eid" node -e '
const fs = require("fs");
const file = process.env.DEPT_HOME + "/events.jsonl";
const lines = fs.readFileSync(file, "utf8").trim().split("\n").map((l) => JSON.parse(l));
const eid = process.env.LIV_EID;
let found = false;
for (const e of lines) if (e.event_id === eid) { e.data.detail = "подделанный detail — не соответствует request"; found = true; }
if (!found) throw new Error("event не найден для подмены detail");
fs.writeFileSync(file, lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
'
"$DL" approval-resolve "$liv_eid" --status approved --actor operator >/dev/null
FAKE_SYSTEMCTL="$(mktemp -d)/fake-systemctl"
FAKE_SYSTEMCTL_LOG="$(mktemp)"
cat > "$FAKE_SYSTEMCTL" <<EOF
#!/bin/bash
echo "SYSTEMCTL \$*" >> "$FAKE_SYSTEMCTL_LOG"
exit 0
EOF
chmod +x "$FAKE_SYSTEMCTL"
out9="$(SYSTEMCTL="$FAKE_SYSTEMCTL" "$DIR/bin/dept-liveness-exec" --approval "$liv_eid" 2>&1)" \
  && fail "dept-liveness-exec исполнил заявку с подделанным detail"
echo "$out9" | command grep -q 'detail ≠ request' || fail "нет anti-forge сообщения 'detail ≠ request'"
[ -s "$FAKE_SYSTEMCTL_LOG" ] && fail "systemctl вызван на подделанной заявке — anti-forge не остановил ДО побочных эффектов"

# ---- 10) happy-path exec: мок systemctl получает правильный юнит, agent_run записан ------
out10a="$("$DIR/bin/dept-liveness-request" --worker test-liveness-w --frozen-min 20 --transcript-min 15)" \
  || fail "вторая заявка liveness_restart не прошла"
liv_eid2="$(echo "$out10a" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).event_id))')"
"$DL" approval-resolve "$liv_eid2" --status approved --actor operator >/dev/null
: > "$FAKE_SYSTEMCTL_LOG"
out10b="$(SYSTEMCTL="$FAKE_SYSTEMCTL" "$DIR/bin/dept-liveness-exec" --approval "$liv_eid2")" \
  || fail "dept-liveness-exec (happy path) упал: $out10b"
command grep -q -- '--user restart claude-auto@test-liveness-w.service' "$FAKE_SYSTEMCTL_LOG" \
  || fail "systemctl вызван не с ожидаемыми аргументами"
echo "$out10b" | command grep -q 'перезапущен' || fail "нет подтверждения перезапуска в выводе"
"$DL" list --kind agent_run --filter "ref=$liv_eid2" \
  | jq -e 'select(.data.run_kind=="liveness_restart" and .data.worker=="test-liveness-w")' >/dev/null \
  || fail "agent_run liveness_restart не записан (или без ref=$liv_eid2 — T2 F3)"

# ---- 10b) /bug 19.07: воркер active в autonomous.json, но НЕ в реестре отдела ------------
# Легитимный кейс (в проде: biomerie-portal, sm-app2-core) — сторож следит за ВСЕМ флотом
# state=active из autonomous.json, членство в registry.json для liveness_restart не требуется
# ни при подаче, ни при исполнении. До фикса request умирал «не найден в реестре отдела» на
# каждом 5-минутном тике (вечный алерт-цикл «не удалось подать заявку», карточка недостижима),
# а exec падал бы «не найден в реестре» даже на одобренной заявке.
mkdir -p "$CLAUDE_CONTROL_DIR/workers/test-liveness-noreg"
jq '.workers["test-liveness-noreg"] = {state:"active"}' "$CLAUDE_CONTROL_DIR/autonomous.json" > "$CLAUDE_CONTROL_DIR/autonomous.json.tmp" \
  && mv "$CLAUDE_CONTROL_DIR/autonomous.json.tmp" "$CLAUDE_CONTROL_DIR/autonomous.json"
out10c="$("$DIR/bin/dept-liveness-request" --worker test-liveness-noreg --frozen-min 6 --transcript-min 6)" \
  || fail "dept-liveness-request отверг active воркера без регистрации в реестре отдела"
liv_eid5="$(echo "$out10c" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).event_id))')"
"$DL" approval-resolve "$liv_eid5" --status approved --actor operator >/dev/null
: > "$FAKE_SYSTEMCTL_LOG"
out10d="$(SYSTEMCTL="$FAKE_SYSTEMCTL" "$DIR/bin/dept-liveness-exec" --approval "$liv_eid5")" \
  || fail "dept-liveness-exec отверг active воркера без регистрации в реестре отдела: $out10d"
command grep -q -- '--user restart claude-auto@test-liveness-noreg.service' "$FAKE_SYSTEMCTL_LOG" \
  || fail "systemctl не вызван для незарегистрированного (но active) воркера"

# ---- 11) exec: systemctl упал → exit 1 с внятным stderr, agent_run НЕ пишется ------------
out11a="$("$DIR/bin/dept-liveness-request" --worker test-liveness-w --frozen-min 30 --transcript-min 25)" \
  || fail "третья заявка liveness_restart не прошла"
liv_eid3="$(echo "$out11a" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).event_id))')"
"$DL" approval-resolve "$liv_eid3" --status approved --actor operator >/dev/null
FAKE_SYSTEMCTL_FAIL="$(mktemp -d)/fake-systemctl-fail"
cat > "$FAKE_SYSTEMCTL_FAIL" <<'EOF'
#!/bin/bash
echo "Unit claude-auto@test-liveness-w.service not found." >&2
exit 5
EOF
chmod +x "$FAKE_SYSTEMCTL_FAIL"
out11b="$(SYSTEMCTL="$FAKE_SYSTEMCTL_FAIL" "$DIR/bin/dept-liveness-exec" --approval "$liv_eid3" 2>&1)" \
  && fail "dept-liveness-exec НЕ упал при ошибке systemctl"
echo "$out11b" | command grep -q 'systemctl restart' || fail "нет внятного сообщения об ошибке systemctl"
# T2 F3: комментарий выше обещает "agent_run НЕ пишется" — раньше это было недоказуемо
# (agent_run не нёс ref заявки, а happy-path #10 уже писал запись для того же worker,
# что дало бы ложное совпадение). Теперь ref=liv_eid3 отличает ЭТУ (упавшую) заявку.
"$DL" list --kind agent_run --filter "ref=$liv_eid3" \
  | jq -e 'select(.data.run_kind=="liveness_restart")' >/dev/null \
  && fail "agent_run записан для заявки liveness_restart, где systemctl упал (ref=$liv_eid3) — die должен идти ДО append"

# ---- 12) exec: воркер уснул МЕЖДУ подачей заявки и решением оператора → отказ при исполнении --
out12a="$("$DIR/bin/dept-liveness-request" --worker test-liveness-w --frozen-min 8 --transcript-min 6)" \
  || fail "четвёртая заявка liveness_restart не прошла"
liv_eid4="$(echo "$out12a" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).event_id))')"
"$DL" approval-resolve "$liv_eid4" --status approved --actor operator >/dev/null
jq '.workers["test-liveness-w"].state = "sleeping"' "$CLAUDE_CONTROL_DIR/autonomous.json" > "$CLAUDE_CONTROL_DIR/autonomous.json.tmp" \
  && mv "$CLAUDE_CONTROL_DIR/autonomous.json.tmp" "$CLAUDE_CONTROL_DIR/autonomous.json"
out12b="$("$DIR/bin/dept-liveness-exec" --approval "$liv_eid4" 2>&1)" \
  && fail "dept-liveness-exec исполнил заявку на не-active воркере"
echo "$out12b" | command grep -q 'не active' || fail "нет пояснения про не-active воркера при исполнении"

echo "  liveness-restart: OK"

echo PASS
