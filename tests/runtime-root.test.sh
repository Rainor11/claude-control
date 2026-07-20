#!/bin/bash
# tests/runtime-root.test.sh — T1 (изоляция тестов от боевого рантайма). Bash-сторона
# резолвера lib/runtime-root.sh: сегодня 24 копии инлайновой логики CONTROL_DIR/DEPT_HOME
# с ТРЕМЯ разными порядками приоритета (см. .superpowers/sdd/iso-t1-brief.md) — резолвер
# заменяет их (миграция вызывающих — отдельная задача T5, здесь только фундамент+тесты).
# Инцидент 20.07: тестовый прогон достал до боевого systemd-юнита из-за отсутствия
# механической границы тест/прод — resolve_runtime_root() под маркером
# CLAUDE_CONTROL_TEST_ROOT это ЕДИНСТВЕННОЕ место, где решение "отказать" принимается,
# и оно fail-closed по умолчанию.
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$DIR/lib/runtime-root.sh"
fail() { echo "FAIL: $1"; exit 1; }

SENTINEL=".claude-control-test-root"

# resolve <profile> [NAME=VALUE ...] — резолвит в ИЗОЛИРОВАННОМ подшелле (unset всех
# легаси+маркер переменных перед применением переданных NAME=VALUE), stdout+stderr слиты
# (для негативных тестов важен текст сообщения), возвращает exit code резолвера.
resolve() {
  local profile="$1"; shift
  (
    # HOME тоже сбрасываем по умолчанию (не только легаси-переменные) — иначе subshell
    # наследует РЕАЛЬНЫЙ $HOME вызывающего (тест держит /home/rainor как боевой сервер),
    # и сценарий "HOME не задан" незаметно превращался бы в "HOME=/home/rainor".
    unset HOME CLAUDE_CONTROL_DIR CLAUDE_AUTO_HOME DEPT_HOME CLAUDE_CONTROL_TEST_ROOT
    local kv
    # shellcheck disable=SC2163  # "export "$kv"" НАМЕРЕННО: $kv сама целиком "NAME=value"
    for kv in "$@"; do export "$kv"; done
    # shellcheck disable=SC1090
    . "$LIB"
    resolve_runtime_root "$profile"
  ) 2>&1
}

new_home() { mktemp -d; }
new_root() { mktemp -d; }
mark_sentinel() { : > "$1/$SENTINEL"; }

# ---------------------------------------------------------------------------
# Паритет с сегодняшним кодом (БЕЗ маркера) — построчно по таблице профилей брифа,
# сверено grep'ом по реальным файлам перед написанием теста.
# ---------------------------------------------------------------------------

# control_only: CONTROL_DIR="${CLAUDE_CONTROL_DIR:-$HOME/.claude-control}" (bin/claude-auto:49 и 16 др.)
home1="$(new_home)"
out="$(resolve control_only "HOME=$home1")" || fail "control_only без переменной упал: $out"
[ "$out" = "$home1/.claude-control" ] || fail "control_only дефолт: получили '$out', ожидали '$home1/.claude-control'"
out="$(resolve control_only "HOME=$home1" "CLAUDE_CONTROL_DIR=/custom/dir")" || fail "control_only с переменной упал: $out"
[ "$out" = "/custom/dir" ] || fail "control_only override: получили '$out'"
# bash ${VAR:-default}: пустая строка = "не задано"
out="$(resolve control_only "HOME=$home1" "CLAUDE_CONTROL_DIR=")" || fail "control_only с пустой переменной упал: $out"
[ "$out" = "$home1/.claude-control" ] || fail "control_only пустая CLAUDE_CONTROL_DIR должна вести себя как unset: получили '$out'"

