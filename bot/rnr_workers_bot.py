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
import hashlib
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
    ForceReply,
    InlineKeyboardButton,
    InlineKeyboardMarkup,
    KeyboardButton,
    Message,
    ReplyKeyboardMarkup,
)

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.normpath(os.path.join(HERE, "..", "bin"))
SESSION_INJECT = os.path.join(BIN, "session-inject")
CLAUDE_AUTO = os.path.join(BIN, "claude-auto")
TG_NOTIFY = "/home/rainor/server/server_monitor/telegram_notify.sh"  # absolute
CONTROL_DIR = os.environ.get("CLAUDE_CONTROL_DIR",
                             os.path.join(os.path.expanduser("~"), ".claude-control"))
WORKERS_DIR = os.path.join(CONTROL_DIR, "workers")
ENV_PATH = os.environ.get("RNR_ENV_PATH", "/home/rainor/server/.env")
BTN_OVERVIEW = "📊 Сводка"
BTN_PROBES = "📡 Датчики"          # legacy (folded into the worker card; handler kept)
BTN_ATTACH = "🔗 Терминал"         # legacy (folded into the worker card; handler kept)
BTN_WHITELIST = "🤖 Воркеры"
TG_LIMIT = 3900  # safe chunk size under Telegram's 4096

sys.path.insert(0, HERE)
import rnr_db  # noqa: E402  (stdlib-only DB helper, same dir)

# --- delivery tunables ---
POLL_SEC = 5          # delivery loop tick
INJECT_TIMEOUT = 20   # session-inject wait-for-idle per attempt (short → loop not blocked)
RETRY_AFTER = 25      # don't re-attempt a row within this many seconds (> INJECT_TIMEOUT)
ALERT_AT = 6          # attempts before a "still trying" ping (~few min)
MAX_ATTEMPTS = 160    # give up + alert (a parked worker may stay busy a while)

# --- approval flow tunables ---
APPR_POLL_SEC = 5       # card-sender + exec loop tick
APPR_MAX_ATTEMPTS = 60  # idempotent whitelist exec retries before giving up + alert

ACTION_LABEL = {
    "whitelist-add": "➕ Добавить в whitelist",
    "whitelist-remove": "🗑 Убрать из whitelist",
    "one-time-send": "✉️ Разовая отправка (Telegram)",
    "mcp-add": "🧩 Подключить MCP-сервер",
}

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


# Auto-collected Telegram contact book (rainor-ai-business). Lets us show a human
# name next to a bare chat_id. Read on demand (small file, infrequent renders).
_CONTACTS_PATH = "/home/rainor/server/services/rainor_ai_business/contacts.json"


