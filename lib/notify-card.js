#!/usr/bin/env node
// lib/notify-card.js — зеркало lib/notify-card.sh для node-компонентов claude-control
// (bin/dept-dispatcher, bin/claude-auto-liveness, bin/dept-rebase-check). Полное описание
// «зачем» и границы ответственности — в шапке .sh-версии; здесь только то, что специфично
// для node.
//
// ОБА рендера обязаны давать ПОБАЙТОВО одинаковую карточку из одинаковых входов — иначе
// оператор получает два разных визуальных языка в зависимости от того, на чём написан
// сторож. Совпадение проверяется тестом (tests/notify-card.test.sh сверяет вывод .sh и .js
// на общем наборе фикстур), а не на честном слове.
//
// КОНТРАКТ ВОЗВРАТА. send() отдаёт {ok, out}, а не голый boolean, — вызывающим вроде
// claude-auto-tg нужен out для разбора message_id. Нынешние сторожа используют .ok, и это
// ровно их сегодняшний контракт: у liveness и dispatcher булев результат доставки НЕСУЩИЙ
// (эпизод помечается «уведомлён» только по факту доставки), поэтому подменять его на
// «всегда true» нельзя.
'use strict';
const { execFileSync } = require('child_process');
const fs = require('fs');

const BUDGET = Number(process.env.NC_BUDGET) > 0 ? Number(process.env.NC_BUDGET) : 3500;
const DIVIDER = '━━━━━━━━━━━━━━';
const WRAP = Number(process.env.NC_WRAP) > 0 ? Number(process.env.NC_WRAP) : 58;
// Дефолт — литерал: telegram_notify.sh грузит именно этот файл жёстко (его строки 29-47),
// проверять токен в другом файле бессмысленно — возьмут всё равно отсюда. Переопределение
// безопасно и нужно тестам: результат проверки — только ВЫБОР БОТА (имя из allowlist
// нотификатора либо ничего), сам токен сюда не попадает и подменён быть не может. Разбор
// «почему это не шов T8» — в шапке .sh-зеркала.
const ENV_FILE = process.env.NC_ENV_FILE || '/home/rainor/server/.env';
// Ошибка РАЗМЕТКИ возвращается API мгновенно, поэтому её ретрай дёшев. Транспортный сбой
// telegram_notify.sh отрабатывает сам (direct 10с + vpn 15с + ssl-retry 15с ≈ 42с) — второй
// такой прогон вылез бы за таймаут. Отсюда запас: 60с на вызов, а не 45с как было.
const TIMEOUT_MS = 60_000;

const esc = (s) => String(s == null ? '' : s)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

// Зеркальный порядок: & последним, иначе "&amp;lt;" схлопнется в "<" вместо "&lt;".
const unesc = (s) => String(s == null ? '' : s)
  .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');

// Снять теги библиотеки И раскодировать сущности: наивный стриппер оставил бы "&lt;" видимым.
const plain = (html) => unesc(String(html == null ? '' : html).replace(/<\/?(?:b|i|code)>/g, ''));

const isMarkupError = (out) => {
  const s = String(out == null ? '' : out);
  return s.includes("can't parse entities") || s.includes('"error_code":400');
};

// Отказ АВТОРИЗАЦИИ бота (отозванный токен, бот заблокирован) — единственный класс, где
// осмысленно перепробовать ДРУГИМ ботом. При транспортном сбое второй бот пойдёт через ту же
// сеть и тот же telegram_notify.sh (~42с): фолбэк удвоил бы задержку, ничего не починив.
const isAuthError = (out) => {
  const s = String(out == null ? '' : out);
  return s.includes('"error_code":401') || s.includes('"error_code":403')
    || s.includes('Unauthorized') || s.includes('Forbidden') || s.includes('bot was blocked');
};

