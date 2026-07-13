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
