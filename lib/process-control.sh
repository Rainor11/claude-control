#!/bin/bash
# lib/process-control.sh — guard процесс-контроля (systemctl / systemd-run / tmux / запись
# systemd user unit-файлов) для bash-обёрток claude-control. T2 изоляции тестов от боевого
# рантайма (см. .superpowers/sdd/iso-t2-brief.md) — T1 (lib/runtime-root.sh) закрыл границу
# по ФАЙЛОВОМУ КОРНЮ (CONTROL_DIR/DEPT_HOME), но боевого контура можно достичь и МИМО корня,
# через процесс-контроль:
#   1. tests/asana-project-integration.test.sh зовёт `claude-auto sleep testw`, а cmd_sleep
#      (bin/claude-auto) делает НАСТОЯЩИЕ `systemctl --user disable --now` и
#      `tmux -L claude-testw kill-session` — мока нет, сьют дотягивается до живого systemd
#      на каждом прогоне.
#   2. Инцидент 20.07: cmd_install_units пишет unit-шаблон через `sed` прямо в
#      $HOME/.config/systemd/user — ДО первого вызова systemctl. Мок одного systemctl не
#      предотвратил бы порчу боевого шаблона claude-auto@.service.
#   3. tmux-сокет адресуется только именем `claude-$name` — у теста и боевого флота общее
#      пространство имён.
#   4. systemd-run НЕ наследует env — CLAUDE_CONTROL_TEST_ROOT, поставленный в окружении
#      диспетчера, теряется в transient-юните, если явно не прокинуть через --setenv.
#
# М1 (Codex-аудит, финальное ревью изоляции T1-T7): строка ниже устарела — T4 ПОДКЛЮЧИЛ guard
# к живым точкам (bash-сторона): `bin/claude-auto-reconciler` (2× systemctl),
# `bin/claude-auto` (17× systemctl + 9× tmux + unit-dir + loginctl),
# `bin/claude-auto-run` (4× tmux, горячий путь) — см. .superpowers/sdd/iso-t4-report.md.
# Node-сторона (lib/process-control.js) подключена к `bin/dept-inbox` и `bin/dept-dispatcher`
# тем же T4. Инвариант "без маркера — побитово прежнее поведение" подтверждён отдельно для
# каждой точки (diff argv фейкового бинаря до/после) и НЕ пострадал от подключения — но
# формулировка "НИ К ОДНОМУ файлу... НЕ подключается" ниже больше не описывает реальность,
# оставлена как исторический контекст T2 (когда guard был только написан и протестирован,
# ещё не подключён нигде).
#
# ЭТА ЗАДАЧА (T2) БЫЛА ADDITIVE: guard писался и тестировался, но НИ К ОДНОМУ файлу в bin/,
# bot/, channels/ НЕ подключался — подключение было отдельной задачей (T4, см. выше — уже
# сделано). Живой флот в РАМКАХ T2 не менялся.
#
# Контракт (буквально из брифа): без маркера CLAUDE_CONTROL_TEST_ROOT — вызывает настоящий
# бинарь, поведение идентично сегодняшнему (условие раскатки: guard не должен ничего менять
# в бою, пока не подключён). Под маркером — переопределяемый шов ОБЯЗАН быть подставлен
# заглушкой ВНУТРИ test root, иначе немедленный отказ ДО любого побочного эффекта (не
# «выполнить и потом пожаловаться»).
#
# Резолвер маркера/корня переиспользуется из lib/runtime-root.sh (containment,
# sentinel-проверка, fail-closed от боевых каталогов) — эта библиотека НЕ дублирует ни
# логику маркера, ни containment, только добавляет НОВЫЕ решения (какой каталог/сокет/
# --setenv использовать под маркером), опираясь на уже провалидированный test root.
#
# НЕ `set -u` здесь (та же причина, что у lib/runtime-root.sh, найдено в T1 ревью): это
# source-able библиотека, `set -u` в коде верхнего уровня протекает в шелл ВЫЗЫВАЮЩЕГО через
# `.` (source). Каждое обращение к переменной защищено явным `${VAR:-}`/`${VAR+set}`.
#
# Usage (тот же паттерн, что у runtime-root.sh — repo-layout И install-layout):
#   BINDIR="$(cd "$(dirname "$0")" && pwd)"
#   . "$BINDIR/../lib/process-control.sh"
#   process_control_preflight systemd_run || exit 1   # ДО мутации реестра/леджера
#   ...
#   process_control_systemctl --user restart "claude-auto@$name.service"
#
# М1 (ревью T2) — ЧЕГО ЭТОТ GUARD НЕ ГАРАНТИРУЕТ: containment (`_runtime_root_contained`)
# проверяет ТОЛЬКО РАСПОЛОЖЕНИЕ заглушки/каталога (лежит ли внутри test root), а НЕ её
# БЕЗВРЕДНОСТЬ. `cp /usr/bin/systemctl "$test_root/fake-systemctl"` пройдёт проверку — это
# буквально настоящий systemctl, просто скопированный внутрь test root. Guard закрывает
# конкретно найденные векторы (asana-project-integration.test.sh дотягивался до боевого
# systemd мимо любой заглушки; инцидент 20.07 писал unit-файл в обход systemctl вовсе), а НЕ
# "что угодно под маркером безопасно исполнить". T4/T5 (подключение guard'а к bin/*, будущие
# задачи) не должны считать эту проверку сильнее, чем она есть — ответственность за то, ЧТО
# именно оказывается заглушкой, остаётся на тестовом раннере.

