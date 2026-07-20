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

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="$DIR/tests"
fail() { echo "FAIL: $1"; exit 1; }

# LEGACY_ALLOWLIST — тесты, существовавшие ДО T3 (bootstrap тогда ещё не существовал в
# принципе), поэтому ни один из них НЕ мог его подключить. Список зафиксирован на момент
# T3 (см. .superpowers/sdd/iso-t3-report.md) — миграция (T6) вычёркивает записи по одной,
# новые записи сюда добавляться НЕ должны (новый тест обязан подключать bootstrap сразу).
declare -A LEGACY_ALLOWLIST=(
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

# has_bootstrap <abs>: тот же паттерн детекции, что tests/run::uses_bootstrap (НАМЕРЕННО
# зеркалится, не выносится в общую библиотеку — это ОДНА строка тривиального grep, не логика
# T1/T2, которую бриф просит не дублировать; если паттерн когда-нибудь изменится, оба места
# видны в одном grep по репо). Паттерн ЯКОРНЫЙ (строка обязана начинаться с `.`+пробел ИЛИ
# `import`+граница слова) — голый substring засчитал бы файл "защищённым", даже если он
# просто УПОМИНАЕТ "lib/bootstrap.sh" в комментарии, реально не подключая его.
has_bootstrap() {
  command grep -qE '^[[:space:]]*(\.[[:space:]]|import\>).*lib/bootstrap\.(sh|mjs)' "$1" 2>/dev/null
}

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

echo "OK: проверено $checked файлов tests/*.test.sh|*.test.mjs — все НЕ-legacy подключают bootstrap, allow-list не устарел"
echo "PASS lint-bootstrap"
