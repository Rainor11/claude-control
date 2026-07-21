#!/bin/bash
# tests/lint-bootstrap.test.sh — рубеж 3 из .superpowers/sdd/iso-t3-brief.md: "тестовый файл
# без bootstrap → lint падает". Рубеж 2 (tests/lib/bootstrap.{sh,mjs}) ловит "запустили тест
# в обход раннера", этот файл ловит ДРУГОЙ класс ошибки — "написали НОВЫЙ тест и забыли
# подключить bootstrap первой строкой" (рубеж 2 тут бессилен: если тест никогда не source'ит
# bootstrap, ему просто некому отказывать).
#
# Совместимость (бриф, раздел «Совместимость: не сломай существующие тесты»): миграция
# существующих 23 тестов на bootstrap — T6, НЕ эта задача. LEGACY_ALLOWLIST ниже — ЯВНЫЙ
# список файлов, для которых отсутствие bootstrap пока ОЖИДАЕМО (не ошибка). Список ОБЯЗАН
# только СОКРАЩАТЬСЯ: если файл из allow-list ВДРУГ обзавёлся bootstrap (мигрировали в T6, но
# забыли вычеркнуть отсюда) — это ТОЖЕ падение лита (см. проверку №2 ниже), а не тихий проход.
# Так "заберут — не забудут вычеркнуть" ловится механически, а не на честном слове.
#
# Этот файл — НОВЫЙ тест T3, сам обязан подключать bootstrap первой строкой (дожфудинг:
# лит проверяет ВСЕ tests/*.test.*, включая самого себя, и сам обязан пройти свою же
# проверку — иначе лит был бы избирательным).
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bootstrap.sh"
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bootstrap-detect.sh"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="$DIR/tests"
fail() { echo "FAIL: $1"; exit 1; }

# EXPECTED_LEGACY_ALLOWLIST_T3 — ЗАМОРОЖЕННЫЙ снимок допустимых имён на момент T3 (В1, ревью:
# "список умеет только сокращаться" была ТОЛЬКО комментарием, ничто механически не мешало
# дописать сюда НОВЫЙ файл вместо подключения bootstrap). Содержимое ИДЕНТИЧНО
# LEGACY_ALLOWLIST ниже на момент создания — это НЕ рабочий список (тот, что реально
# фильтрует бегущий цикл, — LEGACY_ALLOWLIST дальше), а ЭТАЛОН membership-проверки: любая
# запись в LEGACY_ALLOWLIST, которой НЕТ в этом эталоне, — явный признак "дописали новый файл
# в allow-list вместо подключения bootstrap" → FAIL (см. проверку stale-баз/growth ниже).
# НИКОГДА не редактировать этот массив при добавлении нового теста, И не обязательно
# редактировать его вообще при T6-миграции: проверка ниже — SUBSET (LEGACY_ALLOWLIST ⊆
# EXPECTED_LEGACY_ALLOWLIST_T3), а не строгое равенство. LEGACY_ALLOWLIST МОЖЕТ свободно
# сокращаться (T6 вычёркивает мигрированные файлы) без изменения эталона — это тривиально
# сохраняет subset-свойство. Эталон трогать только если найдена ошибка в САМОМ снимке T3
# (например, отсутствующая запись при заведении лита) — не как часть обычного workflow миграции.
declare -A EXPECTED_LEGACY_ALLOWLIST_T3=(
  [tests/asana-comments.test.sh]=1
  [tests/asana-project-integration.test.sh]=1
  [tests/asana-project.test.sh]=1
  [tests/claude-auto-mission-update.test.sh]=1
  [tests/claude-auto-spawn.test.sh]=1
  [tests/dept-approve.test.sh]=1
  [tests/dept-exec-runner.test.sh]=1
  [tests/dept-requests.test.sh]=1
  [tests/dept-withdraw.test.sh]=1
  [tests/ledger-messages.test.sh]=1
  [tests/process-control.test.sh]=1
  [tests/rnr-bot-withdraw.test.sh]=1
  [tests/rnr-db-sanitize.test.sh]=1
  [tests/runtime-root.test.sh]=1
  [tests/dept-dispatcher.test.mjs]=1
  [tests/dept-inbox.test.mjs]=1
  [tests/dept-ledger.test.mjs]=1
  [tests/dept-memory-freshness.test.mjs]=1
  [tests/liveness-decide.test.mjs]=1
  [tests/policy-drift.test.mjs]=1
  [tests/process-control.test.mjs]=1
  [tests/rebase-check-decide.test.mjs]=1
  [tests/runtime-root.test.mjs]=1
)

