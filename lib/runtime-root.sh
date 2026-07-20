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
set -u

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
      echo "resolve_runtime_root: неизвестный профиль '$profile' (ожидался один из: control_only, auto_then_control, auto_then_hardcoded, dept_only)" >&2
      return 1
      ;;
  esac
  if [ -z "${HOME:-}" ]; then
    echo "resolve_runtime_root: переменная HOME не установлена — резолвер не может вычислить боевой корень по умолчанию" >&2
    return 1
  fi

  if [ -n "${CLAUDE_CONTROL_TEST_ROOT:-}" ]; then
    _runtime_root_resolve_test_marker "$profile"
    return $?
  fi
  _runtime_root_resolve_legacy "$profile"
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
      echo "resolve_runtime_root: CLAUDE_CONTROL_TEST_ROOT должен быть абсолютным путём, получено '$marker'" >&2
      return 1
      ;;
  esac

  local canon_root
  canon_root="$(realpath -e "$marker" 2>/dev/null)" || {
    echo "resolve_runtime_root: CLAUDE_CONTROL_TEST_ROOT='$marker' не резолвится (каталог не существует или недоступен)" >&2
    return 1
  }

  if [ "$canon_root" = "/" ]; then
    echo "resolve_runtime_root: CLAUDE_CONTROL_TEST_ROOT не может быть корнем файловой системы '/'" >&2
    return 1
  fi

  # HOME обязан резолвиться — в отличие от prod-дефолтов ниже (которые в чистом
  # dev-окружении легитимно ещё не существуют), $HOME отсутствующим быть не должно; если
  # он всё же не резолвится, fail-closed: не можем поручиться, что test root с ним не
  # совпадает, значит не рискуем и отказываем, а не тихо пропускаем проверку.
  local canon_home
  canon_home="$(realpath -e "$HOME" 2>/dev/null)" || {
    echo "resolve_runtime_root: HOME='$HOME' не резолвится — не могу проверить, что CLAUDE_CONTROL_TEST_ROOT не совпадает с домашним каталогом" >&2
    return 1
  }
  if [ "$canon_root" = "$canon_home" ]; then
    echo "resolve_runtime_root: CLAUDE_CONTROL_TEST_ROOT не может совпадать с домашним каталогом ($canon_home) — слишком широкий охват для тестового корня" >&2
    return 1
  fi

  local canon_prod
  canon_prod="$(realpath -e "$HOME/.claude-control" 2>/dev/null)" || canon_prod=""
  if [ -n "$canon_prod" ] && [ "$canon_root" = "$canon_prod" ]; then
    echo "resolve_runtime_root: CLAUDE_CONTROL_TEST_ROOT совпадает с боевым корнем ($HOME/.claude-control) — тестам сюда нельзя, укажите отдельный временный каталог" >&2
    return 1
  fi

  local canon_hardcoded_prod
  canon_hardcoded_prod="$(realpath -e "$_RUNTIME_ROOT_HARDCODED_PROD" 2>/dev/null)" || canon_hardcoded_prod=""
  if [ -n "$canon_hardcoded_prod" ] && [ "$canon_root" = "$canon_hardcoded_prod" ]; then
    echo "resolve_runtime_root: CLAUDE_CONTROL_TEST_ROOT совпадает с захардкоженным боевым корнем ($_RUNTIME_ROOT_HARDCODED_PROD) — тестам сюда нельзя, укажите отдельный временный каталог" >&2
    return 1
  fi

  if [ ! -e "$canon_root/$_RUNTIME_ROOT_SENTINEL_NAME" ]; then
    echo "resolve_runtime_root: CLAUDE_CONTROL_TEST_ROOT='$canon_root' не содержит sentinel-файл '$_RUNTIME_ROOT_SENTINEL_NAME' — тестовый раннер обязан создать его перед использованием корня (защита от случайно указанного боевого/произвольного каталога)" >&2
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
      echo "resolve_runtime_root: переменная $name='$raw' задана вместе с CLAUDE_CONTROL_TEST_ROOT, но не резолвится — уберите $name или укажите путь внутри тестового корня" >&2
      return 1
    }
    # containment: равенство ИЛИ префикс root+"/" — НЕ голый строковый префикс (иначе
    # "$canon_root-prod" прошёл бы как "подкаталог" "$canon_root").
    if [ "$canon_legacy" != "$canon_root" ] && [ "${canon_legacy#"$canon_root"/}" = "$canon_legacy" ]; then
      echo "resolve_runtime_root: переменная $name='$raw' задана вместе с CLAUDE_CONTROL_TEST_ROOT, но указывает НЕ внутрь тестового корня '$canon_root' — похоже на утечку боевого окружения в тест. Уберите $name или укажите путь внутри тестового корня." >&2
      return 1
    fi
  done

  if [ "$profile" = "dept_only" ]; then
    echo "$canon_root/department"
  else
    echo "$canon_root"
  fi
}
