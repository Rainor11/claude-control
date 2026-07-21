#!/bin/bash
# tests/ledger-messages.test.sh — адаптер шины событий поверх журнала отдела.
# T6: было `export DEPT_HOME="$(mktemp -d)"` — каталог СНАРУЖИ тестового корня, из-за чего
# резолвер T1 законно отказывал bin/dept-ledger («утечка боевого окружения в тест»). Корень
# теперь задаёт раннер, DEPT_HOME тест не выставляет вовсе: под маркером профиль dept_only
# резолвится в <корень>/department, туда и пишет журнал.
set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bootstrap.sh"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LM="$DIR/channels/event-bridge/adapters/ledger-messages"

"$DIR/bin/dept-ledger" send --type question --to dept-head --subject "тест с
переводом строки" --body 'тело' --actor mk-x >/dev/null
out1="$("$LM" --worker dept-head)"
[ "$(printf '%s\n' "$out1" | wc -l)" = 1 ] || { echo 'FAIL: не line-safe (перевод строки в subject)'; exit 1; }
echo "$out1" | grep -q 'dept-message type=question from=mk-x' || { echo 'FAIL: нет строки события'; exit 1; }
printf '%s' "$out1" | od -c | grep -q '036' || { printf '%s\n' 'FAIL: нет скрытого ebid-маркера (\x1e)'; exit 1; }
[ "$("$LM" --worker other | wc -l)" = 0 ] || { echo 'FAIL: чужое сообщение попало'; exit 1; }
out2="$("$LM" --worker dept-head)"
[ "$out1" = "$out2" ] || { echo 'FAIL: строка недетерминирована'; exit 1; }
eid="$(echo "$out1" | grep -o 'evt_[0-9]*_[a-z0-9]*' | head -1)"
"$DIR/bin/dept-ledger" ack "$eid" --actor dept-head >/dev/null
[ -z "$("$LM" --worker dept-head)" ] || { echo 'FAIL: acked сообщение всё ещё эмитится'; exit 1; }

# кап subject: 500-символьная тема не раздувает строку события
longsubj="$(printf 'ы%.0s' $(seq 1 500))"
"$DIR/bin/dept-ledger" send --type question --to capworker --subject "$longsubj" --body 'b' --actor mk-x >/dev/null
caplen="$("$LM" --worker capworker | head -1 | wc -m)"
[ "$caplen" -lt 700 ] || { echo "FAIL: subject не закапан (длина строки $caplen)"; exit 1; }
# позиция ebid-маркера: строка НАЧИНАЕТСЯ со скрытого маркера
"$LM" --worker capworker | head -1 | od -An -c | head -1 | grep -q '^ *036' || { echo 'FAIL: ebid-маркер не в начале строки'; exit 1; }

# нагрузочный смок шины (§14 спеки: валидация до расширения): 10 подписчиков ×
# 5 сообщений, параллельные вызовы адаптера, после ack повторной выдачи нет
for w in $(seq 1 10); do for m in $(seq 1 5); do
  "$DIR/bin/dept-ledger" send --type question --to "load-w$w" --subject "m$m" --body 'x' --actor operator >/dev/null &
done; done; wait
for w in $(seq 1 10); do
  cnt="$("$LM" --worker "load-w$w" | wc -l)"
  [ "$cnt" = 5 ] || { echo "FAIL: load-w$w получил $cnt событий вместо 5"; exit 1; }
done
# параллельный fanout адаптера не мешает друг другу
for w in $(seq 1 10); do "$LM" --worker "load-w$w" >/dev/null & done; wait
eids="$("$LM" --worker load-w1 | grep -o 'evt_[0-9]*_[a-z0-9]*' | sort -u)"
for e in $eids; do "$DIR/bin/dept-ledger" ack "$e" --actor load-w1 >/dev/null; done
[ -z "$("$LM" --worker load-w1)" ] || { echo 'FAIL: после ack события всё ещё эмитятся'; exit 1; }
echo PASS
