#!/usr/bin/env python3
"""rnr_db.py — durable-outbox store for the @RnR_Workers two-way bot.

ONE table `asks` is the single source of truth for worker→operator questions and
escalations AND for the operator's answer + its delivery state. It is written by
two processes (both run as `rainor`):
  * bash helpers `claude-auto-ask` / `claude-auto-tg` (INSERT the row + set the
    Telegram message_id after sending) — they call this file as a CLI;
  * the python poller `rnr_workers_bot.py` (CLAIMS the first answer atomically,
    then a delivery loop drives claimed→delivered) — it imports this file.

Security / correctness invariants (Codex plan review):
  * NO SQL is ever built from worker-controlled text — every statement uses
    sqlite3 parameter binding (this module is the ONLY writer; bash never emits SQL).
  * ONCE-ONLY is a single atomic `UPDATE ... WHERE status='open'` + rowcount check
    (no separate SELECT-then-UPDATE); the first button-press OR reply wins.
  * `busy_timeout` is set on EVERY connection (it is per-connection, not a DB
    property); WAL lets the poller read while a bash helper writes.
  * answer is marked `claimed` (durably stored) BEFORE delivery; a separate retry
    loop drives `claimed`→`delivered`, so a crash / busy worker never loses it.

Status lifecycle:  open → claimed → delivered   (terminal: failed)
"""
import argparse
import datetime
import json
import os
import sqlite3
import sys

DB_PATH = os.environ.get(
    "RNR_ASKS_DB",
    os.path.join(os.path.expanduser("~"), ".claude-control", "rnr-bot", "asks.db"),
)


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def connect():
    d = os.path.dirname(DB_PATH)
    os.makedirs(d, exist_ok=True)
    conn = sqlite3.connect(DB_PATH, timeout=5.0)
    conn.row_factory = sqlite3.Row
    # busy_timeout is PER CONNECTION — must be set every time (Codex HIGH-8).
    conn.execute("PRAGMA busy_timeout=5000")
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    _init(conn)
    try:
        os.chmod(DB_PATH, 0o600)
    except OSError:
        pass
    return conn


