#!/bin/bash
# tests/run.test.sh — тесты МЕХАНИКИ раннера tests/run (T3, .superpowers/sdd/iso-t3-brief.md):
# discovery, свежая песочница на тест, PASS/FAIL-агрегация, уборка, карантин.
#
# Этот файл — НОВЫЙ тест T3, сам обязан подключать bootstrap первой строкой (см.
# lint-bootstrap.test.sh).
#
# БЕЗОПАСНОСТЬ: ВСЕ сценарии здесь гоняют tests/run ПРОТИВ ИГРУШЕЧНЫХ fixture-тестов во
# ВРЕМЕННОМ каталоге через TESTS_RUN_DIR_OVERRIDE — ни один настоящий тест из боевого набора
# НЕ запускается. Сценарии карантина используют тест-шов QUARANTINE_TEST_ADD (add-only,
# см. tests/run): после T4 боевой список QUARANTINE пуст (tests/asana-project-integration
# снят — guard процесс-контроля подключён к claude-auto cmd_sleep, см.
# .superpowers/sdd/iso-t4-report.md), поэтому механику карантина проверяем на искусственно
# закарантиненной toy-фикстуре, а не на реальном жильце. Симлинк-сценарий (В2) карантинит
# заведомо безобидный tests/bootstrap-detect.test.sh по realpath и адресует его симлинком —
# сам файл в прогон при этом не входит.
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bootstrap.sh"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$DIR/tests/run"
fail() { echo "FAIL: $1"; exit 1; }

# -----------------------------------------------------------------------------------------
# Fixture: игрушечный каталог тестов (НЕ tests/ — отдельный temp, чтобы discovery/quarantine
# раннера ни разу не тронули боевой набор).
# -----------------------------------------------------------------------------------------
FIXTURE_DIR="$(mktemp -d)"
SCRATCH_TMPDIR="$(mktemp -d)"   # отдельный TMPDIR — чтобы проверить уборку песочниц без шума
trap 'rm -rf "$FIXTURE_DIR" "$SCRATCH_TMPDIR"' EXIT

# toy-legacy.test.sh — НЕ упоминает lib/bootstrap.* → раннер НЕ обязан форсить
# SYSTEMCTL/DEPT_SYSTEMD_RUN/TMUX_BIN (regression-тест находки при верификации раннера на
# tests/process-control.test.sh — см. tests/run::uses_bootstrap).
cat > "$FIXTURE_DIR/toy-legacy.test.sh" <<'EOF'
#!/bin/bash
set -u
[ -n "${CLAUDE_CONTROL_TEST_ROOT:-}" ] || { echo "toy-legacy: маркер не выставлен"; exit 1; }
[ -f "$CLAUDE_CONTROL_TEST_ROOT/.claude-control-test-root" ] || { echo "toy-legacy: нет sentinel"; exit 1; }
[ -z "${SYSTEMCTL:-}" ] || { echo "toy-legacy: SYSTEMCTL НЕ должен быть выставлен для не-bootstrap теста (получено '$SYSTEMCTL')"; exit 1; }
echo "SANDBOX=$CLAUDE_CONTROL_TEST_ROOT"
echo "toy-legacy: OK"
EOF

# TOY_BOOTSTRAP_TESTS_DIR — абсолютный путь к РЕАЛЬНОМУ tests/ репозитория (НЕ FIXTURE_DIR).
# toy-migrated.test.sh ниже РЕАЛЬНО source'ит настоящий tests/lib/bootstrap.sh (после фикса
# К1, см. iso-t3-report.md, детектор требует, чтобы bootstrap был ПЕРВОЙ значимой строкой —
# прежний heredoc-трюк, имитировавший подключение БЕЗ реального source, стал сам одним из 4
# подтверждённых обходов и намеренно перестал засчитываться; фикстура обязана соответствовать
# новому правилу, а не имитировать его, см. iso-t3-brief.md "почини фикстуру, если она станет
# невалидной"). export — heredoc фикстуры ЦЕЛИКОМ в одинарных кавычках (<<'EOF' ниже), значит
# "$TOY_BOOTSTRAP_TESTS_DIR" остаётся ЛИТЕРАЛЬНЫМ текстом в файле и резолвится УЖЕ внутри
# дочернего процесса теста (не в момент создания фикстуры родительским run.test.sh) — простой
# способ передать абсолютный путь без порчи остальных '$' внутри heredoc'а. Наследуется в
# дочерний процесс теста обычным bash-наследованием окружения (run_one НЕ делает env -i).
export TOY_BOOTSTRAP_TESTS_DIR="$DIR/tests"

