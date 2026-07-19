// dept-inbox-render.js — весь HTML-рендер дашборда «Цифровой отдел» (Task 9, фаза 3).
// Чистые функции (data → html), никакого fs/child_process/http здесь — те живут в
// bin/dept-inbox (сборщики данных + сервер). Дизайн — по скиллу dataviz (палитра,
// stat-плитки, sparkline) + чеклист web-design-guidelines (контраст, focus-visible,
// touch-таргеты, семантика). CSP страницы (default-src 'none'; style-src
// 'unsafe-inline') не допускает JS — весь интерактив статический (native title/details).
'use strict';

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// Возраст по ISO-таймстампу события ledger.
function age(ts) {
  const m = Math.max(0, Math.round((Date.now() - Date.parse(ts)) / 60000));
  if (!Number.isFinite(m)) return '?'; // битый/отсутствующий ts — не рисовать "NaN дн"
  if (m < 60) return m + ' мин';
  if (m < 1440) return Math.floor(m / 60) + ' ч ' + (m % 60) + ' мин';
  return Math.floor(m / 1440) + ' дн';
}

// Возраст по уже посчитанным минутам (собиратель данных сам вычисляет lastActivityMin/
// policyAck.ageMin через Date.now() на момент сбора — здесь только форматирование).
function ageMin(m) {
  if (m == null || !Number.isFinite(m)) return '?';
  const mm = Math.max(0, Math.round(m));
  if (mm < 60) return mm + ' мин';
  if (mm < 1440) return Math.floor(mm / 60) + ' ч ' + (mm % 60) + ' мин';
  return Math.floor(mm / 1440) + ' дн';
}

function summaryOf(e) {
  const d = e.data || {};
  return d.summary || d.subject || (d.status ? `${d.status} → ${d.ref || ''}` : '') || d.worker || '';
}

// Компактный формат больших чисел (dataviz: "auto-compact: 1,284 / 12.9K / $4.2M").
function fmtK(n) {
  if (n == null || !Number.isFinite(n)) return 'n/a';
  const v = Math.abs(n);
  if (v < 1000) return String(n);
  if (v < 10000) return (n / 1000).toFixed(1) + 'K';
  if (v < 1e6) return Math.round(n / 1000) + 'K';
  return (n / 1e6).toFixed(1) + 'M';
}