def _load_contacts():
    try:
        with open(_CONTACTS_PATH, encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except Exception:  # noqa: BLE001
        return {}


def _tg_name(chat_id, contacts=None):
    """Human label for a Telegram id ('Имя Фамилия (@user)' / '@user' / ''), from the
    contact book. Empty when unknown — caller falls back to the raw id."""
    c = contacts if contacts is not None else _load_contacts()
    rec = c.get(str(chat_id))
    if not isinstance(rec, dict):
        return ""
    name = ((rec.get("first_name") or "").strip() + " "
            + (rec.get("last_name") or "").strip()).strip()
    un = (rec.get("username") or "").strip()
    if name and un:
        return f"{name} (@{un})"
    return name or (f"@{un}" if un else "")


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


def _live_ctx_from_transcript(name):
    """Recompute the worker's CURRENT context from the tail of its transcript — the
    last NON-ZERO model-request usage (input + cache_read + cache_creation), the same
    formula claude-auto-heartbeat uses. Returns int tokens, or None if it can't be
    derived (no/unreadable transcript, no real turn in the window). Live read avoids
    the stale-snapshot effect where context.json freezes on a wake/compact turn until
    the worker's next Stop hook fires. Caller already runs this off the event loop."""
    try:
        with open(os.path.join(WORKERS_DIR, name, "state", "last_seen.json")) as f:
            tpath = (json.load(f).get("transcript_path") or "")
    except Exception:  # noqa: BLE001
        return None
    if not tpath or not os.path.isfile(tpath):
        return None
    try:
        with open(tpath, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            window = min(size, 2_000_000)  # tail window — comfortably holds recent turns
            f.seek(size - window)
            lines = f.read().decode("utf-8", "replace").splitlines()
        if window < size and lines:
            lines = lines[1:]  # drop the partial first line
        last = 0
        for ln in lines[-600:]:
            if '"assistant"' not in ln:
                continue
            try:
                obj = json.loads(ln)
            except Exception:  # noqa: BLE001
                continue
            if obj.get("type") != "assistant":
                continue
            u = (obj.get("message") or {}).get("usage") or {}
            s = (int(u.get("input_tokens") or 0)
                 + int(u.get("cache_read_input_tokens") or 0)
                 + int(u.get("cache_creation_input_tokens") or 0))
            if s > 0:
                last = s
        return last or None
    except Exception:  # noqa: BLE001
        return None


def _worker_ctx(name):
    """(ctx_tokens, threshold). Prefer a LIVE recompute from the transcript so the
    number reflects reality immediately; fall back to the context.json snapshot (which
    only refreshes on the worker's Stop hook), then to defaults."""
    snap, thr = 0, 900000
    try:
        with open(os.path.join(WORKERS_DIR, name, "state", "context.json")) as f:
            d = json.load(f)
        snap = int(d.get("ctx_tokens") or 0)
        thr = int(d.get("threshold") or 900000)
    except Exception:  # noqa: BLE001
        pass
    live = _live_ctx_from_transcript(name)
    return (live if live is not None else snap), thr


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
        + "\n<i>ctx — контекст из 900k · загр — загрузка% · дат — датчиков · ! ≥90%</i>"
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
        keyboard=[
            [KeyboardButton(text=BTN_OVERVIEW), KeyboardButton(text=BTN_WHITELIST)],
        ],
        resize_keyboard=True,
        is_persistent=True,
    )


def render_attach():
    """Per-worker tmux attach command — tap a <code> line to copy the exact command,
    no need to remember the session name. Run it in a terminal on ai-dev-1."""
    try:
        names = sorted(n for n in os.listdir(WORKERS_DIR)
                       if os.path.isdir(os.path.join(WORKERS_DIR, n)))
    except OSError:
        return "🔗 <b>Терминал</b>\nНе нашёл воркеров."
    lines = ["🔗 <b>Подключиться к сессии</b> (терминал на ai-dev-1) — тапни команду, чтобы скопировать:", ""]
    for n in names:
        lines.append(f"<b>{esc(n)}</b>")
        lines.append(f"<code>tmux attach -t claude-{esc(n)}</code>")
    lines += ["", "<i>выйти из сессии: Ctrl-b, затем d</i>"]
    return "\n".join(lines)


async def cmd_start(message: Message):
    if not authed_user_chat(message.from_user.id, message.chat.id):
        return
    await message.answer(
        "🤖 <b>RnR Workers</b>\n"
        "Двусторонний канал с автономными воркерами.\n\n"
        "• Воркер пришлёт вопрос с кнопками или эскалацию — нажми кнопку "
        "или <b>ответь реплаем</b>, и ответ уйдёт ему в сессию.\n"
        "• Воркер может запросить одобрение (whitelist / разовая отправка) — "
        "придёт карточка с ✅/❌.\n"
        "• Кнопки внизу: <b>📊 Сводка</b> (флот одним взглядом) и "
        "<b>🤖 Воркеры</b> (карточка по каждому: статус, контекст, датчики, доступы, терминал).",
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


async def cmd_attach_text(message: Message):
    if not authed_user_chat(message.from_user.id, message.chat.id):
        return
    text = await asyncio.to_thread(render_attach)
    try:
        await message.answer(text, parse_mode="HTML", reply_markup=make_keyboard())
    except Exception as e:  # noqa: BLE001
        log.warning("attach send failed: %s", e)


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
    # ➕ whitelist-add: trigger ONLY if this is a reply to a ForceReply prompt WE sent
    # (tracked by message_id in _WL_ADD_PENDING). NOT by a tag in text — worker-authored
    # ask/question text could otherwise forge the tag and hijack the operator's reply.
    wl_worker = _WL_ADD_PENDING.pop(rt.message_id, None)
    if wl_worker:
        if not _valid_worker(wl_worker):
            await message.reply("❌ Воркер не найден.")
            return
        entry = _normalize_entry(message.text or "")  # bare email / tg id OR prefixed
        if not entry:
            _wl_pending_put(rt.message_id, wl_worker)  # let the operator retry the reply
            await message.reply("❌ Не похоже на email или Telegram id. Пришли ещё раз — "
                                "например <code>vasya@alp-itsm.ru</code> или <code>12345</code>.",
                                parse_mode="HTML")
            return
        rc, out = await asyncio.to_thread(_run_allow, "add", wl_worker, entry)
        if rc == 0:
            # ForceReply (the prompt above) hides the persistent bottom panel; re-send it
            # on the confirmation so it comes back without needing /start. The card that
            # follows carries an INLINE kb, which doesn't touch the reply keyboard slot.
            await message.reply(f"✅ Добавил «{esc(wl_worker)}»: <code>{esc(entry)}</code>",
                                parse_mode="HTML", reply_markup=make_keyboard())
            text, kb = await asyncio.to_thread(wl_worker_view, wl_worker)
            await message.answer(text, parse_mode="HTML", reply_markup=kb)
        else:
            await message.reply(f"❌ Не добавил: {esc(out)}", reply_markup=make_keyboard())
        return

    # 📊 set-probe-limit: reply to a ForceReply prompt WE sent (matched by message_id).
    # Consumes the reply and ALWAYS returns — a limit reply must never fall through into
    # normal answer delivery to the worker below.
    limit_worker = _WL_LIMIT_PENDING.pop(rt.message_id, None)
    if limit_worker:
        if not _valid_worker(limit_worker):
            await message.reply("❌ Воркер не найден.")
            return
        raw = (message.text or "").strip()
        try:
            n = int(raw)
        except ValueError:
            n = -1
        if n < 1 or n > _PROBE_LIMIT_CEILING:
            _wl_limit_pending_put(rt.message_id, limit_worker)  # let the operator retry
            await message.reply(f"❌ Нужно число от 1 до {_PROBE_LIMIT_CEILING}. "
                                f"Пришли ещё раз — например <code>10</code>.",
                                parse_mode="HTML")
            return
        rc, out = await asyncio.to_thread(_run_set_limit, limit_worker, n)
        if rc == 0:
            # Restore the persistent bottom panel that ForceReply hid (see add branch).
            await message.reply(f"✅ Лимит датчиков «{esc(limit_worker)}» → <b>{n}</b>",
                                parse_mode="HTML", reply_markup=make_keyboard())
            text, kb = await asyncio.to_thread(wl_worker_view, limit_worker)
            await message.answer(text, parse_mode="HTML", reply_markup=kb)
        else:
            await message.reply(f"❌ Не установил: {esc(out)}", reply_markup=make_keyboard())
        return

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


# ============================ approval flow =================================
# Worker REQUESTS a bounded action from a closed catalog (via claude-auto-request,
# which only INSERTs an 'open' approvals row). The bot renders the CANONICAL card
# from that row, claims the operator's decision once-only, then EXECUTES the action
# itself from the stored fields. The worker never mutates the whitelist or sends.

# Strip control chars AND Unicode bidi/zero-width overrides so the card the operator
# reviews can't be visually spoofed (recipient/body shown verbatim).
_BIDI_RE = re.compile("[​-‏‪-‮⁦-⁩؜﻿]")


def _clean(s):
    return _BIDI_RE.sub("", re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f]", "", s or ""))


def render_approval(row):
    """Canonical approval card — built ONLY from the stored row, so what the operator
    sees is exactly what the executor will run (anti-forge)."""
    worker = esc(_clean(row["worker"]))
    action = row["action"]
    label = ACTION_LABEL.get(action, action)
    lines = [
        f"🔐 <b>Запрос одобрения · воркер «{worker}»</b>",
        "━━━━━━━━━━━━━━",
        f"<b>{esc(label)}</b>",
    ]
    if action in ("whitelist-add", "whitelist-remove"):
        kind = "Telegram" if row.get("arg_kind") == "tg" else "Email"
        val = _clean(str(row.get("arg_value")))
        nm = _tg_name(val) if row.get("arg_kind") == "tg" else ""
        lines.append(f"Контакт: <code>{esc(val)}</code>  · {kind}" + (f" · {esc(nm)}" if nm else ""))
    elif action == "one-time-send":
        val = _clean(str(row.get("arg_value")))
        nm = _tg_name(val)
        lines.append(f"Кому (Telegram): <code>{esc(val)}</code>" + (f" · {esc(nm)}" if nm else ""))
        lines.append("Текст сообщения:")
        lines.append(f"<blockquote>{esc(_clean(row.get('payload') or ''))}</blockquote>")
    elif action == "mcp-add":
        srv = _clean(str(row.get("arg_value")))
        lines.append(f"MCP-сервер: <code>{esc(srv)}</code>")
    if row.get("reason"):
        lines.append(f"\n💬 <i>Причина (со слов воркера): {esc(_clean(row['reason']))}</i>")
    if action == "mcp-add":
        lines.append("\n<i>Это добавит MCP-сервер в набор воркера и перезапустит его. Реши.</i>")
    else:
        lines.append("\n<i>Это меняет права/отправку. Проверь контакт и реши.</i>")
    return "\n".join(lines)


def approval_kb(qid, action=None):
    # mcp-add gets action-specific labels ("Добавить + рестарт"); others use generic ✅/❌.
    yes = "➕ Добавить + рестарт" if action == "mcp-add" else "✅ Одобрить"
    no = "✖ Отклонить" if action == "mcp-add" else "❌ Отклонить"
    return InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(text=yes, callback_data=f"appr:{qid}:1"),
        InlineKeyboardButton(text=no, callback_data=f"appr:{qid}:0"),
    ]])


def exec_whitelist(row):
    """Run the idempotent whitelist mutation as the bot (argv, shell=False). Returns
    (ok, detail). Safe to retry (claude-auto allow dedups)."""
    verb = "add" if row["action"] == "whitelist-add" else "remove"
    entry = f"{row['arg_kind']}:{row['arg_value']}"
    try:
        p = subprocess.run([CLAUDE_AUTO, "allow", verb, row["worker"], entry],
                           capture_output=True, timeout=30)
        out = (p.stdout or b"").decode("utf-8", "replace").strip() \
            or (p.stderr or b"").decode("utf-8", "replace").strip()
        return p.returncode == 0, out[:300]
    except Exception as e:  # noqa: BLE001
        return False, f"exec error: {e}"