# auto_then_control: CONTROL_DIR="${CLAUDE_AUTO_HOME:-${CLAUDE_CONTROL_DIR:-$HOME/.claude-control}}" (bin/dept-liveness-exec:24, bin/dept-liveness-request:33)
out="$(resolve auto_then_control "HOME=$home1")" || fail "auto_then_control без переменных упал: $out"
[ "$out" = "$home1/.claude-control" ] || fail "auto_then_control дефолт: получили '$out'"
out="$(resolve auto_then_control "HOME=$home1" "CLAUDE_CONTROL_DIR=/custom/dir")" || fail "auto_then_control CLAUDE_CONTROL_DIR упал: $out"
[ "$out" = "/custom/dir" ] || fail "auto_then_control CLAUDE_CONTROL_DIR: получили '$out'"
out="$(resolve auto_then_control "HOME=$home1" "CLAUDE_CONTROL_DIR=/custom/dir" "CLAUDE_AUTO_HOME=/auto/dir")" || fail "auto_then_control приоритет упал: $out"
[ "$out" = "/auto/dir" ] || fail "auto_then_control: CLAUDE_AUTO_HOME обязан побеждать CLAUDE_CONTROL_DIR, получили '$out'"

# auto_then_hardcoded: CC_HOME = CLAUDE_AUTO_HOME || '/home/rainor/.claude-control' (bin/claude-auto-liveness:14, dept-inbox:16, dept-rebase-check:16, dept-dispatcher:153) — ИГНОРИРУЕТ CLAUDE_CONTROL_DIR
out="$(resolve auto_then_hardcoded "HOME=$home1")" || fail "auto_then_hardcoded без переменных упал: $out"
[ "$out" = "/home/rainor/.claude-control" ] || fail "auto_then_hardcoded дефолт: получили '$out', ожидали литерал /home/rainor/.claude-control"
out="$(resolve auto_then_hardcoded "HOME=$home1" "CLAUDE_CONTROL_DIR=/custom/dir")" || fail "auto_then_hardcoded с CLAUDE_CONTROL_DIR упал: $out"
[ "$out" = "/home/rainor/.claude-control" ] || fail "auto_then_hardcoded ОБЯЗАН игнорировать CLAUDE_CONTROL_DIR, получили '$out'"
out="$(resolve auto_then_hardcoded "HOME=$home1" "CLAUDE_AUTO_HOME=/auto/dir")" || fail "auto_then_hardcoded с CLAUDE_AUTO_HOME упал: $out"
[ "$out" = "/auto/dir" ] || fail "auto_then_hardcoded CLAUDE_AUTO_HOME: получили '$out'"

# dept_only: DEPT="${DEPT_HOME:-$HOME/.claude-control/department}" (bin/dept-mission-exec:20, dept-exec-runner:28, dept-spawn-exec:17) — ИГНОРИРУЕТ CLAUDE_AUTO_HOME/CLAUDE_CONTROL_DIR
out="$(resolve dept_only "HOME=$home1")" || fail "dept_only без переменных упал: $out"
[ "$out" = "$home1/.claude-control/department" ] || fail "dept_only дефолт: получили '$out'"
out="$(resolve dept_only "HOME=$home1" "DEPT_HOME=/custom/dept")" || fail "dept_only override упал: $out"
[ "$out" = "/custom/dept" ] || fail "dept_only override: получили '$out'"
out="$(resolve dept_only "HOME=$home1" "CLAUDE_AUTO_HOME=/auto/dir" "CLAUDE_CONTROL_DIR=/custom/dir")" || fail "dept_only с чужими переменными упал: $out"
[ "$out" = "$home1/.claude-control/department" ] || fail "dept_only ОБЯЗАН игнорировать CLAUDE_AUTO_HOME/CLAUDE_CONTROL_DIR, получили '$out'"

echo "OK: паритет с легаси-кодом (control_only/auto_then_control/auto_then_hardcoded/dept_only)"

# ---------------------------------------------------------------------------
# Общие негативы
# ---------------------------------------------------------------------------

out="$(resolve bogus_profile "HOME=$home1")" && fail "неизвестный профиль обязан отказывать: $out"
echo "$out" | command grep -qi "профил" || fail "неизвестный профиль: сообщение не объясняет причину: $out"

out="$(resolve control_only)" && fail "без HOME обязан отказывать: $out"
echo "$out" | command grep -q "HOME" || fail "без HOME: сообщение не упоминает HOME: $out"

echo "OK: общие негативы (профиль/HOME)"

# ---------------------------------------------------------------------------
# Маркер CLAUDE_CONTROL_TEST_ROOT — happy path
# ---------------------------------------------------------------------------

