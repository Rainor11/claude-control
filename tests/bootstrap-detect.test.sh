#!/bin/bash
# tests/bootstrap-detect.test.sh — юнит-тесты tests/lib/bootstrap-detect.sh (К1, ревью T3, см.
# .superpowers/sdd/iso-t3-report.md). Тестирует ОБЩУЮ функцию detect_bootstrap_connection
# напрямую, а не через tests/run/tests/lint-bootstrap.test.sh — оба потребителя вызывают ЭТУ
# ЖЕ функцию БЕЗ собственной логики поверх (см. tests/run::uses_bootstrap,
# tests/lint-bootstrap.test.sh::has_bootstrap — тонкие обёртки), значит тестирование функции
# ОДИН раз здесь структурно эквивалентно тестированию "в обеих реализациях детектора" — им
# просто негде разойтись, они делят один и тот же код.
#
# Каждый сценарий — синтетический файл во ВРЕМЕННОМ каталоге (не в реальном tests/, discovery
# раннера/лита их не тронет). Ноль риска для боевого набора.
#
# Этот файл — НОВЫЙ тест T3, сам обязан подключать bootstrap первой строкой (см.
# lint-bootstrap.test.sh).
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bootstrap.sh"
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bootstrap-detect.sh"

FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

# check <имя-сценария> <файл> <ожидаемый-результат: protected|not-protected>
check() {
  local label="$1" file="$2" expect="$3" got
  if detect_bootstrap_connection "$file"; then got=protected; else got=not-protected; fi
  [ "$got" = "$expect" ] \
    || fail "$label: ожидали '$expect', получили '$got' (файл: $file)"
  echo "OK: $label"
}

# -----------------------------------------------------------------------------------------
# Позитивные случаи — реальное подключение, ДОЛЖНО признаваться защищённым.
# -----------------------------------------------------------------------------------------
cat > "$FIXTURE_DIR/legit-plain.test.sh" <<'EOF'
#!/bin/bash
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bootstrap.sh"
echo body
EOF
check "легитимный source (комментарий + source, как во всех T3-файлах)" \
  "$FIXTURE_DIR/legit-plain.test.sh" protected

cat > "$FIXTURE_DIR/legit-set-u.test.sh" <<'EOF'
#!/bin/bash
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bootstrap.sh"
echo body
EOF
check "легитимный source ПОСЛЕ set -u (конвенция репозитория — допустимая пред-строка)" \
  "$FIXTURE_DIR/legit-set-u.test.sh" protected

cat > "$FIXTURE_DIR/legit-set-euo-pipefail.test.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bootstrap.sh"
echo body
EOF
check "легитимный source после 'set -euo pipefail' (другой вариант той же допустимой директивы)" \
  "$FIXTURE_DIR/legit-set-euo-pipefail.test.sh" protected

cat > "$FIXTURE_DIR/legit.test.mjs" <<'EOF'
import './lib/bootstrap.mjs';
import { test } from 'node:test';
EOF
check "легитимный import (.mjs)" "$FIXTURE_DIR/legit.test.mjs" protected

# -----------------------------------------------------------------------------------------
# К1, случай 1: реальный source /dev/null, путь к bootstrap упомянут ТОЛЬКО в trailing-
# комментарии на той же строке.
# -----------------------------------------------------------------------------------------
cat > "$FIXTURE_DIR/bypass1-devnull-comment.test.sh" <<'EOF'
#!/bin/bash
. /dev/null # lib/bootstrap.sh
echo "опасный код выполнился бы здесь"
EOF
check "К1.1: '. /dev/null # lib/bootstrap.sh' — реальный аргумент /dev/null, путь только в комментарии" \
  "$FIXTURE_DIR/bypass1-devnull-comment.test.sh" not-protected

# То же для .mjs — комментарий '//' после реального (фиктивного) импорта.
cat > "$FIXTURE_DIR/bypass1.test.mjs" <<'EOF'
import '/dev/null'; // import './lib/bootstrap.mjs';
console.log("опасный код выполнился бы здесь");
EOF
check "К1.1 (.mjs): фиктивный импорт + путь к bootstrap только в '//'-комментарии" \
  "$FIXTURE_DIR/bypass1.test.mjs" not-protected

# -----------------------------------------------------------------------------------------
# К1, случай 2: bootstrap-путь спрятан внутри heredoc-заглушки (данные для no-op ':',
# никогда не исполняется как source) — буквально то, чем БЫЛА фикстура toy-migrated.test.sh
# в tests/run.test.sh ДО этого фикса (см. iso-t3-report.md).
# -----------------------------------------------------------------------------------------
cat > "$FIXTURE_DIR/bypass2-heredoc.test.sh" <<'EOF'
#!/bin/bash
: <<'BOOTSTRAP_MARKER'
. "$(dirname "$0")/lib/bootstrap.sh"
BOOTSTRAP_MARKER
echo "опасный код выполнился бы здесь"
EOF
check "К1.2: bootstrap-путь внутри heredoc-заглушки (': <<X ... X', никогда не исполняется)" \
  "$FIXTURE_DIR/bypass2-heredoc.test.sh" not-protected

# -----------------------------------------------------------------------------------------
# К1, случай 3: недостижимая ветка (if false; then ... fi).
# -----------------------------------------------------------------------------------------
cat > "$FIXTURE_DIR/bypass3-unreachable.test.sh" <<'EOF'
#!/bin/bash
if false; then
  . tests/lib/bootstrap.sh
fi
echo "опасный код выполнился бы здесь"
EOF
check "К1.3: bootstrap внутри 'if false; then ... fi' — недостижимая ветка" \
  "$FIXTURE_DIR/bypass3-unreachable.test.sh" not-protected

# -----------------------------------------------------------------------------------------
# К1, случай 4 (самый критичный по брифу) — bootstrap ПОСЛЕДНЕЙ строкой файла, ПОСЛЕ
# произвольного опасного кода.
# -----------------------------------------------------------------------------------------
cat > "$FIXTURE_DIR/bypass4-lastline.test.sh" <<'EOF'
#!/bin/bash
echo "опасный код уже выполнился до этой строки"
rm -rf /tmp/что-угодно-опасное
. tests/lib/bootstrap.sh
EOF
check "К1.4 (самый критичный): bootstrap ПОСЛЕДНЕЙ строкой, после произвольного кода" \
  "$FIXTURE_DIR/bypass4-lastline.test.sh" not-protected

cat > "$FIXTURE_DIR/bypass4.test.mjs" <<'EOF'
console.log("опасный код уже выполнился до этой строки");
import './lib/bootstrap.mjs';
EOF
check "К1.4 (.mjs): import ПОСЛЕДНЕЙ строкой, после произвольного кода" \
  "$FIXTURE_DIR/bypass4.test.mjs" not-protected

# -----------------------------------------------------------------------------------------
# Граничные случаи — не входят в 4 подтверждённых обхода, но проверяют, что алгоритм не падает
# и не даёт ложных срабатываний на вырожденных файлах.
# -----------------------------------------------------------------------------------------
cat > "$FIXTURE_DIR/edge-comments-only.test.sh" <<'EOF'
#!/bin/bash
# просто комментарий
set -u
EOF
check "граница: файл целиком из шебанга/комментария/set — ни одной значимой строки" \
  "$FIXTURE_DIR/edge-comments-only.test.sh" not-protected

cat > "$FIXTURE_DIR/edge-empty.test.sh" <<'EOF'
EOF
check "граница: полностью пустой файл" "$FIXTURE_DIR/edge-empty.test.sh" not-protected

echo "PASS bootstrap-detect"