def exec_one_time_tg(row):
    """Send ONE Telegram message as the operator. Caller MUST have won lease_sending
    first (approved→sending) — this is NOT retried (at-most-once)."""
    try:
        # Send the SAME cleaned payload the operator saw on the card (render_approval
        # also _clean's it) — so "what was reviewed == what is sent" (anti-forge for
        # bidi/zero-width chars, which the ASCII-only strip in the helper leaves in).
        body = _clean(row.get("payload") or "")
        p = subprocess.run(
            [TG_NOTIFY, "--as-me", "--chat-id", str(row["arg_value"]), "--", body],
            capture_output=True, timeout=40)
        out = (p.stdout or b"").decode("utf-8", "replace").strip() \
            or (p.stderr or b"").decode("utf-8", "replace").strip()
        return p.returncode == 0, out[:300]
    except Exception as e:  # noqa: BLE001
        return False, f"send error: {e}"


def exec_mcp_add(row):
    """Add an MCP server to the worker's subscription, then restart it so the new set loads.
    Both via claude-auto (argv, shell=False; idempotent — safe to retry; claude-auto
    re-validates the name against the catalog). Returns (ok, detail):
      - mcp-add failed                  → (False, …) → retried, then alerted
      - restart errored (rc!=0)         → (False, …) → server added but NOT loaded → retried
      - restart DEFERRED (worker busy)  → (True, 'pending') → add persisted; set applies on the
                                          next launch; the worker is told it's not active yet
      - restart ok                      → (True, 'restarted') → server live
    The detail is surfaced verbatim to the worker (see notify_worker_outcome)."""
    worker, server = row["worker"], (row.get("arg_value") or "")
    try:
        p = subprocess.run([CLAUDE_AUTO, "mcp-add", worker, server],
                           capture_output=True, timeout=30)
        if p.returncode != 0:
            err = (p.stderr or b"").decode("utf-8", "replace").strip() \
                or (p.stdout or b"").decode("utf-8", "replace").strip()
            return False, f"mcp-add не удался: {err[:200]}"
        r = subprocess.run([CLAUDE_AUTO, "restart", worker], capture_output=True, timeout=90)
        rout = (r.stdout or b"").decode("utf-8", "replace").strip() \
            or (r.stderr or b"").decode("utf-8", "replace").strip()
        if r.returncode != 0:
            # add persisted, but the restart errored → the server is NOT loaded → retry/alert.
            return False, f"сервер '{server}' добавлен в подписку, но рестарт НЕ удался: {rout[:160]}"
        if "DEFERRED" in rout or "занят" in rout.lower():
            return True, (f"сервер '{server}' добавлен; воркер был занят — рестарт отложен, "
                          "сервер активируется при следующем перезапуске (пока недоступен)")
        return True, f"сервер '{server}' подключён, воркер перезапущен"
    except Exception as e:  # noqa: BLE001
        return False, f"exec error: {e}"


async def cb_approval(cb: CallbackQuery):
    chat_id = cb.message.chat.id if cb.message else 0
    if not authed_user_chat(cb.from_user.id, chat_id):
        await cb.answer("нет доступа", show_alert=True)
        return
    parts = (cb.data or "").split(":")
    if len(parts) != 3 or parts[2] not in ("0", "1"):
        await cb.answer("битый запрос", show_alert=True)
        return
    qid, sdec = parts[1], parts[2]
    row = rnr_db.get_appr_by_qid(qid)
    if not row:
        await cb.answer("запрос не найден", show_alert=True)
        return
    # Privileged action ⇒ STRICTER binding than asks: exact chat_id AND message_id
    # must match (fail-closed if message_id was never recorded).
    if (row["chat_id"] != chat_id or not row["message_id"] or not cb.message
            or row["message_id"] != cb.message.message_id):
        await cb.answer("несовпадение сообщения", show_alert=True)
        return
    decision = "approved" if sdec == "1" else "denied"
    claimed = rnr_db.claim_approval(qid, decision, "button")
    if not claimed:
        try:
            await cb.message.edit_reply_markup(reply_markup=None)
        except Exception:  # noqa: BLE001
            pass
        await cb.answer("уже решено ранее", show_alert=True)
        return
    tag = "✅ Одобрено" if decision == "approved" else "❌ Отклонено"
    await cb.answer(tag)
    try:
        new = (cb.message.html_text or "") + f"\n\n{tag}"
        await cb.message.edit_text(new, parse_mode="HTML", reply_markup=None)
    except Exception:  # noqa: BLE001
        try:
            await cb.message.edit_reply_markup(reply_markup=None)
        except Exception:  # noqa: BLE001
            pass
    # approval_exec_loop executes (if approved) + notifies the worker.


async def notify_worker_outcome(bot: Bot, row, approved, ok, detail):
    """Inject the decision outcome into the worker session; mark notified only on a
    successful inject (else it is retried by the loop — notified_at stays NULL)."""
    qid = row["qid"]
    human = ACTION_LABEL.get(row["action"], row["action"])
    argd = f" ({row.get('arg_kind')}:{row.get('arg_value')})" if row.get("arg_value") else ""
    if not approved:
        body = f"Оператор ОТКЛОНИЛ запрос: {human}{argd}. Не повторяй; действуй иначе или эскалируй."
    elif ok:
        # mcp-add: surface the exact state (restarted / restart-deferred) — a deferred restart
        # means the server is added but NOT loaded yet, so the worker must NOT assume it's live.
        if row["action"] == "mcp-add" and detail:
            body = f"Оператор ОДОБРИЛ: {human}{argd}. {detail}."
        else:
            body = f"Оператор ОДОБРИЛ, выполнено: {human}{argd}. Можешь продолжать."
    else:
        body = f"Оператор одобрил, но выполнить НЕ удалось: {detail}. Не повторяй сам; эскалируй оператору."
    msg = f"[ответ оператора на твой запрос (#{qid})]\n{body}"
    rc = await asyncio.to_thread(run_session_inject, row["tmux_target"], msg)
    if rc == 0:
        rnr_db.mark_notified(qid)
        log.info("approval outcome delivered #%s → %s (approved=%s ok=%s)",
                 qid, row["worker"], approved, ok)


