#!/bin/bash
# tests/rnr-bot-auth-blocked.test.sh — ответ оператора не должен сгорать, пока на хосте
# протух логин.
#
# deliver() считает попытку ДО вызова session-inject, а после MAX_ATTEMPTS помечает ответ
# failed. При мёртвой авторизации хоста инжект физически невозможен ни в одну сессию — и
# ответ оператора, набранный в боте, потерялся бы «за N неудачных попыток», хотя ни одной
# настоящей попытки доставки не было.
#
# Контракт: rc=4 (auth-blocked, session-inject ничего не печатал в pane) НЕ расходует попытку
# и не помечает ответ доставленным.
set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bootstrap.sh"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$DIR/bot/venv/bin/python3"
[ -x "$PY" ] || PY="python3"

"$PY" <<PYEOF
import asyncio, sys
sys.path.insert(0, "$DIR/bot")
import rnr_workers_bot as bot_mod

failures = []
def check(cond, msg):
    if not cond:
        failures.append(msg)

calls = {"attempts": 0, "delivered": 0, "failed": 0, "undo": 0}
class FakeDB:
    def record_attempt(self, qid):
        calls["attempts"] += 1
        return calls["attempts"]
    def undo_attempt(self, qid):
        calls["undo"] += 1
        calls["attempts"] -= 1
    def mark_delivered(self, qid):
        calls["delivered"] += 1
    def mark_failed(self, qid):
        calls["failed"] += 1

class FakeBot:
    def __init__(self):
        self.sent = []
    async def send_message(self, chat, text):
        self.sent.append(text)

bot_mod.rnr_db = FakeDB()
row = {"qid": 42, "tmux_target": "claude-dept-archivist", "worker": "dept-archivist",
       "answer_text": "ответ оператора", "answered_via": "text"}

# 1) auth-blocked (rc=4) — попытка не тратится, доставленным не помечаем
bot_mod.run_session_inject = lambda target, framed: 4
asyncio.run(bot_mod.deliver(FakeBot(), row))
check(calls["attempts"] == 0, f"rc=4 израсходовал попытку (attempts={calls['attempts']}) — ответ оператора сгорит за MAX_ATTEMPTS")
check(calls["undo"] == 1, "rc=4 не откатил счётчик попыток")
check(calls["delivered"] == 0, "rc=4 помечен как доставленный")
check(calls["failed"] == 0, "rc=4 помечен как проваленный")

# 2) обычный отказ (rc=1) — попытка считается, прежнее поведение не задето
bot_mod.run_session_inject = lambda target, framed: 1
asyncio.run(bot_mod.deliver(FakeBot(), row))
check(calls["attempts"] == 1, f"обычный отказ перестал считать попытку (attempts={calls['attempts']})")

# 3) успех — доставлено
bot_mod.run_session_inject = lambda target, framed: 0
asyncio.run(bot_mod.deliver(FakeBot(), row))
check(calls["delivered"] == 1, "успешная доставка не помечена")

if failures:
    for f in failures:
        print("FAIL:", f)
    sys.exit(1)
print("PASS: tests/rnr-bot-auth-blocked.test.sh")
PYEOF
