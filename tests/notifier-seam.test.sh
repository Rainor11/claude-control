#!/bin/bash
# tests/notifier-seam.test.sh — T8 п.1: шов telegram-нотификатора, ГЕЙТИРОВАННЫЙ маркером
# CLAUDE_CONTROL_TEST_ROOT (lib/process-control.sh::process_control_notifier_path).
#
# ЧТО ЭТО ЗАКРЫВАЕТ. Пять точек держали путь к telegram_notify.sh абсолютным и
# НЕперекрываемым намеренно (анти-подмена: воркер не должен уметь перенаправить уведомления
# оператору). Побочный эффект — тест не мог подставить заглушку, и забытый override означал
# СООБЩЕНИЕ ЖИВОМУ ЧЕЛОВЕКУ из тестового прогона. Теперь override допускается только под
# валидным маркером; без маркера значение env не читается вовсе.
#
# ЗАПРЕЩЕНО здесь: настоящие systemctl/systemd-run/tmux/loginctl и настоящая отправка в
# Telegram. Единственный «исполняемый нотификатор» в этом файле — заглушка раннера
# ($TELEGRAM_NOTIFY внутри песочницы), которая только пишет argv в $STUB_LOG.
#
# shellcheck disable=SC2030,SC2031  # НАМЕРЕННО: каждый сценарий export'ит переменные ТОЛЬКО
# внутри своего `( ... )`-подшелла (seam_env ниже) — локальность и есть цель, иначе один
# сценарий отравил бы окружение следующего. Тот же приём и то же подавление, что в
# tests/process-control.test.sh.
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bootstrap.sh"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$DIR/lib/process-control.sh"
LITERAL="/home/rainor/server/server_monitor/telegram_notify.sh"
ROOT="$CLAUDE_CONTROL_TEST_ROOT"
STUB="$TELEGRAM_NOTIFY"
# Раннер подставляет TELEGRAM_NOTIFY КАЖДОМУ тесту с прологом — а этот файл тестирует САМ
# шов, включая сценарий «переопределение НЕ задано» (обязан быть отказ). Унаследованное
# значение подменило бы проверяемое поведение. Гасим ОДИН раз здесь, ПОСЛЕ пролога (пролог
# сам требует полностью построенной песочницы), дальше каждый сценарий передаёт значение
# СВОИМ env-префиксом на вызове. Внутри seam_env unset делать нельзя — он затёр бы именно
# эти явные префиксы (тот же приём и та же оговорка, что в tests/process-control.test.sh).
unset TELEGRAM_NOTIFY

fail() { echo "FAIL: $1"; exit 1; }

# seam_env <root|-> [env-присваивания через префикс вызова] — зовёт
# process_control_notifier_path "$LITERAL" в ИЗОЛИРОВАННОМ подшелле. "-" = маркер не
# выставляется вовсе (прод-путь). Тот же приём, что run_env в tests/process-control.test.sh:
# переменные, переданные env-префиксом на вызове seam_env, наследуются подшеллом, но НЕ
# протекают ни в родительский шелл, ни в соседний сценарий.
seam_env() {
  local root="$1"
  (
    unset CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME CLAUDE_CONTROL_TEST_ROOT
    [ "$root" = "-" ] || export CLAUDE_CONTROL_TEST_ROOT="$root"
    # shellcheck disable=SC1090
    . "$LIB"
    process_control_notifier_path "$LITERAL"
  )
}

# ---------------------------------------------------------------------------------------
# 1. БЕЗ маркера — буквально переданный литерал, сколько бы «подмен» ни лежало в окружении.
#    Это и есть инвариант «в бою поведение побитово прежнее»: анти-подмена не ослаблена.
# ---------------------------------------------------------------------------------------
evil_dir="$ROOT/evil-path"
mkdir -p "$evil_dir"
printf '#!/bin/bash\nexit 0\n' > "$evil_dir/telegram_notify.sh"
chmod +x "$evil_dir/telegram_notify.sh"

out="$(seam_env -)" || fail "без маркера шов обязан отработать успешно, получено: $out"
[ "$out" = "$LITERAL" ] || fail "без маркера ожидался литерал '$LITERAL', получено '$out'"

out="$(TELEGRAM_NOTIFY="$evil_dir/telegram_notify.sh" seam_env -)" \
  || fail "без маркера с подсунутым TELEGRAM_NOTIFY шов обязан отработать успешно"
[ "$out" = "$LITERAL" ] \
  || fail "без маркера TELEGRAM_NOTIFY обязан ИГНОРИРОВАТЬСЯ, получено '$out'"

out="$(CLAUDE_AUTO_TG=/tmp/evil-a CLAUDE_CONTROL_TG=/tmp/evil-b seam_env -)" \
  || fail "без маркера с подсунутыми CLAUDE_AUTO_TG/CLAUDE_CONTROL_TG шов обязан отработать"
