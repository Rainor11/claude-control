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
FIXTURE="$DIR/tests/fixtures/runtime-root-cases.json"
fail() { echo "FAIL: $1"; exit 1; }

command -v jq >/dev/null 2>&1 || fail "jq не найден — нужен для чтения tests/fixtures/runtime-root-cases.json"

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
# B2 (ревью T1, находка): таблица легаси-паритета (профиль + env + ожидание) больше НЕ
# дублируется руками параллельно в .sh и .mjs — общая tests/fixtures/runtime-root-cases.json
# гоняется ОБОИМИ раннерами (js-сторона дополнительно сравнивает bash-результат с js
# подпроцессом — см. tests/runtime-root.test.mjs). Здесь просто прогоняем таблицу через
# bash-реализацию и сверяем с ожиданием фикстуры.
# ---------------------------------------------------------------------------

case_count="$(jq 'length' "$FIXTURE")"
i=0
while [ "$i" -lt "$case_count" ]; do
  name="$(jq -r ".[$i].name" "$FIXTURE")"
  profile="$(jq -r ".[$i].profile" "$FIXTURE")"
  ok="$(jq -r ".[$i].expect.ok" "$FIXTURE")"
  kvs=()
  while IFS= read -r line; do
    [ -n "$line" ] && kvs+=("$line")
  done < <(jq -r ".[$i].env | to_entries[] | \"\(.key)=\(.value)\"" "$FIXTURE")

  out="$(resolve "$profile" "${kvs[@]}")"
  rc=$?
  if [ "$ok" = "true" ]; then
    value="$(jq -r ".[$i].expect.value" "$FIXTURE")"
    [ "$rc" -eq 0 ] || fail "fixture '$name': ожидали успех, получили отказ: $out"
    [ "$out" = "$value" ] || fail "fixture '$name': получили '$out', ожидали '$value'"
  else
    errpattern="$(jq -r ".[$i].expect.errorPattern" "$FIXTURE")"
    [ "$rc" -ne 0 ] || fail "fixture '$name': ожидали отказ, получили успех: $out"
    echo "$out" | command grep -qi "$errpattern" || fail "fixture '$name': сообщение не содержит '$errpattern': $out"
  fi
  i=$((i + 1))
done

echo "OK: fixture-таблица tests/fixtures/runtime-root-cases.json — $case_count кейсов"

# ---------------------------------------------------------------------------
# Маркер CLAUDE_CONTROL_TEST_ROOT — happy path
# ---------------------------------------------------------------------------

home1="$(new_home)"
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

echo "OK: маркер — happy path (все профили, symlink)"

# ---------------------------------------------------------------------------
# Маркер — негативные кейсы (ядро задачи: fail-closed)
# ---------------------------------------------------------------------------

# В3 (ревью T1): пустая строка ЗАДАНА (не unset) — обязан отказать, НЕ вести себя как unset.
# Раньше `${CLAUDE_CONTROL_TEST_ROOT:-}` считал "" тем же, что "не задано" → молчаливый
# фолбэк на боевой резолв (раннер мог подставить невыставленную переменную).
out="$(resolve control_only "HOME=$home1" "CLAUDE_CONTROL_TEST_ROOT=")" \
  && fail "пустой (но заданный) маркер обязан отказывать, а прошёл: $out"
echo "$out" | command grep -qi "абсолютн" || fail "пустой маркер: сообщение не объясняет причину: $out"

# без sentinel
root_no_sentinel="$(new_root)"
out="$(resolve control_only "HOME=$home1" "CLAUDE_CONTROL_TEST_ROOT=$root_no_sentinel")" \
  && fail "маркер без sentinel обязан отказывать: $out"
echo "$out" | command grep -qi "sentinel" || fail "маркер без sentinel: сообщение не объясняет причину: $out"

# М1 (ревью T1): sentinel-КАТАЛОГ не должен приниматься как валидный sentinel
root_sentinel_dir="$(new_root)"; mkdir -p "$root_sentinel_dir/$SENTINEL"
out="$(resolve control_only "HOME=$home1" "CLAUDE_CONTROL_TEST_ROOT=$root_sentinel_dir")" \
  && fail "sentinel-каталог обязан отказывать: $out"
echo "$out" | command grep -qi "sentinel" || fail "sentinel-каталог: сообщение не объясняет причину: $out"

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

echo "OK: маркер — базовые негативы (пустой/sentinel/каталог-sentinel/относительный/несуществующий/'/'/HOME/боевые корни)"

# ---------------------------------------------------------------------------
# К1 (ревью T1, КРИТИЧНОЕ): containment боевого корня — обе стороны вложенности, для обоих
# боевых корней. Голая equality-проверка (было изначально) пропускала test root ВНУТРИ
# боевого дерева (раннер сам кладёт туда sentinel — рабочий обход fail-closed) и test root,
# СОДЕРЖАЩИЙ боевой корень целиком.
# ---------------------------------------------------------------------------

# test root ВНУТРИ $HOME-боевого дерева ($HOME/.claude-control/inner)
home_k1="$(new_home)"; mkdir -p "$home_k1/.claude-control/inner"; mark_sentinel "$home_k1/.claude-control/inner"
out="$(resolve control_only "HOME=$home_k1" "CLAUDE_CONTROL_TEST_ROOT=$home_k1/.claude-control/inner")" \
  && fail "test root внутри \$HOME/.claude-control обязан отказывать: $out"
echo "$out" | command grep -qi "боев" || fail "test root внутри боевого дерева: сообщение не объясняет причину: $out"

# symlink на test root ВНУТРИ $HOME-боевого дерева — отказ после разыменования
link_k1="$(mktemp -u)"
ln -s "$home_k1/.claude-control/inner" "$link_k1"
out="$(resolve control_only "HOME=$home_k1" "CLAUDE_CONTROL_TEST_ROOT=$link_k1")"
rc_k1=$?
if [ $rc_k1 -eq 0 ]; then rm -f "$link_k1"; fail "symlink на test root внутри боевого дерева обязан отказывать: $out"; fi
echo "$out" | command grep -qi "боев" || { rm -f "$link_k1"; fail "symlink внутри боевого дерева: сообщение не объясняет причину: $out"; }
rm -f "$link_k1"

# test root, СОДЕРЖАЩИЙ $HOME-боевой корень целиком (base — родитель $HOME/.claude-control)
base_k1="$(new_root)"
home_k1b="$base_k1/home"; mkdir -p "$home_k1b/.claude-control"
out="$(resolve control_only "HOME=$home_k1b" "CLAUDE_CONTROL_TEST_ROOT=$base_k1")" \
  && fail "test root, содержащий \$HOME-боевой корень, обязан отказывать: $out"
echo "$out" | command grep -qi "боев" || fail "test root содержит боевой корень: сообщение не объясняет причину: $out"

# test root, СОДЕРЖАЩИЙ захардкоженный боевой корень (/home содержит /home/rainor/.claude-control)
# — read-only realpath, никакой записи/чтения содержимого /home/rainor/.claude-control.
out="$(resolve control_only "HOME=$home1" "CLAUDE_CONTROL_TEST_ROOT=/home")" \
  && fail "test root=/home (содержит захардкоженный боевой корень) обязан отказывать: $out"
echo "$out" | command grep -qi "боев" || fail "test root=/home: сообщение не объясняет причину: $out"

echo "OK: К1 — containment боевого корня (обе стороны, оба корня)"

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