# Находим свой каталог через BASH_SOURCE (не $0!) — эта библиотека сама source'ит соседний
# lib/runtime-root.sh, и при `source process-control.sh` из чужого скрипта $0 указывал бы на
# ВЫЗЫВАЮЩИЙ файл, а не на process-control.sh — BASH_SOURCE[0] даёт путь именно ЭТОГО файла
# независимо от того, кто и откуда его source'ит.
_PROCESS_CONTROL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$_PROCESS_CONTROL_LIB_DIR/runtime-root.sh"

# ---------------------------------------------------------------------------------------
# Слой A: резолв test root (делегирует ВСЮ валидацию resolve_runtime_root — T1 уже покрыл
# fail-closed исчерпывающе: sentinel, containment с боевыми корнями, dangling HOME и т.д.)
# ---------------------------------------------------------------------------------------

# _process_control_test_root — печатает канонический test root в stdout, если
# CLAUDE_CONTROL_TEST_ROOT задан И валиден; печатает ПУСТУЮ строку и возвращает 0, если
# маркер вообще не задан (прод-путь — ничего не проверяем, идентично сегодняшнему коду).
# Возвращает 1 ТОЛЬКО когда маркер присутствует, но невалиден (resolve_runtime_root уже
# напечатал причину в stderr — не дублируем текст ошибки здесь).
_process_control_test_root() {
  if [ -z "${CLAUDE_CONTROL_TEST_ROOT+set}" ]; then
    echo ""
    return 0
  fi
  resolve_runtime_root control_only
}

# ---------------------------------------------------------------------------------------
# Слой B: чистые функции решений (строка/массив → строка/массив, БЕЗ обращения к файловой
# системе) — принимают уже резолвленный test_root (пустая строка = "нет маркера"), не сами
# его вычисляют. Тестируются напрямую + кросс-проверкой с JS-стороной через общую фикстуру
# tests/fixtures/process-control-cases.json (конвенция репозитория: "чистые функции решений
# — в module.exports/отдельные функции + unit-тест", см. dept-dispatcher.js runnerArgv).
# ---------------------------------------------------------------------------------------

# process_control_unit_dir_decision <test_root_or_empty> <home> — каталог для записи
# systemd user unit-файлов. Без test_root — реальный $HOME/.config/systemd/user (сегодняшнее
# поведение bin/claude-auto: SYSTEMD_USER_DIR="$HOME/.config/systemd/user"). С test_root —
# ВСЕГДА подкаталог test root, никогда реальный боевой каталог (инцидент 20.07: тестовый
# прогон испортил боевой шаблон claude-auto@.service, записав прямо в $HOME/.config/systemd/
# user). Буквальная конкатенация строк (не realpath/normalize) — паритет с bash
# "$var/suffix"-интерполяцией, которую JS-сторона обязана воспроизвести побитово (см. В1
# T1 — path.join нормализует, буквальная интерполяция нет).
process_control_unit_dir_decision() {
  local test_root="${1:-}" home="${2:-}"
  if [ -n "$test_root" ]; then
    echo "$test_root/systemd-user"
  else
    echo "$home/.config/systemd/user"
  fi
}