[ "$out" = "$LITERAL" ] \
  || fail "без маркера CLAUDE_AUTO_TG/CLAUDE_CONTROL_TG обязаны ИГНОРИРОВАТЬСЯ, получено '$out'"

out="$(PATH="$evil_dir:$PATH" seam_env -)" || fail "без маркера с фейком в PATH шов обязан отработать"
[ "$out" = "$LITERAL" ] || fail "без маркера PATH не должен влиять на путь нотификатора, получено '$out'"
echo "OK: 1 — без маркера путь нотификатора неперекрываем (env/PATH игнорируются)"

# ---------------------------------------------------------------------------------------
# 2. ПОД маркером с заглушкой внутри test root — печатается путь заглушки.
# ---------------------------------------------------------------------------------------
out="$(TELEGRAM_NOTIFY="$STUB" seam_env "$ROOT")" || fail "под маркером с заглушкой ожидался успех, получено: $out"
[ "$out" = "$STUB" ] || fail "под маркером ожидался путь заглушки '$STUB', получено '$out'"
echo "OK: 2 — под маркером шов отдаёт заглушку раннера"

# ---------------------------------------------------------------------------------------
# 3. ПОД маркером БЕЗ переопределения — отказ (fail-closed). Это главный сценарий: тест,
#    забывший подставить заглушку, обязан упасть, а не написать живому человеку.
#    Проверяем и то, что stdout ПУСТ — путь боевого нотификатора не должен «протечь» наружу
#    даже вместе с ненулевым кодом (вызывающий может проигнорировать rc).
# ---------------------------------------------------------------------------------------
err="$(seam_env "$ROOT" 2>&1 >/dev/null)"
out="$(seam_env "$ROOT" 2>/dev/null)" && fail "под маркером без TELEGRAM_NOTIFY ожидался ОТКАЗ, получено '$out'"
[ -z "$out" ] || fail "под маркером при отказе stdout обязан быть пуст, получено '$out'"
case "$err" in
  *"НЕ внутрь тестового корня"*) ;;
  *) fail "ожидалось сообщение про 'НЕ внутрь тестового корня', получено: $err" ;;
esac
echo "OK: 3 — под маркером без заглушки отказ (боевой путь наружу не отдаётся)"

# ---------------------------------------------------------------------------------------
# 4. ПОД маркером с переопределением СНАРУЖИ test root — отказ (в т.ч. симлинк изнутри
#    наружу: containment считается ПОСЛЕ realpath, см. process_control_check_binary_seam).
# ---------------------------------------------------------------------------------------
outside="$(mktemp -d "${TMPDIR:-/tmp}/t8-outside.XXXXXX")" || fail "mktemp -d"
printf '#!/bin/bash\nexit 0\n' > "$outside/telegram_notify.sh"
chmod +x "$outside/telegram_notify.sh"
out="$(TELEGRAM_NOTIFY="$outside/telegram_notify.sh" seam_env "$ROOT" 2>/dev/null)" \
  && { rm -rf "$outside"; fail "переопределение СНАРУЖИ test root обязано быть отвергнуто, получено '$out'"; }

ln -s "$outside/telegram_notify.sh" "$ROOT/notify-symlink.sh"
out="$(TELEGRAM_NOTIFY="$ROOT/notify-symlink.sh" seam_env "$ROOT" 2>/dev/null)" \
  && { rm -rf "$outside"; fail "симлинк ИЗНУТРИ корня НАРУЖУ обязан быть отвергнут (realpath), получено '$out'"; }
rm -rf "$outside"
echo "OK: 4 — переопределение наружу test root (в т.ч. через симлинк) отвергнуто"

# ---------------------------------------------------------------------------------------
# 5. Арность: вызов без аргумента — usage-отказ через `return 1`, а НЕ убийство вызывающего
#    шелла (та же дыра класса `${1:?}`, что чинили в T2/финальном ревью для
#    process_control_tmux/check_unit_dir/check_binary_seam — не переоткрывать её новой функцией).
# ---------------------------------------------------------------------------------------
alive="$(
  (
    set -u
    unset CLAUDE_CONTROL_TEST_ROOT
    # shellcheck disable=SC1090
    . "$LIB"
    process_control_notifier_path >/dev/null 2>&1 && echo "НЕОЖИДАННЫЙ УСПЕХ"
    echo "ШЕЛЛ-ЖИВ"
  )
)"
[ "$alive" = "ШЕЛЛ-ЖИВ" ] || fail "вызов без аргумента обязан вернуть 1 и НЕ убивать вызывающий шелл, получено: $alive"
echo "OK: 5 — вызов без аргумента: отказ через return, вызывающий шелл жив"

