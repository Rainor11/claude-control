#!/bin/bash
# tests/lib/bootstrap.sh — обязательный пролог для tests/*.test.sh (T3 изоляции тестов от
# боевого рантайма, см. .superpowers/sdd/iso-t3-brief.md). Подключается ОДНОЙ строкой первой
# строкой каждого теста:
#   # shellcheck disable=SC1091
#   . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bootstrap.sh"
#
# Рубеж 2 из брифа: T1 (lib/runtime-root.sh) и T2 (lib/process-control.sh) защищают ТОЛЬКО
# тот тест, который сам выставил маркер CLAUDE_CONTROL_TEST_ROOT — резолвер под отсутствующим
# маркером законно применяет боевой дефолт. Тест, который «забыл» пролог, ничем не защищён.
# Этот файл закрывает именно этот разрыв: прямой запуск `./tests/foo.test.sh` в обход
# tests/run (маркер не выставлен, ИЛИ выставлен, но песочница неполная) → немедленный явный
# отказ ДО того, как тело теста успело сделать хоть один побочный эффект, а не тихий боевой
# прогон.
#
# Контракт (буквально из брифа): "Sentinel и заглушки создаёт РАННЕР — bootstrap только
# проверяет, что они на месте." Этот файл НИЧЕГО не готовит сам (не создаёт sentinel, не
# создаёт заглушки, не резолвит песочницу) — только ПРОВЕРЯЕТ, переиспользуя T1
# (resolve_runtime_root — маркер/sentinel/containment) и T2 (process_control_preflight —
# заглушки SYSTEMCTL/DEPT_SYSTEMD_RUN/TMUX_BIN внутри test root). Ни логика маркера, ни
# containment, ни resolve-executable здесь НЕ дублируются — ровно требование брифа "T3
# переиспользует T1 и T2, не пишет свои версии".
#
# НЕ `set -u` здесь (тот же довод, что у lib/runtime-root.sh/lib/process-control.sh, T1/T2
# ревью): это source-able библиотека, `set -u` в коде верхнего уровня протекает в шелл
# ВЫЗЫВАЮЩЕГО теста через `.` (source) — сюрприз, который тестам не нужен. Каждое обращение
# к переменной здесь уже защищено явным `${VAR+set}`/`${VAR:-}`.

# М1 (ревью T3) — детект НЕ-bash интерпретатора (например, `sh tests/foo.test.sh` — команда
# ИГНОРИРУЕТ shebang теста и трактует ВЕСЬ файл, включая наш `.` source ниже, как POSIX sh/
# dash). Без этой проверки СЛЕДУЮЩАЯ строка (`${BASH_SOURCE[0]}`, bash-специфичный синтаксис
# массива) упала бы под dash с невнятным "Bad substitution" — безопасность НЕ страдает (тело
# теста всё равно не выполняется), но сообщение не объясняет причину. Проверка нарочно
# ПОРТИРУЕМА (POSIX `${VAR:-}`, работает и под dash/sh — никакого bash-синтаксиса до неё) и
# стоит СТРОГО ПЕРЕД первым bash-специфичным выражением файла.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "tests/lib/bootstrap.sh: требуется bash (обнаружен НЕ-bash интерпретатор — похоже, тест запущен как 'sh tests/foo.test.sh', shebang проигнорирован). Запусти через раннер: tests/run <имя файла>" >&2
  exit 1
fi

# BASH_SOURCE[0], не $0 — этот файл сам source'ится тестом, $0 указывал бы на ВЫЗЫВАЮЩИЙ файл
# (тот же довод, что в lib/process-control.sh про поиск своего каталога).
_BOOTSTRAP_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_BOOTSTRAP_REPO_DIR="$(cd "$_BOOTSTRAP_TESTS_DIR/.." && pwd)"

# _bootstrap_die <reason> — русский текст причины + явная подсказка "как правильно" (запусти
# через раннер) в stderr, exit 1. BASH_SOURCE[0] внутри ЭТОЙ функции — сам bootstrap.sh (файл,
# где функция ОПРЕДЕЛЕНА); BASH_SOURCE[1] — ТОЖЕ bootstrap.sh (вызов _bootstrap_die происходит
# из ЕГО СОБСТВЕННОГО top-level кода, а `.` source не заводит отдельный функциональный кадр —
# проверено эмпирически: инструментирован BASH_SOURCE-массив в тестовом прогоне, [1] неизменно
# совпадал с bootstrap.sh). BASH_SOURCE[2] — файл, который source'ит НАС (реальный тест) —
# именно его показываем пользователю как "как правильно запустить".
_bootstrap_die() {
  local caller="${BASH_SOURCE[2]:-<неизвестный тестовый файл>}"
  echo "tests/lib/bootstrap.sh: $1" >&2
  echo "tests/lib/bootstrap.sh: запусти тест через раннер, не напрямую: tests/run $(basename "$caller")" >&2
  exit 1
}

# Рубеж 2, шаг 1: маркер вообще не выставлен — прямой запуск в обход раннера. Проверяем
# ИМЕННО "задана" (`${VAR+set}`), не "непусто" — та же семантика, что в T1
# (resolve_runtime_root): раннер, случайно подставивший невыставленную переменную, обязан
# получить явный отказ здесь же, а не тихий пропуск дальше в резолвер.
if [ -z "${CLAUDE_CONTROL_TEST_ROOT+set}" ]; then
  _bootstrap_die "маркер CLAUDE_CONTROL_TEST_ROOT не выставлен — тест запущен в обход tests/run, боевой контур ничем не защищён"
fi

# shellcheck disable=SC1091
. "$_BOOTSTRAP_REPO_DIR/lib/runtime-root.sh"
# shellcheck disable=SC1091
. "$_BOOTSTRAP_REPO_DIR/lib/process-control.sh"

# Рубеж 2, шаг 2: маркер выставлен, но невалиден (не резолвится / нет sentinel / пересекается
# с боевым корнем / легаси-переменная течёт наружу) — resolve_runtime_root уже делает ВСЮ эту
# проверку (T1), здесь только делегируем и оборачиваем сообщение через _bootstrap_die.
_bootstrap_msg="$(resolve_runtime_root control_only 2>&1)" || _bootstrap_die "$_bootstrap_msg"

# Рубеж 2, шаг 3: заглушки процесс-контроля — раннер ОБЯЗАН был подставить SYSTEMCTL/
# DEPT_SYSTEMD_RUN/TMUX_BIN внутри test root (см. контракт песочницы в брифе). Без них
# process_control_preflight резолвит дефолтное ИМЯ бинаря (buquально "systemctl"/"tmux"/
# "systemd-run") через command -v/PATH — это настоящий системный бинарь СНАРУЖИ test root,
# и T2 fail-closed откажет сам; здесь просто оборачиваем его сообщение тем же _bootstrap_die
# (не дублируем containment/command-v логику — она уже в lib/process-control.sh).
for _bootstrap_cls in systemctl systemd_run tmux; do
  _bootstrap_msg="$(process_control_preflight "$_bootstrap_cls" 2>&1)" \
    || _bootstrap_die "заглушка процесс-контроля класса '$_bootstrap_cls' не на месте (раннер обязан создать её внутри test root ДО запуска теста): $_bootstrap_msg"
done

unset _bootstrap_cls _bootstrap_msg