root1="$(new_root)"; mark_sentinel "$root1"
canon_root1="$(realpath -e "$root1")"
for profile in control_only auto_then_control auto_then_hardcoded; do
  out="$(resolve "$profile" "HOME=$home1" "CLAUDE_CONTROL_TEST_ROOT=$root1")" \
    || fail "маркер happy-path ($profile) упал: $out"
  [ "$out" = "$canon_root1" ] || fail "маркер happy-path ($profile): получили '$out', ожидали '$canon_root1'"
done

out="$(resolve dept_only "HOME=$home1" "CLAUDE_CONTROL_TEST_ROOT=$root1")" \
  || fail "маркер dept_only упал: $out"
[ "$out" = "$canon_root1/department" ] || fail "маркер dept_only: получили '$out', ожидали '$canon_root1/department'"

# symlink на test root — резолвится в канонический (реальный) путь
link1="$(mktemp -u)"
ln -s "$root1" "$link1"
out="$(resolve control_only "HOME=$home1" "CLAUDE_CONTROL_TEST_ROOT=$link1")" \
  || { rm -f "$link1"; fail "маркер через symlink упал: $out"; }
[ "$out" = "$canon_root1" ] || { rm -f "$link1"; fail "маркер через symlink: получили '$out', ожидали канонический '$canon_root1'"; }
rm -f "$link1"

# пустая строка = маркер не задан
out="$(resolve control_only "HOME=$home1" "CLAUDE_CONTROL_TEST_ROOT=")" \
  || fail "пустой маркер обязан вести себя как unset (легаси-путь), а упал: $out"
[ "$out" = "$home1/.claude-control" ] || fail "пустой маркер: получили '$out', ожидали легаси-дефолт"

echo "OK: маркер — happy path (все профили, symlink, пустая строка)"

# ---------------------------------------------------------------------------
# Маркер — негативные кейсы (ядро задачи: fail-closed)
# ---------------------------------------------------------------------------

# без sentinel
root_no_sentinel="$(new_root)"
out="$(resolve control_only "HOME=$home1" "CLAUDE_CONTROL_TEST_ROOT=$root_no_sentinel")" \
  && fail "маркер без sentinel обязан отказывать: $out"
echo "$out" | command grep -qi "sentinel" || fail "маркер без sentinel: сообщение не объясняет причину: $out"

# относительный путь
out="$(resolve control_only "HOME=$home1" "CLAUDE_CONTROL_TEST_ROOT=relative/path")" \
  && fail "маркер-относительный путь обязан отказывать: $out"
echo "$out" | command grep -qi "абсолютн" || fail "маркер-относительный: сообщение не объясняет причину: $out"

# несуществующий путь
out="$(resolve control_only "HOME=$home1" "CLAUDE_CONTROL_TEST_ROOT=/no/such/path/at/all")" \
  && fail "несуществующий маркер обязан отказывать: $out"
echo "$out" | command grep -qi "не резолвится\|не существует" || fail "несуществующий маркер: сообщение не объясняет причину: $out"

# маркер = "/"
out="$(resolve control_only "HOME=$home1" "CLAUDE_CONTROL_TEST_ROOT=/")" \
  && fail "маркер '/' обязан отказывать: $out"
echo "$out" | command grep -qi "корн" || fail "маркер '/': сообщение не объясняет причину: $out"

# маркер = $HOME
out="$(resolve control_only "HOME=$home1" "CLAUDE_CONTROL_TEST_ROOT=$home1")" \
  && fail "маркер = HOME обязан отказывать: $out"
echo "$out" | command grep -qi "домашн" || fail "маркер = HOME: сообщение не объясняет причину: $out"

# несуществующий (dangling) $HOME — отказ, а не тихий пропуск проверки на совпадение
root_dangling="$(new_root)"; mark_sentinel "$root_dangling"
out="$(resolve control_only "HOME=/no/such/home/at/all" "CLAUDE_CONTROL_TEST_ROOT=$root_dangling")" \
  && fail "dangling HOME обязан отказывать: $out"
echo "$out" | command grep -q "HOME" || fail "dangling HOME: сообщение не упоминает HOME: $out"

