#!/bin/bash
# Бот гасит карточку отозванной заявки (фаза 4, Task 7 Step 2). process_approval получает
# status='withdrawn' (rnr_db.claim_withdraw уже перевёл строку — Task 6) и обязан:
#   - погасить карточку в Telegram (edit_message_text с картой + тегом «Отозвано автором»,
#     реконструированной через render_approval — в схеме approvals нет card_html);
#   - если правка текста упала — fallback на снятие клавиатуры (edit_message_reply_markup);
#   - НЕ инжектить исход воркеру (он сам отозвал — сообщать ему нечего);
#   - M8: если ОБА edit-пути упали — ограниченный ретрай на attempts/APPR_MAX_ATTEMPTS
#     (тот же счётчик, что denied/approved-ветки), notified_at НЕ ставится, пока попытки
#     не исчерпаны (иначе кнопки остаются живыми навсегда без единого шанса на дозагрузку).
#     После исчерпания — notified_at (строка обязана уйти из next_actionable за конечное
#     число тиков) + лог + alert_operator (оператор иначе не узнает про мусорную карточку).
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
        self.sent_messages = []  # M8: alert_operator(bot, text) -> bot.send_message(OPERATOR, text)
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
    async def send_message(self, chat_id, text):
        self.sent_messages.append((chat_id, text))
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

# 3) M8: оба пути падают ОДИН РАЗ -> notified_at НЕ ставится (ретрай), строка остаётся
#    actionable — до фикса notified_at ставился безусловно даже на первой же неудаче.
row3 = mk_row("q3", "evt_3_cccc", 4444, "третья причина")
bot3 = FakeBot(text_fails=True, markup_fails=True)
asyncio.run(bot_mod.process_approval(bot3, row3))
row3_after = rnr_db.get_appr_by_qid("q3")
check(row3_after["notified_at"] is None,
      "M8: notified_at выставлен после ОДНОЙ неудачной попытки — ретрай не сработал")
check(row3_after["attempts"] == 1, f"M8: attempts не инкрементирован после попытки: {row3_after['attempts']}")
check(len(bot3.sent_messages) == 0, "M8: alert_operator не должен звать на первой неудаче (рано)")
actionable3 = rnr_db.next_actionable(limit=50)
check("q3" in {r['qid'] for r in actionable3},
      "M8: строка после одной неудачной попытки должна остаться в next_actionable (ретрай)")

# 3b) M8: попытки исчерпаны (APPR_MAX_ATTEMPTS) -> notified_at ставится, лог + alert_operator,
#     строка обязана уйти из next_actionable за конечное число тиков (не вечный цикл)
row3b = mk_row("q3b", "evt_3b_gggg", 4747, "исчерпание ретраев")
bot3b = FakeBot(text_fails=True, markup_fails=True)
for i in range(bot_mod.APPR_MAX_ATTEMPTS):
    asyncio.run(bot_mod.process_approval(bot3b, row3b))
row3b_after = rnr_db.get_appr_by_qid("q3b")
check(row3b_after["attempts"] == bot_mod.APPR_MAX_ATTEMPTS,
      f"M8: attempts={row3b_after['attempts']}, ожидался {bot_mod.APPR_MAX_ATTEMPTS}")
check(row3b_after["notified_at"] is not None,
      "M8: notified_at НЕ выставлен после исчерпания попыток — строка зациклится в exec_loop навечно")
check(len(bot3b.sent_messages) == 1, f"M8: alert_operator ожидался ровно 1 раз, вызван {len(bot3b.sent_messages)}")
if bot3b.sent_messages:
    _, alert_text = bot3b.sent_messages[0]
    check("q3b" in alert_text, "M8: алерт оператору не содержит qid проблемной карточки")
    check(str(bot_mod.APPR_MAX_ATTEMPTS) in alert_text, "M8: алерт не упоминает число попыток")
actionable3b = rnr_db.next_actionable(limit=50)
check("q3b" not in {r['qid'] for r in actionable3b},
      "M8: строка обязана покинуть next_actionable после исчерпания попыток (не вечный цикл)")

# 3c) M8: восстановление ДО исчерпания — несколько неудач, потом успех -> notified_at
#     ставится СРАЗУ на успешной попытке, alert_operator НЕ зовётся (не «исчерпание»)
row3c = mk_row("q3c", "evt_3c_hhhh", 4848, "восстановилось")
bot3c = FakeBot(text_fails=True, markup_fails=True)
for i in range(3):
    asyncio.run(bot_mod.process_approval(bot3c, row3c))
row3c_mid = rnr_db.get_appr_by_qid("q3c")
check(row3c_mid["notified_at"] is None, "M8: notified_at выставлен раньше времени (до восстановления)")
bot3c.text_fails = False  # Telegram снова доступен
asyncio.run(bot_mod.process_approval(bot3c, row3c))
row3c_after = rnr_db.get_appr_by_qid("q3c")
check(row3c_after["notified_at"] is not None, "M8: notified_at не выставлен сразу после успешной попытки")
check(row3c_after["attempts"] == 4, f"M8: attempts после восстановления: {row3c_after['attempts']} (ожидался 4)")
check(len(bot3c.sent_messages) == 0, "M8: alert_operator не должен звать — заявка восстановилась, не исчерпалась")

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

# 6) /bug ф4: reason приходит от воркера без ограничений — claim_withdraw обязан капнуть
#    result до 400 (зеркало dept-ledger approval-withdraw .slice(0,400)), иначе тег
#    «Отозвано автором: …» пробивает лимит Telegram-сообщения (4096), правка текста падает,
#    и карточка остаётся без пометки отзыва (срабатывает только fallback-снятие кнопок).
row6 = mk_row("q6", "evt_6_ffff", 4646, "ю" * 5000)
check(len(row6["result"]) <= 400, f"result не капнут: {len(row6['result'])} симв. > 400")
bot6 = FakeBot()
asyncio.run(bot_mod.process_approval(bot6, row6))
check(len(bot6.text_calls) == 1, "карточка с длинной причиной не погашена основным путём")
if bot6.text_calls:
    t = bot6.text_calls[0].get("text", "")
    check(len(t) < 4096, f"текст карточки {len(t)} симв. >= лимита Telegram 4096")
    check("Отозвано автором" in t, "тег отзыва потерян при длинной причине")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS")
PYEOF
