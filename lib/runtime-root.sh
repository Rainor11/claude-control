#!/bin/bash
# lib/runtime-root.sh — единственный резолвер корня рантайма (CONTROL_DIR/DEPT_HOME) для
# bash-обёрток claude-control. До этого файла порядок приоритета переменных был скопирован
# построчно в 24 местах с ТРЕМЯ разными порядками (см. .superpowers/sdd/iso-t1-brief.md) —
# без общей точки правды тестовый прогон не имел механической границы от боевого флота
# (инцидент 20.07: прогон теста поднял посторонний systemd-юнит и оставил испорченную
# переменную в общем шаблоне claude-auto@.service).
#
# resolve_runtime_root() — ЕДИНСТВЕННОЕ место, где решение "отказать" под тестовым
# маркером CLAUDE_CONTROL_TEST_ROOT принимается. Fail-closed по умолчанию: любая
# двусмысленность (не резолвится, указывает на боевой каталог, легаси-переменная течёт
# наружу test root) — явный отказ с русским текстом причины, НИКОГДА тихий фолбэк на
# боевой путь.
#
# Профили НЕ унифицированы (сознательно, см. бриф): CLAUDE_AUTO_HOME имеет конфликтующую
# семантику — bin/claude-auto-run:258 кладёт в неё каталог КОНКРЕТНОГО воркера
# (workers/<name>), а не корень флота. Дать ей единый глобальный приоритет означало бы, что
# команда из сессии воркера может принять workers/<name> за корень всего флота.
#
# Usage (repo-layout И install-layout — install.sh кладёт lib/ рядом с bin/, тот же
# относительный путь ../lib работает в обоих раскладках, включая --link с symlink'ами):
#   BINDIR="$(cd "$(dirname "$0")" && pwd)"
#   . "$BINDIR/../lib/runtime-root.sh"
#   CONTROL_DIR="$(resolve_runtime_root control_only)" || exit 1
#
# НЕ `set -u` здесь намеренно (ревью T1, находка М3): это source-able библиотека, и `set -u`
# в исполняемом коде верхнего уровня протекает в шелл ВЫЗЫВАЮЩЕГО через `.` (source) — сюрприз
# для будущих вызывающих (T5), который им не нужен. Внутри файла КАЖДОЕ обращение к переменной
# уже защищено явным `${VAR:-}`/`${VAR+set}` (ради паритета с bash `${VAR:-default}` из
# легаси-кода) — `set -u` не даёт здесь дополнительной защиты, только побочный эффект.
# Тесты (tests/runtime-root.test.sh) выставляют `set -u` у СЕБЯ и явно `unset`/`export`
# нужные переменные в изолированном подшелле перед source — это их ответственность, не библиотеки.

# Имя sentinel-файла выбирает T3 (раннер, который его и создаёт) — здесь фиксируем
# контракт, чтобы резолвер и раннер не разъехались по имени.
_RUNTIME_ROOT_SENTINEL_NAME=".claude-control-test-root"
# Литерал auto_then_hardcoded-профиля — ЖИВОЙ каталог на проде, буквально тот же текст,
# что хардкодят claude-auto-liveness/dept-inbox/dept-rebase-check/dept-dispatcher. НЕ
# $HOME-based специально: даже если резолвер вызван с чужим HOME, этот путь остаётся
# заблокирован под тестовым маркером.
_RUNTIME_ROOT_HARDCODED_PROD="/home/rainor/.claude-control"

# resolve_runtime_root <profile>
#   profile ∈ control_only | auto_then_control | auto_then_hardcoded | dept_only
# stdout: резолвленный путь. При отказе: русский текст причины в stderr, exit не ноль.
resolve_runtime_root() {
  local profile="${1:-}"
  case "$profile" in
    control_only|auto_then_control|auto_then_hardcoded|dept_only) ;;
    *)
      echo "runtime-root: неизвестный профиль '$profile' (ожидался один из: control_only, auto_then_control, auto_then_hardcoded, dept_only)" >&2
      return 1
      ;;
  esac
  if [ -z "${HOME:-}" ]; then
    echo "runtime-root: переменная HOME не установлена — резолвер не может вычислить боевой корень по умолчанию" >&2
    return 1
  fi

  # В3 (ревью T1): проверяем, что переменная ЗАДАНА (`${VAR+set}`), НЕ что она непустая
  # (`${VAR:-}`). Легаси-переменные ниже намеренно повторяют bash `${VAR:-default}`
  # ("пустая строка = не задано") ради паритета со старым кодом — но CLAUDE_CONTROL_TEST_ROOT
  # НОВАЯ переменная без такого обязательства. Раннер, подставивший невыставленную
  # переменную (CLAUDE_CONTROL_TEST_ROOT="$SOME_VAR"), получает "" — и обязан явно отказать
  # (не абсолютный путь), а не тихо уйти в боевой резолв.
  if [ -n "${CLAUDE_CONTROL_TEST_ROOT+set}" ]; then
    _runtime_root_resolve_test_marker "$profile"
    return $?
  fi
  _runtime_root_resolve_legacy "$profile"
}

