#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DEPT_HOME="$(mktemp -d)"
LM="$DIR/channels/event-bridge/adapters/ledger-messages"

"$DIR/bin/dept-ledger" send --type question --to dept-head --subject "тест с
переводом строки" --body 'тело' --actor mk-x >/dev/null
out1="$("$LM" --worker dept-head)"
[ "$(printf '%s\n' "$out1" | wc -l)" = 1 ] || { echo 'FAIL: не line-safe (перевод строки в subject)'; exit 1; }
echo "$out1" | grep -q 'dept-message type=question from=mk-x' || { echo 'FAIL: нет строки события'; exit 1; }
printf '%s' "$out1" | od -c | grep -q '036' || { echo 'FAIL: нет скрытого ebid-маркера (\x1e)'; exit 1; }
[ "$("$LM" --worker other | wc -l)" = 0 ] || { echo 'FAIL: чужое сообщение попало'; exit 1; }
out2="$("$LM" --worker dept-head)"
[ "$out1" = "$out2" ] || { echo 'FAIL: строка недетерминирована'; exit 1; }
eid="$(echo "$out1" | grep -o 'evt_[0-9]*_[a-z0-9]*' | head -1)"
"$DIR/bin/dept-ledger" ack "$eid" --actor dept-head >/dev/null
[ -z "$("$LM" --worker dept-head)" ] || { echo 'FAIL: acked сообщение всё ещё эмитится'; exit 1; }
echo PASS
