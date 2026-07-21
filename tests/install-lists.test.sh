#!/bin/bash
# tests/install-lists.test.sh — T8 п.2: install.sh и uninstall.sh обязаны ставить и снимать
# ОДИН И ТОТ ЖЕ набор файлов и юнитов.
#
# ЗАЧЕМ МЕХАНИЧЕСКАЯ ПРОВЕРКА. Списки живут в двух файлах и синхронизировались вручную — и
# разошлись: install.sh ставил девять bin-скриптов, uninstall.sh снимал пять (не снимались
# claude-auto, claude-auto-self-probes, claude-auto-tg, claude-control-url-notify), а
# claude-control-url-notify.service install.sh ещё и `enable`-ил, но снос про него не знал
# вовсе. Правка списков без этого теста означает, что дефект вернётся при следующей новой
# точке установки — ровно тот класс «жёсткий список сам станет местом, где забудут», против
# которого построен весь остальной забор.
#
# Проверка чисто СТАТИЧЕСКАЯ: файлы читаются как текст. Ни install.sh, ни uninstall.sh не
# запускаются (они трогают systemd и $HOME/.local/bin живого сервера) — этот тест физически
# не может ничего установить или снести.
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bootstrap.sh"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $1"; exit 1; }

# list_of <файл> <первое слово цикла> — элементы `for <var> in a b c \<перенос> d; do`,
# отсортированные и склеенные пробелами. Комментарии, стоящие ОТДЕЛЬНЫМИ строками до цикла,
# не мешают: берём строку, начинающуюся ровно с "for <var> in", и продолжения по "\".
list_of() {
  local file="$1" var="$2"
  awk -v var="$var" '
    index($0, "for " var " in ") == 1 { collecting = 1; line = substr($0, length("for " var " in ") + 1) }
    collecting == 2 { line = line " " $0 }
    collecting {
      if (line ~ /\\[[:space:]]*$/) { sub(/\\[[:space:]]*$/, "", line); collecting = 2; next }
      sub(/;.*$/, "", line); print line; exit
    }
  ' "$file" | tr ' ' '\n' | command grep -v '^$' | sort | tr '\n' ' '
}

for pair in "script:bin-скрипты" "libfile:lib-файлы"; do
  var="${pair%%:*}"; human="${pair##*:}"
  inst="$(list_of "$DIR/install.sh" "$var")"
  unin="$(list_of "$DIR/uninstall.sh" "$var")"
  [ -n "$inst" ] || fail "не нашёл цикл 'for $var in' в install.sh — проверка списка '$human' сломана, почини её, а не удаляй"
  [ -n "$unin" ] || fail "не нашёл цикл 'for $var in' в uninstall.sh — проверка списка '$human' сломана, почини её, а не удаляй"
  [ "$inst" = "$unin" ] \
    || fail "$human: install.sh ставит [$inst], uninstall.sh снимает [$unin] — списки обязаны совпадать"
  echo "OK: $human совпадают ($inst)"
done

# Юниты: КАЖДЫЙ *_UNIT, который install.sh рендерит/включает, обязан упоминаться в
# uninstall.sh (там он и disable'ится, и удаляется — оба цикла ходят по одному набору имён).
for unit in $(command grep -oE '^[A-Z_]+_UNIT="[a-z0-9.-]+"' "$DIR/install.sh" | cut -d'"' -f2 | sort -u); do
  command grep -q "\"$unit\"" "$DIR/uninstall.sh" \
    || fail "юнит '$unit' install.sh ставит, а uninstall.sh про него не знает — после сноса останется включённый юнит с ExecStart на удалённый бинарь"
  echo "OK: юнит $unit снимается"
done

echo "PASS install-lists"
