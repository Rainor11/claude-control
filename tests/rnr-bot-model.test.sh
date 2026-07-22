#!/bin/bash
# tests/rnr-bot-model.test.sh — подэкран выбора модели воркера (фича «смена модели из
# бота»): wl_model_view рендерит кнопки ИЗ каталога get-model (текущая помечена, дефолт
# отдельной кнопкой-сентинелом, «Перезапустить сейчас» переиспользует wl:mres), враждебные
# имена из ручных spec.json/models.json экранируются (parse_mode=HTML) и капятся, каталог
# ограничен потолком кнопок; _model_token — стабильный отпечаток (stale-кнопка не выберет
# чужую модель); _worker_model различает строку / null (дефолт) / повреждённый тип.
set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bootstrap.sh"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$DIR/bot/venv/bin/python3"
[ -x "$PY" ] || PY="python3"

"$PY" <<PYEOF
import json, os, sys
sys.path.insert(0, "$DIR/bot")
import rnr_workers_bot as bot_mod

failures = []
def check(cond, msg):
    if not cond:
        failures.append(msg)

def btns(kb):
    return [b for row in kb.inline_keyboard for b in row]

W = "wtest"

# ---- wl_model_view: обычный случай — текущая помечена, дефолт-кнопка, рестарт = wl:mres ----
info = {"model": "opus", "default": "opus[1m]", "available": ["opus[1m]", "opus", "sonnet"]}
text, kb = bot_mod.wl_model_view(W, info)
bs = btns(kb)
cur = [b for b in bs if b.text.startswith("🟢") and "opus" in b.text and "⭐" not in b.text]
check(len(cur) == 1 and cur[0].text == "🟢 opus", "текущая модель не помечена ровно одной 🟢-кнопкой")
check(cur[0].callback_data == f"wl:mset:{W}:{bot_mod._model_token('opus')}",
      "callback выбранной модели не sha1-токен")
check(any(b.callback_data == f"wl:mset:{W}:default" and b.text.startswith("⚪") for b in bs),
      "нет кнопки-сентинела «По умолчанию» (⚪ при явной модели)")
check(any(b.callback_data == f"wl:mres:{W}" for b in bs),
      "нет «Перезапустить сейчас» → wl:mres (обязан переиспользовать общий обработчик)")
check(any(b.callback_data == f"wl:model:{W}" for b in bs), "нет кнопки «Обновить»")
check(any(b.callback_data == f"wl:w:{W}" for b in bs), "нет возврата к воркеру")
check(all(len(b.callback_data.encode()) <= 64 for b in bs), "callback_data >64 байт")
check("opus" in text and "перезапуск" in text.lower(), "текст без текущей модели/пометки о рестарте")

# ---- дефолт: model=null → помечена дефолт-кнопка, модельные кнопки ⚪ ----
text, kb = bot_mod.wl_model_view(W, {"model": None, "default": "opus[1m]",
                                     "available": ["opus", "sonnet"]})
bs = btns(kb)
check(any(b.callback_data == f"wl:mset:{W}:default" and b.text.startswith("🟢") for b in bs),
      "model=null: дефолт-кнопка не помечена 🟢")
check(all(b.text.startswith("⚪") for b in bs if b.callback_data.startswith(f"wl:mset:{W}:")
          and not b.callback_data.endswith(":default")),
      "model=null: модельная кнопка ложно помечена")
check("по умолчанию" in text.lower(), "model=null: в тексте нет «по умолчанию»")

# ---- враждебное имя: экранирование HTML + токен вместо имени в callback ----
evil = "<b>приве&т</b>"
text, kb = bot_mod.wl_model_view(W, {"model": evil, "default": "opus[1m]", "available": [evil]})
check("<b>приве" not in text, "враждебное имя модели попало в HTML неэкранированным")
check("&lt;b&gt;" in text, "esc() не применён к имени модели")
check(all(evil not in b.callback_data for b in btns(kb)), "сырое имя модели в callback_data")

# ---- текущая вне каталога: предупреждение в тексте, БЕЗ кнопки (set-model её отвергнет) ----
text, kb = bot_mod.wl_model_view(W, {"model": "legacy-x", "default": "opus[1m]",
                                     "available": ["opus"]})
check("нет в каталоге" in text, "текущая-вне-каталога не помечена в тексте")
check(all(b.callback_data != f"wl:mset:{W}:{bot_mod._model_token('legacy-x')}" for b in btns(kb)),
      "для модели вне каталога нарисована set-кнопка (упадёт об валидацию CLI)")

# ---- потолок кнопок: раздутый каталог не взрывает клавиатуру ----
big = [f"m{i}" for i in range(100)]
text, kb = bot_mod.wl_model_view(W, {"model": None, "default": "opus[1m]", "available": big})
model_btns = [b for b in btns(kb) if b.callback_data.startswith(f"wl:mset:{W}:")
              and not b.callback_data.endswith(":default")]
check(len(model_btns) == bot_mod._MODEL_BTN_CAP, "потолок кнопок каталога не применён")
check("первые" in text, "обрезка каталога не показана в тексте")

