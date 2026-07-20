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
# ЭТА ЗАДАЧА ADDITIVE: guard пишется и тестируется, но НИ К ОДНОМУ файлу в bin/, bot/,
# channels/ НЕ подключается — подключение отдельная задача (T4). Живой флот не меняется.
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

# _process_control_check_binary_seam <var_name> <value> — под маркером: <value> обязан
# резолвиться (command -v — поддерживает и голое имя из PATH, и абсолютный путь) в
# исполняемый файл, и этот файл (ПОСЛЕ realpath — символическая ссылка на боевой бинарь
# ВНУТРИ test root обязана быть поймана, не только буквальный путь) обязан лежать ВНУТРИ
# test root. Без маркера — не проверяет НИЧЕГО (прод-путь, идентичный сегодняшнему —
# guard не добавляет новых отказов там, где раньше их не было).
_process_control_check_binary_seam() {
  local var_name="$1" value="$2" test_root resolved
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
      _process_control_check_binary_seam SYSTEMCTL "${SYSTEMCTL:-systemctl}"
      ;;
    systemd_run)
      _process_control_check_binary_seam DEPT_SYSTEMD_RUN "${DEPT_SYSTEMD_RUN:-systemd-run}"
      ;;
    tmux)
      _process_control_check_binary_seam TMUX_BIN "${TMUX_BIN:-tmux}"
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
# случайному значению). Адресация сокета — через process_control_tmux_socket_argv (слой B):
# без маркера `-L claude-<name>` (сегодняшнее bin/claude-auto-run:81), под маркером единый
# `-S "<root>/tmux.sock"`.
process_control_tmux() {
  local name="${1:?process_control_tmux: usage: process_control_tmux <name> [tmux-args...]}"
  shift
  process_control_preflight tmux || return 1
  local test_root
  test_root="$(_process_control_test_root)" || return 1
  local -a sock_args=()
  while IFS= read -r line; do sock_args+=("$line"); done < <(process_control_tmux_socket_argv "$name" "$test_root")
  "${TMUX_BIN:-tmux}" "${sock_args[@]}" "$@"
}

# process_control_systemd_run <args...> — прокси на переопределяемый шов DEPT_SYSTEMD_RUN
# (прецедент bin/dept-dispatcher:185: SYSTEMD_RUN = process.env.DEPT_SYSTEMD_RUN ||
# 'systemd-run'). Под маркером ПРЕПЕНДИТ --setenv CLAUDE_CONTROL_TEST_ROOT=<root> ПЕРЕД
# аргументами вызывающего (см. process_control_systemd_run_setenv_argv) — маркер обязан
# долететь до transient-юнита, иначе вложенный процесс потеряет защиту (см. шапку файла,
# проблема №4). Без маркера argv не меняется — поведение идентично прямому вызову.
process_control_systemd_run() {
  process_control_preflight systemd_run || return 1
  local test_root
  test_root="$(_process_control_test_root)" || return 1
  local -a setenv_args=()
  while IFS= read -r line; do setenv_args+=("$line"); done < <(process_control_systemd_run_setenv_argv "$test_root")
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
  local dir="${1:?process_control_check_unit_dir: usage: process_control_check_unit_dir <dir>}"
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