async def process_approval(bot: Bot, row):
    qid, worker, status, action = row["qid"], row["worker"], row["status"], row["action"]
    attempts = rnr_db.record_attempt_appr(qid)

    if status == "denied":
        await notify_worker_outcome(bot, row, approved=False, ok=None, detail="")
        return

    # one-time-send crashed mid-send (lease set, no terminal write) → at-most-once:
    # NEVER resend. Mark failed-uncertain, alert operator, tell the worker it's unknown.
    if status == "sending":
        rnr_db.mark_exec_failed(qid, "uncertain: crashed mid-send, NOT resent")
        await alert_operator(
            bot, f"⚠️ Разовая отправка воркера «{worker}» (#{qid}) прервалась в момент "
                 f"отправки — НЕ повторяю автоматически. Проверь вручную, ушло ли сообщение.")
        await notify_worker_outcome(bot, row, approved=True, ok=False,
                                    detail="отправка прервалась, исход НЕИЗВЕСТЕН")
        return

    if status == "approved":
        if action in ("whitelist-add", "whitelist-remove"):
            ok, detail = await asyncio.to_thread(exec_whitelist, row)
            if ok:
                rnr_db.mark_executed(qid, detail)
                await notify_worker_outcome(bot, row, approved=True, ok=True, detail=detail)
            elif attempts >= APPR_MAX_ATTEMPTS:
                rnr_db.mark_exec_failed(qid, detail)
                await alert_operator(
                    bot, f"❌ Не смог выполнить «{action}» для «{worker}» (#{qid}) за "
                         f"{attempts} попыток: {detail}")
            # else: leave 'approved' → backoff retry (idempotent)
            return
        if action == "mcp-add":
            ok, detail = await asyncio.to_thread(exec_mcp_add, row)
            if ok:
                rnr_db.mark_executed(qid, detail)
                await notify_worker_outcome(bot, row, approved=True, ok=True, detail=detail)
            elif attempts >= APPR_MAX_ATTEMPTS:
                rnr_db.mark_exec_failed(qid, detail)
                await alert_operator(
                    bot, f"❌ Не смог подключить MCP-сервер для «{worker}» (#{qid}) за "
                         f"{attempts} попыток: {detail}")
            # else: leave 'approved' → backoff retry (idempotent)
            return
        if action == "one-time-send":
            leased = await asyncio.to_thread(rnr_db.lease_sending, qid)
            if not leased:
                return  # lost the lease (concurrent / already moved) — skip
            ok, detail = await asyncio.to_thread(exec_one_time_tg, leased)
            if ok:
                rnr_db.mark_executed(qid, detail)
                await notify_worker_outcome(bot, leased, approved=True, ok=True, detail=detail)
            else:
                rnr_db.mark_exec_failed(qid, detail)  # at-most-once: do NOT retry a send
                await alert_operator(
                    bot, f"⚠️ Разовая отправка воркера «{worker}» (#{qid}) не удалась: "
                         f"{detail}. НЕ повторяю автоматически.")
                await notify_worker_outcome(bot, leased, approved=True, ok=False, detail=detail)
            return

    # executed/failed but worker not yet notified (crash between exec and notify) → notify
    if status in ("executed", "failed"):
        await notify_worker_outcome(bot, row, approved=True, ok=(status == "executed"),
                                    detail=row.get("result") or "")


async def card_sender_loop(bot: Bot):
    """Render + send the canonical card for each new 'open' request, then record its
    message_id. The card is built by the BOT (not the worker helper) — single source."""
    log.info("approval card-sender loop started")
    while True:
        try:
            for row in rnr_db.next_unsent(limit=10):
                if row["chat_id"] != OPERATOR:
                    # forged/corrupt chat_id (legit rows always carry OPERATOR from .env):
                    # DELETE it (a sentinel message_id would collide with the partial
                    # UNIQUE(chat_id,message_id) on repeats and poison the loop).
                    rnr_db.delete_approval(row["qid"])
                    log.warning("approval row %s chat_id!=OPERATOR — deleted", row["qid"])
                    continue
                try:
                    m = await bot.send_message(OPERATOR, render_approval(row),
                                               parse_mode="HTML",
                                               reply_markup=approval_kb(row["qid"], row["action"]))
                    rnr_db.set_message_id_appr(row["qid"], m.message_id)
                    log.info("approval card sent qid=%s worker=%s action=%s",
                             row["qid"], row["worker"], row["action"])
                except Exception as e:  # noqa: BLE001
                    log.warning("approval card send failed qid=%s: %s", row["qid"], e)
        except Exception as e:  # noqa: BLE001
            log.exception("card_sender_loop error: %s", e)
        await asyncio.sleep(APPR_POLL_SEC)


async def approval_exec_loop(bot: Bot):
    log.info("approval exec loop started")
    while True:
        try:
            for row in rnr_db.next_actionable(limit=20, retry_after_sec=RETRY_AFTER):
                await process_approval(bot, row)
        except Exception as e:  # noqa: BLE001
            log.exception("approval_exec_loop error: %s", e)
        await asyncio.sleep(APPR_POLL_SEC)


_ENTRY_TG = re.compile(r"tg:-?\d+$")
_ENTRY_EMAIL = re.compile(r"email:[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$")
_BARE_TG = re.compile(r"-?\d+$")
_BARE_EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$")


def _normalize_entry(s):
    """Accept a bare email / bare Telegram id (the natural thing to paste) OR the
    explicit tg:/email: form → return a validated `kind:value`, or None."""
    s = (s or "").strip()
    if s.startswith("tg:") or s.startswith("email:"):
        cand = s
    elif _BARE_TG.fullmatch(s):
        cand = "tg:" + s
    elif _BARE_EMAIL.fullmatch(s):
        cand = "email:" + s.lower()
    else:
        return None
    return cand if (_ENTRY_TG.fullmatch(cand) or _ENTRY_EMAIL.fullmatch(cand)) else None


async def cmd_allow(message: Message):
    """Operator-only whitelist management from the phone. Strict parser (exact arity,
    single line, validated tokens) → subprocess claude-auto allow (shell=False)."""
    if not authed_user_chat(message.from_user.id, message.chat.id):
        return
    raw = (message.text or "").strip()
    if "\n" in raw:
        await message.reply("❌ Одна строка: /allow list|add|remove <воркер> [tg:<id>|email:<addr>]")
        return
    parts = raw.split()
    parts[0] = parts[0].split("@")[0]  # tolerate /allow@bot
    if len(parts) < 3:
        await message.reply("Использование: /allow list|add|remove <воркер> [tg:<id>|email:<addr>]")
        return
    action, worker = parts[1], parts[2]
    if action not in ("list", "add", "remove"):
        await message.reply("❌ Действие: list | add | remove")
        return
    if not re.fullmatch(r"[A-Za-z0-9_-]+", worker):
        await message.reply("❌ Имя воркера: только [A-Za-z0-9_-]")
        return
    cmd = [CLAUDE_AUTO, "allow", action, worker]
    if action == "list":
        if len(parts) != 3:
            await message.reply("❌ list не принимает доп. аргументы")
            return
    else:
        if len(parts) != 4:
            await message.reply("❌ Нужна ровно одна запись: tg:<id> | email:<addr>")
            return
        entry = parts[3]
        if not (_ENTRY_TG.fullmatch(entry) or _ENTRY_EMAIL.fullmatch(entry)):
            await message.reply("❌ Запись: tg:<число> | email:<addr@dom.tld>")
            return
        cmd.append(entry)
    try:
        p = await asyncio.to_thread(
            lambda: subprocess.run(cmd, capture_output=True, timeout=15))
        out = (p.stdout or b"").decode("utf-8", "replace").strip() \
            or (p.stderr or b"").decode("utf-8", "replace").strip() or "(пусто)"
        await message.reply(f"<pre>{esc(out[:3500])}</pre>", parse_mode="HTML")
    except Exception as e:  # noqa: BLE001
        await message.reply(f"❌ Ошибка: {esc(str(e))}")


# ===================== whitelist management UI (buttons) ====================
# Operator manages each worker's people-allow entirely by TAPPING: pick a worker,
# see its whitelist, 🗑 to remove an entry, ➕ to add (which asks for the contact via
# one ForceReply — the only thing a button can't carry is a brand-new address/id).
# Every callback is operator-authed; the worker name is validated + must exist; the
# entry is validated; execution is the same idempotent `claude-auto allow`.