# ---------------------------------------------------------------------------------------
# 6. Проводка всех ПЯТИ точек: каждая зовёт шов и ни одна не держит голого присваивания
#    боевого литерала. Статическая проверка — потому что четыре из пяти точек невозможно
#    исполнить в песочнице целиком (супервизор воркера, воркер-идентичность через /proc), а
#    «забыли перевести шестую точку» — ровно тот регресс, который надо ловить механически.
# ---------------------------------------------------------------------------------------
for f in bin/claude-auto-tg bin/claude-auto-ask bin/claude-auto-send bin/claude-auto-run; do
  command grep -q 'process_control_notifier_path' "$DIR/$f" \
    || fail "$f не зовёт process_control_notifier_path — точка выпала из шва"
  command grep -qE '^\s*\.\s+.*lib/process-control\.sh' "$DIR/$f" \
    || fail "$f не подключает lib/process-control.sh"
  command grep -qE "^(TG|TG_NOTIFY)=\"$LITERAL\"" "$DIR/$f" \
    && fail "$f вернул голое присваивание боевого литерала в обход шва"
done
command grep -q '_notifier_path("'"$LITERAL"'")' "$DIR/bot/rnr_workers_bot.py" \
  || fail "bot/rnr_workers_bot.py не зовёт _notifier_path — точка выпала из шва"
command grep -qE "^TG_NOTIFY = \"$LITERAL\"" "$DIR/bot/rnr_workers_bot.py" \
  && fail "bot/rnr_workers_bot.py вернул голое присваивание боевого литерала в обход шва"
echo "OK: 6 — все пять точек подключены к шву, голых присваиваний литерала не осталось"

# ---------------------------------------------------------------------------------------
# 7. E2E python-точки: РЕАЛЬНЫЙ импорт bot/rnr_workers_bot.py под песочницей обязан дать
#    TG_NOTIFY = заглушка раннера. Это не статическая проверка — модуль исполняет свой
#    настоящий модульный код (тот же путь, каким его импортирует tests/rnr-bot-withdraw.test.sh).
# ---------------------------------------------------------------------------------------
PY="$DIR/bot/venv/bin/python3"
[ -x "$PY" ] || PY="python3"
got="$(TELEGRAM_NOTIFY="$STUB" "$PY" -B -c "import sys; sys.path.insert(0, '$DIR/bot'); import rnr_workers_bot as m; print(m.TG_NOTIFY)" 2>&1 | tail -1)"
[ "$got" = "$STUB" ] || fail "импорт rnr_workers_bot под маркером дал TG_NOTIFY='$got', ожидалась заглушка '$STUB'"
echo "OK: 7 — bot/rnr_workers_bot.py под маркером резолвит нотификатор в заглушку"

# ---------------------------------------------------------------------------------------
# 8. E2E bash-точки: bin/claude-auto-tg исполняется ЦЕЛИКОМ под песочницей, и вызов уходит в
#    заглушку — доказательство по её логу ($STUB_LOG), а не по коду возврата.
#    Точка требует операторский .env по АБСОЛЮТНОМУ пути (получатель, а не нотификатор — он
#    вне T8): на машине без него лег пропускается явным сообщением, остальные семь остаются.
#    Безопасность лега не зависит от наличия .env: под маркером без заглушки шов ОТКАЗЫВАЕТ
#    (сценарий 3 выше) — пути «выполнить настоящим нотификатором» здесь не существует.
# ---------------------------------------------------------------------------------------
OPERATOR_ENV="/home/rainor/server/.env"
if [ -r "$OPERATOR_ENV" ] && command grep -qE '^TELEGRAM_CHAT_ID=' "$OPERATOR_ENV"; then
  # Лог заглушки создаётся ПЕРВЫМ её вызовом — до него файла может не быть вовсе.
  before=0; [ -f "$STUB_LOG" ] && before="$(wc -l < "$STUB_LOG")"
  TELEGRAM_NOTIFY="$STUB" "$DIR/bin/claude-auto-tg" "смок T8: проверка шва нотификатора" >/dev/null 2>&1 \
    || fail "claude-auto-tg под песочницей завершился ошибкой"
  after=0; [ -f "$STUB_LOG" ] && after="$(wc -l < "$STUB_LOG")"
  [ "$after" -gt "$before" ] || fail "заглушка нотификатора не была вызвана (в $STUB_LOG ничего не добавилось)"
  command grep -q 'telegram-notify.sh' "$STUB_LOG" \
    || fail "в логе заглушки нет вызова telegram-notify.sh: $(cat "$STUB_LOG")"
  command grep -q 'смок T8' "$STUB_LOG" \
    || fail "в логе заглушки нет текста сообщения — argv до заглушки не долетел"
  echo "OK: 8 — claude-auto-tg под маркером ушёл В ЗАГЛУШКУ (подтверждено логом argv)"
else
  echo "ПРОПУСК: 8 — операторский $OPERATOR_ENV недоступен/без TELEGRAM_CHAT_ID (получатель — не предмет T8), e2e-лег bash-точки пропущен"
fi

echo "PASS notifier-seam"