# process_control_tmux_socket_argv <name> <test_root_or_empty> — печатает ДВЕ строки (флаг,
# значение) адресации tmux-сокета. Без test_root — сегодняшнее поведение bin/claude-auto-run:
# `-L claude-<name>` (глобальное имя, общее пространство с боевым флотом — источник
# проблемы №3 из шапки файла). С test_root — единый файл сокета ВНУТРИ test root
# (`-S "<root>/tmux.sock"`): весь тестовый флот уже изолирован собственным test root, дробить
# сокет ещё и по имени воркера внутри него не нужно.
process_control_tmux_socket_argv() {
  local name="${1:-}" test_root="${2:-}"
  if [ -n "$test_root" ]; then
    printf '%s\n%s\n' "-S" "$test_root/tmux.sock"
  else
    printf '%s\n%s\n' "-L" "claude-$name"
  fi
}

# process_control_systemd_run_setenv_argv <test_root_or_empty> — печатает НОЛЬ строк (нет
# маркера — не трогаем argv, поведение идентично сегодняшнему) либо ДВЕ строки
# (--setenv, CLAUDE_CONTROL_TEST_ROOT=<root>) — маркер обязан прокидываться в transient-юнит
# systemd-run (systemd-run НЕ наследует env клиента, см. проблему №4 в шапке файла), иначе
# вложенный процесс (например dept-exec-runner, запущенный ЧЕРЕЗ этот systemd-run) потеряет
# маркер и окажется БЕЗ защиты — вызовет настоящие systemctl/tmux уже ничем не прикрытый.
process_control_systemd_run_setenv_argv() {
  local test_root="${1:-}"
  if [ -n "$test_root" ]; then
    printf '%s\n%s\n' "--setenv" "CLAUDE_CONTROL_TEST_ROOT=$test_root"
  fi
}

# ---------------------------------------------------------------------------------------
# Слой C: интеграционные функции (трогают файловую систему/PATH, сами резолвят test root
# через слой A и решения через слой B).
# ---------------------------------------------------------------------------------------