# message_id → worker for pending ➕ ForceReply prompts (in-memory; lost on restart,
# which just means the operator re-taps ➕). Keyed by the bot's own prompt message_id
# so a worker cannot forge the trigger via text.
_WL_ADD_PENDING = {}


def _wl_pending_put(mid, worker):
    if len(_WL_ADD_PENDING) > 100:
        _WL_ADD_PENDING.clear()  # crude cap — these are short-lived
    _WL_ADD_PENDING[mid] = worker


# 📊 set-probe-limit pending ForceReply prompts. Same shape & anti-forge rationale as
# _WL_ADD_PENDING: keyed by the bot's own prompt message_id so a worker cannot trigger
# a limit change via text.
_WL_LIMIT_PENDING = {}


def _wl_limit_pending_put(mid, worker):
    if len(_WL_LIMIT_PENDING) > 100:
        _WL_LIMIT_PENDING.clear()  # crude cap — short-lived
    _WL_LIMIT_PENDING[mid] = worker


# Worker-name charset AND length bound — kept in sync with `claude-auto adopt`
# (which enforces the same 40-char cap), so the bot never hides a legitimately
# created worker. The cap also keeps every callback_data (longest is
# "wl:rmc:<worker>:<idx>:<token>" ≈ worker+19) safely under Telegram's 64-byte
# limit, and filters odd dir names out of the inline buttons.
_WORKER_RE = re.compile(r"[A-Za-z0-9_-]{1,40}")


def _list_workers():
    try:
        return sorted(n for n in os.listdir(WORKERS_DIR)
                      if _WORKER_RE.fullmatch(n)
                      and os.path.isdir(os.path.join(WORKERS_DIR, n)))
    except OSError:
        return []


def _valid_worker(w):
    return bool(w) and bool(_WORKER_RE.fullmatch(w)) \
        and os.path.isdir(os.path.join(WORKERS_DIR, w))


def _read_allow_entries(worker):
    """Parsed people-allow as [(kind, value)], kind ∈ {tg,email}."""
    entries = []
    try:
        with open(os.path.join(WORKERS_DIR, worker, "people-allow")) as f:
            for ln in f:
                ln = ln.strip()
                if not ln or ln.startswith("#"):
                    continue
                p = ln.split()
                if len(p) >= 2 and p[0] in ("tg", "email"):
                    entries.append((p[0], p[1]))
    except OSError:
        pass
    return entries


def _run_allow(action, worker, entry=None):
    cmd = [CLAUDE_AUTO, "allow", action, worker]
    if entry:
        cmd.append(entry)
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=15)
        out = (p.stdout or b"").decode("utf-8", "replace").strip() \
            or (p.stderr or b"").decode("utf-8", "replace").strip()
        return p.returncode, out[:300]
    except Exception as e:  # noqa: BLE001
        return 99, str(e)


def _run_set_limit(worker, n):
    """Set the worker's self-service probe ceiling via claude-auto (shell=False argv;
    claude-auto validates worker, range, and writes spec.json atomically under the
    shared lock). Returns (returncode, short_output)."""
    try:
        p = subprocess.run([CLAUDE_AUTO, "set-probe-limit", worker, str(n)],
                           capture_output=True, timeout=15)
        out = (p.stdout or b"").decode("utf-8", "replace").strip() \
            or (p.stderr or b"").decode("utf-8", "replace").strip()
        return p.returncode, out[:300]
    except Exception as e:  # noqa: BLE001
        return 99, str(e)


def _run_lifecycle(action, worker):
    """stop|start a worker via claude-auto. Idempotent and registry-aware
    (stop → state=stopped so the reconciler won't wake it; start → state=active).
    systemctl can be slower than `allow` → wider timeout. Returns (rc, short_out)."""
    try:
        p = subprocess.run([CLAUDE_AUTO, action, worker], capture_output=True, timeout=30)
        out = (p.stdout or b"").decode("utf-8", "replace").strip() \
            or (p.stderr or b"").decode("utf-8", "replace").strip()
        return p.returncode, out[:300]
    except Exception as e:  # noqa: BLE001
        return 99, str(e)


def _run_mcp(*args):
    """Run a claude-auto MCP/lifecycle subcommand (get-mcp/set-mcp/mcp-add/mcp-rm/
    mcp-reset/restart) as the operator (argv, shell=False; claude-auto validates names
    against the catalog + writes spec.json atomically under the shared lock). Wider
    timeout because `restart` drives systemctl. Returns (returncode, short_output)."""
    try:
        p = subprocess.run([CLAUDE_AUTO, *args], capture_output=True, timeout=60)
        out = (p.stdout or b"").decode("utf-8", "replace").strip() \
            or (p.stderr or b"").decode("utf-8", "replace").strip()
        return p.returncode, out
    except Exception as e:  # noqa: BLE001
        return 99, str(e)


def _worker_mcp(worker):
    """The worker's MCP view via `claude-auto get-mcp`: {subscribed, catalog, missing}
    (subscribed is None when the worker inherits ALL). Returns the dict, or None on error."""
    rc, out = _run_mcp("get-mcp", worker)
    if rc != 0:
        return None
    try:
        return json.loads(out)
    except Exception:  # noqa: BLE001
        return None


def _mcp_token(name):
    """12-char fingerprint of an MCP server name, embedded in the toggle callback so a
    stale button (catalog changed since render) resolves safely (never toggles the wrong
    server). Wider than the 8-char whitelist token — extra headroom under the 64B limit."""
    return hashlib.sha1(f"mcp:{name}".encode("utf-8")).hexdigest()[:12]


def _confirm_kb(yes_cb, yes_label, back_cb):
    """Two-button confirm row: [<yes_label> → yes_cb] [↩️ Отмена → back_cb]."""
    return InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(text=yes_label, callback_data=yes_cb),
        InlineKeyboardButton(text="↩️ Отмена", callback_data=back_cb),
    ]])


def _entry_token(kind, val):
    """Short fingerprint of a whitelist entry — embedded in the 🗑 callback so a stale
    button (list changed since render) can't delete a different entry by index."""
    return hashlib.sha1(f"{kind}:{val}".encode("utf-8")).hexdigest()[:8]


async def _safe_edit(message, text, kb):
    """edit_text that ignores Telegram's benign 'message is not modified' but logs
    real failures (so a length-blowup doesn't silently leave a stale card).
    Returns True if the card now shows the intended content (edited OR already
    identical), False on a real failure so the caller can surface a fallback."""
    try:
        await message.edit_text(text, parse_mode="HTML", reply_markup=kb)
        return True
    except Exception as e:  # noqa: BLE001
        if "not modified" in str(e).lower():
            return True
        log.warning("whitelist card edit failed: %s", e)
        return False