// ---------------------------------------------------------------------------
// Дизайн-система: CSS-переменные light/dark (dataviz-палитра), карточки, бейджи,
// meter, sparkline. Статус-цвета (ok/warn/err/down) не темизируются (dataviz:
// "status palette — fixed, never themed") — одни и те же hex в обоих режимах.
// ---------------------------------------------------------------------------
const CSS = `
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
:root,body{
  color-scheme:dark;
  --bg:#0d0d0d;--card:#1a1a19;--card2:#232422;--fg:#ffffff;--fg2:#c3c2b7;--muted:#9a988f;
  --border:rgba(255,255,255,.14);--grid:#2c2c2a;--accent:#3987e5;
  --ok:#0ca30c;--warn:#fab219;--err:#d03b3b;--down:#ec835a;
  /* solid-fill варианты (нав-пилюля, meter warn) — те же семейства оттенков, но подобраны
     под WCAG 1.4.11 (≥3:1 UI-компонент) / 4.5:1 (текст поверх заливки) в ОБОИХ темах разом,
     поэтому не темизируются — как и статус-цвета выше (dataviz: "status palette — never
     themed"). --accent-strong — шаг 600 секвенциальной рампы синего (references/palette.md);
     --warn-strong — притемнённый янтарь: чистый --warn (#fab219) даёт 1.6:1 на светлом
     треке meter — ниже порога не-текстового контраста. */
  --accent-strong:#184f95;--warn-strong:#a66a00;
  /* --err-text — err(#d03b3b) как обычный текст на тёмном фоне даёт 4.05:1 (ниже 4.5:1 AA);
     категориальный красный dark-шаг (#e66767, palette.md) даёт 6.02:1 — только для ТЕКСТА
     (err-banner). Бейджи/meter остаются на --err — там цвет всегда с иконкой+подписью. */
  --err-text:#e66767;
}
@media (prefers-color-scheme:light){
  :root,body{
    color-scheme:light;
    --bg:#f9f9f7;--card:#ffffff;--card2:#f0efec;--fg:#0b0b0b;--fg2:#52514e;--muted:#726f68;
    --border:rgba(11,11,11,.14);--grid:#e1e0d9;
    /* --accent: dataviz light-mode categorical blue #2a78d6 даёт 4.42:1 на карточке / 4.19:1
       на фоне — ниже 4.5:1 AA для текста ссылок (accent используется как color всех <a>).
       #256abf — шаг 500 той же секвенциальной рампы (references/palette.md) — 5.1–5.4:1
       везде, тот же оттенок синего, просто следующий шаг вниз по светлоте. */
    --accent:#256abf;--err-text:#d03b3b;
  }
}
@media (prefers-reduced-motion:reduce){*{transition:none!important;animation:none!important}}
body{margin:0;font:15px/1.55 system-ui,-apple-system,"Segoe UI",sans-serif;background:var(--bg);color:var(--fg)}
.wrap{max-width:74rem;margin:0 auto;padding:0 1rem 3rem}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px;border-radius:3px}
h1{font-size:1.4rem;margin:1.1rem 0 .4rem}
h2{font-size:1.05rem;margin:1.5rem 0 .5rem;color:var(--fg2)}
h3{font-size:.95rem;margin:0 0 .4rem;color:var(--fg2)}
p.meta{color:var(--fg2);font-size:.88rem}
.back-link{display:inline-block;padding:.6rem 0}
.err-banner{color:var(--err-text);border:1px solid var(--err-text);padding:.5rem .9rem;border-radius:8px;
  background:rgba(208,59,59,.08);margin:.7rem 0;font-size:.92rem}
header.topbar{background:var(--card);border-bottom:1px solid var(--border);position:sticky;top:0;z-index:1}
nav.topnav{max-width:74rem;margin:0 auto;padding:.4rem .8rem;display:flex;flex-wrap:wrap;gap:.2rem;align-items:center}
nav.topnav .brand{font-weight:700;color:var(--fg);margin-right:.4rem;padding:.6rem .2rem;font-size:.95rem}
nav.topnav a{padding:.65rem .9rem;min-height:2.75rem;display:inline-flex;align-items:center;border-radius:8px;
  color:var(--fg2);font-weight:600;font-size:.92rem}
nav.topnav a:hover{background:var(--card2);color:var(--fg)}
nav.topnav a[aria-current="page"]{background:var(--accent-strong);color:#fff}
table{border-collapse:collapse;width:100%;margin:.5rem 0 1.5rem;font-size:.92rem}
td,th{border-bottom:1px solid var(--border);padding:.4rem .55rem;text-align:left;vertical-align:top}
th{color:var(--muted);font-weight:600;font-size:.78rem;text-transform:uppercase;letter-spacing:.02em}
tbody tr:hover{background:var(--card2)}
.tablewrap{overflow-x:auto}
blockquote{border-left:3px solid var(--border);margin:.5rem 0;padding:.2rem .8rem;white-space:pre-wrap;color:var(--fg2)}
pre.diff{background:var(--card2);border:1px solid var(--border);padding:.6rem .8rem;overflow-x:auto;
  line-height:1.35;font-size:13px;border-radius:8px}
.da{color:#7ee787}.dd{color:#ff8f7a}.dh{color:var(--muted)}.dc{color:var(--fg2)}
details{margin:.4rem 0}
details>summary{cursor:pointer;color:var(--accent);font-weight:600;padding:.3rem 0}
.request-block{background:var(--card2);border:1px solid var(--border);border-radius:10px;padding:.8rem 1rem;margin:.7rem 0}
.request-block dl{display:grid;grid-template-columns:max-content 1fr;gap:.3rem .9rem;margin:.5rem 0 0}
.request-block dt{color:var(--muted);font-weight:600;font-size:.85rem}
.request-block dd{margin:0;color:var(--fg2);word-break:break-word;font-size:.9rem}
.proxy-note{color:var(--muted);font-size:.86rem;border-left:3px solid var(--border);padding:.35rem .9rem;margin:.7rem 0}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:.7rem;margin:1rem 0}
.stat{background:var(--card);border:1px solid var(--border);border-radius:10px;padding:.7rem .9rem}
.stat a{color:inherit;display:block}
.stat-label{color:var(--muted);font-size:.76rem;text-transform:uppercase;letter-spacing:.03em}
.stat-value{font-size:1.5rem;font-weight:700;color:var(--fg);margin-top:.15rem}
.office-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:1rem;margin:1rem 0}
@media (max-width:480px){.office-grid{grid-template-columns:1fr}.stats{grid-template-columns:repeat(2,1fr)}}
.card{background:var(--card);border:1px solid var(--border);border-radius:12px;padding:.9rem 1rem;
  display:flex;flex-direction:column;gap:.6rem}
.card-head{display:flex;align-items:flex-start;gap:.6rem}
.avatar{font-size:1.5rem;line-height:1.2;flex:0 0 auto}
.card-head-info{flex:1 1 auto;min-width:0}
.card-title{font-weight:700;font-size:1rem;color:var(--fg);display:inline-block;padding:.65rem 0;margin:-.65rem 0}
.card-sub{color:var(--fg2);font-size:.85rem}
.badge{margin-left:auto;flex:0 0 auto;font-size:.78rem;font-weight:700;padding:.3rem .6rem;
  border-radius:999px;border:1px solid transparent;white-space:nowrap}
.badge-ok{background:rgba(12,163,12,.15);border-color:rgba(12,163,12,.5)}
.badge-warn{background:rgba(250,178,25,.2);border-color:rgba(250,178,25,.6)}
.badge-err{background:rgba(208,59,59,.16);border-color:rgba(208,59,59,.55)}
.badge-down{background:rgba(236,131,90,.2);border-color:rgba(236,131,90,.6)}
.badge-sleep{background:rgba(154,152,143,.2);border-color:rgba(154,152,143,.55)}
.card-meta{display:grid;grid-template-columns:repeat(2,1fr);gap:.3rem .8rem;margin:0;font-size:.84rem}
.card-meta dt{color:var(--muted);font-weight:500}
.card-meta dd{margin:0;color:var(--fg2)}
.meter{display:flex;align-items:center;gap:.5rem;font-size:.78rem;color:var(--fg2)}
.meter-track{flex:1 1 auto;height:8px;border-radius:4px;background:var(--card2);border:1px solid var(--border);overflow:hidden}
.meter-fill{height:100%;border-radius:4px;background:var(--accent)}
.meter-fill.warn{background:var(--warn-strong)}
.meter-fill.err{background:var(--err)}
.card-probes{font-size:.78rem;color:var(--muted)}
.spark{color:var(--accent);flex:0 0 auto}
</style>`.trim();