# process_control_check_binary_seam <var_name> <value> — под маркером: <value> обязан
# резолвиться (command -v — поддерживает и голое имя из PATH, и абсолютный путь) в
# исполняемый файл, и этот файл (ПОСЛЕ realpath — символическая ссылка на боевой бинарь
# ВНУТРИ test root обязана быть поймана, не только буквальный путь) обязан лежать ВНУТРИ
# test root. Без маркера — не проверяет НИЧЕГО (прод-путь, идентичный сегодняшнему —
# guard не добавляет новых отказов там, где раньше их не было).
#
# М3 (ревью T2): публичная (была `_process_control_check_binary_seam`) — паритет с JS-стороной
# ТОЛЬКО В ЭКСПОРТИРОВАННОСТИ (`checkBinarySeam` в module.exports с самого начала), НЕ В
# СИГНАТУРЕ/АРНОСТИ. Для T4-миграции bash-кода, который продолжает сам вычислять свой шов
# (тот же резон, что у уже публичной `process_control_check_unit_dir` рядом с
# `process_control_unit_dir`), нужен эквивалент — приватность здесь была не осознанным
# решением, а случайной асимметрией с JS.
#
# В6 (Codex-аудит, финальное ревью изоляции T1-T7): АРНОСТЬ этой функции и JS-стороны
# СОЗНАТЕЛЬНО РАЗНАЯ, не паритетна — абзац выше говорит про "паритет" ТОЛЬКО в смысле
# экспортированности/публичности, не сигнатуры, но формулировка приглашала к путанице
# (Codex прочитал её как "вызов совместим с JS"). Эта функция — ДВУХАРГУМЕНТНАЯ, резолвит
# test_root САМА (см. `_process_control_test_root` ниже); JS-сторона `checkBinarySeam(varName,
# value, testRootOrNull)` — ТРЁХаргументная, test root вычисляет и передаёт вызывающий
# (`preflight`). Мигрант, портирующий bash-вызов на JS "по аналогии" (2 аргумента, ожидая, что
# JS тоже сам резолвит корень), молча получил бы fail-open под маркером в JS — этот класс
# дыры закрыт в JS явным отказом на `undefined` третьего аргумента (см. checkBinarySeam в
# lib/process-control.js). Если понадобится по-настоящему унифицировать сигнатуры — делать
# явно и одним шагом для обеих сторон, не полагаясь на комментарий как на гарантию совместимости.
process_control_check_binary_seam() {
  # М4 (bughunt Б1, 21.07): было `local var_name="$1" value="$2" ...` — под `set -u` (его
  # ставят ВСЕ боевые bash-обёртки) вызов без обоих аргументов давал unbound variable, а это
  # УБИВАЕТ ВЕСЬ ВЫЗЫВАЮЩИЙ ШЕЛЛ (не только функцию — библиотека source'ится в чужой процесс
  # через `.`), т.к. функция публичная (с В6-фикса выше). Тот же класс дыры, что уже чинили в
  # М3 для process_control_tmux и process_control_check_unit_dir (см. комментарии там), но эту
  # функцию пропустили. Явная проверка + `return 1` — тот же die-путь, каким уже оформлены ВСЕ
  # ОСТАЛЬНЫЕ отказы этого файла; проверка безусловна (до резолва test_root), как у обоих
  # функций-прецедентов.
  local var_name="${1:-}" value="${2:-}" test_root resolved
  if [ -z "$var_name" ] || [ -z "$value" ]; then
    echo "process-control: process_control_check_binary_seam: usage: process_control_check_binary_seam <var_name> <value>" >&2
    return 1
  fi
  test_root="$(_process_control_test_root)" || return 1
  [ -n "$test_root" ] || return 0

  resolved="$(command -v -- "$value" 2>/dev/null)" || {
    echo "process-control: $var_name='$value' не найден (command -v не резолвит) — под тестовым маркером CLAUDE_CONTROL_TEST_ROOT обязана быть исполняемая заглушка внутри test root, а не невыставленный/битый шов" >&2
    return 1
  }
  resolved="$(realpath -e -- "$resolved" 2>/dev/null)" || {
    echo "process-control: $var_name='$value' резолвится в '$resolved', но realpath не смог канонизировать" >&2
    return 1
  }
  if ! _runtime_root_contained "$resolved" "$test_root"; then
    echo "process-control: $var_name='$value' (→ '$resolved') указывает НЕ внутрь тестового корня '$test_root' — под CLAUDE_CONTROL_TEST_ROOT обязана быть заглушка ВНУТРИ test root (иначе тест дотягивается до настоящего бинаря); либо $var_name не переопределён вовсе (дефолт = реальный '$value'), либо переопределён на путь/симлинк снаружи" >&2
    return 1
  fi
  return 0
}

# process_control_preflight <class> — class ∈ systemctl | systemd_run | tmux | unit_dir.
# ЯВНАЯ функция проверки доступности бэкенда, ОТДЕЛЬНАЯ от обёрток-исполнителей ниже: вызывающий
# (например dept-dispatcher) обязан вызвать её ДО мутации реестра/леджера (bin/dept-dispatcher:454
# помечает заявку executing ДО попытки systemd-run) — так отказ происходит ДО побочного эффекта,
# а не "выполнить и потом пожаловаться". НЕ исполняет и не проверяет ничего реальнее, чем
# command -v/realpath (read-only) — сама команда НИКОГДА не запускается этой функцией.
process_control_preflight() {
  local class="${1:-}"
  case "$class" in
    systemctl)
      process_control_check_binary_seam SYSTEMCTL "${SYSTEMCTL:-systemctl}"
      ;;
    systemd_run)
      process_control_check_binary_seam DEPT_SYSTEMD_RUN "${DEPT_SYSTEMD_RUN:-systemd-run}"
      ;;
    tmux)
      process_control_check_binary_seam TMUX_BIN "${TMUX_BIN:-tmux}"
      ;;
    unit_dir)
      process_control_unit_dir >/dev/null
      ;;
    *)
      echo "process_control_preflight: неизвестный класс '$class' (ожидался один из: systemctl, systemd_run, tmux, unit_dir)" >&2
      return 1
      ;;
  esac
}

# process_control_systemctl <args...> — прокси на переопределяемый шов SYSTEMCTL (прецедент
# bin/dept-liveness-exec:25: SYSTEMCTL="${SYSTEMCTL:-systemctl}"). Preflight ДО exec —
# fail-closed под маркером без заглушки/с заглушкой снаружи test root, без маркера поведение
# идентично прямому вызову `systemctl "$@"`.
process_control_systemctl() {
  process_control_preflight systemctl || return 1
  "${SYSTEMCTL:-systemctl}" "$@"
}