# LEGACY_ALLOWLIST — тесты, существовавшие ДО T3 (bootstrap тогда ещё не существовал в
# принципе), поэтому ни один из них НЕ мог его подключить. Список зафиксирован на момент
# T3 (см. .superpowers/sdd/iso-t3-report.md) — миграция (T6) вычёркивает записи по одной,
# новые записи сюда добавляться НЕ должны (новый тест обязан подключать bootstrap сразу).
# Механически это теперь проверяется: любая запись здесь ОБЯЗАНА присутствовать в
# EXPECTED_LEGACY_ALLOWLIST_T3 (см. growth-проверку ниже) — просто дописать сюда новое имя
# без синхронной правки эталона больше не проходит незаметно.
declare -A LEGACY_ALLOWLIST=(
  [tests/asana-comments.test.sh]=1
  [tests/asana-project.test.sh]=1
  [tests/dept-exec-runner.test.sh]=1
  [tests/process-control.test.sh]=1
  [tests/rnr-bot-withdraw.test.sh]=1
  [tests/rnr-db-sanitize.test.sh]=1
  [tests/runtime-root.test.sh]=1
  [tests/process-control.test.mjs]=1
  [tests/runtime-root.test.mjs]=1
)

# has_bootstrap <abs>: тонкая обёртка над detect_bootstrap_connection (tests/lib/
# bootstrap-detect.sh, sourced выше) — ОДНА и та же реализация, что tests/run::uses_bootstrap,
# вынесена в общий файл (К1 ревью T3): прежний "голый substring по всему файлу" засчитывал
# bootstrap подключённым в 4 случаях без реальной защиты (см. полное обоснование в
# tests/lib/bootstrap-detect.sh) — дублировать новую (многострочную) логику в двух местах
# значило бы гарантированно разойтись, общий файл делает это структурно невозможным.
has_bootstrap() {
  detect_bootstrap_connection "$1"
}

# В1 (ревью T3) — LEGACY_ALLOWLIST РОС бы молча: ничто механически не мешало дописать сюда
# новый файл вместо подключения bootstrap, "список умеет только сокращаться" была ТОЛЬКО
# комментарием. Механическая проверка: КАЖДАЯ запись LEGACY_ALLOWLIST обязана быть членом
# ЗАМОРОЖЕННОГО EXPECTED_LEGACY_ALLOWLIST_T3 (см. его определение выше) — если нет, это
# запись, которой не было на момент T3, то есть кто-то добавил новый тест в allow-list вместо
# подключения bootstrap. Это НЕ проверка "совпадает 1-в-1" (allow-list ОБЯЗАН уметь
# сокращаться при T6-миграции) — это проверка "не содержит ничего СВЕРХ эталона" (subset).
unexpected_allowlist=()
for rel in "${!LEGACY_ALLOWLIST[@]}"; do
  [ -n "${EXPECTED_LEGACY_ALLOWLIST_T3[$rel]+set}" ] || unexpected_allowlist+=("$rel")
done

shopt -s nullglob
all_files=("$TESTS_DIR"/*.test.sh "$TESTS_DIR"/*.test.mjs)
shopt -u nullglob
[ "${#all_files[@]}" -gt 0 ] || fail "не нашёл ни одного tests/*.test.sh|*.test.mjs — discovery сломан?"

missing=()
stale_allowlist=()
checked=0

for f in "${all_files[@]}"; do
  rel="tests/$(basename "$f")"
  checked=$((checked + 1))
  if [ -n "${LEGACY_ALLOWLIST[$rel]+set}" ]; then
    # В allow-list — bootstrap пока ОЖИДАЕМО отсутствует. Если он ПОЯВИЛСЯ — запись устарела
    # (см. заголовок файла, "список умеет только сокращаться").
    if has_bootstrap "$f"; then
      stale_allowlist+=("$rel")
    fi
    continue
  fi
  # НЕ в allow-list — новый (или уже мигрированный) тест, bootstrap ОБЯЗАН быть.
  has_bootstrap "$f" || missing+=("$rel")
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo "FAIL: тесты без tests/lib/bootstrap.{sh,mjs} (не в LEGACY_ALLOWLIST — обязаны подключать):"
  printf '  %s\n' "${missing[@]}"
  exit 1
fi

if [ "${#stale_allowlist[@]}" -gt 0 ]; then
  echo "FAIL: файлы из LEGACY_ALLOWLIST уже подключают bootstrap — вычеркни их из списка (см. заголовок файла, 'список умеет только сокращаться'):"
  printf '  %s\n' "${stale_allowlist[@]}"
  exit 1
fi

if [ "${#unexpected_allowlist[@]}" -gt 0 ]; then
  echo "FAIL: LEGACY_ALLOWLIST содержит запись(и), которых НЕ было на момент T3 (EXPECTED_LEGACY_ALLOWLIST_T3) — новый тест обязан подключать bootstrap сразу, не добавляться в allow-list (В1):"
  printf '  %s\n' "${unexpected_allowlist[@]}"
  exit 1
fi

echo "OK: проверено $checked файлов tests/*.test.sh|*.test.mjs — все НЕ-legacy подключают bootstrap, allow-list не устарел и не вырос сверх эталона T3"
echo "PASS lint-bootstrap"