const NAV = [
  { id: 'office', href: '/', label: 'Офис' },
  { id: 'approvals', href: '/approvals', label: 'Аппрувы' },
  { id: 'incidents', href: '/incidents', label: 'Инциденты' },
  { id: 'activity', href: '/activity', label: 'Активность' },
];
function navHtml(active) {
  return NAV.map((n) => `<a href="${n.href}"${n.id === active ? ' aria-current="page"' : ''}>${esc(n.label)}</a>`).join('');
}
function page(title, body, active) {
  return `<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="refresh" content="60">
<title>${esc(title)}</title><style>${CSS}</style></head><body>
<header class="topbar"><nav class="topnav" aria-label="Разделы отдела"><span class="brand">Цифровой отдел</span>${navHtml(active)}</nav></header>
<main class="wrap">${body}</main>
</body></html>`;
}

// Единый стиль баннера ошибки чтения. readError к этому моменту УЖЕ generic-текст
// (p2#11 — dl() в bin/dept-inbox сам не пропускает сырой stderr/ENOENT наружу).
function errBanner(readError) {
  return readError
    ? `<p class="err-banner">⚠️ Ошибка чтения журнала — данные могут быть неполными: ${esc(readError)}</p>` : '';
}

// detail с видом unified diff рендерим раскрашенным построчно; прочее — blockquote
function renderDetail(detail) {
  if (!detail) return '<p class="meta">детали не приложены</p>';
  const looksDiff = /^(@@ |--- |\+\+\+ )/m.test(detail);
  if (!looksDiff) return `<blockquote>${esc(detail)}</blockquote>`;
  const rows = detail.split('\n').map((l) => {
    const c = l.startsWith('+') ? 'da' : l.startsWith('-') ? 'dd' : l.startsWith('@@') ? 'dh' : 'dc';
    return `<span class="${c}">${esc(l)}</span>`;
  }).join('\n');
  return `<pre class="diff">${rows}</pre>`;
}