# process_control_tmux <name> [tmux-args...] — прокси на переопределяемый шов TMUX_BIN
# (НЕ переменная `TMUX` — её выставляет сам tmux изнутри активной сессии в
# `<сокет>,<pid>,<индекс>`, использовать это имя под своё переопределение означало бы либо
# конфликтовать с реальным tmux-окружением вызывающего, либо срабатывать по чужому
# случайному значению). Адресация сокета: без маркера `-L claude-<name>` (сегодняшнее
# bin/claude-auto-run:81), под маркером единый `-S "<root>/tmux.sock"`.
#
# К2 (ревью T2): argv сокета строится ПРЯМО ЗДЕСЬ инлайновым `if`, а НЕ через
# `process_control_tmux_socket_argv` + `while read -r line; do sock_args+=("$line"); done`
# (было раньше). Построчный транспорт через `read` РЕЖЕТ вывод по `\n` — если `name` содержит
# ВСТРОЕННЫЙ перевод строки (например `$'a\nkill-server'`), значение "claude-$name" вместо
# ОДНОГО argv-элемента с `\n` внутри превращается в ДВА отдельных элемента, и вторая "строка"
# (`kill-server`) долетает до tmux как ПОЗИЦИОННЫЙ аргумент — argv-инъекция вместо простого
# искажения имени сессии (проверено ревьюером: `tmux -L claude-a kill-server list-sessions`).
# `process_control_tmux_socket_argv` остаётся как чистая функция для фикстуры/кросс-проверки
# с JS (`tmuxSocketArgv` строит массив нативно, без транспорта через текст, поэтому у неё
# этого бага никогда не было) — но РЕАЛЬНЫЙ вызов её больше не использует.
#
# Валидация charset `name` — тот же паттерн, что `bin/claude-auto:78,486,649`
# (`^[a-zA-Z0-9_-]+$`) — fail-closed ДО построения argv: без неё встроенный `\n` (или другой
# спецсимвол) в имени воротился бы в argv буквально (exec через массив, не через `eval`, так
# что shell-инъекции как таковой нет, но искажение argv само по себе уже нежелательно —
# и после этого фикса единственный канал распространения имени тоже устранён).
#
# В1 (ревью T2): guard прежде НЕ владел своим argv — "$@" вызывающего шёл ПОСЛЕ наших
# sock_args, и если вызывающий (по ошибке или инъекции) добавлял СВОЙ -L/-S, оба долетали до
# tmux. Повтор ОДНОИМЁННОГО флага в getopt-разборе — "последний побеждает", а `-S` вдобавок
# ещё и молча гасит предшествующий `-L` (man tmux: "If -S is specified... any -L flag is
# ignored") — оба случая переопределяют адресацию, которую guard обязан гарантировать под
# маркером (проверено ревьюером: `fake-tmux -S <root>/tmux.sock -S /tmp/GLOBAL-prod.sock ...`).
# Сканируем "$@" ДО вызова бинаря и отказываем явно, а не полагаемся, что вызывающий никогда
# так не сделает.
process_control_tmux() {
  # М3 (Codex-аудит, финальное ревью изоляции T1-T7): было `${1:?...}` — при пустом/
  # отсутствующем `$1` bash `${var:?message}` печатает message и ЗАВЕРШАЕТ ВЕСЬ ВЫЗЫВАЮЩИЙ
  # ПРОЦЕСС (`exit`, не `return`) — сюрприз для вызывающего скрипта (например bin/claude-auto,
  # который source'ит эту библиотеку В СВОЙ ЖЕ шелл): опечатка/пустая переменная в вызове
  # `process_control_tmux ""` убивала бы ВЕСЬ `claude-auto`, а не только эту функцию,
  # асимметрично с JS-стороной, где эквивалентная валидация — catchable `throw`. Явная
  # проверка + `return 1` — тот же die-путь, каким уже оформлены ВСЕ ОСТАЛЬНЫЕ отказы в этом
  # файле (echo "process-control: ..." >&2; return 1), деградация теста/вызывающего, не убийство.
  local name="${1:-}"
  if [ -z "$name" ]; then
    echo "process-control: process_control_tmux: usage: process_control_tmux <name> [tmux-args...]" >&2
    return 1
  fi
  shift
  [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || {
    echo "process-control: process_control_tmux: имя воркера '$name' содержит недопустимые символы (разрешено [a-zA-Z0-9_-])" >&2
    return 1
  }
  local arg
  for arg in "$@"; do
    case "$arg" in
      -L|-L*|-S|-S*)
        echo "process-control: process_control_tmux не принимает -L/-S от вызывающего — сокет назначает guard, передайте только tmux-команду и её аргументы (получено: '$arg')" >&2
        return 1
        ;;
    esac
  done
  process_control_preflight tmux || return 1
  local test_root
  test_root="$(_process_control_test_root)" || return 1
  local -a sock_args
  if [ -n "$test_root" ]; then
    sock_args=(-S "$test_root/tmux.sock")
  else
    sock_args=(-L "claude-$name")
  fi
  "${TMUX_BIN:-tmux}" "${sock_args[@]}" "$@"
}