# _runtime_root_contained <child> <root> — 0 (истина), если child == root ИЛИ child
# начинается с root+"/". НЕ голый строковый префикс — иначе "$root-prod" прошёл бы как
# "подкаталог" "$root". Общая функция: раньше эта логика жила инлайново только в цикле
# легаси-переменных — теперь используется и там, и в проверке боевых корней (К1 ревью T1).
_runtime_root_contained() {
  local child="$1" root="$2"
  [ "$child" = "$root" ] && return 0
  case "$child" in
    "$root"/*) return 0 ;;
  esac
  return 1
}

# _runtime_root_reject_if_entangled_with_prod <canon_root> <prod_path_raw> — боевой корень и
# test root не должны пересекаться НИ В ОДНОМ направлении: совпадать, test root вложен в
# боевой, ИЛИ test root содержит боевой целиком. Голая equality-проверка (было изначально)
# пропускала два рабочих обхода fail-closed (К1 ревью T1): test root ВНУТРИ боевого дерева
# (например "$HOME/.claude-control/inner" — sentinel туда кладёт сам раннер) и test root,
# СОДЕРЖАЩИЙ боевой корень целиком (например "/home"). Возвращает 1 (и печатает причину в
# stderr) при пересечении, иначе 0 (в т.ч. если prod_path_raw вообще не резолвится в этом
# окружении — сравнивать не с чем).
_runtime_root_reject_if_entangled_with_prod() {
  local canon_root="$1" prod_path_raw="$2" canon_prod
  canon_prod="$(realpath -e "$prod_path_raw" 2>/dev/null)" || return 0
  if _runtime_root_contained "$canon_root" "$canon_prod" || _runtime_root_contained "$canon_prod" "$canon_root"; then
    echo "runtime-root: CLAUDE_CONTROL_TEST_ROOT='$canon_root' пересекается с боевым корнем ($prod_path_raw) — совпадает с ним, вложен в него или содержит его целиком; тестам сюда нельзя, укажите отдельный временный каталог вне боевого дерева" >&2
    return 1
  fi
  return 0
}

# _runtime_root_resolve_legacy <profile> — БЕЗ маркера: буквальное повторение сегодняшних
# строк из вызывающих файлов (сверено grep'ом на момент написания, см. отчёт T1).
_runtime_root_resolve_legacy() {
  local profile="$1"
  local prod_default="$HOME/.claude-control"
  case "$profile" in
    control_only)
      # CONTROL_DIR="${CLAUDE_CONTROL_DIR:-$HOME/.claude-control}" — bin/claude-auto:49 и 16 др.
      echo "${CLAUDE_CONTROL_DIR:-$prod_default}"
      ;;
    auto_then_control)
      # CONTROL_DIR="${CLAUDE_AUTO_HOME:-${CLAUDE_CONTROL_DIR:-$HOME/.claude-control}}" —
      # bin/dept-liveness-exec:24, bin/dept-liveness-request:33
      echo "${CLAUDE_AUTO_HOME:-${CLAUDE_CONTROL_DIR:-$prod_default}}"
      ;;
    auto_then_hardcoded)
      # const CC_HOME = process.env.CLAUDE_AUTO_HOME || '/home/rainor/.claude-control' —
      # bin/claude-auto-liveness:14, dept-inbox:16, dept-rebase-check:16, dept-dispatcher:153.
      # CLAUDE_CONTROL_DIR здесь НЕ читается вовсе — это не упущение, а буквальное
      # повторение сегодняшней строки.
      echo "${CLAUDE_AUTO_HOME:-$_RUNTIME_ROOT_HARDCODED_PROD}"
      ;;
    dept_only)
      # DEPT="${DEPT_HOME:-$HOME/.claude-control/department}" — bin/dept-mission-exec:20,
      # bin/dept-exec-runner:28, bin/dept-spawn-exec:17. Литеральный $HOME-фоллбэк — эти три
      # файла не консультируют ни CLAUDE_AUTO_HOME, ни CLAUDE_CONTROL_DIR для этого пути.
      echo "${DEPT_HOME:-$HOME/.claude-control/department}"
      ;;
  esac
}

# _runtime_root_resolve_test_marker <profile> — под CLAUDE_CONTROL_TEST_ROOT: маркер И
# единственный источник корня разом. Любая двусмысленность — explicit отказ (см. заголовок
# файла).
_runtime_root_resolve_test_marker() {
  local profile="$1"
  local marker="$CLAUDE_CONTROL_TEST_ROOT"

  case "$marker" in
    /*) ;;
    *)
      echo "runtime-root: CLAUDE_CONTROL_TEST_ROOT должен быть абсолютным путём, получено '$marker'" >&2
      return 1
      ;;
  esac

  local canon_root
  canon_root="$(realpath -e "$marker" 2>/dev/null)" || {
    echo "runtime-root: CLAUDE_CONTROL_TEST_ROOT='$marker' не резолвится (каталог не существует или недоступен)" >&2
    return 1
  }

  if [ "$canon_root" = "/" ]; then
    echo "runtime-root: CLAUDE_CONTROL_TEST_ROOT не может быть корнем файловой системы '/'" >&2
    return 1
  fi

  # HOME обязан резолвиться — в отличие от prod-дефолтов ниже (которые в чистом
  # dev-окружении легитимно ещё не существуют), $HOME отсутствующим быть не должно; если
  # он всё же не резолвится, fail-closed: не можем поручиться, что test root с ним не
  # совпадает, значит не рискуем и отказываем, а не тихо пропускаем проверку.
  local canon_home
  canon_home="$(realpath -e "$HOME" 2>/dev/null)" || {
    echo "runtime-root: HOME='$HOME' не резолвится — не могу проверить, что CLAUDE_CONTROL_TEST_ROOT не совпадает с домашним каталогом" >&2
    return 1
  }
  if [ "$canon_root" = "$canon_home" ]; then
    echo "runtime-root: CLAUDE_CONTROL_TEST_ROOT не может совпадать с домашним каталогом ($canon_home) — слишком широкий охват для тестового корня" >&2
    return 1
  fi

  # К1 (ревью T1): проверяем ОБЕ стороны вложенности для ОБОИХ боевых корней, не только
  # равенство — _runtime_root_reject_if_entangled_with_prod делает realpath+containment в
  # обе стороны и печатает причину в stderr сама.
  _runtime_root_reject_if_entangled_with_prod "$canon_root" "$HOME/.claude-control" || return 1
  _runtime_root_reject_if_entangled_with_prod "$canon_root" "$_RUNTIME_ROOT_HARDCODED_PROD" || return 1

  # М1 (ревью T1): sentinel обязан быть ОБЫЧНЫМ ФАЙЛОМ, не каталогом — `-e` считал каталог с
  # таким именем валидным sentinel (обходится одним `mkdir` вместо `touch`). `-f`, не `-e`.
  if [ ! -f "$canon_root/$_RUNTIME_ROOT_SENTINEL_NAME" ]; then
    echo "runtime-root: CLAUDE_CONTROL_TEST_ROOT='$canon_root' не содержит sentinel-файл '$_RUNTIME_ROOT_SENTINEL_NAME' (обязан быть обычным файлом, не каталогом) — тестовый раннер обязан создать его перед использованием корня (защита от случайно указанного боевого/произвольного каталога)" >&2
    return 1
  fi

  # Легаси-переменные под маркером ИГНОРИРУЮТСЯ для вычисления значения (маркер —
  # единственный корень), но если заданы и указывают НАРУЖУ test root — похоже на утечку
  # боевого окружения в тест, отказываем явно вместо тихого переопределения.
  local name raw canon_legacy
  for name in CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME; do
    raw="${!name:-}"
    [ -n "$raw" ] || continue
    canon_legacy="$(realpath -e "$raw" 2>/dev/null)" || {
      echo "runtime-root: переменная $name='$raw' задана вместе с CLAUDE_CONTROL_TEST_ROOT, но не резолвится — уберите $name или укажите путь внутри тестового корня" >&2
      return 1
    }
    # containment через общую _runtime_root_contained (К1 ревью T1: раньше эта логика была
    # инлайнена только тут — вынесена в отдельную функцию, чтобы жила в одном месте).
    if ! _runtime_root_contained "$canon_legacy" "$canon_root"; then
      echo "runtime-root: переменная $name='$raw' задана вместе с CLAUDE_CONTROL_TEST_ROOT, но указывает НЕ внутрь тестового корня '$canon_root' — похоже на утечку боевого окружения в тест. Уберите $name или укажите путь внутри тестового корня." >&2
      return 1
    fi
  done

  if [ "$profile" = "dept_only" ]; then
    echo "$canon_root/department"
  else
    echo "$canon_root"
  fi
}