const REQUEST_FIELD_LABELS = {
  client: 'клиент', name: 'имя воркера', gid: 'asana gid', url: 'asana url', note: 'заметка',
  worker: 'воркер', reason: 'причина', mission_text: 'текст миссии',
};
// Codex-аудит К4: если у аппрува есть data.request — рендерим отдельным блоком «Заявка
// (исполняемые данные)», чтобы оператор видел РОВНО то, что исполнит диспетчер (не только
// прозу detail). mission_text — потенциально длинный (до 22000 симв.) — всегда за <details>.
function renderRequestBlock(request) {
  if (!request || typeof request !== 'object' || Array.isArray(request)) return '';
  const rows = Object.entries(request).map(([k, v]) => {
    const label = esc(REQUEST_FIELD_LABELS[k] || k);
    if (k === 'mission_text') {
      const text = String(v ?? '');
      return `<div><dt>${label}</dt><dd><details><summary>показать текст миссии (${text.length} симв.)</summary>` +
        `<blockquote>${esc(text)}</blockquote></details></dd></div>`;
    }
    return `<div><dt>${label}</dt><dd>${esc(String(v))}</dd></div>`;
  }).join('');
  return `<div class="request-block"><h3>Заявка (исполняемые данные)</h3><dl>${rows}</dl></div>`;
}

function renderApproval(e, statuses, readError) {
  if (!e) {
    // при ошибке чтения НЕ выдавать «не найдено» — реальное состояние аппрува неизвестно
    if (readError) return page('ошибка чтения журнала', `${errBanner(readError)}
<p>Не удалось прочитать журнал — состояние аппрува неизвестно, обнови страницу.</p>
<p><a class="back-link" href="/approvals">← в аппрувы</a></p>`, 'approvals');
    return page('не найдено', '<p>Аппрув не найден.</p><p><a class="back-link" href="/approvals">← в аппрувы</a></p>', 'approvals');
  }
  const st = statuses.length ? statuses[statuses.length - 1].data.status : (e.data.status || 'open');
  const hist = statuses.map((s) => `<li>${esc(s.ts)} — <b>${esc(s.data.status)}</b> (${esc(s.actor)})</li>`).join('');
  const body = `${errBanner(readError)}
<p><a class="back-link" href="/approvals">← в аппрувы</a></p>
<h1>${esc(e.data.summary)}</h1>
<p class="meta">${esc(e.event_id)} · от ${esc(e.data.from)} · тип ${esc(e.data.kind_of)} · открыт ${esc(e.ts)} (${esc(age(e.ts))} назад) · статус: <b>${esc(st)}</b></p>
${renderRequestBlock(e.data.request)}
${renderDetail(e.data.detail)}
${hist ? `<h2>История</h2><ul>${hist}</ul>` : ''}
<p class="meta">Решение — кнопками в Telegram (@RnR_Workers). Эта страница только показывает.</p>`;
  return page(`Аппрув ${e.event_id}`, body, 'approvals');
}

