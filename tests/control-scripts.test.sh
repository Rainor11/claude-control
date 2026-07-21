#!/bin/bash
# tests/control-scripts.test.sh — T8 п.3: три старых скрипта управления контрол-сессией
# (bin/claude-rc, bin/claude-control-watchdog, bin/claude-control-session) переведены
# ВНУТРЬ забора: корень рантайма — через lib/runtime-root.sh (профиль control_only, как у
# остальных точек после T5), а kick() watchdog'а — через guard процесс-контроля (T2).
#
# ЧТО ЭТО ЗАКРЫВАЛО. До T8 эти три файла резолвили $HOME/.claude-control сами, мимо
# резолвера: под тестовым маркером их спасала ТОЛЬКО подмена HOME раннером — случайность,
# а не проверяемая граница. И bin/claude-control-watchdog звал НАСТОЯЩИЙ
# `systemctl --user restart` голой командой: под маркером его прикрывала лишь PATH-заглушка,
# то есть defense-in-depth вместо проверки.
#
# ЗАПРЕЩЕНО здесь: настоящие systemctl/systemd-run/tmux/loginctl. Watchdog ниже запускается
# ЦЕЛИКОМ, и его kick() обязан уйти в ЗАГЛУШКУ раннера ($SYSTEMCTL) — это и есть проверяемое
# утверждение; лог заглушки показывает точный argv. claude-control-session запускается с
# CLAUDE_BIN-заглушкой вместо настоящего claude. claude-rc запускается только с --help
# (read-only). Ни одна из трёх точек не доходит до боевого контура.
#
# shellcheck disable=SC2030,SC2031  # НАМЕРЕННО: env выставляется префиксом на каждом вызове
# (локально для него), а не глобально — тот же приём, что в tests/process-control.test.sh.
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bootstrap.sh"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$CLAUDE_CONTROL_TEST_ROOT"

fail() { echo "FAIL: $1"; exit 1; }

# ---------------------------------------------------------------------------------------
# 1. Статика: все три точки резолвят корень через резолвер, резолвят СВОЙ путь через
#    `readlink -f "$0"` (файлы симлинкнуты в ~/.local/bin, а ~/.local/lib пуст — без
#    разыменования source библиотеки промахнулся бы) и не держат собственного
#    $HOME/.claude-control.
# ---------------------------------------------------------------------------------------
for f in bin/claude-rc bin/claude-control-watchdog bin/claude-control-session; do
  command grep -q 'resolve_runtime_root control_only' "$DIR/$f" \
    || fail "$f не резолвит корень через resolve_runtime_root"
  # shellcheck disable=SC2016  # ищем ЛИТЕРАЛЬНУЮ строку `readlink -f "$0"` в исходнике —
  # раскрытие здесь было бы ошибкой, одинарные кавычки намеренные (то же ниже про $HOME).
  command grep -q 'readlink -f "$0"' "$DIR/$f" \
    || fail "$f резолвит свой путь без readlink -f — через симлинк из ~/.local/bin ../lib не найдётся"
  # В комментариях путь упоминаться может (объяснение «что было»), в КОДЕ — нет.
  # shellcheck disable=SC2016
  if command grep -vE '^\s*#' "$DIR/$f" | command grep -q '\$HOME/\.claude-control'; then
    fail "$f всё ещё резолвит \$HOME/.claude-control в коде мимо резолвера"
  fi
done
echo "OK: 1 — три точки резолвят корень через резолвер, свой путь — через readlink -f"

# ---------------------------------------------------------------------------------------
# 2. Статика: у watchdog'а не осталось голого systemctl (самая содержательная часть п.3).
# ---------------------------------------------------------------------------------------
command grep -q 'process_control_systemctl --user restart' "$DIR/bin/claude-control-watchdog" \
  || fail "kick() watchdog'а не переведён на process_control_systemctl"
if command grep -vE '^\s*#' "$DIR/bin/claude-control-watchdog" | command grep -qE '(^|[^_])systemctl '; then
  fail "в коде watchdog'а остался голый вызов systemctl"
fi
echo "OK: 2 — kick() watchdog'а идёт через guard, голого systemctl в коде нет"