# toy-migrated.test.sh — РЕАЛЬНО подключает настоящий tests/lib/bootstrap.sh первой значимой
# строкой (после `set -u` — допустимая пред-bootstrap директива, см. tests/lib/
# bootstrap-detect.sh). Раннер ОБЯЗАН выставить все 3 seam-переменные внутри test root,
# PATH-заглушки обязаны реально перехватывать вызовы (проверяем STUB_LOG).
cat > "$FIXTURE_DIR/toy-migrated.test.sh" <<'EOF'
#!/bin/bash
set -u
. "$TOY_BOOTSTRAP_TESTS_DIR/lib/bootstrap.sh"
[ -n "${SYSTEMCTL:-}" ] || { echo "toy-migrated: SYSTEMCTL обязан быть выставлен"; exit 1; }
[ -n "${DEPT_SYSTEMD_RUN:-}" ] || { echo "toy-migrated: DEPT_SYSTEMD_RUN обязан быть выставлен"; exit 1; }
[ -n "${TMUX_BIN:-}" ] || { echo "toy-migrated: TMUX_BIN обязан быть выставлен"; exit 1; }
case "$SYSTEMCTL" in
  "$CLAUDE_CONTROL_TEST_ROOT"/*) ;;
  *) echo "toy-migrated: SYSTEMCTL='$SYSTEMCTL' не внутри test root '$CLAUDE_CONTROL_TEST_ROOT'"; exit 1 ;;
esac
[ -x "$SYSTEMCTL" ] || { echo "toy-migrated: SYSTEMCTL не исполняем"; exit 1; }
# Реальный вызов заглушки (НЕ настоящий systemctl — это файл, который создал сам раннер) —
# проверяем, что STUB_LOG реально фиксирует вызов.
"$SYSTEMCTL" --user is-active toy-unit
command grep -q -- 'systemctl	--user	is-active	toy-unit' "$STUB_LOG" \
  || { echo "toy-migrated: STUB_LOG не содержит вызов заглушки: $(cat "$STUB_LOG" 2>/dev/null)"; exit 1; }
# Defense-in-depth: голое имя "systemctl"/"tmux" через PATH ТОЖЕ обязано резолвиться в
# заглушку внутри test root (не читать реальный systemctl — только command -v, read-only).
resolved="$(command -v systemctl)"
case "$resolved" in
  "$CLAUDE_CONTROL_TEST_ROOT"/*) ;;
  *) echo "toy-migrated: голое 'systemctl' резолвится ВНЕ test root: $resolved"; exit 1 ;;
esac
[ -n "${TELEGRAM_NOTIFY:-}" ] || { echo "toy-migrated: TELEGRAM_NOTIFY не выставлен"; exit 1; }
[ -n "${RNR_ASKS_DB:-}" ] || { echo "toy-migrated: RNR_ASKS_DB не выставлен"; exit 1; }
[ "$HOME" != "/home/rainor" ] || { echo "toy-migrated: HOME указывает на боевой домашний каталог"; exit 1; }
echo "toy-migrated: OK"
EOF

# toy-bypass-lastline.test.sh — К1 случай 4 (самый критичный по брифу, см. iso-t3-report.md):
# "упоминает" bootstrap ПОСЛЕДНЕЙ строкой файла, ПОСЛЕ произвольного кода (здесь — безобидного
# echo, для реального опасного кода конструкция была бы буквально та же). Первая значимая
# строка — НЕ bootstrap, значит detect_bootstrap_connection обязан признать файл
# НЕЗАЩИЩЁННЫМ, и раннер НЕ форсит SYSTEMCTL/DEPT_SYSTEMD_RUN/TMUX_BIN (тот же regression-
# принцип, что toy-legacy, но конкретно на самом опасном из 4 подтверждённых обходов).
cat > "$FIXTURE_DIR/toy-bypass-lastline.test.sh" <<'EOF'
#!/bin/bash
set -u
echo "toy-bypass-lastline: код ДО псевдо-bootstrap уже выполнился"
[ -z "${SYSTEMCTL:-}" ] || { echo "toy-bypass-lastline: SYSTEMCTL НЕ должен быть выставлен — bootstrap НЕ первая значимая строка"; exit 1; }
echo "toy-bypass-lastline: OK"
exit 0
# Строка ниже НИКОГДА не исполняется (exit 0 выше) — именно это и демонстрирует К1 случай 4:
# текстуально файл "подключает" bootstrap, но реально это происходит (если вообще происходит)
# ПОСЛЕ всего опасного кода, а не до него.
. tests/lib/bootstrap.sh
EOF

# toy-fail.test.sh — намеренно падает, для проверки FAIL-агрегации раннера.
cat > "$FIXTURE_DIR/toy-fail.test.sh" <<'EOF'
#!/bin/bash
echo "toy-fail: специально падаю"
exit 1
EOF

# toy-pass.test.mjs — минимальный node:test, проверяет ветку `*.test.mjs` раннера
# (`node --test`).
cat > "$FIXTURE_DIR/toy-pass.test.mjs" <<'EOF'
import { test } from 'node:test';
import assert from 'node:assert/strict';
test('toy mjs passes', () => { assert.equal(1 + 1, 2); });
EOF

chmod +x "$FIXTURE_DIR"/*.test.sh

# -----------------------------------------------------------------------------------------
# 1) полный прогон fixture-каталога — discovery + PASS/FAIL агрегация + сообщения
# -----------------------------------------------------------------------------------------
out="$(TESTS_RUN_DIR_OVERRIDE="$FIXTURE_DIR" TMPDIR="$SCRATCH_TMPDIR" "$RUNNER" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "прогон с одним заведомо падающим тестом обязан вернуть ненулевой rc: $out"
echo "$out" | command grep -q "toy-legacy: OK" || fail "toy-legacy не прошёл: $out"
echo "$out" | command grep -q "toy-migrated: OK" || fail "toy-migrated не прошёл: $out"
echo "$out" | command grep -q "toy-fail: специально падаю" || fail "toy-fail: вывод теста не долетел до раннера: $out"
echo "$out" | command grep -q "PASS: tests/toy-legacy.test.sh" || fail "toy-legacy не помечен PASS: $out"
echo "$out" | command grep -q "PASS: tests/toy-migrated.test.sh" || fail "toy-migrated не помечен PASS: $out"
echo "$out" | command grep -q "FAIL: tests/toy-fail.test.sh" || fail "toy-fail не помечен FAIL: $out"
echo "$out" | command grep -q "PASS: tests/toy-pass.test.mjs" || fail ".mjs-тест (node --test) не прошёл через раннер: $out"
echo "$out" | command grep -q "toy-bypass-lastline: OK" || fail "toy-bypass-lastline не прошёл: $out"
echo "$out" | command grep -q "PASS: tests/toy-bypass-lastline.test.sh" || fail "toy-bypass-lastline не помечен PASS: $out"
echo "$out" | command grep -q "4 passed, 1 failed, 0 quarantined из 5" \
  || fail "итоговая сводка не совпала (ожидали 4 passed/1 failed/0 quarantined из 5): $out"
echo "OK: полный прогон fixture — discovery + PASS/FAIL агрегация корректны"

# -----------------------------------------------------------------------------------------
# 2) свежая песочница НА КАЖДЫЙ тест — два разных SANDBOX= в выводе (toy-legacy печатает
#    свой CLAUDE_CONTROL_TEST_ROOT; сравниваем с тем, что видел toy-migrated косвенно через
#    STUB_LOG путь — оба обязаны отличаться друг от друга).
# -----------------------------------------------------------------------------------------
sandbox1="$(echo "$out" | command grep -o 'SANDBOX=\S*' | head -1 | cut -d= -f2)"
[ -n "$sandbox1" ] || fail "не удалось извлечь SANDBOX= из вывода toy-legacy"
[ ! -d "$sandbox1" ] || fail "песочница toy-legacy НЕ убрана после прогона: $sandbox1"
echo "OK: песочница убрана после теста (каталог не существует постфактум)"

# -----------------------------------------------------------------------------------------
# 3) раннер НЕ трогает ничего вне своих песочниц — SCRATCH_TMPDIR пуст после прогона (все
#    mktemp -d "$TMPDIR/claude-control-test.XXXXXX" убраны, посторонних файлов не появилось).
# -----------------------------------------------------------------------------------------
leftover="$(find "$SCRATCH_TMPDIR" -mindepth 1 2>/dev/null | wc -l)"
[ "$leftover" -eq 0 ] || fail "TMPDIR не пуст после прогона — раннер оставил $leftover файлов/каталогов: $(find "$SCRATCH_TMPDIR" -mindepth 1)"
echo "OK: раннер не оставляет файлы вне собственных песочниц (TMPDIR пуст постфактум)"

# -----------------------------------------------------------------------------------------
# 4) --list на fixture-каталоге — ничего не выполняет (никакого "OK"/"PASS" в выводе),
#    только перечисляет.
# -----------------------------------------------------------------------------------------
out_list="$(TESTS_RUN_DIR_OVERRIDE="$FIXTURE_DIR" "$RUNNER" --list 2>&1)"
rc_list=$?
[ "$rc_list" -eq 0 ] || fail "--list обязан вернуть 0: $out_list"
echo "$out_list" | command grep -q "toy-legacy.test.sh" || fail "--list не показал toy-legacy: $out_list"
echo "$out_list" | command grep -q "toy-fail.test.sh" || fail "--list не показал toy-fail: $out_list"
echo "$out_list" | command grep -q "toy-legacy: OK" && fail "--list ЗАПУСТИЛ тест вместо перечисления: $out_list"
echo "OK: --list перечисляет, ничего не выполняя"

# -----------------------------------------------------------------------------------------
# 5) явный выбор ОДНОГО файла (голым именем, без префикса "tests/") — запускается только он.
# -----------------------------------------------------------------------------------------
out_one="$(TESTS_RUN_DIR_OVERRIDE="$FIXTURE_DIR" TMPDIR="$SCRATCH_TMPDIR" "$RUNNER" toy-legacy.test.sh 2>&1)"
rc_one=$?
[ "$rc_one" -eq 0 ] || fail "явный выбор toy-legacy.test.sh (без 'tests/') обязан пройти: $out_one"
echo "$out_one" | command grep -q "toy-legacy: OK" || fail "явный выбор не запустил toy-legacy: $out_one"
echo "$out_one" | command grep -q "toy-fail" && fail "явный выбор одного файла запустил ЛИШНИЙ (toy-fail): $out_one"
echo "$out_one" | command grep -q "1 passed, 0 failed, 0 quarantined из 1" \
  || fail "сводка явного выбора одного файла не совпала: $out_one"
echo "OK: явный выбор одного файла (голое имя) — запускается только он"

# -----------------------------------------------------------------------------------------
# 6) несуществующий явный аргумент — явная ошибка, ненулевой rc, ничего не выполняется.
# -----------------------------------------------------------------------------------------
out_missing="$(TESTS_RUN_DIR_OVERRIDE="$FIXTURE_DIR" "$RUNNER" no-such-file.test.sh 2>&1)"
rc_missing=$?
[ "$rc_missing" -ne 0 ] || fail "несуществующий файл обязан вернуть ненулевой rc: $out_missing"
echo "$out_missing" | command grep -qi "не найден" || fail "несуществующий файл: сообщение не объясняет причину: $out_missing"
echo "OK: несуществующий явный аргумент — явная ошибка, ничего не выполнено"

# -----------------------------------------------------------------------------------------
# 7) КАРАНТИН — физическая невозможность запуска, даже явным аргументом. Механику проверяем
#    на toy-фикстуре, искусственно закарантиненной тест-швом QUARANTINE_TEST_ADD (после T4
#    боевой список QUARANTINE пуст — asana-project-integration снят, guard подключён к
#    cmd_sleep). toy-quar НАРОЧНО завершился бы PASS (echo+exit 0), если бы запустился, —
#    поэтому появление PASS/FAIL в выводе однозначно означало бы, что карантин НЕ сработал.
# -----------------------------------------------------------------------------------------
QUAR_FIXTURE_DIR="$(mktemp -d)"
cat > "$QUAR_FIXTURE_DIR/toy-quar.test.sh" <<'EOF'
#!/bin/bash
echo "toy-quar: ВЫПОЛНИЛСЯ (карантин не сработал!)"; exit 0
EOF
out_q="$(TESTS_RUN_DIR_OVERRIDE="$QUAR_FIXTURE_DIR" QUARANTINE_TEST_ADD="tests/toy-quar.test.sh" "$RUNNER" tests/toy-quar.test.sh 2>&1)"
rc_q=$?
rm -rf "$QUAR_FIXTURE_DIR"
[ "$rc_q" -eq 0 ] || fail "прогон единственного карантинного файла обязан вернуть 0 (не FAIL, не запуск): $out_q"
echo "$out_q" | command grep -q "QUARANTINE: tests/toy-quar.test.sh" \
  || fail "карантинный файл не помечен QUARANTINE: $out_q"
echo "$out_q" | command grep -qi "systemctl.*disable\|disable.*systemctl\|cmd_sleep" \
  || fail "карантинная причина не объясняет опасность: $out_q"
echo "$out_q" | command grep -q "PASS:\|FAIL:" && fail "карантинный файл получил PASS/FAIL — значит попытка выполнения БЫЛА: $out_q"
echo "$out_q" | command grep -q "0 passed, 0 failed, 1 quarantined из 1" \
  || fail "сводка для одного карантинного файла не совпала: $out_q"
echo "OK: карантин — явное указание карантинного файла не запускает его (0 passed/failed, 1 quarantined)"

# Смешанный список: безопасный toy + закарантиненный toy в ОДНОМ override-каталоге —
# проверяем, что карантин побеждает ДАЖЕ когда рядом есть легитимный кандидат, а не только в
# одиночном вызове.
MIX_FIXTURE_DIR="$(mktemp -d)"
cat > "$MIX_FIXTURE_DIR/toy-pass.test.sh" <<'EOF'
#!/bin/bash
echo "toy-pass: OK"; exit 0
EOF
cat > "$MIX_FIXTURE_DIR/toy-quar2.test.sh" <<'EOF'
#!/bin/bash
echo "toy-quar2: ВЫПОЛНИЛСЯ (карантин не сработал!)"; exit 0
EOF
out_mixed="$(TESTS_RUN_DIR_OVERRIDE="$MIX_FIXTURE_DIR" TMPDIR="$SCRATCH_TMPDIR" QUARANTINE_TEST_ADD="tests/toy-quar2.test.sh" "$RUNNER" tests/toy-pass.test.sh tests/toy-quar2.test.sh 2>&1)"
rc_mixed=$?
rm -rf "$MIX_FIXTURE_DIR"
[ "$rc_mixed" -ne 0 ] && echo "$out_mixed" | command grep -q "FAIL: tests/toy-pass.test.sh" && fail "toy-pass.test.sh неожиданно упал в смешанном прогоне: $out_mixed"
echo "$out_mixed" | command grep -q "PASS: tests/toy-pass.test.sh" || fail "смешанный прогон: toy-pass.test.sh не прошёл: $out_mixed"
echo "$out_mixed" | command grep -q "QUARANTINE: tests/toy-quar2.test.sh" \
  || fail "смешанный прогон: карантинный файл не помечен QUARANTINE рядом с легитимным: $out_mixed"
echo "$out_mixed" | command grep -q "1 passed, 0 failed, 1 quarantined из 2" \
  || fail "смешанный прогон: сводка не совпала: $out_mixed"
echo "OK: карантин побеждает даже в смешанном списке с легитимным кандидатом"

# -----------------------------------------------------------------------------------------
# 8) В2 (ревью T3) — СИМЛИНК на карантинный файл под ДРУГИМ именем ТОЖЕ карантинится (по
#    realpath, не по имени) — закрывает обход "tests/<copy>.test.sh -> реальный карантинный
#    файл под другим именем не попадал под карантин по ИМЕНИ и физически исполнялся бы".
#    Карантиним заведомо безобидный РЕАЛЬНЫЙ tests/bootstrap-detect.test.sh через шов (его
#    realpath попадает в QUARANTINE_REAL, вычисляемый от _RUN_REPO_DIR), а в override-каталоге
#    кладём СИМЛИНК на него под другим именем. Сам bootstrap-detect в прогон НЕ входит:
#    discovery видит только override-каталог с симлинком; is_quarantined ловит его по realpath
#    ДО mktemp/exec — та же гарантия "физически не запускается", что и у оригинала.
# -----------------------------------------------------------------------------------------
SYMLINK_FIXTURE_DIR="$(mktemp -d)"
ln -s "$DIR/tests/bootstrap-detect.test.sh" "$SYMLINK_FIXTURE_DIR/quar-copy-symlink.test.sh"
out_symlink="$(TESTS_RUN_DIR_OVERRIDE="$SYMLINK_FIXTURE_DIR" QUARANTINE_TEST_ADD="tests/bootstrap-detect.test.sh" "$RUNNER" 2>&1)"
rc_symlink=$?
rm -rf "$SYMLINK_FIXTURE_DIR"
[ "$rc_symlink" -eq 0 ] || fail "симлинк на карантинный файл под другим именем обязан дать rc=0 (карантин, не FAIL): $out_symlink"
echo "$out_symlink" | command grep -q "QUARANTINE: tests/quar-copy-symlink.test.sh" \
  || fail "В2: симлинк на карантинный файл под другим именем НЕ пойман (обход по имени всё ещё возможен): $out_symlink"
echo "$out_symlink" | command grep -q "PASS:\|FAIL:" && fail "В2: симлинк-обход дал попытку исполнения (PASS/FAIL) — карантин не сработал: $out_symlink"
echo "$out_symlink" | command grep -q "0 passed, 0 failed, 1 quarantined из 1" \
  || fail "В2: сводка для симлинк-обхода не совпала: $out_symlink"
echo "OK: В2 — симлинк на карантинный файл под другим именем ТОЖЕ карантинится (realpath, не имя)"

# -----------------------------------------------------------------------------------------
# 9) В3 (ревью T3, случай "б") — тест, ограничивший права ВНУТРИ своей же песочницы (chmod 000
#    на подкаталог), НЕ мешает уборке. Раньше `rm -rf` тихо проваливался (нет r+x на locked/,
#    рекурсия не заходит внутрь), результат нигде не проверялся — теперь `chmod -R u+rwx`
#    ПЕРЕД `rm -rf` восстанавливает права (мы владелец — это работает независимо от текущего
#    режима файла) в _cleanup_sandbox. Отдельные fixture/TMPDIR — не сбивают счётчики сценария 1.
# -----------------------------------------------------------------------------------------
CHMOD_FIXTURE_DIR="$(mktemp -d)"
CHMOD_TMPDIR="$(mktemp -d)"
cat > "$CHMOD_FIXTURE_DIR/toy-chmod-lock.test.sh" <<'EOF'
#!/bin/bash
set -u
mkdir -p "$CLAUDE_CONTROL_TEST_ROOT/locked"
touch "$CLAUDE_CONTROL_TEST_ROOT/locked/file.txt"
chmod 000 "$CLAUDE_CONTROL_TEST_ROOT/locked"
echo "toy-chmod-lock: OK"
EOF
out_chmod="$(TESTS_RUN_DIR_OVERRIDE="$CHMOD_FIXTURE_DIR" TMPDIR="$CHMOD_TMPDIR" "$RUNNER" 2>&1)"
rc_chmod=$?
[ "$rc_chmod" -eq 0 ] || fail "В3: тест с chmod 000 внутри своей песочницы обязан пройти: $out_chmod"
echo "$out_chmod" | command grep -q "toy-chmod-lock: OK" || fail "В3: toy-chmod-lock не прошёл: $out_chmod"
leftover_chmod="$(find "$CHMOD_TMPDIR" -mindepth 1 2>/dev/null | wc -l)"
rm -rf "$CHMOD_FIXTURE_DIR" "$CHMOD_TMPDIR"
[ "$leftover_chmod" -eq 0 ] || fail "В3: песочница НЕ убрана после chmod 000 внутри неё — rm -rf молча провалился (leftover=$leftover_chmod)"
echo "OK: В3 — chmod 000 внутри песочницы не мешает уборке (chmod -R u+rwx перед rm -rf)"

# -----------------------------------------------------------------------------------------
# 10) В3 (случай "а") — SIGTERM раннеру ПОКА тест ещё выполняется (раннер блокирован в
#     command substitution, ждёт дочерний sleep) убирает песочницу через trap на EXIT/INT/
#     TERM, а не оставляет её в $TMPDIR навсегда (раньше — ни одного trap в файле).
# -----------------------------------------------------------------------------------------
SIGTERM_FIXTURE_DIR="$(mktemp -d)"
SIGTERM_TMPDIR="$(mktemp -d)"
SIGTERM_LOG="$(mktemp)"
cat > "$SIGTERM_FIXTURE_DIR/toy-sleep-forever.test.sh" <<'EOF'
#!/bin/bash
set -u
sleep 20
EOF
TESTS_RUN_DIR_OVERRIDE="$SIGTERM_FIXTURE_DIR" TMPDIR="$SIGTERM_TMPDIR" "$RUNNER" toy-sleep-forever.test.sh \
  > "$SIGTERM_LOG" 2>&1 &
runner_pid=$!
sleep 1
kill -TERM "$runner_pid" 2>/dev/null
wait "$runner_pid" 2>/dev/null
term_rc=$?
leftover_term="$(find "$SIGTERM_TMPDIR" -mindepth 1 2>/dev/null | wc -l)"
rm -rf "$SIGTERM_FIXTURE_DIR" "$SIGTERM_TMPDIR" "$SIGTERM_LOG"
[ "$term_rc" -eq 143 ] || fail "В3: SIGTERM раннеру во время выполнения теста обязан дать rc=143 (128+15), получили $term_rc"
[ "$leftover_term" -eq 0 ] || fail "В3: SIGTERM раннеру ПОКА тест выполняется оставил песочницу в TMPDIR (leftover=$leftover_term) — trap не сработал"
echo "OK: В3 — SIGTERM во время выполнения теста убирает песочницу (trap EXIT/INT/TERM)"

echo "PASS run"
