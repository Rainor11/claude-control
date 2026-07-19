#!/bin/bash
# Бот гасит карточку отозванной заявки (фаза 4, Task 7 Step 2). process_approval получает
# status='withdrawn' (rnr_db.claim_withdraw уже перевёл строку — Task 6) и обязан:
#   - погасить карточку в Telegram (edit_message_text с картой + тегом «Отозвано автором»,
#     реконструированной через render_approval — в схеме approvals нет card_html);
#   - если правка текста упала — fallback на снятие клавиатуры (edit_message_reply_markup);
#   - НЕ инжектить исход воркеру (он сам отозвал — сообщать ему нечего);
#   - выставить notified_at ВСЕГДА (даже если оба edit-пути упали) — иначе next_actionable
#     крутил бы строку вечно.
# Также проверяет, что 'withdrawn' попал в статус-фильтр next_actionable (rnr_db.py).
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PY="$DIR/bot/venv/bin/python3"
[ -x "$PY" ] || PY="python3"
export RNR_ASKS_DB="$(mktemp -d)/asks.db"

"$PY" <<PYEOF
import asyncio, os, sys
sys.path.insert(0, "$DIR/bot")
import rnr_db
import rnr_workers_bot as bot_mod

failures = []
def check(cond, msg):
    if not cond:
        failures.append(msg)

class FakeBot:
    def __init__(self, text_fails=False, markup_fails=False):
        self.text_fails = text_fails
        self.markup_fails = markup_fails
        self.text_calls = []
        self.markup_calls = []
    async def edit_message_text(self, **kw):
        self.text_calls.append(kw)
        if self.text_fails:
            raise RuntimeError("boom-text")
        return True
    async def edit_message_reply_markup(self, **kw):
        self.markup_calls.append(kw)
        if self.markup_fails:
            raise RuntimeError("boom-markup")
        return True

def mk_row(qid, event_id, message_id, reason):
    rnr_db.insert_approval(qid, "w1", "claude-w1", 555, "dept-approval",
                            arg_kind="event_id", arg_value=event_id,
                            payload="детали заявки", reason="было надо")
    if message_id is not None:
        rnr_db.set_message_id_appr(qid, message_id)
    res = rnr_db.claim_withdraw(event_id, "w1", reason)
    check(res == "withdrawn", f"claim_withdraw не перевёл {qid} в withdrawn: {res!r}")
    return rnr_db.get_appr_by_qid(qid)

# 1) happy path: карточка гасится текстом, notified_at ставится, воркер НЕ уведомляется
row1 = mk_row("q1", "evt_1_aaaa", 4242, "смок причина")
bot1 = FakeBot()
asyncio.run(bot_mod.process_approval(bot1, row1))
check(len(bot1.text_calls) == 1, f"edit_message_text вызван {len(bot1.text_calls)} раз, ожидался 1")
if bot1.text_calls:
    c = bot1.text_calls[0]
    check(c.get("chat_id") == 555, f"chat_id не 555: {c.get('chat_id')!r}")
    check(c.get("message_id") == 4242, f"message_id не 4242: {c.get('message_id')!r}")
    check(c.get("parse_mode") == "HTML", f"parse_mode не HTML: {c.get('parse_mode')!r}")
    check(c.get("reply_markup") is None, "reply_markup не снят (не None)")
    check("Отозвано автором" in c.get("text", ""), "текст карточки не содержит тег отзыва")
    check("смок причина" in c.get("text", ""), "текст карточки не содержит причину отзыва")
    check(len(bot1.markup_calls) == 0, "fallback markup вызван зря на happy path")
row1_after = rnr_db.get_appr_by_qid("q1")
check(row1_after["notified_at"] is not None, "notified_at не выставлен после гашения карточки")

# 2) fallback: edit_message_text падает -> edit_message_reply_markup снимает клавиатуру
row2 = mk_row("q2", "evt_2_bbbb", 4343, "вторая причина")
bot2 = FakeBot(text_fails=True)
asyncio.run(bot_mod.process_approval(bot2, row2))
check(len(bot2.text_calls) == 1, "edit_message_text (fallback-путь) не был вызван")
check(len(bot2.markup_calls) == 1, "fallback edit_message_reply_markup не вызван после падения текста")
if bot2.markup_calls:
    c = bot2.markup_calls[0]
    check(c.get("chat_id") == 555, "fallback: chat_id не 555")
    check(c.get("message_id") == 4343, "fallback: message_id не 4343")
row2_after = rnr_db.get_appr_by_qid("q2")
check(row2_after["notified_at"] is not None, "notified_at не выставлен после fallback-гашения")

# 3) оба пути падают -> notified_at ВСЁ РАВНО выставляется (иначе вечный цикл в exec_loop)
row3 = mk_row("q3", "evt_3_cccc", 4444, "третья причина")
bot3 = FakeBot(text_fails=True, markup_fails=True)
asyncio.run(bot_mod.process_approval(bot3, row3))
row3_after = rnr_db.get_appr_by_qid("q3")
check(row3_after["notified_at"] is not None,
      "notified_at не выставлен, когда оба edit-пути упали — строка зациклится в exec_loop")

# 4) карточка ещё не была отправлена (message_id IS NULL) -> ни один edit не вызывается,
#    но notified_at всё равно ставится (нечего гасить, не крутить строку вечно)
row4 = mk_row("q4", "evt_4_dddd", None, "четвёртая причина")
bot4 = FakeBot()
asyncio.run(bot_mod.process_approval(bot4, row4))
check(len(bot4.text_calls) == 0, "edit_message_text вызван, хотя карточка не была отправлена")
check(len(bot4.markup_calls) == 0, "edit_message_reply_markup вызван, хотя карточка не была отправлена")
row4_after = rnr_db.get_appr_by_qid("q4")
check(row4_after["notified_at"] is not None, "notified_at не выставлен для неотправленной карточки")

# 5) next_actionable() учитывает withdrawn (row без notified_at ещё не помечен)
row5 = mk_row("q5", "evt_5_eeee", 4545, "пятая причина")
actionable = rnr_db.next_actionable(limit=50)
qids = {r["qid"] for r in actionable}
check("q5" in qids, "next_actionable не подхватывает status='withdrawn'")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS")
PYEOF