# process_control_systemd_run <args...> — прокси на переопределяемый шов DEPT_SYSTEMD_RUN
# (прецедент bin/dept-dispatcher:185: SYSTEMD_RUN = process.env.DEPT_SYSTEMD_RUN ||
# 'systemd-run'). Под маркером ПРЕПЕНДИТ --setenv CLAUDE_CONTROL_TEST_ROOT=<root> ПЕРЕД
# аргументами вызывающего — маркер обязан долететь до transient-юнита, иначе вложенный
# процесс потеряет защиту (см. шапку файла, проблема №4). Без маркера argv не меняется —
# поведение идентично прямому вызову.
#
# К2 (ревью T2): argv строится ПРЯМО ЗДЕСЬ (не через read-loop транспорт из
# `process_control_systemd_run_setenv_argv`, см. подробное обоснование у process_control_tmux
# выше — та же построчная уязвимость применима и здесь, если `test_root` когда-либо содержал
# бы встроенный перевод строки: технически допустимо в имени каталога Linux, хоть и экзотично).
#
# В1 (ревью T2): guard прежде НЕ владел своим argv — сканируем "$@" на ДВА независимых вектора
# инъекции env ДО вызова бинаря:
#  1) повторный --setenv/-E С ИМЕНЕМ НАШЕГО МАРКЕРА — systemd-run берёт последнее значение
#     одноимённой переменной (man systemd-run: "--setenv может повторяться"), а наш --setenv
#     стоит ПЕРВЫМ — одноимённый после него победил бы и подменил test root (проверено
#     ревьюером: `fake-sdrun --setenv CLAUDE_CONTROL_TEST_ROOT=<root> --setenv
#     CLAUDE_CONTROL_TEST_ROOT=/home/rainor/.claude-control`). Другие --setenv (для СВОИХ
#     переменных вызывающего) разрешены — легитимный сценарий T4 (передать задаче env).
#  2) -p/--property Environment=... — независимый способ присвоить env transient-юниту,
#     которым НАШ КОД не пользуется вовсе — блокируем флаг целиком, не разбирая содержимое
#     (Environment= может нести несколько присваиваний через пробел в одной строке).
#
# ДЕФЕКТ 2 (повторное ревью T2): голая форма `--setenv CLAUDE_CONTROL_TEST_ROOT` (БЕЗ
# "=value") НЕ ошибка у systemd-run — man: «When "=" and VALUE are omitted, the value of the
# variable is passed from the environment in which systemd-run is invoked» — тихий
# альтернативный канал присвоить переменную из окружения САМОГО systemd-run (которое
# унаследует его от guard-процесса). Паттерны `CLAUDE_CONTROL_TEST_ROOT=*`/`...=*` требовали
# буквальный "=" — голое имя без него не матчилось и проходило необнаруженным. Для каждой из
# четырёх форм (раздельная `--setenv`/`-E` + следующий arg; слитная `--setenv=NAME`,
# `-ENAME`, `-E=NAME`) в case ниже добавлена ТОЧНАЯ голая альтернатива БЕЗ "=" (не wildcard —
# `-p*`/`--property*` ниже это wildcard, а здесь каждая форма перечислена явным литералом).
process_control_systemd_run() {
  local arg prev=""
  for arg in "$@"; do
    case "$prev" in
      --setenv|-E)
        case "$arg" in
          CLAUDE_CONTROL_TEST_ROOT=*|CLAUDE_CONTROL_TEST_ROOT)
            echo "process-control: process_control_systemd_run — вызывающему запрещено переопределять CLAUDE_CONTROL_TEST_ROOT через --setenv (маркер назначает guard, получено '$arg')" >&2
            return 1
            ;;
        esac
        ;;
    esac
    case "$arg" in
      --setenv=CLAUDE_CONTROL_TEST_ROOT=*|--setenv=CLAUDE_CONTROL_TEST_ROOT|-E=CLAUDE_CONTROL_TEST_ROOT=*|-ECLAUDE_CONTROL_TEST_ROOT=*|-E=CLAUDE_CONTROL_TEST_ROOT|-ECLAUDE_CONTROL_TEST_ROOT)
        echo "process-control: process_control_systemd_run — вызывающему запрещено переопределять CLAUDE_CONTROL_TEST_ROOT через --setenv (получено '$arg')" >&2
        return 1
        ;;
      -p*|--property*)
        echo "process-control: process_control_systemd_run не принимает -p/--property от вызывающего (Environment= — зарезервированный вектор для маркера, guard блокирует весь флаг целиком) — получено '$arg'" >&2
        return 1
        ;;
    esac
    prev="$arg"
  done

  process_control_preflight systemd_run || return 1
  local test_root
  test_root="$(_process_control_test_root)" || return 1
  local -a setenv_args=()
  if [ -n "$test_root" ]; then
    setenv_args=(--setenv "CLAUDE_CONTROL_TEST_ROOT=$test_root")
  fi
  "${DEPT_SYSTEMD_RUN:-systemd-run}" "${setenv_args[@]}" "$@"
}

