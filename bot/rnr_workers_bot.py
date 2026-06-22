#!/usr/bin/env python3
"""rnr_workers_bot.py — the @RnR_Workers two-way Telegram bot for claude-control.

It is the UI + answer-claimer for worker↔operator messaging, plus a durable
delivery outbox that injects the operator's answer back into the worker session.

Responsibilities:
  * receive inline-button taps  (callback_data "ask:<qid>:<idx>") and operator
    REPLIES to a worker message, CLAIM the first one atomically (once-only), and
    queue it for delivery;
  * a background delivery loop drains claimed answers via `session-inject`
    (retry + backoff; resumes after a restart — the SQLite outbox is durable);
  * a view-only menu (/start) that shells out to `claude-auto overview`.

Security (Codex plan review): every callback/reply is AUTHORIZED FIRST — accepted
only from the operator (from_user.id AND chat.id both == operator), and a callback
is cross-checked against the stored row's chat_id/message_id. No public callback
prefixes. Delivery is at-least-once; the worker dedups by the visible #<qid> tag.

Resilience mirrors server_notifier.py: AiohttpSession through the sing-box proxy,
polling retry with backoff + getMe health-check + session reset.
"""
import asyncio
import fcntl
import html
import json
import logging
import os
import re
import subprocess
import sys

from aiogram import Bot, Dispatcher, F
from aiogram.client.session.aiohttp import AiohttpSession
from aiogram.filters import Command, CommandStart
from aiogram.types import (
    CallbackQuery,
    InlineKeyboardButton,
    InlineKeyboardMarkup,
    Message,
)

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.normpath(os.path.join(HERE, "..", "bin"))
SESSION_INJECT = os.path.join(BIN, "session-inject")
CLAUDE_AUTO = os.path.join(BIN, "claude-auto")
ENV_PATH = os.environ.get("RNR_ENV_PATH", "/home/rainor/server/.env")

sys.path.insert(0, HERE)
import rnr_db  # noqa: E402  (stdlib-only DB helper, same dir)

# --- delivery tunables ---
POLL_SEC = 5          # delivery loop tick
INJECT_TIMEOUT = 20   # session-inject wait-for-idle per attempt (short → loop not blocked)
RETRY_AFTER = 25      # don't re-attempt a row within this many seconds (> INJECT_TIMEOUT)
ALERT_AT = 6          # attempts before a "still trying" ping (~few min)
MAX_ATTEMPTS = 160    # give up + alert (a parked worker may stay busy a while)

log = logging.getLogger("rnr-workers-bot")


def load_env(path=ENV_PATH):
    d = {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k = k.strip()
                v = v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                    v = v[1:-1]
                d[k] = v
    except OSError:
        pass
    return d


ENV = load_env()
TOKEN = ENV.get("RNR_WORKERS_BOT_TOKEN", "").strip()
try:
    OPERATOR = int(re.sub(r"[^0-9]", "", ENV.get("TELEGRAM_CHAT_ID", "") or "0"))
except ValueError:
    OPERATOR = 0
PROXY_URL = os.environ.get("HTTPS_PROXY", "http://127.0.0.1:1081")


def esc(s):
    return html.escape(s or "", quote=False)


def authed_user_chat(user_id, chat_id):
    return user_id == OPERATOR and chat_id == OPERATOR


def _sanitize(text, cap=3500):
    text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f]", "", text or "")
    return text[:cap]


def run_session_inject(target, text):
    """Inject `text` into the worker's tmux session as a user turn. Returns the
    session-inject exit code (0 = delivered). Blocking → call via to_thread."""
    try:
        p = subprocess.run(
            [SESSION_INJECT, "--timeout", str(INJECT_TIMEOUT), target, "-"],
            input=text.encode("utf-8"),
            capture_output=True,
            timeout=INJECT_TIMEOUT + 30,
        )
        if p.returncode != 0:
            log.warning("session-inject rc=%s target=%s err=%s",
                        p.returncode, target, p.stderr.decode("utf-8", "replace")[:300])
        return p.returncode
    except Exception as e:  # noqa: BLE001
        log.warning("session-inject crashed target=%s: %s", target, e)
        return 99


def run_overview():
    try:
        p = subprocess.run([CLAUDE_AUTO, "overview"], capture_output=True, timeout=30)
        out = p.stdout.decode("utf-8", "replace")
        if not out.strip():
            out = p.stderr.decode("utf-8", "replace") or "(пусто)"
        return out
    except Exception as e:  # noqa: BLE001
        return f"overview не отработал: {e}"


def build_framed(row):
    qid = row["qid"]
    if row.get("answered_via") == "button":
        q = row.get("question") or ""
        label = row.get("answer_text") or ""
        body = f'На твой вопрос «{q}» оператор выбрал: «{label}»'
    else:
        body = row.get("answer_text") or ""
    return f"[ответ оператора на твой вопрос (#{qid})]\n{body}"


