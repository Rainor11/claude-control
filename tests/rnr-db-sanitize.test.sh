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

# ---------------------------------------------------------------------------------------
# T6: дефолт пути БД (когда RNR_ASKS_DB НЕ задана) обязан идти через резолвер корня.
# До T6 он был захардкожен на ~/.claude-control/rnr-bot/asks.db, и изоляция держалась ТОЛЬКО
# на том, что раннер экспортирует RNR_ASKS_DB. Но rnr_db.py зовут ПОДПРОЦЕССОМ bash-обёртки
# (dept-liveness-request, dept-withdraw) — вызов под маркером, но без унаследованной
# переменной, писал бы в БОЕВУЮ sqlite оператора. Здесь снимаем переменную ЯВНО и проверяем,
# что запись легла в песочницу, а «боевой» каталог (относительно HOME, который раннер тоже
# подменил на песочницу) не появился вовсе.
# ---------------------------------------------------------------------------------------
fake_prod_db="$HOME/.claude-control/rnr-bot/asks.db"
[ -e "$fake_prod_db" ] && { echo "FAIL: боевая БД существует ДО проверки — тест собран неверно"; exit 1; }
env -u RNR_ASKS_DB python3 "$DB_PY" insert-approval --qid q4 --worker w --tmux-target t \
  --chat-id 1 --action dept-approval --arg-kind event_id --arg-value evt_3_cccc \
  --payload 'проверка дефолтного пути БД' \
  || { echo 'FAIL: insert-approval без RNR_ASKS_DB упал'; exit 1; }
[ -f "$CLAUDE_CONTROL_TEST_ROOT/rnr-bot/asks.db" ] \
  || { echo 'FAIL: без RNR_ASKS_DB БД не появилась в песочнице — дефолт мимо резолвера'; exit 1; }
[ -e "$fake_prod_db" ] \
  && { echo "FAIL: без RNR_ASKS_DB запись ушла в боевой путь ($fake_prod_db) — резолвер обойдён"; exit 1; }
env -u RNR_ASKS_DB python3 "$DB_PY" get-appr-by-qid --qid q4 | grep -q '"qid": *"q4"' \
  || { echo 'FAIL: строка не читается из БД в песочнице'; exit 1; }
# И обратная сторона: q4 писался в ДРУГУЮ БД, чем q1-q3 (RNR_ASKS_DB от раннера) — иначе
# проверка выше ничего бы не доказывала.
python3 "$DB_PY" get-appr-by-qid --qid q4 2>/dev/null | grep -q '"qid"' \
  && { echo 'FAIL: q4 виден и в БД раннера — значит дефолт и RNR_ASKS_DB указывают в одно место'; exit 1; }

echo PASS