# ---- текущая модель ЗА потолком кнопок — не считается «выпавшей из каталога» ----
text, kb = bot_mod.wl_model_view(W, {"model": "m50", "default": "opus[1m]", "available": big})
check("нет в каталоге" not in text,
      "модель за потолком кнопок ложно объявлена выпавшей из models.json")

# ---- пустой каталог: подсказка про models.json, дефолт-кнопка есть ----
text, kb = bot_mod.wl_model_view(W, {"model": None, "default": "opus[1m]", "available": []})
check("models.json" in text, "пустой каталог без подсказки про models.json")
check(any(b.callback_data == f"wl:mset:{W}:default" for b in btns(kb)),
      "пустой каталог: пропала дефолт-кнопка")

# ---- повреждённый .model (не строка): предупреждение, не «по умолчанию» ----
text, kb = bot_mod.wl_model_view(W, {"model": {"x": 1}, "default": "opus[1m]",
                                     "available": ["opus"]})
check("повреждён" in text, "повреждённый .model не помечен")
check(not any(b.callback_data == f"wl:mset:{W}:default" and b.text.startswith("🟢")
              for b in btns(kb)), "повреждённый .model выдан за дефолт")

# ---- _model_token: стабилен, различает имена, 12 hex ----
t1, t2 = bot_mod._model_token("opus"), bot_mod._model_token("opus[1m]")
check(t1 != t2 and t1 == bot_mod._model_token("opus") and len(t1) == 12
      and all(c in "0123456789abcdef" for c in t1), "_model_token нестабилен/не 12-hex")
check(t1 != "default" and t2 != "default", "токен пересёкся с сентинелом default")

# ---- _worker_model: строка / null=дефолт / мусорный тип / нет файла ----
wd = os.path.join(bot_mod.WORKERS_DIR, "mspec")
os.makedirs(wd, exist_ok=True)
for val, want in [("opus", "opus"), (None, None), ("", None), (42, "⚠"), ([1], "⚠")]:
    with open(os.path.join(wd, "spec.json"), "w") as f:
        json.dump({"session_id": "s", "model": val}, f)
    got = bot_mod._worker_model("mspec")
    check(got == want, f"_worker_model({val!r}) → {got!r}, ожидалось {want!r}")
check(bot_mod._worker_model("no-such-worker") is None, "нет spec.json → обязан быть None (дефолт)")

# ---- обработчик wl:mset (cb_wl): default-сентинел, валидный токен, stale-токен ----
import asyncio

class _FakeChat:
    id = 1

class _FakeMsg:
    chat = _FakeChat()
    def __init__(self):
        self.edits = []
    async def edit_text(self, text, parse_mode=None, reply_markup=None):
        self.edits.append(text)
    async def answer(self, text, parse_mode=None):
        pass

class _FakeUser:
    id = 1

class _FakeCb:
    def __init__(self, data):
        self.data = data
        self.message = _FakeMsg()
        self.from_user = _FakeUser()
        self.answers = []
    async def answer(self, text=None, show_alert=False):
        self.answers.append((text or "", show_alert))

os.makedirs(os.path.join(bot_mod.WORKERS_DIR, "w1"), exist_ok=True)  # _valid_worker: dir must exist
INFO = {"model": "opus", "default": "opus[1m]", "available": ["opus", "sonnet"]}
calls = []
bot_mod.authed_user_chat = lambda uid, chat: True
bot_mod._worker_model_info = lambda w: dict(INFO)
bot_mod._run_mcp = lambda *a: (calls.append(a), (0, "ok"))[1]

# валидный токен → set-model с РАЗРЕШЁННЫМ именем (не токеном)
cb = _FakeCb(f"wl:mset:w1:{bot_mod._model_token('sonnet')}")
asyncio.run(bot_mod.cb_wl(cb))
check(("set-model", "w1", "sonnet") in calls, "mset не вызвал set-model с резолвнутым именем")
check(cb.message.edits, "mset не перерисовал подэкран после записи")

# default-сентинел → set-model --default
calls.clear()
cb = _FakeCb("wl:mset:w1:default")
asyncio.run(bot_mod.cb_wl(cb))
check(("set-model", "w1", "--default") in calls, "сентинел default не привёл к set-model --default")

# stale-токен (модели уже нет в каталоге) → БЕЗ set-model, ре-рендер + alert
calls.clear()
cb = _FakeCb(f"wl:mset:w1:{bot_mod._model_token('vanished')}")
asyncio.run(bot_mod.cb_wl(cb))
check(not any(a[0] == "set-model" for a in calls), "stale-токен привёл к записи модели")
check(any("измен" in (t or "") for t, _ in cb.answers), "stale-токен без alert-объяснения")
check(cb.message.edits, "stale-токен не перерисовал подэкран")

if failures:
    print("FAIL rnr-bot-model:")
    for m in failures:
        print(" -", m)
    sys.exit(1)
print("PASS rnr-bot-model")
PYEOF