def wl_workers_kb():
    """Worker picker: one button per worker prefixed with 🟢/🔴 by unit state, plus a
    stats header (active/stopped counts). Returns (header_text, kb). Blocking
    (systemctl is-active per worker) → callers run it via asyncio.to_thread.
    The 🟢/🔴 lives only in the button TEXT — callback_data stays `wl:w:<worker>`."""
    workers = _list_workers()
    states = {w: _worker_active(w) for w in workers}
    rows, pair = [], []
    for w in workers:
        dot = "🟢" if states[w] else "🔴"
        pair.append(InlineKeyboardButton(text=f"{dot} {w}", callback_data=f"wl:w:{w}"))
        if len(pair) == 2:
            rows.append(pair)
            pair = []
    if pair:
        rows.append(pair)
    if not rows:
        return ("🤖 <b>Воркеры</b>\nНе нашёл воркеров.",
                InlineKeyboardMarkup(inline_keyboard=[[InlineKeyboardButton(
                    text="(нет воркеров)", callback_data="wl:list")]]))
    active = sum(1 for v in states.values() if v)
    header = (f"🤖 <b>Воркеры</b> · 🟢 {active} актив. · 🔴 {len(workers) - active} остановл.\n"
              "Выбери воркера:")
    return header, InlineKeyboardMarkup(inline_keyboard=rows)


def _worker_cwd(name):
    """Worker's working directory (where it runs / its deal repo). spec.json is the
    canonical source (set at adopt); fall back to last_seen.json (heartbeat)."""
    for rel in ("spec.json", "state/last_seen.json"):
        try:
            with open(os.path.join(WORKERS_DIR, name, rel)) as f:
                cwd = (json.load(f).get("cwd") or "").strip()
            if cwd:
                return cwd
        except Exception:  # noqa: BLE001
            continue
    return ""


# Default self-service probe ceiling — kept in sync with claude-auto-self-probes
# MAX_PROBES_DEFAULT and the claude-auto set-probe-limit hard ceiling.
_PROBE_LIMIT_DEFAULT = 20
_PROBE_LIMIT_CEILING = 100


def _worker_max_probes(name):
    """Worker's self-service probe ceiling from spec.json `.max_probes`. Same clamp as
    the consumer: an int in 1..100, else the default — so a corrupted/out-of-range value
    is shown as the default rather than as a real (over-cap) limit."""
    try:
        with open(os.path.join(WORKERS_DIR, name, "spec.json")) as f:
            v = json.load(f).get("max_probes")
        if isinstance(v, int) and not isinstance(v, bool) \
                and 1 <= v <= _PROBE_LIMIT_CEILING:
            return v
    except Exception:  # noqa: BLE001
        pass
    return _PROBE_LIMIT_DEFAULT


def _worker_mcp_summary(worker):
    """Cheap MCP-subscription summary for the card button — spec.json only, no catalog
    read (the hot card path). Mirrors the launch tri-state: 'все' (absent/null → inherit
    all), 'N' (explicit subscription of N), '⚠' (malformed → launch fails closed)."""
    try:
        with open(os.path.join(WORKERS_DIR, worker, "spec.json")) as f:
            v = json.load(f).get("mcp_servers")
    except Exception:  # noqa: BLE001
        return "все"
    if v is None:
        return "все"
    if isinstance(v, list):
        return str(len([x for x in v if isinstance(x, str)]))
    return "⚠"


def wl_mcp_view(worker, mcp):
    """MCP-server submenu for a worker. `mcp` is the parsed `claude-auto get-mcp` dict
    ({subscribed, catalog, missing}; subscribed=None ⇒ inherits ALL). Returns (text, kb).
    Each catalog server is a toggle (✓ on / ○ off); ⚠️ rows are subscribed-but-vanished
    (tap to drop). Changes need a restart to take effect (button below)."""
    subscribed = mcp.get("subscribed")          # list | None
    catalog = mcp.get("catalog") or []
    missing = mcp.get("missing") or []
    inherit = subscribed is None
    sub_set = set(subscribed or [])

    lines = [f"🧩 <b>MCP-серверы</b> · «{esc(worker)}»"]
    if inherit:
        lines.append("Сейчас <b>наследует ВСЕ</b> серверы каталога (подписки нет). "
                     "Первое изменение зафиксирует явный набор — дальше воркер поднимает "
                     "только отмеченные ✓.")
    else:
        lines.append(f"Подписан на <b>{len(sub_set)}</b> из {len(catalog)} · "
                     "🟢 вкл · 🔴 выкл" + (" · ⚠️ исчез из каталога" if missing else ""))
    lines.append("<i>⚙️ stdio — поднимает процесс (память); 🌐 http/sse — почти бесплатно.</i>")
    lines.append("━━━━━━━━━━━━━━")
    for c in catalog:
        nm = str(c.get("name", "?"))
        on = inherit or (nm in sub_set)
        kind = "⚙️ stdio" if c.get("stdio") else "🌐 http"
        lines.append(f"{'🟢' if on else '🔴'} <b>{esc(nm)}</b> · {kind}")
    for m in missing:
        lines.append(f"⚠️ <b>{esc(str(m))}</b> · подписан, нет в каталоге")
    lines.append("━━━━━━━━━━━━━━")
    lines.append("⚠️ Изменения применяются после <b>перезапуска</b>.")

    rows = []
    for c in catalog:
        nm = str(c.get("name", "?"))
        on = inherit or (nm in sub_set)
        kind = "⚙️" if c.get("stdio") else "🌐"
        rows.append([InlineKeyboardButton(
            text=f"{'🟢' if on else '🔴'} {kind} {nm}"[:60],
            callback_data=f"wl:mtog:{worker}:{_mcp_token(nm)}")])
    for m in missing:
        rows.append([InlineKeyboardButton(
            text=f"⚠️🗑 {m}"[:60], callback_data=f"wl:mtog:{worker}:{_mcp_token(str(m))}")])
    if not inherit:
        rows.append([InlineKeyboardButton(text="↩️ Сбросить (наследовать все)",
                                          callback_data=f"wl:mrst:{worker}")])
    rows.append([InlineKeyboardButton(text="🔄 Перезапустить сейчас",
                                      callback_data=f"wl:mres:{worker}")])
    rows.append([InlineKeyboardButton(text="🔄 Обновить", callback_data=f"wl:mcp:{worker}"),
                 InlineKeyboardButton(text="⬅️ К воркеру", callback_data=f"wl:w:{worker}")])
    text = "\n".join(lines)
    if len(text) > TG_LIMIT:
        text = text[:TG_LIMIT - 1].rstrip() + "\n…"
    return text, InlineKeyboardMarkup(inline_keyboard=rows)