// /approvals — перенос инбокса фазы 2 (без изменения семантики) + блок «исполнение»
// (executed/exec_failed за 7 дней — Codex-видимость итога заявок).
function renderApprovalsPage(d) {
  const apr = (d.approvals || []).map((e) => `<tr><td>${esc(age(e.ts))}</td><td>${esc(e.data.from)}</td>
<td>${esc(e.data.kind_of)}</td><td><a href="/a/${esc(e.event_id)}">${esc(e.data.summary)}</a></td></tr>`).join('')
    || '<tr><td colspan="4">пусто — решений никто не ждёт</td></tr>';
  const inc = (d.incidents || []).map((e) => `<tr><td>${esc(age(e.ts))}</td><td>${esc(e.data.severity)}</td>
<td>${esc(e.data.about_worker)}</td><td>${esc(e.data.summary)}</td></tr>`).join('')
    || '<tr><td colspan="4">пусто</td></tr>';
  const rec = (d.recent || []).map((e) => `<tr><td>${esc((e.ts || '').slice(0, 16).replace('T', ' '))}</td>
<td>${esc(e.actor)}</td><td>${esc(e.kind)}</td><td>${esc(summaryOf(e))}</td></tr>`).join('');
  const exec = (d.executed || []).map((e) => `<tr><td>${esc(age(e.ts))}</td>
<td><a href="/a/${esc(e.data.ref)}">${esc(e.data.ref)}</a></td><td>${esc(e.data.status)}</td><td>${esc(e.data.note || '')}</td></tr>`).join('')
    || '<tr><td colspan="4">за 7 дней исполнений не было</td></tr>';
  // M-2: заявки между решением человека и финалом раннера (approved-исполняемые ждут
  // диспетчера, executing — раннер в работе) — сборка в collectApprovalsPage (dept-inbox).
  // approved_foreign — approved-исполняемая НЕ от руководителя/operator: pickExecutable
  // диспетчера её не возьмёт никогда, честно говорим об этом вместо «ждёт диспетчера».
  const EXEC_PHASE_LABEL = { executing: 'executing', approved: 'approved — ждёт диспетчера',
    approved_foreign: 'approved — диспетчер НЕ возьмёт (подал не руководитель)' };
  const execNow = (d.executingNow || []).map((e) => `<tr><td>${esc(age(e.ts))}</td><td>${esc(e.data.from)}</td>
<td>${esc(e.data.kind_of)}</td><td>${esc(EXEC_PHASE_LABEL[e.phase] || e.phase)}</td>
<td><a href="/a/${esc(e.event_id)}">${esc(e.data.summary)}</a></td></tr>`).join('')
    || '<tr><td colspan="5">ничего не исполняется</td></tr>';
  const workers = Object.keys((d.registry && d.registry.workers) || {}).length;
  const body = `${errBanner(d.readError)}
<h1>Аппрувы</h1>
<p class="meta">правила: ${esc((d.policy && d.policy.version) || '?')} · воркеров в реестре: ${workers} · автообновление 60с</p>
<h2>⏳ Ждут решения (${(d.approvals || []).length})</h2>
<div class="tablewrap"><table><tr><th>висит</th><th>кто</th><th>тип</th><th>что</th></tr>${apr}</table></div>
<h2>⚙️ Исполняются (${(d.executingNow || []).length})</h2>
<div class="tablewrap"><table><tr><th>возраст</th><th>кто</th><th>тип</th><th>фаза</th><th>что</th></tr>${execNow}</table></div>
<h2>🚨 Открытые инциденты (${(d.incidents || []).length})</h2>
<div class="tablewrap"><table><tr><th>возраст</th><th>severity</th><th>о ком</th><th>что</th></tr>${inc}</table></div>
<h2>Исполнение заявок (7 дней)</h2>
<div class="tablewrap"><table><tr><th>когда</th><th>заявка</th><th>статус</th><th>заметка</th></tr>${exec}</table></div>
<h2>Последние события</h2>
<div class="tablewrap"><table><tr><th>когда (UTC)</th><th>кто</th><th>вид</th><th>что</th></tr>${rec}</table></div>`;
  return page('Отдел — аппрувы', body, 'approvals');
}

// ---------------------------------------------------------------------------
// «Офис» — Task 9
// ---------------------------------------------------------------------------

const ROLE_AVATAR = { руководитель: '👔', архивариус: '📚', тп: '🔧', мк: '🤝' };
function roleAvatar(role) { return ROLE_AVATAR[role] || '⚙️'; }

// Приоритет статус-бейджа (сверху вниз, ровно один на карточку — Codex-приёмка):
// 🔴 инцидент about_worker → ⏳ ждёт человека (открытый аппрув from) → 😴 спит →
// ⛔ down (state=active, юнит не поднят) → 🟢 в строю.
function statusOf(w) {
  if (w.openIncidents) return { icon: '🔴', label: 'инцидент', cls: 'err' };
  if (w.openApprovals) return { icon: '⏳', label: 'ждёт человека', cls: 'warn' };
  if (w.state === 'sleeping') return { icon: '😴', label: 'спит', cls: 'sleep' };
  if (w.state === 'active' && w.unitUp === false) return { icon: '⛔', label: 'down', cls: 'down' };
  return { icon: '🟢', label: 'в строю', cls: 'ok' };
}

