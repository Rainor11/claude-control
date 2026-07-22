#!/bin/bash
# tests/claude-auto-model.test.sh — get-model/set-model: каталог из $CONTROL_DIR/models.json
# (читается на каждый вызов, нормализуется), запись .model в spec.json ТОЛЬКО под общим
# локом state/.probes-rmw.lock (главный acceptance-инвариант фичи «смена модели из бота»),
# --default пишет null, default резолвится как у launcher'а (env процесса → env-файл юнита
# ~/.config/claude-control/env → opus[1m]). Плюс fail-closed spec_rmw: лок-файл не
# открывается → отказ, spec не тронут (раньше писал БЕЗ лока молча).
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bootstrap.sh"
CA="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/claude-auto"
CC="$CLAUDE_CONTROL_TEST_ROOT"

fail() { echo "FAIL: $1"; exit 1; }

W="$CC/workers/m1"
mkdir -p "$W/state"
printf '{"session_id":"s-1","cwd":"/tmp","permission_mode":"acceptEdits","seeded":false,"model":null}\n' > "$W/spec.json"

# ---------------------------------------------------------------------------------------
# 1. Каталог: отсутствует → available:[]; битый JSON → []; нормализация (не-строки,
#    пустые, >64 символов, control chars — отброшены; дубли схлопнуты).
# ---------------------------------------------------------------------------------------
out="$("$CA" get-model m1)" || fail "get-model упал без models.json"
[ "$(jq -c '.available' <<<"$out")" = "[]" ] || fail "нет models.json → available обязан быть []: $out"
[ "$(jq -c '.model' <<<"$out")" = "null" ] || fail "model:null ожидался: $out"

echo 'не json' > "$CC/models.json"
[ "$("$CA" get-model m1 | jq -c '.available')" = "[]" ] || fail "битый models.json → available []"

long="$(printf 'x%.0s' $(seq 1 65))"
jq -n --arg l "$long" \
  '["opus[1m]","opus","opus",42,"", $l, "bad\u0001ctl", "op us", "-flag", "--default", "sonnet"]' \
  > "$CC/models.json"
avail="$("$CA" get-model m1 | jq -c '.available')"
[ "$avail" = '["opus","opus[1m]","sonnet"]' ] || fail "нормализация каталога: $avail"

# потолок каталога: раздутый файл не пролезает целиком (защита ARG_MAX/клавиатуры)
jq -n '[range(0;70) | "m\(.)"]' > "$CC/models.json"
[ "$("$CA" get-model m1 | jq '.available | length')" = "64" ] || fail "потолок каталога (64) не применён"
jq -n '["opus[1m]","opus","sonnet"]' > "$CC/models.json"

# ---------------------------------------------------------------------------------------
# 2. default: env процесса > env-файл юнита > opus[1m].
# ---------------------------------------------------------------------------------------
[ "$("$CA" get-model m1 | jq -r '.default')" = "opus[1m]" ] || fail "дефолт без env обязан быть opus[1m]"
mkdir -p "$HOME/.config/claude-control"
echo 'CLAUDE_AUTO_DEFAULT_MODEL=sonnet' > "$HOME/.config/claude-control/env"
[ "$("$CA" get-model m1 | jq -r '.default')" = "sonnet" ] || fail "дефолт из env-файла юнита не подхвачен"
[ "$(CLAUDE_AUTO_DEFAULT_MODEL='haiku' "$CA" get-model m1 | jq -r '.default')" = "haiku" ] \
  || fail "env процесса обязан перекрывать env-файл"
rm -f "$HOME/.config/claude-control/env"

# ---------------------------------------------------------------------------------------
# 3. set-model: пишет .model; --default пишет null; отказ на модель вне каталога, на
#    пробел/сверхдлинную, на несуществующего воркера. spec остаётся валидным объектом.
# ---------------------------------------------------------------------------------------
"$CA" set-model m1 'opus[1m]' >/dev/null || fail "set-model на модель из каталога упал"
[ "$(jq -r '.model' "$W/spec.json")" = "opus[1m]" ] || fail ".model не записан"
[ "$(jq -r '.session_id' "$W/spec.json")" = "s-1" ] || fail "set-model потерял соседние ключи spec"

"$CA" set-model m1 --default >/dev/null || fail "set-model --default упал"
[ "$(jq -c '.model' "$W/spec.json")" = "null" ] || fail "--default обязан писать null"

# ""≈дефолт: launcher (${model:-…}) трактует пустую строку как «дефолт» — get-model тоже
jq '.model = ""' "$W/spec.json" > "$W/spec.tmp" && mv "$W/spec.tmp" "$W/spec.json"
[ "$("$CA" get-model m1 | jq -c '.model')" = "null" ] || fail '.model="" обязан показываться как null'
"$CA" set-model m1 --default >/dev/null

# нечитаемый spec → get-model обязан отказать, а не рисовать «здоровый дефолт»
mkdir -p "$CC/workers/broken"
"$CA" get-model broken 2>/dev/null && fail "get-model по воркеру без spec.json обязан отказывать"
echo 'мусор' > "$CC/workers/broken/spec.json"
"$CA" get-model broken 2>/dev/null && fail "get-model по битому spec.json обязан отказывать"

"$CA" set-model m1 'gpt-9000' 2>/dev/null && fail "модель вне каталога обязана отказывать"
"$CA" set-model m1 'op us' 2>/dev/null && fail "пробел в имени обязан отказывать"
"$CA" set-model m1 "$long" 2>/dev/null && fail ">64 символов обязано отказывать"
"$CA" set-model nope 'opus' 2>/dev/null && fail "несуществующий воркер обязан отказывать"
[ "$(jq -c '.model' "$W/spec.json")" = "null" ] || fail "отказы не должны трогать spec"
jq -e 'type=="object"' "$W/spec.json" >/dev/null || fail "spec перестал быть объектом"

# ---------------------------------------------------------------------------------------
# 4. Лок живьём: пока .probes-rmw.lock удержан, set-model НЕ пишет; после освобождения —
#    дописывает (flock -w 10 внутри spec_rmw дожидается).
# ---------------------------------------------------------------------------------------
(
  flock 9
  touch "$CC/scratch-lock-held"
  sleep 2
) 9>"$W/state/.probes-rmw.lock" &
holder=$!
# дождаться, что фон реально взял лок
for _ in $(seq 1 50); do [ -f "$CC/scratch-lock-held" ] && break; sleep 0.1; done
[ -f "$CC/scratch-lock-held" ] || fail "фоновый держатель лока не стартовал"
"$CA" set-model m1 'sonnet' >/dev/null &
setter=$!
sleep 0.7
[ "$(jq -c '.model' "$W/spec.json")" = "null" ] || fail "запись прошла ПОД чужим локом (гонка RMW)"
wait "$holder"
wait "$setter" || fail "set-model не дописал после освобождения лока"
[ "$(jq -r '.model' "$W/spec.json")" = "sonnet" ] || fail "модель не записана после освобождения лока"

# ---------------------------------------------------------------------------------------
# 5. Fail-closed: лок-файл нельзя открыть (state/ без прав на запись) → die, spec цел.
# ---------------------------------------------------------------------------------------
rm -f "$W/state/.probes-rmw.lock"
chmod 500 "$W/state"
if "$CA" set-model m1 'opus' 2>/dev/null; then
  chmod 755 "$W/state"
  fail "лок-файл не открывается, а запись прошла (обязан fail-closed)"
fi
chmod 755 "$W/state"
[ "$(jq -r '.model' "$W/spec.json")" = "sonnet" ] || fail "fail-closed отказ тронул spec"

echo "PASS claude-auto-model"