# ---------------------------------------------------------------------------------------
# 3. E2E watchdog: замороженная сессия + ARM=1 → kick уходит В ЗАГЛУШКУ, а состояние
#    (watchdog.log, счётчик промахов) пишется ВНУТРЬ test root, а не в боевой каталог.
#    DEBUG_FILE намеренно НЕ создаём: отсутствующий файл даёт age=999999 → вердикт frozen.
# ---------------------------------------------------------------------------------------
# ТРИПВАЙР — и защита, и доказательство «не тавтология».
#
# ВАЖНАЯ ОСОБЕННОСТЬ ЭТОГО СКРИПТА: claude-control-watchdog в самом начале ПЕРЕЗАПИСЫВАЕТ
# PATH фиксированным списком ("$HOME/.local/bin:$HOME/bin:/usr/local/bin:/usr/bin:/bin").
# Значит PATH-shadow раннера (каталог заглушек первым в PATH) внутри этого скрипта НЕ
# ДЕЙСТВУЕТ ВОВСЕ: до T8 его голый `systemctl` резолвился бы в НАСТОЯЩИЙ /usr/bin/systemctl
# даже под маркером (проверено эмпирически). То есть у этой точки не было и defense-in-depth.
#
# Отсюда два следствия. (1) Запись в $STUB_LOG может появиться ТОЛЬКО через $SYSTEMCTL —
# абсолютный путь, мимо PATH, — то есть исключительно через guard: сценарий различает старый
# и новый код, а не проходит на обоих. (2) Трипвайр надо ставить в ТОТ PATH, который скрипт
# себе назначает сам, — в "$HOME/.local/bin" ПЕСОЧНИЦЫ (HOME подменён раннером). Оттуда он
# перекрывает настоящий /usr/bin/systemctl: если голый вызов когда-нибудь вернётся, тест
# поймает его файлом-отметкой, а не звонком в живой systemd.
TRIPFILE="$ROOT/tripwire-hit"
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/systemctl" <<STUB
#!/bin/bash
echo "\$*" >> "$TRIPFILE"
exit 0
STUB
chmod +x "$HOME/.local/bin/systemctl"

run_watchdog() { # <путь к исполняемому watchdog>
  CLAUDE_CONTROL_WATCHDOG_ARM=1 \
  CLAUDE_CONTROL_MISS_THRESHOLD=1 \
  CLAUDE_CONTROL_LABEL=claude-control-TEST.service \
  CLAUDE_CONTROL_DEBUG_FILE="$ROOT/control.debug.log" \
  "$1"
}

before=0; [ -f "$STUB_LOG" ] && before="$(wc -l < "$STUB_LOG")"
run_watchdog "$DIR/bin/claude-control-watchdog" || fail "watchdog завершился ошибкой"
after=0; [ -f "$STUB_LOG" ] && after="$(wc -l < "$STUB_LOG")"
[ "$after" -gt "$before" ] || fail "заглушка процесс-контроля не вызывалась — kick никуда не ушёл"
command grep -q $'systemctl\t--user\trestart\tclaude-control-TEST.service' "$STUB_LOG" \
  || fail "в логе заглушки нет 'systemctl --user restart claude-control-TEST.service': $(cat "$STUB_LOG")"
[ ! -e "$TRIPFILE" ] || fail "kick пошёл ГОЛЫМ systemctl через PATH, а не через guard (трипвайр сработал: $(cat "$TRIPFILE"))"
[ -f "$ROOT/watchdog.log" ] || fail "watchdog.log не создан внутри test root — корень не уехал в песочницу"
[ -f "$ROOT/.watchdog-misses" ] || fail "счётчик промахов не создан внутри test root"
[ ! -e "$HOME/.claude-control/watchdog.log" ] || fail "watchdog написал в \$HOME/.claude-control песочницы вместо корня маркера"
echo "OK: 3 — watchdog под маркером кикает ЗАГЛУШКУ через guard (трипвайр на голый systemctl не сработал)"

# ---------------------------------------------------------------------------------------
# 4. То же самое, но запуск ЧЕРЕЗ СИМЛИНК (как в ~/.local/bin): проверяем ровно тот случай,
#    ради которого в файле стоит `readlink -f "$0"`. Каталог симлинка НЕ имеет соседнего
#    lib/ — без разыменования source упал бы.
# ---------------------------------------------------------------------------------------
mkdir -p "$ROOT/fakebin"
ln -s "$DIR/bin/claude-control-watchdog" "$ROOT/fakebin/claude-control-watchdog"
[ -d "$ROOT/fakebin/../lib" ] && fail "фикстура сломана: рядом с симлинком не должно быть lib/"
rm -f "$STUB_LOG"
run_watchdog "$ROOT/fakebin/claude-control-watchdog" || fail "watchdog через симлинк завершился ошибкой (не нашёл ../lib?)"
command grep -q $'systemctl\t--user\trestart\tclaude-control-TEST.service' "$STUB_LOG" \
  || fail "через симлинк kick не дошёл до заглушки: $(cat "$STUB_LOG" 2>/dev/null)"