def wl_worker_view(worker):
    """Rich per-worker panel (one card): status + session + sensors + whitelist
    (each contact a 🗑 button) + ➕ add + terminal attach. Blocking (systemctl + file
    reads) → callers run it via asyncio.to_thread."""
    active = _worker_active(worker)
    ctx, thr = _worker_ctx(worker)
    pct = round(ctx / thr * 100) if thr else 0
    entries = _read_allow_entries(worker)
    contacts = _load_contacts()
    probes = _worker_probe_objs(worker)
    limit = _worker_max_probes(worker)
    mcp_sum = _worker_mcp_summary(worker)

    lines = [f"🤖 <b>{esc(worker)}</b>  {'🟢 активен' if active else '🔴 остановлен'}"]
    lines.append(f"🧠 Контекст <b>{round(ctx / 1000)}k</b> / {round(thr / 1000)}k · "
                 f"загрузка <b>{pct}%</b>" + (" ⚠️" if pct >= 90 else ""))
    cwd = _worker_cwd(worker)
    if cwd:
        lines.append(f"📁 <code>{esc(cwd)}</code>")
    lines.append("━━━━━━━━━━━━━━")
    # sensors (per-worker, reusing the probe formatters)
    if probes:
        lines.append(f"📡 <b>Датчики · {len(probes)}</b> · лимит самообслуживания <b>{limit}</b>")
        for p in probes:
            pname = str(p.get("name", "?"))[:48]  # cap worker-set name (anti-blowup)
            seg = [f"{_probe_emoji(p.get('source', ''))} <b>{esc(pname)}</b>"]
            tgt = _probe_target(p)
            if tgt:
                seg.append(esc(tgt))
            freq = _freq_short(p.get("interval_sec"), p.get("source", ""))
            if freq:
                seg.append(freq)
            lines.append("  " + " · ".join(seg) + esc(_probe_next_suffix(worker, p)))
    else:
        lines.append(f"📡 <i>датчиков нет</i> · лимит самообслуживания <b>{limit}</b>")
    lines.append("━━━━━━━━━━━━━━")
    # whitelist
    lines.append("🔐 <b>Доступы</b> — кому пишет без твоего аппрува:")
    if entries:
        for kind, val in entries:
            if kind == "tg":
                nm = _tg_name(val, contacts)
                lines.append(f"💬 <code>{esc(val)}</code>" + (f" — {esc(nm)}" if nm else ""))
            else:
                lines.append(f"📧 <code>{esc(val)}</code>")
        lines.append("<i>🗑 убрать · ➕ добавить</i>")
    else:
        lines.append("<i>пусто</i> · ➕ чтобы добавить")
    lines.append("━━━━━━━━━━━━━━")
    lines.append("🧩 <b>MCP</b>: " + ("наследует все" if mcp_sum == "все"
                 else "подписка повреждена ⚠️" if mcp_sum == "⚠"
                 else f"подписка на {mcp_sum} серв."))
    lines.append(f"\n🔗 <code>tmux attach -t claude-{esc(worker)}</code>")

    rows = []
    for i, (kind, val) in enumerate(entries):
        disp = (_tg_name(val, contacts) or val) if kind == "tg" else val
        short = disp if len(disp) <= 24 else disp[:22] + "…"
        rows.append([InlineKeyboardButton(
            text=f"🗑 {'💬' if kind == 'tg' else '📧'} {short}",
            callback_data=f"wl:rm:{worker}:{i}:{_entry_token(kind, val)}")])
    rows.append([InlineKeyboardButton(text="➕ Добавить контакт", callback_data=f"wl:add:{worker}")])
    # lifecycle: one state-aware button (sleep needs confirm, wake is immediate)
    if active:
        rows.append([InlineKeyboardButton(text="⏸️ Усыпить", callback_data=f"wl:stop:{worker}")])
    else:
        rows.append([InlineKeyboardButton(text="▶️ Разбудить", callback_data=f"wl:start:{worker}")])
    rows.append([InlineKeyboardButton(text=f"📊 Лимит датчиков ({limit})",
                                      callback_data=f"wl:limit:{worker}")])
    rows.append([InlineKeyboardButton(text=f"🧩 MCP-серверы ({mcp_sum})",
                                      callback_data=f"wl:mcp:{worker}")])
    rows.append([InlineKeyboardButton(text="🔄 Обновить", callback_data=f"wl:w:{worker}"),
                 InlineKeyboardButton(text="⬅️ К воркерам", callback_data="wl:list")])
    text = "\n".join(lines)
    if len(text) > TG_LIMIT:  # hard cap so a bloated card never fails edit_text
        text = text[:TG_LIMIT - 1].rstrip() + "\n…"
    return text, InlineKeyboardMarkup(inline_keyboard=rows)


async def cmd_whitelist_text(message: Message):
    if not authed_user_chat(message.from_user.id, message.chat.id):
        return
    text, kb = await asyncio.to_thread(wl_workers_kb)
    await message.answer(text, parse_mode="HTML", reply_markup=kb)


