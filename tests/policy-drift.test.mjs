// T6: обязательный пролог изоляции (tests/lib/bootstrap.mjs) — первым значимым действием
// файла, до любого импорта bin/*: модули отдела резолвят корень рантайма уже на загрузке.
import './lib/bootstrap.mjs';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const { driftBucket, silentWorkers } = createRequire(import.meta.url)('../channels/event-bridge/adapters/ledger-policy-drift');

const MIN = 60_000, HOUR = 3600_000;
const now = 1_784_000_000_000;
const reg = { workers: {
  'dept-head': { role: 'руководитель' },
  'mk-a': { role: 'мк', client: 'a' },
  'mk-b': { role: 'мк', client: 'b' },
  'dept-tp': { role: 'тп' },
  'legacy-x': { role: 'legacy' },
} };
const cur = { version: 'v9', mtimeMs: now - 2 * HOUR };
const ack = (worker, version, tsMs) => ({ kind: 'policy_ack', ts: new Date(tsMs).toISOString(), data: { worker, policy_version: version } });
// Состояния из autonomous.json. По умолчанию все активны, кроме явно спящих.
const st = { 'dept-head': 'active', 'mk-a': 'active', 'mk-b': 'active', 'dept-tp': 'active', 'legacy-x': 'active' };
const stWith = (over) => ({ ...st, ...over });

test('бакеты эскалируют: до 30 мин молчим, дальше 30мин → 6ч → сутки', () => {
  assert.equal(driftBucket(now - 10 * MIN, now), null, 'сразу после публикации не дёргаем — флот ещё читает');
  assert.equal(driftBucket(now - 45 * MIN, now), '30 минут');
  assert.equal(driftBucket(now - 8 * HOUR, now), '6 часов');
  assert.equal(driftBucket(now - 30 * HOUR, now), 'сутки');
});

test('молчун — тот, у кого ack на старой версии', () => {
  const acks = [ack('dept-head', 'v9', now - HOUR), ack('mk-a', 'v8', now - 20 * HOUR), ack('mk-b', 'v9', now - HOUR), ack('dept-tp', 'v9', now - HOUR)];
  assert.deepEqual(silentWorkers(reg, acks, cur, st), ['mk-a']);
});

test('молчун — тот, у кого ack СТАРШЕ mtime правил (перечитал до правки)', () => {
  const acks = [ack('dept-head', 'v9', now - 3 * HOUR), ack('mk-a', 'v9', now - HOUR), ack('mk-b', 'v9', now - HOUR), ack('dept-tp', 'v9', now - HOUR)];
  assert.deepEqual(silentWorkers(reg, acks, cur, st), ['dept-head']);
});

test('молчун — тот, у кого ack нет вовсе', () => {
  const acks = [ack('mk-a', 'v9', now - HOUR), ack('mk-b', 'v9', now - HOUR), ack('dept-tp', 'v9', now - HOUR)];
  assert.deepEqual(silentWorkers(reg, acks, cur, st), ['dept-head']);
});

test('legacy-воркеры не считаются молчунами (не роли отдела)', () => {
  const acks = [ack('dept-head', 'v9', now - HOUR), ack('mk-a', 'v9', now - HOUR), ack('mk-b', 'v9', now - HOUR), ack('dept-tp', 'v9', now - HOUR)];
  assert.deepEqual(silentWorkers(reg, acks, cur, st), [], 'legacy-x без ack не должен попасть в молчуны');
});

test('TTL не делает молчуна: свежая версия, но ack старше 24ч — это дело турникета, не планёрки', () => {
  const old = { version: 'v9', mtimeMs: now - 40 * HOUR };
  const acks = [ack('dept-head', 'v9', now - 30 * HOUR), ack('mk-a', 'v9', now - 30 * HOUR), ack('mk-b', 'v9', now - 30 * HOUR), ack('dept-tp', 'v9', now - 30 * HOUR)];
  assert.deepEqual(silentWorkers(reg, acks, old, st), [], 'ack действующей версии, сделанный после её mtime — не дрейф');
});

test('учитывается ПОСЛЕДНИЙ ack воркера, а не первый', () => {
  const acks = [ack('mk-a', 'v8', now - 20 * HOUR), ack('mk-a', 'v9', now - HOUR),
    ack('dept-head', 'v9', now - HOUR), ack('mk-b', 'v9', now - HOUR), ack('dept-tp', 'v9', now - HOUR)];
  assert.deepEqual(silentWorkers(reg, acks, cur, st), []);
});

test('список молчунов отсортирован (детерминизм — иначе дедуп bridge поплывёт)', () => {
  const acks = [ack('dept-tp', 'v9', now - HOUR)];
  assert.deepEqual(silentWorkers(reg, acks, cur, st), ['dept-head', 'mk-a', 'mk-b']);
});

test('СПЯЩИЙ не молчун — даже со старым ack (решение оператора №2: спящих не будим)', () => {
  // Живой кейс: diaverum-russ спит с ack v4. Без фильтра он держал бы датчик в вечном
  // дрейфе и Руководитель получал бы все три нуджа по воркеру, которого рассылка
  // намеренно пропустила. Правила он догонит турникетом при первом approve.
  const acks = [ack('dept-head', 'v9', now - HOUR), ack('mk-b', 'v9', now - HOUR),
    ack('dept-tp', 'v9', now - HOUR), ack('mk-a', 'v4', now - 40 * HOUR)];
  assert.deepEqual(silentWorkers(reg, acks, cur, stWith({ 'mk-a': 'sleeping' })), []);
});

test('воркер без записи в autonomous.json не молчун (нет состояния — нет активности)', () => {
  const acks = [ack('dept-head', 'v9', now - HOUR), ack('mk-b', 'v9', now - HOUR), ack('dept-tp', 'v9', now - HOUR)];
  assert.deepEqual(silentWorkers(reg, acks, cur, stWith({ 'mk-a': undefined })), []);
});

test('проснувшийся воркер СНОВА молчун (состояние active + старый ack)', () => {
  const acks = [ack('dept-head', 'v9', now - HOUR), ack('mk-b', 'v9', now - HOUR),
    ack('dept-tp', 'v9', now - HOUR), ack('mk-a', 'v4', now - 40 * HOUR)];
  assert.deepEqual(silentWorkers(reg, acks, cur, stWith({ 'mk-a': 'active' })), ['mk-a']);
});