function meterHtml(ctx) {
  if (!ctx || !Number.isFinite(ctx.tokens) || !Number.isFinite(ctx.threshold) || ctx.threshold <= 0) {
    return `<div class="meter"><span>контекст: n/a</span></div>`;
  }
  const pct = Math.max(0, Math.min(100, Math.round((ctx.tokens / ctx.threshold) * 100)));
  const cls = pct >= 90 ? 'err' : pct >= 70 ? 'warn' : '';
  const label = `контекст: ${fmtK(ctx.tokens)} из ${fmtK(ctx.threshold)} токенов (${pct}%)`;
  return `<div class="meter"><div class="meter-track" role="progressbar" aria-valuenow="${pct}" aria-valuemin="0" ` +
    `aria-valuemax="100" aria-label="${esc(label)}"><div class="meter-fill ${cls}" style="width:${pct}%"></div></div>` +
    `<span class="meter-num">${esc(fmtK(ctx.tokens))}/${esc(fmtK(ctx.threshold))}</span></div>`;
}

function workerCardHtml(w) {
  const st = statusOf(w);
  const avatar = roleAvatar(w.role);
  const href = '/w/' + esc(encodeURIComponent(w.name));
  const probes = (w.probes && w.probes.length) ? w.probes.map((p) => esc(p)).join(', ') : '—';
  const ack = w.policyAck ? `${esc(w.policyAck.version || '?')} · ${ageMin(w.policyAck.ageMin)} назад` : 'n/a';
  const compactions = Number.isFinite(w.compactions) ? esc(w.compactions) : 'n/a';
  const lastAct = w.lastActivityMin != null ? `${ageMin(w.lastActivityMin)} назад` : 'n/a';
  return `<article class="card">
<div class="card-head">
<span class="avatar" aria-hidden="true">${avatar}</span>
<div class="card-head-info"><a class="card-title" href="${href}">${esc(w.name)}</a>
<div class="card-sub">${esc(w.client || w.role || '')}</div></div>
<span class="badge badge-${st.cls}" title="${esc(st.label)}"><span aria-hidden="true">${st.icon}</span> ${esc(st.label)}</span>
</div>
<dl class="card-meta">
<div><dt>Миссия</dt><dd>${esc(w.missionVersion || 'n/a')}</dd></div>
<div><dt>Policy-ack</dt><dd>${ack}</dd></div>
<div><dt>Компакций</dt><dd>${compactions}</dd></div>
<div><dt>Активность</dt><dd>${lastAct}</dd></div>
</dl>
${meterHtml(w.ctx)}
<div class="card-probes">датчики: ${probes}</div>
</article>`;
}

function renderOffice(d) {
  const workers = d.workers || [];
  const cards = workers.map(workerCardHtml).join('\n') || '<p class="meta">воркеров отдела нет в реестре</p>';
  const body = `${errBanner(d.readError)}
<h1>Офис</h1>
<div class="stats">
<div class="stat"><div class="stat-label">Правила</div><div class="stat-value">${esc((d.policy && d.policy.version) || '?')}</div></div>
<div class="stat"><a href="/approvals"><div class="stat-label">Открытых аппрувов</div><div class="stat-value">${esc(d.openApprovals ?? 0)}</div></a></div>
<div class="stat"><a href="/incidents"><div class="stat-label">Открытых инцидентов</div><div class="stat-value">${esc(d.openIncidents ?? 0)}</div></a></div>
<div class="stat"><div class="stat-label">Спящих</div><div class="stat-value">${esc(d.sleepingCount ?? 0)}</div></div>
</div>
<div class="office-grid">${cards}</div>
<p class="meta">legacy-контуров (без карточек, старые автономные воркеры вне ролей отдела): ${esc(d.legacyCount ?? 0)}</p>`;
  return page('Отдел — офис', body, 'office');
}

// ---------------------------------------------------------------------------
// /w/<name> — таймлайн агента
// ---------------------------------------------------------------------------

function timelineSummary(e) {
  const d = e.data || {};
  if (e.kind === 'agent_run') return `${d.run_kind || '?'}${d.reason ? ': ' + d.reason : ''}`;
  if (e.kind === 'policy_ack') return `policy_ack ${d.policy_version || ''}`;
  return summaryOf(e);
}