def _init(conn):
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS asks (
            qid             TEXT PRIMARY KEY,
            kind            TEXT NOT NULL,            -- 'ask' | 'notify'
            worker          TEXT NOT NULL,
            tmux_target     TEXT NOT NULL,            -- 'claude-<worker>'
            chat_id         INTEGER NOT NULL,
            message_id      INTEGER,                  -- set after the message is sent
            question        TEXT,
            options_json    TEXT,                     -- JSON array of visible labels
            status          TEXT NOT NULL DEFAULT 'open',  -- open|claimed|delivered|failed
            answered_via    TEXT,                     -- 'button' | 'reply'
            answer_idx      INTEGER,
            answer_text     TEXT,
            attempts        INTEGER NOT NULL DEFAULT 0,
            last_attempt_at TEXT,
            created_at      TEXT NOT NULL,
            answered_at     TEXT,
            delivered_at    TEXT
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_chat_msg
            ON asks(chat_id, message_id) WHERE message_id IS NOT NULL;
        CREATE INDEX IF NOT EXISTS idx_status ON asks(status);

        -- approvals: worker→operator requests for a BOUNDED action from a CLOSED
        -- catalog. The worker only INSERTs an 'open' row (no message_id); the bot
        -- renders the canonical card from THIS row, records message_id, claims the
        -- operator's decision once-only, then executes from the stored fields.
        CREATE TABLE IF NOT EXISTS approvals (
            qid             TEXT PRIMARY KEY,
            worker          TEXT NOT NULL,
            tmux_target     TEXT NOT NULL,            -- 'claude-<worker>'
            chat_id         INTEGER NOT NULL,
            message_id      INTEGER,                  -- set when the bot SENDS the card
            action          TEXT NOT NULL,            -- whitelist-add|whitelist-remove|one-time-send
            arg_kind        TEXT,                     -- 'tg' | 'email'
            arg_value       TEXT,                     -- chat_id / email addr (the recipient)
            payload         TEXT,                     -- one-time-send body (bound, shown + sent)
            reason          TEXT,                     -- worker's stated reason (DATA, shown labeled)
            status          TEXT NOT NULL DEFAULT 'open',  -- open|approved|sending|denied|executed|failed
            decided_via     TEXT,                     -- 'button'
            decided_at      TEXT,
            executed_at     TEXT,                     -- action performed
            notified_at     TEXT,                     -- outcome injected back to the worker (terminal)
            attempts        INTEGER NOT NULL DEFAULT 0,
            last_attempt_at TEXT,
            result          TEXT,
            created_at      TEXT NOT NULL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_appr_chat_msg
            ON approvals(chat_id, message_id) WHERE message_id IS NOT NULL;
        CREATE INDEX IF NOT EXISTS idx_appr_status ON approvals(status);
        """
    )
    conn.commit()


# ---- writers (bash CLI + poller) -------------------------------------------

def insert_ask(qid, kind, worker, tmux_target, chat_id, question, options_json):
    # Validate options_json is a JSON array of strings (defensive — bash already
    # validated, but never trust the input that crosses a process boundary).
    opts = json.loads(options_json) if options_json else []
    if not isinstance(opts, list) or not all(isinstance(x, str) for x in opts):
        raise ValueError("options_json must be a JSON array of strings")
    conn = connect()
    try:
        with conn:
            conn.execute(
                "INSERT INTO asks (qid,kind,worker,tmux_target,chat_id,question,options_json,status,created_at) "
                "VALUES (?,?,?,?,?,?,?,'open',?)",
                (qid, kind, worker, tmux_target, int(chat_id), question,
                 json.dumps(opts, ensure_ascii=False), now_iso()),
            )
    finally:
        conn.close()


def set_message_id(qid, message_id):
    conn = connect()
    try:
        with conn:
            conn.execute("UPDATE asks SET message_id=? WHERE qid=?", (int(message_id), qid))
    finally:
        conn.close()


def delete_ask(qid):
    conn = connect()
    try:
        with conn:
            conn.execute("DELETE FROM asks WHERE qid=?", (qid,))
    finally:
        conn.close()


# ---- once-only claim (atomic) ----------------------------------------------

def _claim(conn, where_sql, params, via, answer_idx, answer_text):
    """Single atomic claim. Returns the claimed row dict, or None if it was not
    'open' (already answered / not found)."""
    cur = conn.execute(
        "UPDATE asks SET status='claimed', answered_via=?, answer_idx=?, answer_text=?, answered_at=? "
        "WHERE " + where_sql + " AND status='open'",
        (via, answer_idx, answer_text, now_iso(), *params),
    )
    if cur.rowcount != 1:
        return None
    row = conn.execute(
        "SELECT * FROM asks WHERE " + where_sql + " LIMIT 1", params
    ).fetchone()
    return dict(row) if row else None


def claim_by_qid(qid, via, answer_idx=None, answer_text=None):
    conn = connect()
    try:
        with conn:
            return _claim(conn, "qid=?", (qid,), via, answer_idx, answer_text)
    finally:
        conn.close()


def claim_by_message(chat_id, message_id, via, answer_text=None):
    conn = connect()
    try:
        with conn:
            return _claim(conn, "chat_id=? AND message_id=?",
                          (int(chat_id), int(message_id)), via, None, answer_text)
    finally:
        conn.close()


# ---- reads (UX routing only — never the claim decision) ---------------------

def get_by_qid(qid):
    conn = connect()
    try:
        row = conn.execute("SELECT * FROM asks WHERE qid=?", (qid,)).fetchone()
        return dict(row) if row else None
    finally:
        conn.close()


def get_by_message(chat_id, message_id):
    conn = connect()
    try:
        row = conn.execute(
            "SELECT * FROM asks WHERE chat_id=? AND message_id=? LIMIT 1",
            (int(chat_id), int(message_id)),
        ).fetchone()
        return dict(row) if row else None
    finally:
        conn.close()


# ---- delivery outbox -------------------------------------------------------

def next_undelivered(limit=20, retry_after_sec=0):
    """Claimed-but-not-delivered rows, oldest first, whose last attempt is older
    than retry_after_sec (backoff)."""
    cutoff = (datetime.datetime.now(datetime.timezone.utc)
              - datetime.timedelta(seconds=retry_after_sec)).isoformat()
    conn = connect()
    try:
        rows = conn.execute(
            "SELECT * FROM asks WHERE status='claimed' "
            "AND (last_attempt_at IS NULL OR last_attempt_at < ?) "
            "ORDER BY answered_at ASC LIMIT ?",
            (cutoff, int(limit)),
        ).fetchall()
        return [dict(r) for r in rows]
    finally:
        conn.close()


def record_attempt(qid):
    conn = connect()
    try:
        with conn:
            conn.execute(
                "UPDATE asks SET attempts=attempts+1, last_attempt_at=? WHERE qid=?",
                (now_iso(), qid),
            )
            row = conn.execute("SELECT attempts FROM asks WHERE qid=?", (qid,)).fetchone()
            return row["attempts"] if row else 0
    finally:
        conn.close()


def mark_delivered(qid):
    conn = connect()
    try:
        with conn:
            conn.execute(
                "UPDATE asks SET status='delivered', delivered_at=? WHERE qid=?",
                (now_iso(), qid),
            )
    finally:
        conn.close()


def mark_failed(qid):
    conn = connect()
    try:
        with conn:
            conn.execute("UPDATE asks SET status='failed' WHERE qid=?", (qid,))
    finally:
        conn.close()


# ---- approvals: closed-catalog action requests -----------------------------

ALLOWED_ACTIONS = ("whitelist-add", "whitelist-remove", "one-time-send")


def insert_approval(qid, worker, tmux_target, chat_id, action,
                    arg_kind=None, arg_value=None, payload=None, reason=None):
    """Insert an 'open' approval request. The worker is the ONLY caller (via the
    claude-auto-request bash helper); the bot renders/sends the card from this row."""
    if action not in ALLOWED_ACTIONS:
        raise ValueError("action not in closed catalog: %r" % (action,))
    if arg_kind not in (None, "tg", "email"):
        raise ValueError("arg_kind must be tg|email")
    conn = connect()
    try:
        with conn:
            conn.execute(
                "INSERT INTO approvals "
                "(qid,worker,tmux_target,chat_id,action,arg_kind,arg_value,payload,reason,status,created_at) "
                "VALUES (?,?,?,?,?,?,?,?,?,'open',?)",
                (qid, worker, tmux_target, int(chat_id), action, arg_kind,
                 arg_value, payload, reason, now_iso()),
            )
    finally:
        conn.close()


def set_message_id_appr(qid, message_id):
    conn = connect()
    try:
        with conn:
            conn.execute("UPDATE approvals SET message_id=? WHERE qid=?",
                         (int(message_id), qid))
    finally:
        conn.close()


def delete_approval(qid):
    conn = connect()
    try:
        with conn:
            conn.execute("DELETE FROM approvals WHERE qid=?", (qid,))
    finally:
        conn.close()


def next_unsent(limit=10):
    """Open requests whose card was not sent yet (message_id IS NULL)."""
    conn = connect()
    try:
        rows = conn.execute(
            "SELECT * FROM approvals WHERE status='open' AND message_id IS NULL "
            "ORDER BY created_at ASC LIMIT ?", (int(limit),),
        ).fetchall()
        return [dict(r) for r in rows]
    finally:
        conn.close()


def claim_approval(qid, decision, decided_via="button"):
    """Atomic once-only decision: open → approved|denied. Returns the row or None."""
    if decision not in ("approved", "denied"):
        raise ValueError("decision must be approved|denied")
    conn = connect()
    try:
        with conn:
            cur = conn.execute(
                "UPDATE approvals SET status=?, decided_via=?, decided_at=? "
                "WHERE qid=? AND status='open'",
                (decision, decided_via, now_iso(), qid),
            )
            if cur.rowcount != 1:
                return None
            row = conn.execute("SELECT * FROM approvals WHERE qid=?", (qid,)).fetchone()
            return dict(row) if row else None
    finally:
        conn.close()


def lease_sending(qid):
    """At-most-once guard for the non-idempotent one-time-send: atomically move
    approved → sending. Returns the row if WE won the lease, else None (so a crash
    after the Telegram call leaves status='sending' and is NEVER auto-resent)."""
    conn = connect()
    try:
        with conn:
            cur = conn.execute(
                "UPDATE approvals SET status='sending', last_attempt_at=? "
                "WHERE qid=? AND status='approved'",
                (now_iso(), qid),
            )
            if cur.rowcount != 1:
                return None
            row = conn.execute("SELECT * FROM approvals WHERE qid=?", (qid,)).fetchone()
            return dict(row) if row else None
    finally:
        conn.close()


def get_appr_by_qid(qid):
    conn = connect()
    try:
        row = conn.execute("SELECT * FROM approvals WHERE qid=?", (qid,)).fetchone()
        return dict(row) if row else None
    finally:
        conn.close()


def get_appr_by_message(chat_id, message_id):
    conn = connect()
    try:
        row = conn.execute(
            "SELECT * FROM approvals WHERE chat_id=? AND message_id=? LIMIT 1",
            (int(chat_id), int(message_id)),
        ).fetchone()
        return dict(row) if row else None
    finally:
        conn.close()


def next_actionable(limit=20, retry_after_sec=0):
    """Rows the exec loop must still act on: a decision was made (or a one-time-send
    is mid-flight) but the worker hasn't been notified yet. Backoff via last_attempt_at."""
    cutoff = (datetime.datetime.now(datetime.timezone.utc)
              - datetime.timedelta(seconds=retry_after_sec)).isoformat()
    conn = connect()
    try:
        rows = conn.execute(
            "SELECT * FROM approvals WHERE notified_at IS NULL "
            "AND status IN ('approved','executed','denied','sending','failed') "
            "AND (last_attempt_at IS NULL OR last_attempt_at < ?) "
            "ORDER BY decided_at ASC LIMIT ?",
            (cutoff, int(limit)),
        ).fetchall()
        return [dict(r) for r in rows]
    finally:
        conn.close()


def record_attempt_appr(qid):
    conn = connect()
    try:
        with conn:
            conn.execute(
                "UPDATE approvals SET attempts=attempts+1, last_attempt_at=? WHERE qid=?",
                (now_iso(), qid),
            )
            row = conn.execute("SELECT attempts FROM approvals WHERE qid=?", (qid,)).fetchone()
            return row["attempts"] if row else 0
    finally:
        conn.close()


def mark_executed(qid, result=None):
    conn = connect()
    try:
        with conn:
            conn.execute(
                "UPDATE approvals SET status='executed', executed_at=?, result=? WHERE qid=?",
                (now_iso(), result, qid),
            )
    finally:
        conn.close()


def mark_exec_failed(qid, result=None):
    conn = connect()
    try:
        with conn:
            conn.execute(
                "UPDATE approvals SET status='failed', executed_at=?, result=? WHERE qid=?",
                (now_iso(), result, qid),
            )
    finally:
        conn.close()


def mark_notified(qid):
    conn = connect()
    try:
        with conn:
            conn.execute("UPDATE approvals SET notified_at=? WHERE qid=?",
                         (now_iso(), qid))
    finally:
        conn.close()


# ---- CLI (for bash helpers + tests) ----------------------------------------

def _emit(obj):
    if obj is None:
        return  # empty stdout = "no row" for bash callers
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")


def main(argv=None):
    p = argparse.ArgumentParser(prog="rnr_db.py")
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("init")

    sp = sub.add_parser("insert-ask")
    sp.add_argument("--qid", required=True)
    sp.add_argument("--kind", required=True, choices=["ask", "notify"])
    sp.add_argument("--worker", required=True)
    sp.add_argument("--tmux-target", required=True)
    sp.add_argument("--chat-id", required=True, type=int)
    sp.add_argument("--question", default="")
    sp.add_argument("--options-json", default="[]")

    sp = sub.add_parser("set-message-id")
    sp.add_argument("--qid", required=True)
    sp.add_argument("--message-id", required=True, type=int)

    sp = sub.add_parser("delete-ask")
    sp.add_argument("--qid", required=True)

    sp = sub.add_parser("claim-by-qid")
    sp.add_argument("--qid", required=True)
    sp.add_argument("--via", required=True, choices=["button", "reply"])
    sp.add_argument("--answer-idx", type=int)
    sp.add_argument("--answer-text")

    sp = sub.add_parser("claim-by-message")
    sp.add_argument("--chat-id", required=True, type=int)
    sp.add_argument("--message-id", required=True, type=int)
    sp.add_argument("--via", default="reply", choices=["button", "reply"])
    sp.add_argument("--answer-text")

    sp = sub.add_parser("get-by-qid")
    sp.add_argument("--qid", required=True)

    sp = sub.add_parser("get-by-message")
    sp.add_argument("--chat-id", required=True, type=int)
    sp.add_argument("--message-id", required=True, type=int)

    sp = sub.add_parser("next-undelivered")
    sp.add_argument("--limit", type=int, default=20)
    sp.add_argument("--retry-after-sec", type=int, default=0)

    sp = sub.add_parser("record-attempt")
    sp.add_argument("--qid", required=True)

    sp = sub.add_parser("mark-delivered")
    sp.add_argument("--qid", required=True)

    sp = sub.add_parser("mark-failed")
    sp.add_argument("--qid", required=True)

    sp = sub.add_parser("insert-approval")
    sp.add_argument("--qid", required=True)
    sp.add_argument("--worker", required=True)
    sp.add_argument("--tmux-target", required=True)
    sp.add_argument("--chat-id", required=True, type=int)
    sp.add_argument("--action", required=True, choices=list(ALLOWED_ACTIONS))
    sp.add_argument("--arg-kind", choices=["tg", "email"])
    sp.add_argument("--arg-value")
    sp.add_argument("--payload")
    sp.add_argument("--reason")

    sp = sub.add_parser("get-appr-by-qid")
    sp.add_argument("--qid", required=True)

    a = p.parse_args(argv)

    if a.cmd == "init":
        connect().close()
        return 0
    if a.cmd == "insert-ask":
        try:
            insert_ask(a.qid, a.kind, a.worker, a.tmux_target, a.chat_id,
                       a.question, a.options_json)
        except sqlite3.IntegrityError:
            return 3  # qid collision — caller should retry with a fresh qid
        return 0
    if a.cmd == "set-message-id":
        set_message_id(a.qid, a.message_id); return 0
    if a.cmd == "delete-ask":
        delete_ask(a.qid); return 0
    if a.cmd == "claim-by-qid":
        _emit(claim_by_qid(a.qid, a.via, a.answer_idx, a.answer_text)); return 0
    if a.cmd == "claim-by-message":
        _emit(claim_by_message(a.chat_id, a.message_id, a.via, a.answer_text)); return 0
    if a.cmd == "get-by-qid":
        _emit(get_by_qid(a.qid)); return 0
    if a.cmd == "get-by-message":
        _emit(get_by_message(a.chat_id, a.message_id)); return 0
    if a.cmd == "next-undelivered":
        sys.stdout.write(json.dumps(next_undelivered(a.limit, a.retry_after_sec),
                                    ensure_ascii=False) + "\n")
        return 0
    if a.cmd == "record-attempt":
        _emit({"attempts": record_attempt(a.qid)}); return 0
    if a.cmd == "mark-delivered":
        mark_delivered(a.qid); return 0
    if a.cmd == "mark-failed":
        mark_failed(a.qid); return 0
    if a.cmd == "insert-approval":
        try:
            insert_approval(a.qid, a.worker, a.tmux_target, a.chat_id, a.action,
                            a.arg_kind, a.arg_value, a.payload, a.reason)
        except sqlite3.IntegrityError:
            return 3  # qid collision — caller retries with a fresh qid
        return 0
    if a.cmd == "get-appr-by-qid":
        _emit(get_appr_by_qid(a.qid)); return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