# process_control_unit_dir — резолвит каталог, КУДА писать systemd user unit-файлы (замена
# прямого "$HOME/.config/systemd/user" в bin/claude-auto cmd_install_units). Возвращает 1,
# если маркер задан, но невалиден (см. _process_control_test_root) — сообщение уже в stderr.
process_control_unit_dir() {
  local test_root
  test_root="$(_process_control_test_root)" || return 1
  process_control_unit_dir_decision "$test_root" "${HOME:-}"
}

# process_control_check_unit_dir <dir> — валидатор ПРОИЗВОЛЬНОГО каталога unit-файлов, для
# кода, который продолжает вычислять каталог сам (постепенная миграция T4), но хочет ту же
# защиту перед записью. Без маркера — не проверяет ничего. Под маркером — <dir> обязан быть
# ВНУТРИ test root (containment, не строковый префикс — переиспользует _runtime_root_contained
# из T1), иначе явный отказ ДО записи. `realpath -m` (не `-e`) — каталог обычно ещё не
# существует на момент проверки (создаётся `mkdir -p` уже ПОСЛЕ прохождения проверки).
process_control_check_unit_dir() {
  # М3 (Codex-аудит, финальное ревью изоляции T1-T7): та же правка, что у process_control_tmux
  # выше — было `${1:?...}` (убивает ВЕСЬ вызывающий процесс через `exit`, не `return`),
  # теперь explicit-проверка + `return 1`, тот же die-путь, каким оформлены остальные отказы
  # в этом файле.
  local dir="${1:-}"
  if [ -z "$dir" ]; then
    echo "process-control: process_control_check_unit_dir: usage: process_control_check_unit_dir <dir>" >&2
    return 1
  fi
  local test_root canon_dir
  test_root="$(_process_control_test_root)" || return 1
  [ -n "$test_root" ] || return 0

  canon_dir="$(realpath -m -- "$dir" 2>/dev/null)" || {
    echo "process-control: каталог unit-файлов '$dir' не резолвится realpath" >&2
    return 1
  }
  if ! _runtime_root_contained "$canon_dir" "$test_root"; then
    echo "process-control: каталог unit-файлов '$dir' (→ '$canon_dir') СНАРУЖИ тестового корня '$test_root' — под CLAUDE_CONTROL_TEST_ROOT запись unit-файлов в \$HOME/.config/systemd/user или любой другой каталог вне test root запрещена (инцидент 20.07: тестовый прогон испортил боевой шаблон claude-auto@.service)" >&2
    return 1
  fi
  return 0
}