function renderTimeline(name, events, readError, card) {
  const rows = (events || []).map((e) => `<tr><td>${esc((e.ts || '').slice(0, 16).replace('T', ' '))}</td>
<td>${esc(e.actor)}</td><td>${esc(e.kind)}</td><td>${esc(timelineSummary(e))}</td></tr>`).join('')
    || '<tr><td colspan="4">событий не найдено</td></tr>';
  const headCard = card ? `<div class="office-grid">${workerCardHtml(card)}</div>` : '';
  const body = `${errBanner(readError)}
<p><a class="back-link" href="/">← в офис</a></p>
<h1>Таймлайн: ${esc(name)}</h1>
${headCard}
<h2>Последние события (до 100)</h2>
<div class="tablewrap"><table><tr><th>когда (UTC)</th><th>кто</th><th>вид</th><th>что</th></tr>${rows}</table></div>`;
  return page(`Воркер ${name}`, body, null);
}

// ---------------------------------------------------------------------------
// /activity — «бюджеты» v1 (активность-прокси)
// ---------------------------------------------------------------------------

// Inline SVG sparkline — без осей, тонкая полилиния, aria-label с сырыми числами
// (dataviz: marks-and-anatomy — 2px line, round join/cap; components — Sparkline).
function sparkline(days, w, h) {
  const W = w || 112, H = h || 28;
  const arr = Array.isArray(days) && days.length ? days : [0];
  const max = Math.max(1, ...arr);
  const stepX = arr.length > 1 ? W / (arr.length - 1) : 0;
  const pts = arr.map((v, i) => `${(i * stepX).toFixed(1)},${(H - (Math.max(0, v) / max) * H).toFixed(1)}`).join(' ');
  const label = `активность за ${arr.length} дней: ${arr.join(', ')}`;
  return `<svg class="spark" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(label)}">` +
    `<polyline points="${pts}" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>`;
}

function renderActivity(rows, readError) {
  const items = (rows || []).map((r) => `<tr><td>${esc(r.name)}</td><td>${esc(r.events7d ?? 0)}</td>
<td>${esc(r.compactions ?? 0)}</td><td>${esc(r.wakes ?? 0)}</td><td>${esc(r.rebases ?? 0)}</td><td>${esc(r.spawns ?? 0)}</td>
<td>${sparkline(r.days)}</td></tr>`).join('') || '<tr><td colspan="7">данных нет</td></tr>';
  const body = `${errBanner(readError)}
<h1>Активность</h1>
<p class="proxy-note">⚠️ Расход токенов подписка не отдаёт — это активность-прокси (события/компакции/wake·rebase·spawn
за 7 дней, sparkline — события по дням за 14 дней). Честные бюджеты (парсинг расхода из транскриптов) — в бэклоге, Asana Server support.</p>
<div class="tablewrap"><table><tr><th>воркер</th><th>событий/7д</th><th>компакций</th><th>wake</th><th>rebase</th><th>спавнов</th>
<th>14д</th></tr>${items}</table></div>`;
  return page('Отдел — активность', body, 'activity');
}

// ---------------------------------------------------------------------------
// /incidents — incident-board
// ---------------------------------------------------------------------------

function incidentRow(e) {
  return `<tr><td>${esc(age(e.ts))}</td><td>${esc(e.data.severity)}</td><td>${esc(e.data.about_worker)}</td>
<td>${esc(e.data.summary)}</td><td>${esc(e.data.status || 'open')}</td></tr>`;
}
function renderIncidents(d) {
  const open = (d.open || []).map(incidentRow).join('') || '<tr><td colspan="5">открытых инцидентов нет</td></tr>';
  const closed = (d.closed || []).map(incidentRow).join('') || '<tr><td colspan="5">за 14 дней не закрывалось</td></tr>';
  const body = `${errBanner(d.readError)}
<h1>Инциденты</h1>
<h2>🚨 Открытые (${(d.open || []).length})</h2>
<div class="tablewrap"><table><tr><th>возраст</th><th>severity</th><th>о ком</th><th>что</th><th>статус</th></tr>${open}</table></div>
<h2>Закрытые за 14 дней (${(d.closed || []).length})</h2>
<div class="tablewrap"><table><tr><th>возраст</th><th>severity</th><th>о ком</th><th>что</th><th>статус</th></tr>${closed}</table></div>`;
  return page('Отдел — инциденты', body, 'incidents');
}

module.exports = {
  esc, age, ageMin, summaryOf, fmtK, page, errBanner, renderDetail, renderRequestBlock,
  renderApproval, renderApprovalsPage, renderOffice, renderTimeline, renderActivity, renderIncidents,
  roleAvatar, statusOf, meterHtml, sparkline, workerCardHtml,
};