async def cb_wl(cb: CallbackQuery):
    chat_id = cb.message.chat.id if cb.message else 0
    if not authed_user_chat(cb.from_user.id, chat_id):
        await cb.answer("нет доступа", show_alert=True)
        return
    parts = (cb.data or "").split(":")
    sub = parts[1] if len(parts) > 1 else ""

    # Strict arity: reject unknown subs AND trailing junk (hardens the protocol so
    # only well-formed operator callbacks act). worker is at parts[2] (when present).
    arity = {"list": 2, "w": 3, "add": 3, "start": 3, "stop": 3,
             "stopc": 3, "limit": 3, "rm": 5, "rmc": 5,
             "mcp": 3, "mtog": 4, "mrst": 3, "mres": 3}
    if arity.get(sub) != len(parts):
        await cb.answer("неизвестная команда", show_alert=True)
        return

    if sub == "list":
        text, kb = await asyncio.to_thread(wl_workers_kb)
        await _safe_edit(cb.message, text, kb)
        await cb.answer()
        return

    worker = parts[2]
    if not _valid_worker(worker):
        await cb.answer("воркер не найден", show_alert=True)
        return

    if sub == "w":
        text, kb = await asyncio.to_thread(wl_worker_view, worker)
        await _safe_edit(cb.message, text, kb)
        await cb.answer()
        return

    # ---- lifecycle: start (immediate, harmless) / stop (confirm → stopc) ----
    if sub == "start":
        await cb.answer("бужу…")  # answer first — the subprocess may outlast the 15s callback TTL
        rc, out = await asyncio.to_thread(_run_lifecycle, "start", worker)
        text, kb = await asyncio.to_thread(wl_worker_view, worker)
        await _safe_edit(cb.message, text, kb)  # card reflects the REAL state (is-active)
        if rc != 0:
            await cb.message.answer(
                f"❌ Не удалось разбудить «{esc(worker)}»: <code>{esc(out)}</code>",
                parse_mode="HTML")
        return

    if sub == "stop":
        # confirm step — stop interrupts the worker's current turn (context is kept).
        # Ack the callback FIRST (instant, within the TTL), THEN edit the card.
        await cb.answer()
        ok = await _safe_edit(
            cb.message,
            f"⏸️ Усыпить воркера «<b>{esc(worker)}</b>»?\n"
            f"Текущая работа прервётся, но весь контекст сделки сохранится — "
            f"разбудишь, и он продолжит с того же места.",
            _confirm_kb(f"wl:stopc:{worker}", "⏸️ Усыпить", f"wl:w:{worker}"))
        if not ok:
            await cb.message.answer("⚠️ Не смог показать подтверждение — открой карточку воркера заново.")
        return

    if sub == "stopc":
        await cb.answer("усыпляю…")
        rc, out = await asyncio.to_thread(_run_lifecycle, "stop", worker)
        text, kb = await asyncio.to_thread(wl_worker_view, worker)
        await _safe_edit(cb.message, text, kb)
        if rc != 0:
            await cb.message.answer(
                f"❌ Не удалось усыпить «{esc(worker)}»: <code>{esc(out)}</code>",
                parse_mode="HTML")
        return

    # ---- whitelist removal: rm (confirm) → rmc (execute) -------------------
    if sub in ("rm", "rmc"):
        try:
            idx = int(parts[3])
        except ValueError:
            await cb.answer("битый индекс", show_alert=True)
            return
        token = parts[4]
        entries = await asyncio.to_thread(_read_allow_entries, worker)
        # stale-button guard, checked on BOTH confirm and execute: index AND content
        # fingerprint must still match, else the list changed → refresh, don't act.
        if idx < 0 or idx >= len(entries) or _entry_token(*entries[idx]) != token:
            await cb.answer("список изменился — обновил", show_alert=True)
            text, kb = await asyncio.to_thread(wl_worker_view, worker)
            await _safe_edit(cb.message, text, kb)
            return
        kind, val = entries[idx]
        if sub == "rm":
            await cb.answer()  # ack first, then edit
            contacts = await asyncio.to_thread(_load_contacts)
            nm = _tg_name(val, contacts) if kind == "tg" else ""
            ok = await _safe_edit(
                cb.message,
                f"🗑 Убрать из доступов «<b>{esc(worker)}</b>»?\n"
                f"{'💬' if kind == 'tg' else '📧'} <code>{esc(val)}</code>"
                + (f" — {esc(nm)}" if nm else "")
                + "\nПосле этого воркер не сможет писать этому контакту без твоего аппрува.",
                _confirm_kb(f"wl:rmc:{worker}:{idx}:{token}", "🗑 Убрать", f"wl:w:{worker}"))
            if not ok:
                await cb.message.answer("⚠️ Не смог показать подтверждение — открой карточку воркера заново.")
            return
        # sub == "rmc" — execute the removal
        await cb.answer("убираю…")
        rc, _out = await asyncio.to_thread(_run_allow, "remove", worker, f"{kind}:{val}")
        text, kb = await asyncio.to_thread(wl_worker_view, worker)
        await _safe_edit(cb.message, text, kb)
        if rc != 0:
            await cb.message.answer(
                f"❌ Не удалось убрать <code>{esc(val)}</code> у «{esc(worker)}»",
                parse_mode="HTML")
        return

    if sub == "add":
        # ForceReply: the operator replies with just the contact (no command to memorize).
        # We remember THIS prompt's message_id → worker so the reply is matched by id,
        # not by any worker-authored text tag (anti-hijack).
        m = await cb.message.answer(
            f"➕ Контакт для «{esc(worker)}» — ответь РЕПЛАЕМ на это сообщение.\n"
            f"Просто пришли email или Telegram id (префикс не нужен):\n"
            f"<code>vasya@alp-itsm.ru</code>  или  <code>12345</code>",
            parse_mode="HTML", reply_markup=ForceReply(selective=False))
        _wl_pending_put(m.message_id, worker)
        await cb.answer()
        return

    if sub == "limit":
        # ForceReply: operator replies with just a number. Matched back by the bot
        # prompt's message_id (anti-hijack), same as ➕ add.
        cur = await asyncio.to_thread(_worker_max_probes, worker)
        m = await cb.message.answer(
            f"📊 Лимит датчиков для «{esc(worker)}» — ответь РЕПЛАЕМ на это сообщение.\n"
            f"Сейчас <b>{cur}</b>. Пришли число от 1 до {_PROBE_LIMIT_CEILING} "
            f"(сколько датчиков воркер навесит на себя сам):",
            parse_mode="HTML", reply_markup=ForceReply(selective=False))
        _wl_limit_pending_put(m.message_id, worker)
        await cb.answer()
        return

    # ---- MCP servers: open menu (mcp) / toggle (mtog) / reset (mrst) / restart (mres) ----
    if sub == "mcp":
        mcp = await asyncio.to_thread(_worker_mcp, worker)
        if mcp is None:
            await cb.answer("не смог прочитать MCP-набор", show_alert=True)
            return
        text, kb = wl_mcp_view(worker, mcp)
        await _safe_edit(cb.message, text, kb)
        await cb.answer()
        return

    if sub == "mtog":
        token = parts[3]
        mcp = await asyncio.to_thread(_worker_mcp, worker)
        if mcp is None:
            await cb.answer("не смог прочитать MCP-набор", show_alert=True)
            return
        subscribed = mcp.get("subscribed")
        catalog = mcp.get("catalog") or []
        missing = mcp.get("missing") or []
        names = [str(c.get("name")) for c in catalog] + [str(m) for m in missing]
        target = next((n for n in names if _mcp_token(n) == token), None)
        if not target:  # catalog changed since render → re-resolve, don't act on a stale button
            await cb.answer("каталог изменился — обновил", show_alert=True)
            text, kb = wl_mcp_view(worker, mcp)
            await _safe_edit(cb.message, text, kb)
            return
        if subscribed is None:
            # inherit-all: every server is ON → toggling materializes an explicit set = rest
            rest = [str(c.get("name")) for c in catalog if str(c.get("name")) != target]
            rc, out = await asyncio.to_thread(_run_mcp, "set-mcp", worker, *rest)
            verb = "выключен"
        elif target in set(subscribed):
            rc, out = await asyncio.to_thread(_run_mcp, "mcp-rm", worker, target)
            verb = "выключен"
        else:
            rc, out = await asyncio.to_thread(_run_mcp, "mcp-add", worker, target)
            verb = "включён"
        await cb.answer(f"ошибка: {out[:180]}" if rc != 0
                        else f"{target}: {verb} · перезапусти для применения", show_alert=(rc != 0))
        mcp = await asyncio.to_thread(_worker_mcp, worker)
        if mcp is not None:
            text, kb = wl_mcp_view(worker, mcp)
            await _safe_edit(cb.message, text, kb)
        return

    if sub == "mrst":
        rc, out = await asyncio.to_thread(_run_mcp, "mcp-reset", worker)
        await cb.answer(f"ошибка: {out[:180]}" if rc != 0
                        else "сброшено — наследует все · перезапусти", show_alert=(rc != 0))
        mcp = await asyncio.to_thread(_worker_mcp, worker)
        if mcp is not None:
            text, kb = wl_mcp_view(worker, mcp)
            await _safe_edit(cb.message, text, kb)
        return

    if sub == "mres":
        await cb.answer("перезапускаю…")  # restart drives systemctl → may outlast the 15s TTL
        rc, out = await asyncio.to_thread(_run_mcp, "restart", worker)
        text, kb = await asyncio.to_thread(wl_worker_view, worker)
        await _safe_edit(cb.message, text, kb)
        if rc != 0:
            await cb.message.answer(
                f"❌ Рестарт «{esc(worker)}»: <code>{esc(out)}</code>", parse_mode="HTML")
        elif "DEFERRED" in out or "занят" in out.lower():
            await cb.message.answer(
                f"⏸️ «<b>{esc(worker)}</b>» сейчас занят — рестарт отложен. Новый MCP-набор "
                "применится при следующем перезапуске (или нажми ещё раз, когда освободится).",
                parse_mode="HTML")
        return

    await cb.answer()


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
    dp.message.register(cmd_attach_text, F.text == BTN_ATTACH)
    dp.message.register(cmd_whitelist_text, F.text == BTN_WHITELIST)
    dp.message.register(cmd_allow, Command("allow"))
    dp.callback_query.register(cb_ask, F.data.startswith("ask:"))
    dp.callback_query.register(cb_approval, F.data.startswith("appr:"))
    dp.callback_query.register(cb_wl, F.data.startswith("wl:"))
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
    asyncio.create_task(card_sender_loop(bot))
    asyncio.create_task(approval_exec_loop(bot))

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