// Имя env-переменной с токеном @RnR_Workers, если он валиден; иначе null (уйдём дефолтным
// ботом). Сломанный токен — не повод молчать: доставка важнее отсутствия шапки «🖥️ Сервер».
function botTokenEnv() {
  try {
    const line = fs.readFileSync(ENV_FILE, 'utf8').split('\n')
      .find((l) => l.startsWith('RNR_WORKERS_BOT_TOKEN='));
    if (!line) return null;
    const val = line.slice('RNR_WORKERS_BOT_TOKEN='.length).replace(/^["' ]+|["' ]+$/g, '');
    return /^[0-9]+:[A-Za-z0-9_-]+$/.test(val) ? 'RNR_WORKERS_BOT_TOKEN' : null;
  } catch { return null; }
}

// Список токенов → « · »-строки с отступом и переносом. cap>0 сворачивает хвост в «… (ещё N)».
function wrapItems(items, cap) {
  const toks = (Array.isArray(items) ? items : String(items == null ? '' : items).split(/\s+/))
    .map((t) => String(t)).filter(Boolean);
  const shown = cap > 0 && toks.length > cap ? cap : toks.length;
  const lines = [];
  let line = '';
  for (let i = 0; i < shown; i++) {
    const e = esc(toks[i]);
    if (!line) line = e;
    // Ширина — в КОДОВЫХ ТОЧКАХ ([...line].length), а НЕ в UTF-16 (.length): bash-зеркало
    // меряет ${#line}, то есть кодовые точки, и на списке эмодзи рендеры расходились —
    // паритет, который обещает шапка файла, ломался.
    else if ([...line].length >= WRAP) { lines.push(`   ${line}`); line = e; }
    else line = `${line} · ${e}`;
  }
  if (line) lines.push(`   ${line}`);
  let out = lines.join('\n');
  if (shown < toks.length) out += ` · … (ещё ${toks.length - shown})`;
  return out;
}

// Обрезка по UTF-16 units без разрыва суррогатной пары («…» сам стоит 1 unit).
function truncU16(str, lim) {
  str = String(str == null ? '' : str);
  if (str.length <= lim) return str;
  let n = Math.max(0, lim - 1);
  const c = str.charCodeAt(n - 1);
  if (n > 0 && c >= 0xD800 && c <= 0xDBFF) n -= 1;   // не рвём пару пополам
  return str.slice(0, n) + '…';
}

// scap (0 = без капа) режет ДЛИННЫЕ ОДИНОЧНЫЕ значения — текст секции-блока и цитату. Без
// него лестница вытеснения умела ужимать только списки, и карточка с одним огромным блоком
// проваливалась в аварийную обрезку готового HTML.
function renderParts(spec, cap, withQuote, withFields, scap) {
  const parts = [];
  let head = '';
  if (Array.isArray(spec.head) && spec.head.length) {
    const [emoji, title, sub] = spec.head;
    head = `${esc(emoji)} <b>${esc(title)}</b>${sub ? ` · ${esc(sub)}` : ''}\n${DIVIDER}`;
  }
  // Блок фактов клеится к шапке одним переводом строки: разделитель уже отбил шапку, вторая
  // пустая строка подряд разорвала бы то, что читается как единое «кто и что».
  if (withFields) {
    const fields = (spec.fields || [])
      .filter(([k, v]) => k && v != null && String(v) !== '')
      .map(([k, v]) => `${esc(k)} — <b>${esc(v)}</b>`);
    if (fields.length) head = head ? `${head}\n${fields.join('\n')}` : fields.join('\n');
  }
  if (head) parts.push(head);

  for (const s of spec.sections || []) {
    if (!s) continue;
    const body = s.text != null
      ? (String(s.text).trim()
          ? `   <code>${esc(scap > 0 ? truncU16(s.text, scap) : s.text)}</code>` : '')
      : wrapItems(s.items, cap);
    if (!body.trim()) continue;   // пустая секция не печатается вовсе
    parts.push(`${esc(s.emoji)} <b>${esc(s.title)}</b>\n${body}`);
  }
  if (withQuote && spec.quote && String(spec.quote).trim()) {
    parts.push(`💬 <i>${esc(scap > 0 ? truncU16(spec.quote, scap) : spec.quote)}</i>`);
  }
  if (spec.note && String(spec.note).trim()) {
    parts.push(esc(spec.note));
  }
  if (spec.action && String(spec.action).trim()) {
    parts.push(`➡️ <b>Что делать</b>\n   ${esc(spec.action)}`);
  }
  return parts.join('\n\n');
}

// build(spec) — готовая карточка. Бюджет применяется ПЕРЕСБОРКОЙ с меньшим содержимым, а не
// обрезкой готового HTML: разрез внутри тега или сущности сам по себе даёт 400. Порядок
// вытеснения — от наименее ценного: длинные списки → цитата → блок фактов. Заголовок и
// «Что делать» выживают всегда. В JS .length УЖЕ считает UTF-16 code units — те же единицы,
// которыми меряет Telegram (в bash-зеркале для этого нужна отдельная jq-идиома).
function build(spec) {
  let out = renderParts(spec, 0, true, true, 0);
  if (out.length <= BUDGET) return out;
  // 1) ужимаем длинные одиночные значения (хвост stderr в секции-блоке, цитату)
  for (const scap of [1200, 400, 120]) {
    out = renderParts(spec, 0, true, true, scap);
    if (out.length <= BUDGET) return out;
  }
  // 2) ужимаем списки
  for (const cap of [24, 12, 6, 3]) {
    out = renderParts(spec, cap, true, true, 120);
    if (out.length <= BUDGET) return out;
  }
  // 3) выбрасываем цитату, затем блок фактов
  out = renderParts(spec, 3, false, true, 120);
  if (out.length <= BUDGET) return out;
  out = renderParts(spec, 3, false, false, 120);
  if (out.length <= BUDGET) return out;
  // 4) Патология. Готовый HTML НЕ режем — разрез внутри тега или сущности сам даёт 400.
  // Разворачиваем в plain, режем сырой текст, экранируем обратно; экранирование раздувает
  // строку (& → &amp;), поэтому ужимаем в цикле, пока не влезет.
  const raw = plain(out);
  for (let lim = BUDGET; lim > 32; lim = Math.floor(lim / 2)) {
    const cut = esc(truncU16(raw, lim));
    if (cut.length <= BUDGET) return cut;
  }
  return esc(truncU16(raw, 32));
}

// send(html, {tg, chatId, timeoutMs}) → {ok, out}
// tg — УЖЕ отрезолвленный путь нотификатора: библиотека его не ищет (см. шапку .sh).
function send(html, opts = {}) {
  const tg = opts.tg;
  if (!tg || !html) return { ok: false, out: '' };
  const args = [];
  const bte = botTokenEnv();
  if (bte) args.push('--bot-token-env', bte);
  if (opts.chatId != null && opts.chatId !== '') {
    // Минус ЗНАЧИМ: у групп chat_id отрицательный. Нынешние вызывающие тянут его через
    // awk gsub(/[^0-9]/,"") и молча съедают знак — сюда эту ошибку не переносим.
    if (!/^-?[0-9]+$/.test(String(opts.chatId))) return { ok: false, out: '' };
    args.push('--chat-id', String(opts.chatId));
  }
  const timeout = opts.timeoutMs || TIMEOUT_MS;
  const run = (extra, text) => {
    // `--` завершает разбор флагов → карточка никогда не перечитается как флаг.
    try {
      return { ok: true, out: execFileSync(tg, [...args, ...extra, '--', text],
        { encoding: 'utf8', timeout }) };
    } catch (e) {
      return { ok: false, out: `${e.stdout || ''}${e.stderr || ''}${e.message || ''}` };
    }
  };
  let r = run(['--parse-mode', 'HTML'], html);
  if (!r.ok && isMarkupError(r.out)) r = run([], plain(html));
  // Отозванный токен @RnR_Workers синтаксически валиден (botTokenEnv его пропускает), а
  // Telegram отвечает 401/403 — на best-effort точках алерт пропал бы, хотя дефолтный бот
  // жив. Последняя попытка — им. Только если флаг реально ставился, иначе это повтор того же.
  if (!r.ok && bte && isAuthError(r.out)) {
    const plainArgs = [];
    if (opts.chatId != null && opts.chatId !== '') plainArgs.push('--chat-id', String(opts.chatId));
    try {
      r = { ok: true, out: execFileSync(tg, [...plainArgs, '--', plain(html)], { encoding: 'utf8', timeout }) };
    } catch (e) {
      r = { ok: false, out: `${e.stdout || ''}${e.stderr || ''}${e.message || ''}` };
    }
  }
  return r;
}

module.exports = {
  build, send, esc, unesc, plain, isMarkupError, isAuthError, botTokenEnv, wrapItems, truncU16,
  BUDGET, DIVIDER, WRAP, TIMEOUT_MS,
};
