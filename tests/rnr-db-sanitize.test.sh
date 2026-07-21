#!/bin/bash
# Битый UTF-8 в argv (следствие байтовой обрезки в bash-хелперах: `cut -c` режет
# посреди multibyte-символа) не должен валить INSERT единственного писателя БД:
# sqlite3 отказывается биндить строки с lone surrogates (UnicodeEncodeError),
# и до фикса и запрос-approval, и ask падали целиком.
set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bootstrap.sh"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB_PY="$DIR/bot/rnr_db.py"
# T6: путь к БД карточек подставляет раннер (RNR_ASKS_DB внутри песочницы) — свой
# `mktemp -d` тут больше не нужен и только скрывал бы, кто на самом деле отвечает за
# изоляцию боевой sqlite.

# payload с расколотым посередине кириллическим символом (как после cut -c1-2001)
broken="$(python3 -c "print('я'*1500)" | cut -c1-2001)"

python3 "$DB_PY" insert-approval --qid q1 --worker w --tmux-target t --chat-id 1 \
  --action dept-approval --arg-kind event_id --arg-value evt_1_aaaa \
  --payload "$broken" || { echo 'FAIL: insert-approval упал на битом UTF-8 payload'; exit 1; }
python3 "$DB_PY" get-appr-by-qid --qid q1 | grep -q '"qid": *"q1"' \
  || { echo 'FAIL: строка approval не записана'; exit 1; }
# осколок заменён на U+FFFD, целые символы не тронуты
python3 "$DB_PY" get-appr-by-qid --qid q1 | python3 -c '
import json,sys
row=json.loads(sys.stdin.read())
p=row["payload"]
assert "�" in p, "нет замещающего символа"
assert p.count("я") == 1000, f"целые символы повреждены: {p.count(chr(1103))}"
' || { echo 'FAIL: payload санитизирован неверно'; exit 1; }

# тот же класс для asks: QUESTION после cut -c1-2500 (claude-auto-ask)
python3 "$DB_PY" insert-ask --qid q2 --kind ask --worker w --tmux-target t --chat-id 1 \
  --question "$broken" || { echo 'FAIL: insert-ask упал на битом UTF-8 question'; exit 1; }
python3 "$DB_PY" get-by-qid --qid q2 | grep -q '"qid": *"q2"' \
  || { echo 'FAIL: строка ask не записана'; exit 1; }

# чистый юникод проходит без изменений
python3 "$DB_PY" insert-approval --qid q3 --worker w --tmux-target t --chat-id 1 \
  --action dept-approval --arg-kind event_id --arg-value evt_2_bbbb \
  --payload 'обычный русский текст — ёж, §, 🚀'
python3 "$DB_PY" get-appr-by-qid --qid q3 | grep -q 'обычный русский текст — ёж, §, 🚀' \
  || { echo 'FAIL: чистый юникод искажён'; exit 1; }

echo PASS
