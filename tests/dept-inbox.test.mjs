import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const { renderInbox, renderApproval } = createRequire(import.meta.url)('../bin/dept-inbox');

const apr = { event_id: 'evt_1_aaaa', ts: new Date().toISOString(), actor: 'mk-prodmash',
  data: { kind_of: 'outgoing', from: 'mk-prodmash', status: 'open',
    summary: 'письмо в <script>alert(1)</script>', detail: 'полный текст письма' } };

test('renderInbox показывает открытый аппрув и экранирует HTML', () => {
  const html = renderInbox({ approvals: [apr], incidents: [], recent: [],
    registry: { workers: {} }, policy: { version: 'v2' } });
  assert.ok(html.includes('evt_1_aaaa'));
  assert.ok(html.includes('&lt;script&gt;'));
  assert.ok(!html.includes('<script>alert'));
  assert.ok(html.includes('v2'));
});

test('renderInbox на пустых данных не падает', () => {
  const html = renderInbox({ approvals: [], incidents: [], recent: [], registry: { workers: {} }, policy: {} });
  assert.ok(html.includes('пусто'));
});

test('renderApproval показывает detail и историю статусов', () => {
  const html = renderApproval(apr, [{ ts: '2026-07-13T10:00:00Z', actor: 'operator',
    data: { status: 'approved', ref: 'evt_1_aaaa' } }]);
  assert.ok(html.includes('полный текст письма'));
  assert.ok(html.includes('approved'));
});

test('renderApproval для неизвестного id — страница «не найдено»', () => {
  assert.ok(renderApproval(null, []).includes('не найден'));
});

test('renderApproval при ошибке чтения — баннер, не «не найден»-маскировка', () => {
  const html = renderApproval(null, [], 'spawn dept-ledger ENOENT');
  assert.ok(html.includes('Ошибка чтения журнала'));
  assert.ok(html.includes('spawn dept-ledger ENOENT'));
  assert.ok(!html.includes('не найден'));
});

test('renderApproval с событием и readError — и карточка, и баннер', () => {
  const html = renderApproval(apr, [], 'история статусов недоступна');
  assert.ok(html.includes('Ошибка чтения журнала'));
  assert.ok(html.includes('полный текст письма'));
});

test('renderApproval без readError (два аргумента) — баннера нет', () => {
  assert.ok(!renderApproval(apr, []).includes('Ошибка чтения журнала'));
  assert.ok(!renderApproval(null, []).includes('Ошибка чтения журнала'));
});

test('кривой/отсутствующий ts рисуется как «?», а не NaN', () => {
  const bad = { ...apr, ts: undefined };
  const html = renderApproval(bad, []);
  assert.ok(!html.includes('NaN'), 'NaN просочился в возраст');
  assert.ok(html.includes('(? назад)'));
});

test('renderApproval раскрашивает unified diff построчно', () => {
  const d = { ...apr, data: { ...apr.data, detail: '--- a\n+++ b\n@@ -1 +1 @@\n-старое\n+новое\n контекст' } };
  const html = renderApproval(d, []);
  assert.ok(html.includes('<pre class="diff">'));
  assert.ok(html.includes('<span class="da">+новое</span>'));
  assert.ok(html.includes('<span class="dd">-старое</span>'));
});
