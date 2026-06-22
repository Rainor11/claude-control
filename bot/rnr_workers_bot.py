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
import datetime
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
    KeyboardButton,
    Message,
    ReplyKeyboardMarkup,
)

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.normpath(os.path.join(HERE, "..", "bin"))
SESSION_INJECT = os.path.join(BIN, "session-inject")
CLAUDE_AUTO = os.path.join(BIN, "claude-auto")
CONTROL_DIR = os.environ.get("CLAUDE_CONTROL_DIR",
                             os.path.join(os.path.expanduser("~"), ".claude-control"))
WORKERS_DIR = os.path.join(CONTROL_DIR, "workers")
ENV_PATH = os.environ.get("RNR_ENV_PATH", "/home/rainor/server/.env")
BTN_OVERVIEW = "📋 Воркеры — статус"
BTN_PROBES = "📡 Датчики"
TG_LIMIT = 3900  # safe chunk size under Telegram's 4096

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


def _worker_active(name):
    try:
        p = subprocess.run(["systemctl", "--user", "is-active", f"claude-auto@{name}.service"],
                           capture_output=True, timeout=5)
        return p.stdout.decode("utf-8", "replace").strip() == "active"
    except Exception:  # noqa: BLE001
        return False


def _worker_ctx(name):
    try:
        with open(os.path.join(WORKERS_DIR, name, "state", "context.json")) as f:
            d = json.load(f)
        return int(d.get("ctx_tokens") or 0), int(d.get("threshold") or 700000)
    except Exception:  # noqa: BLE001
        return 0, 700000


def _worker_probes(name):
    try:
        with open(os.path.join(WORKERS_DIR, name, "event-bridge.config.json")) as f:
            d = json.load(f)
        return len(d.get("probes") or [])
    except Exception:  # noqa: BLE001
        return 0


def render_overview():
    """Compact, mobile-friendly status — one short line per worker (NOT a wide
    terminal table). Built from source files, not parsed `claude-auto overview`."""
    try:
        names = sorted(n for n in os.listdir(WORKERS_DIR)
                       if os.path.isdir(os.path.join(WORKERS_DIR, n)))
    except OSError:
        return "📋 <b>Воркеры</b>\nНе нашёл воркеров."
    rows = []
    for n in names:
        ctx, thr = _worker_ctx(n)
        rows.append({
            "name": n,
            "active": _worker_active(n),
            "ctx": ctx,
            "pct": round(ctx / thr * 100) if thr else 0,
            "probes": _worker_probes(n),
        })
    up = sum(1 for r in rows if r["active"])
    down = len(rows) - up
    # down first (нужно внимание), затем по загрузке контекста ↓ (близкие к компакту — сверху)
    rows.sort(key=lambda r: (r["active"], -r["pct"]))
    # Monospace table for true vertical alignment. NO emoji inside <pre> — emoji are
    # not single-width and would break column alignment; status uses ●/○, units go to
    # the legend. Columns are narrow (probe COUNT, not names) so lines don't run wide.
    w = min(22, max((len(r["name"]) for r in rows), default=6))
    # header row aligned to the same column widths (dot col = 1 char)
    body = [f"{' '} {'воркер':<{w}} {'ctx':>5} {'загр':>5} {'дат':>3}"]
    for r in rows:
        nm = r["name"]
        if len(nm) > w:
            nm = nm[:w - 2] + ".."
        dot = "●" if r["active"] else "○"
        if not r["active"]:
            body.append(f"{dot} {nm:<{w}} {'down':>5}")
            continue
        ctxk = f"{round(r['ctx'] / 1000)}k"
        pctw = f"{r['pct']}%" + ("!" if r["pct"] >= 90 else "")
        body.append(f"{dot} {nm:<{w}} {ctxk:>5} {pctw:>5} {r['probes']:>3}")
    table = "<pre>" + esc("\n".join(body)) + "</pre>"
    return (
        f"📋 <b>Воркеры</b> · 🟢 {up} / 🔴 {down}\n"
        + table
        + "\n<i>ctx — контекст из 700k · загр — загрузка% · дат — датчиков · ! ≥90%</i>"
    )


def _worker_probe_objs(name):
    try:
        with open(os.path.join(WORKERS_DIR, name, "event-bridge.config.json")) as f:
            return json.load(f).get("probes") or []
    except Exception:  # noqa: BLE001
        return []


def _argval(args, flag):
    try:
        return args[args.index(flag) + 1]
    except (ValueError, IndexError, AttributeError):
        return None


def _fmt_yyyymmdd(s):
    if s and re.fullmatch(r"\d{8}", str(s)):
        return f"{s[6:8]}.{s[4:6]}.{s[0:4]}"
    return str(s)


def _freq_short(sec, src):
    if (src or "").startswith("date-gate"):
        return ""
    try:
        sec = int(sec)
    except (TypeError, ValueError):
        return "?"
    if sec < 60:
        return f"{sec}с"
    if sec < 3600:
        return f"{sec // 60}м"
    if sec % 3600 == 0:
        return f"{sec // 3600}ч"
    return f"{sec // 60}м"


_SRC_EMOJI = {"gmail": "✉️", "asana": "📋", "telegram": "💬", "tg": "💬",
              "date-gate": "📅", "timer": "⏱", "timer-tick": "⏱"}


def _probe_emoji(src):
    for k, v in _SRC_EMOJI.items():
        if (src or "").startswith(k):
            return v
    return "🔹"