# process_control_notifier_path <захардкоженный-абсолютный-путь> — печатает путь к
# telegram_notify.sh для ПЯТИ точек, которые держат его абсолютным и НЕперекрываемым
# НАМЕРЕННО (bin/claude-auto-tg, bin/claude-auto-ask, bin/claude-auto-send,
# bin/claude-auto-run::notify_operator, bot/rnr_workers_bot.py — комментарий в коде:
# «absolute — NOT $PATH/env», чтобы воркер не мог перенаправить уведомления оператору).
#
# ЗАЧЕМ ШОВ (T8, п.1). Из-за неперекрываемости тест не может подставить заглушку — забытый
# override означает СООБЩЕНИЕ ЖИВОМУ ЧЕЛОВЕКУ. Ровно тот же класс, что systemctl/tmux в
# шапке файла, только цена ошибки не "испорченный unit", а "воркер написал оператору из
# тестового прогона".
#
# ПОЧЕМУ АНТИ-ПОДМЕНА НЕ СЛАБЕЕТ. Переопределение ($TELEGRAM_NOTIFY) читается ТОЛЬКО при
# выставленном И валидном маркере — то есть когда resolve_runtime_root (T1) уже подтвердил
# каталог с sentinel-файлом ВНЕ боевого дерева. Без маркера значение env не читается вовсе,
# возвращается ровно переданный литерал. Воркер, желающий перенаправить уведомления, обязан
# был бы выставить валидный маркер — но тогда у него уедет в песочницу и КОРЕНЬ рантайма
# (реестр воркеров, spec.json, ledger), т.е. атака самоубийственна: он перестаёт видеть свой
# же боевой контур. Уровень «полностью скомпрометированный воркер того же uid» этим не
# закрывается и никогда не закрывался (см. честную границу в шапке bin/claude-auto-send).
#
# ОДИН КОНТРАКТ — ОДНО ИМЯ. Из трёх имён того же шва, которые сегодня экспортирует
# tests/run (TELEGRAM_NOTIFY / CLAUDE_CONTROL_TG / CLAUDE_AUTO_TG), здесь читается ТОЛЬКО
# TELEGRAM_NOTIFY: у остальных двух есть СВОИ живые читатели (bin/claude-auto-notify,
# bin/claude-control-url-notify, bin/event-bridge-watch, bin/claude-auto-self-probes), где
# они перекрываются и БЕЗ маркера — это легаси-поведение мы не трогаем. Гейтированные точки
# сводим к одному имени, чтобы «подставил заглушку» означало ровно одну переменную.
#
# ПАРИТЕТА С JS-СТОРОНОЙ ЗДЕСЬ НЕТ СОЗНАТЕЛЬНО (в отличие от checkBinarySeam/tmuxSocketArgv):
# у node-читателей нотификатора (bin/claude-auto-liveness, bin/dept-rebase-check,
# bin/dept-dispatcher) шов и так открыт — `process.env.TELEGRAM_NOTIFY || '<путь>'`, гейтить
# там нечего, и функция-близнец в lib/process-control.js была бы мёртвым кодом. Появится
# node-точка с НЕперекрываемым путём — добавлять близнеца тогда, а не «на всякий случай».
process_control_notifier_path() {
  local hardcoded="${1:-}" test_root value
  if [ -z "$hardcoded" ]; then
    echo "process-control: process_control_notifier_path: usage: process_control_notifier_path <захардкоженный-абсолютный-путь>" >&2
    return 1
  fi
  test_root="$(_process_control_test_root)" || return 1
  if [ -z "$test_root" ]; then
    # Без маркера — БУКВАЛЬНО переданный литерал, ни одного чтения env: побитовый паритет с
    # прежней строкой `TG="/home/rainor/server/server_monitor/telegram_notify.sh"`.
    printf '%s\n' "$hardcoded"
    return 0
  fi
  # Под маркером дефолт — тот же боевой литерал, и он ОБЯЗАН провалить проверку шва (он вне
  # test root). Это не обходной путь, а ровно тот же приём, что у process_control_preflight
  # с `${SYSTEMCTL:-systemctl}`: «не переопределён» и «переопределён наружу» дают ОДИН и тот
  # же явный отказ с уже написанным в T2 текстом причины, без второй реализации проверки.
  value="${TELEGRAM_NOTIFY:-$hardcoded}"
  process_control_check_binary_seam TELEGRAM_NOTIFY "$value" || return 1
  printf '%s\n' "$value"
}