[ ! -e "$TRIPFILE" ] || fail "через симлинк kick пошёл голым systemctl (трипвайр: $(cat "$TRIPFILE"))"
echo "OK: 4 — через симлинк библиотека находится, kick снова уходит в заглушку через guard"

# ---------------------------------------------------------------------------------------
# 5. E2E claude-rc: под маркером корень уезжает в test root — видно по строке «Projects
#    file:» в --help. Запускается ТОЛЬКО --help (read-only, до tmux дело не доходит).
# ---------------------------------------------------------------------------------------
if command -v yq >/dev/null 2>&1; then
  : > "$ROOT/projects.yaml"
  out="$("$DIR/bin/claude-rc" --help 2>&1)" || fail "claude-rc --help завершился ошибкой: $out"
  case "$out" in
    *"Projects file: $ROOT/projects.yaml"*) ;;
    *) fail "claude-rc под маркером резолвит projects.yaml НЕ в test root: $out" ;;
  esac
  echo "OK: 5 — claude-rc под маркером берёт projects.yaml из test root"
else
  echo "ПРОПУСК: 5 — yq не установлен, claude-rc отказывается работать без него (не предмет T8)"
fi

# ---------------------------------------------------------------------------------------
# 6. E2E claude-control-session: вместо настоящего claude подставлена CLAUDE_BIN-заглушка,
#    которая печатает свой рабочий каталог и argv. Под маркером и cd, и --debug-file обязаны
#    указывать в test root (до T8 это был бы боевой ~/.claude-control).
# ---------------------------------------------------------------------------------------
cat > "$ROOT/fake-claude" <<'STUB'
#!/bin/bash
printf 'CWD=%s\n' "$PWD"
printf 'ARGV=%s\n' "$*"
STUB
chmod +x "$ROOT/fake-claude"
out="$(CLAUDE_BIN="$ROOT/fake-claude" "$DIR/bin/claude-control-session" 2>&1)" \
  || fail "claude-control-session завершился ошибкой: $out"
case "$out" in
  *"CWD=$ROOT"*) ;;
  *) fail "claude-control-session сделал cd НЕ в test root: $out" ;;
esac
case "$out" in
  *"--debug-file $ROOT/control.debug.log"*) ;;
  *) fail "claude-control-session передал --debug-file вне test root: $out" ;;
esac
echo "OK: 6 — claude-control-session под маркером работает в test root (cd + --debug-file)"

# ---------------------------------------------------------------------------------------
# 7. В2 (ревью T8): claude-control-session БЕЗ явного CLAUDE_BIN обязан уйти в заглушку
#    РАННЕРА, а не искать голое имя `claude` по PATH. Скрипт назначает себе СВОЙ PATH
#    ($HOME/.local/bin:…), поэтому stub_dir раннера из PATH сюда не доживает — единственная
#    граница здесь это форсированный tests/run::CLAUDE_BIN. Раньше раннер его, наоборот,
#    unset'ил, и тест спасала лишь случайность (настоящий claude лежит в подменённом
#    $HOME/.local/bin); появись claude в /usr/local/bin — поднялась бы НАСТОЯЩАЯ
#    remote-control-сессия. Доказательство — по логу argv заглушки, не по коду возврата.
# ---------------------------------------------------------------------------------------
before=0; [ -f "$STUB_LOG" ] && before="$(wc -l < "$STUB_LOG")"
out="$("$DIR/bin/claude-control-session" 2>&1)" \
  || fail "claude-control-session без явного CLAUDE_BIN завершился ошибкой: $out"
after=0; [ -f "$STUB_LOG" ] && after="$(wc -l < "$STUB_LOG")"
[ "$after" -gt "$before" ] \
  || fail "заглушка claude не вызвана — CLAUDE_BIN не форсирован раннером, голое имя ушло в PATH скрипта"
command grep -qE "^claude$(printf '\t')remote-control" "$STUB_LOG" \
  || fail "в логе заглушки нет вызова claude remote-control: $(cat "$STUB_LOG")"
echo "OK: 7 — claude-control-session без явного CLAUDE_BIN уходит в заглушку раннера (В2)"

echo "PASS control-scripts"