# ============================ handlers ======================================

def make_menu():
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="📋 Воркеры — статус", callback_data="menu:overview")],
    ])


async def cmd_start(message: Message):
    if not authed_user_chat(message.from_user.id, message.chat.id):
        return
    await message.answer(
        "🤖 <b>RnR Workers</b>\n"
        "Двусторонний канал с автономными воркерами.\n\n"
        "• Воркер пришлёт вопрос с кнопками или эскалацию — нажми кнопку "
        "или <b>ответь реплаем</b>, и ответ уйдёт ему в сессию.\n"
        "• Меню ниже — статус всех воркеров.",
        parse_mode="HTML",
        reply_markup=make_menu(),
    )


async def cb_menu_overview(cb: CallbackQuery):
    if not authed_user_chat(cb.from_user.id, cb.message.chat.id if cb.message else 0):
        await cb.answer("нет доступа", show_alert=True)
        return
    await cb.answer("Собираю статус…")
    out = await asyncio.to_thread(run_overview)
    text = "<b>📋 Воркеры</b>\n<pre>" + esc(out[:3500]) + "</pre>"
    try:
        await cb.message.answer(text, parse_mode="HTML", reply_markup=make_menu())
    except Exception as e:  # noqa: BLE001
        log.warning("overview send failed: %s", e)
        await cb.message.answer("Не смог отрисовать overview (см. лог).")


async def cb_ask(cb: CallbackQuery):
    chat_id = cb.message.chat.id if cb.message else 0
    if not authed_user_chat(cb.from_user.id, chat_id):
        await cb.answer("нет доступа", show_alert=True)
        return
    parts = (cb.data or "").split(":")
    if len(parts) != 3:
        await cb.answer("битый запрос", show_alert=True)
        return
    _, qid, sidx = parts
    try:
        idx = int(sidx)
    except ValueError:
        await cb.answer("битый вариант", show_alert=True)
        return

    row = rnr_db.get_by_qid(qid)
    if not row:
        await cb.answer("вопрос не найден", show_alert=True)
        return
    # cross-check the callback message against the stored row (Codex HIGH-6).
    if row["chat_id"] != chat_id or (row["message_id"] and cb.message
                                     and row["message_id"] != cb.message.message_id):
        await cb.answer("несовпадение сообщения", show_alert=True)
        return
    labels = json.loads(row["options_json"] or "[]")
    if idx < 0 or idx >= len(labels):
        await cb.answer("неизвестный вариант", show_alert=True)
        return
    label = labels[idx]

    claimed = rnr_db.claim_by_qid(qid, "button", idx, label)
    if not claimed:
        try:
            await cb.message.edit_reply_markup(reply_markup=None)
        except Exception:  # noqa: BLE001
            pass
        await cb.answer("уже отвечено ранее", show_alert=True)
        return

    await cb.answer("✅ Принято")
    try:
        new = (cb.message.html_text or "") + f"\n\n✅ Выбрано: {esc(label)}"
        await cb.message.edit_text(new, parse_mode="HTML", reply_markup=None)
    except Exception:  # noqa: BLE001
        try:
            await cb.message.edit_reply_markup(reply_markup=None)
        except Exception:  # noqa: BLE001
            pass
    # delivery loop (status=claimed) will inject it.


async def on_reply(message: Message):
    if not authed_user_chat(message.from_user.id, message.chat.id):
        return
    rt = message.reply_to_message
    answer_text = _sanitize(message.text or message.caption or "")
    if not answer_text.strip():
        await message.reply("↩️ Пустой ответ — пришли текст.")
        return

    row = rnr_db.get_by_message(message.chat.id, rt.message_id)
    if not row:
        # Fallback: parse the visible 🆔 RNR-<qid> from the replied message text. Accept
        # it ONLY in the operator's own chat AND only when the row's message_id is not yet
        # known (the send→set-message-id race window) or it matches the replied message —
        # so a reply to a quoted/forwarded copy carrying an open qid can't answer the wrong
        # question (Codex HIGH-3).
        m = re.search(r"RNR-([A-Za-z0-9_-]{6,})", (rt.text or rt.caption or ""))
        if m:
            cand = rnr_db.get_by_qid(m.group(1))
            if (cand and cand["chat_id"] == message.chat.id
                    and (cand["message_id"] is None or cand["message_id"] == rt.message_id)):
                row = cand
    if not row:
        await message.reply("↩️ Это сообщение не ждёт здесь ответа.")
        return

    claimed = rnr_db.claim_by_qid(row["qid"], "reply", None, answer_text)
    if not claimed:
        await message.reply("⏳ На это уже отвечено ранее — повторный ответ НЕ отправлен.")
        return
    await message.reply(f"✅ Принято, передаю воркеру «{esc(row['worker'])}».")


# ============================ delivery loop =================================