def _probe_target(p):
    """Short, human target — NOT the full query (gmail queries can be huge)."""
    src = p.get("source", "")
    args = p.get("cmd") if isinstance(p.get("cmd"), list) else []
    if src == "gmail":
        q = _argval(args, "--query") or ""
        m = re.search(r"(?:^|\s)from:(\S+)", q)  # positive from:, not -from: exclusions
        t = m.group(1) if m else q
        return (t[:30] + "…") if len(t) > 30 else t
    if src == "asana":
        t = _argval(args, "--task") or "?"
        return "задача …" + t[-6:]
    if src in ("telegram", "tg"):
        return "чат " + (_argval(args, "--chat-id") or "?")
    if src.startswith("date-gate"):
        return "разовый"
    if src.startswith("timer"):
        return "таймер"
    return src


def _probe_next_suffix(name, p):
    """' → <when>' when meaningful: exact date for date-gate; exact HH:MM once the
    event-bridge-watch last-run stamp exists; empty otherwise (freq implies cadence)."""
    src = p.get("source", "")
    if src.startswith("date-gate"):
        cmd = p.get("cmd") if isinstance(p.get("cmd"), list) else []
        return f" → {_fmt_yyyymmdd(cmd[1])}" if len(cmd) > 1 else ""
    try:
        ident = re.sub(r"[^A-Za-z0-9_-]", "_", p.get("name", ""))
        with open(os.path.join(WORKERS_DIR, name, "state", f".lastrun-{ident}")) as f:
            last = int(f.read().strip())
        nxt = last + int(p.get("interval_sec") or 60)
        return " → " + datetime.datetime.fromtimestamp(nxt).strftime("%H:%M")
    except Exception:  # noqa: BLE001
        return ""


def render_probes():
    """Per-worker probe detail — ONE compact line per sensor (emoji · name · target
    · freq · next). Returns a LIST of HTML chunks (≤ Telegram limit)."""
    try:
        names = sorted(n for n in os.listdir(WORKERS_DIR)
                       if os.path.isdir(os.path.join(WORKERS_DIR, n)))
    except OSError:
        return ["📡 <b>Датчики</b>\nНе нашёл воркеров."]
    blocks = []
    for n in names:
        probes = _worker_probe_objs(n)
        if not probes:
            continue
        lines = [f"▸ <b>{esc(n)}</b> ({len(probes)})"]
        for p in probes:
            seg = [f"{_probe_emoji(p.get('source', ''))} <b>{esc(p.get('name', '?'))}</b>"]
            tgt = _probe_target(p)
            if tgt:
                seg.append(esc(tgt))
            freq = _freq_short(p.get("interval_sec"), p.get("source", ""))
            if freq:
                seg.append(freq)
            lines.append("  " + " · ".join(seg) + esc(_probe_next_suffix(n, p)))
        blocks.append("\n".join(lines))
    if not blocks:
        return ["📡 <b>Датчики</b>\nНи у одного воркера нет активных датчиков."]
    # pack worker-blocks into messages under the Telegram limit
    chunks, cur = [], "📡 <b>Датчики по воркерам</b>\n"
    for b in blocks:
        if len(cur) + len(b) + 2 > TG_LIMIT:
            chunks.append(cur.rstrip())
            cur = ""
        cur += "\n" + b + "\n"
    if cur.strip():
        chunks.append(cur.rstrip())
    return chunks


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

def make_keyboard():
    # Persistent ReplyKeyboard — кнопки всегда внизу в панели (не inline).
    return ReplyKeyboardMarkup(
        keyboard=[[KeyboardButton(text=BTN_OVERVIEW), KeyboardButton(text=BTN_PROBES)]],
        resize_keyboard=True,
        is_persistent=True,
    )


async def cmd_start(message: Message):
    if not authed_user_chat(message.from_user.id, message.chat.id):
        return
    await message.answer(
        "🤖 <b>RnR Workers</b>\n"
        "Двусторонний канал с автономными воркерами.\n\n"
        "• Воркер пришлёт вопрос с кнопками или эскалацию — нажми кнопку "
        "или <b>ответь реплаем</b>, и ответ уйдёт ему в сессию.\n"
        "• Кнопка внизу — статус всех воркеров.",
        parse_mode="HTML",
        reply_markup=make_keyboard(),
    )


async def cmd_overview_text(message: Message):
    if not authed_user_chat(message.from_user.id, message.chat.id):
        return
    text = await asyncio.to_thread(render_overview)
    try:
        await message.answer(text, parse_mode="HTML", reply_markup=make_keyboard())
    except Exception as e:  # noqa: BLE001
        log.warning("overview send failed: %s", e)
        await message.answer("Не смог отрисовать статус (см. лог).")


async def cmd_probes_text(message: Message):
    if not authed_user_chat(message.from_user.id, message.chat.id):
        return
    chunks = await asyncio.to_thread(render_probes)
    for i, ch in enumerate(chunks):
        try:
            # keyboard only on the last chunk (keeps the panel without re-spamming)
            kb = make_keyboard() if i == len(chunks) - 1 else None
            await message.answer(ch, parse_mode="HTML", reply_markup=kb)
        except Exception as e:  # noqa: BLE001
            log.warning("probes send failed: %s", e)


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
    dp.message.register(cmd_overview_text, F.text == BTN_OVERVIEW)
    dp.message.register(cmd_probes_text, F.text == BTN_PROBES)
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