# маркер = боевой $HOME/.claude-control
home_prod="$(new_home)"; mkdir -p "$home_prod/.claude-control"
out="$(resolve control_only "HOME=$home_prod" "CLAUDE_CONTROL_TEST_ROOT=$home_prod/.claude-control")" \
  && fail "маркер = боевой \$HOME/.claude-control обязан отказывать: $out"
echo "$out" | command grep -qi "боев" || fail "маркер = боевой \$HOME/.claude-control: сообщение не объясняет причину: $out"

# маркер = захардкоженный боевой корень (ЖИВОЙ каталог на этом сервере — только realpath,
# read-only, никакой записи)
out="$(resolve control_only "HOME=$home1" "CLAUDE_CONTROL_TEST_ROOT=/home/rainor/.claude-control")" \
  && fail "маркер = хардкод /home/rainor/.claude-control обязан отказывать: $out"
echo "$out" | command grep -qi "боев" || fail "маркер = хардкод боевого корня: сообщение не объясняет причину: $out"

echo "OK: маркер — базовые негативы (sentinel/относительный/несуществующий/'/'/HOME/боевые корни)"

# легаси-переменная наружу test root
root2="$(new_root)"; mark_sentinel "$root2"
outside="$(new_root)"
out="$(resolve control_only "HOME=$home1" "CLAUDE_CONTROL_TEST_ROOT=$root2" "CLAUDE_CONTROL_DIR=$outside")" \
  && fail "легаси-переменная наружу test root обязана отказывать: $out"
echo "$out" | command grep -q "CLAUDE_CONTROL_DIR" || fail "легаси наружу: сообщение не называет переменную-виновника: $out"

# легаси-переменная внутрь test root — ОК
inside="$root2/sub"; mkdir -p "$inside"
out="$(resolve control_only "HOME=$home1" "CLAUDE_CONTROL_TEST_ROOT=$root2" "CLAUDE_CONTROL_DIR=$inside")" \
  || fail "легаси-переменная внутрь test root не должна ломать резолв: $out"
[ "$out" = "$(realpath -e "$root2")" ] || fail "легаси внутрь: получили '$out', ожидали test root"

# containment: /tmp/xxx-prod НЕ должен пройти как "подкаталог" /tmp/xxx (голый строковый префикс — баг)
base3="$(new_root)"
prefroot="$base3/root"; mkdir -p "$prefroot"; mark_sentinel "$prefroot"
prefsibling="$base3/root-prod"; mkdir -p "$prefsibling"
out="$(resolve control_only "HOME=$home1" "CLAUDE_CONTROL_TEST_ROOT=$prefroot" "CLAUDE_CONTROL_DIR=$prefsibling")" \
  && fail "sibling-каталог с общим текстовым префиксом обязан отказывать (containment, не string prefix): $out"
echo "$out" | command grep -q "CLAUDE_CONTROL_DIR" || fail "containment-баг: сообщение не называет переменную: $out"

# ".."-обход: легаси-переменная текстово "внутри", после realpath — снаружи
base4="$(new_root)"
inner="$base4/inner"; mkdir -p "$inner"; mark_sentinel "$inner"
outside4="$base4/outside"; mkdir -p "$outside4"
escaping="$inner/../outside"
out="$(resolve dept_only "HOME=$home1" "CLAUDE_CONTROL_TEST_ROOT=$inner" "DEPT_HOME=$escaping")" \
  && fail "'..'-обход легаси-переменной обязан отказывать: $out"
echo "$out" | command grep -q "DEPT_HOME" || fail "'..'-обход: сообщение не называет переменную: $out"

# недостижимая легаси-переменная (путь не существует вовсе)
root5="$(new_root)"; mark_sentinel "$root5"
out="$(resolve auto_then_hardcoded "HOME=$home1" "CLAUDE_CONTROL_TEST_ROOT=$root5" "CLAUDE_AUTO_HOME=/no/such/leftover/path")" \
  && fail "недостижимая легаси-переменная обязана отказывать: $out"
echo "$out" | command grep -q "CLAUDE_AUTO_HOME" || fail "недостижимая легаси: сообщение не называет переменную: $out"

echo "OK: маркер — легаси-переменные (наружу/внутрь/containment/../недостижима)"

echo "PASS runtime-root"