_LOCK_FH = None  # kept process-lifetime so the flock is held until exit


def acquire_singleton():
    """Refuse to run a second instance. Telegram allows one getUpdates consumer per
    token, but the delivery loop runs independently of polling — two processes would
    BOTH inject the same answer (Codex CRIT-1). A flock makes the bot a singleton."""
    global _LOCK_FH
    lockdir = os.path.join(os.path.expanduser("~"), ".claude-control", "rnr-bot")
    os.makedirs(lockdir, exist_ok=True)
    _LOCK_FH = open(os.path.join(lockdir, "bot.lock"), "w")
    try:
        fcntl.flock(_LOCK_FH, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log.error("another rnr-workers-bot already holds the lock — exiting (no double delivery)")
        sys.exit(1)


async def alert_operator(bot: Bot, text):
    try:
        await bot.send_message(OPERATOR, text)
    except Exception as e:  # noqa: BLE001
        log.warning("alert_operator failed: %s", e)


async def deliver(bot: Bot, row):
    qid = row["qid"]
    target = row["tmux_target"]
    worker = row["worker"]
    framed = build_framed(row)
    attempts = rnr_db.record_attempt(qid)
    rc = await asyncio.to_thread(run_session_inject, target, framed)
    if rc == 0:
        rnr_db.mark_delivered(qid)
        log.info("delivered #%s → %s (attempt %s)", qid, worker, attempts)
        return
    if attempts == ALERT_AT:
        await alert_operator(
            bot, f"⚠️ Пока не могу доставить твой ответ воркеру «{worker}» (#{qid}) — "
                 f"он занят/недоступен. Продолжаю попытки.")
    if attempts >= MAX_ATTEMPTS:
        rnr_db.mark_failed(qid)
        await alert_operator(
            bot, f"❌ Не доставил ответ воркеру «{worker}» (#{qid}) за {attempts} попыток. "
                 f"Загляни в сессию вручную: tmux attach -t {target}")


async def delivery_loop(bot: Bot):
    log.info("delivery loop started (poll=%ss)", POLL_SEC)
    while True:
        try:
            rows = rnr_db.next_undelivered(limit=20, retry_after_sec=RETRY_AFTER)
            for row in rows:
                await deliver(bot, row)
        except Exception as e:  # noqa: BLE001
            log.exception("delivery loop error: %s", e)
        await asyncio.sleep(POLL_SEC)


# ============================ wiring + run =================================

def build_dispatcher():
    dp = Dispatcher()
    dp.message.register(cmd_start, CommandStart())
    dp.message.register(cmd_start, Command("help"))
    dp.callback_query.register(cb_menu_overview, F.data == "menu:overview")
    dp.callback_query.register(cb_ask, F.data.startswith("ask:"))
    dp.message.register(on_reply, F.reply_to_message)
    return dp


def make_bot():
    return Bot(token=TOKEN, session=AiohttpSession(proxy=PROXY_URL))


async def health_check(bot: Bot):
    try:
        await asyncio.wait_for(bot.get_me(), timeout=15)
        return True
    except Exception:  # noqa: BLE001
        return False


async def main():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
        handlers=[logging.StreamHandler(sys.stdout)],
    )
    if not TOKEN:
        log.error("RNR_WORKERS_BOT_TOKEN not set in %s — cannot start", ENV_PATH)
        sys.exit(1)
    if not OPERATOR:
        log.error("TELEGRAM_CHAT_ID (operator) not set in %s — cannot start", ENV_PATH)
        sys.exit(1)
    acquire_singleton()              # one delivery loop only — no double injection
    rnr_db.connect().close()  # ensure schema exists

    bot = make_bot()
    dp = build_dispatcher()
    asyncio.create_task(delivery_loop(bot))

    retry_delay = 5
    consecutive_fails = 0
    retry_count = 0
    while True:
        try:
            me = await bot.get_me()
            log.info("polling as @%s (operator=%s)", me.username, OPERATOR)
            await dp.start_polling(bot, handle_signals=False)
            break
        except (KeyboardInterrupt, SystemExit):
            break
        except Exception as e:  # noqa: BLE001
            retry_count += 1
            consecutive_fails += 1
            log.error("polling error (try %s): %s", retry_count, e)
            if consecutive_fails >= 3:
                if not await health_check(bot):
                    log.warning("getMe failed — resetting session")
                    try:
                        await bot.session.close()
                    except Exception:  # noqa: BLE001
                        pass
                    bot.session = AiohttpSession(proxy=PROXY_URL)
                consecutive_fails = 0
            await asyncio.sleep(retry_delay)
            retry_delay = min(retry_delay * 2, 60)
            if retry_count % 10 == 0:
                retry_delay = 5
    try:
        await bot.session.close()
    except Exception:  # noqa: BLE001
        pass


if __name__ == "__main__":
    asyncio.run(main())
