# Цифровой отдел — ядро (dept-ledger, dept-approve, dept-inbox, liveness)

Субстрат «Цифрового отдела» — организация ролевых воркеров поверх
autonomous-слоя (`docs/autonomous.md`). Канон отдела (роли, policy, дизайн)
живёт в brain, не здесь — см. «Связанное».

## Ledger

`~/.claude-control/department/events.jsonl` (override `DEPT_HOME`) —
append-only JSONL, единственный писатель `bin/dept-ledger` (lockfile,
живёт ≤10с на запись). Конверт: `{v, event_id, seq, ts, actor, kind, data}`.
`kind` ∈ `message, message_status, approval, approval_status, incident,
incident_status, agent_run, registry_change, policy_ack`. Статусные
`*_status` ссылаются на исходное событие через `data.ref = event_id` — сам
ledger неизменяем, эффективный статус выводится сверху (`effectiveStatus`).
`message.type` ∈ `question, proposal, incident, handoff`;
`message_status.status` ∈ `acked, handled, dead`; `approval_status.status`
∈ `approved, denied`.

## Команды

- `dept-ledger append --kind <k> --data '<json>'` — низкоуровневая запись.
- `dept-ledger list [--kind <k>] [--filter k=v ...] [--status <s>] [--limit N]`.
- `dept-ledger send --type <question|proposal|incident|handoff> --to <worker>
  --subject <s> [--body <b>] [--refs a,b]` — сахар над `append --kind message`
  (статус сразу `queued`); валидирует топологию отправителя/адресата (см.
  «Топология шины»).
- `dept-ledger ack <event_id>` / `resolve <event_id> --status <handled|dead>`.
- `dept-ledger approval-open --kind-of <k> --summary <s> [--detail <d>]` —
  `--detail` обрезается до 4000 символов; если каталог правил читаем,
  пишет `policy_version_seen` (аудит: какая версия правил действовала в
  момент открытия).
- `dept-ledger approval-resolve <event_id> --status <approved|denied>` —
  идемпотентно: повтор того же статуса не создаёт новую запись, возвращает
  `{"deduped":true}`.
- `dept-ledger incident-open --about <worker> --severity <s> --summary <s>` —
  пишет `incident`; если в реестре есть роль `тп` — сразу шлёт ей `message`
  типа `incident` со ссылкой.
- `dept-ledger incident-resolve <event_id> --status <resolved|wontfix|
  duplicate> [--ref-main <event_id>]` — закрывает инцидент; `--ref-main` —
  ссылка на основной инцидент при `duplicate`.
- `dept-ledger policy-current` / `policy-ack --version vN` / `policy-check
  --worker <w>` — см. «Policy-refresh».
- `dept-ledger registry-set <worker> --role <r> [--client <c>]
  [--escalates-to <w>] [--mission-version <v>]` / `registry-get` /
  `registry-list` — роль валидируется (см. «Реестр ролей»).
- `dept-ledger snapshot` — см. «Snapshot».
- `dept-approve --kind-of <k> --summary <s> [--detail <d>]` — см.
  «dept-approve».

## Топология шины (`send`)

`dept-ledger send` резолвит роли `from`/`to` из `registry.json` и
блокирует, когда ОБЕ роли известны и нарушают топологию:

- **МК → МК запрещено** — падает с «прямое сообщение МК→МК запрещено
  (policy 3.1) — отправь question руководителю»; вопрос вне своей зоны МК
  шлёт `dept-head`.
- **Руководителю — только `question`/`proposal`** — остальные типы
  (`incident`, `handoff`) `send` отклоняет с подсказкой: `incident` —
  через `incident-open` (сам маршрутизирует на роль `тп`), `handoff` —
  адресату напрямую.

Если хотя бы одна роль не резолвится (воркер не в реестре) — проверка не
срабатывает, `send` пропускает сообщение.

## Policy-refresh (турникет правил)

Канон правил — `wiki/work/ai-dev/отдел/правила/policy-vN.md` в brain
(override `DEPT_POLICY_DIR`); действующая версия — файл с наибольшим `N`.

- `dept-ledger policy-current` — `{version, file}` действующей версии.
- `dept-ledger policy-ack --version vN [--actor <w>]` — подтверждение
  прочтения; версия ДОЛЖНА совпасть с действующей (иначе падает с прямой
  подсказкой перечитать файл и повторить). Пишет событие `policy_ack`.
- `dept-ledger policy-check --worker <w>` — проходит, только если у `<w>`
  есть `policy_ack` на действующую версию, сделанный ПОСЛЕ последнего
  изменения файла правил (по mtime) и не старше `DEPT_POLICY_ACK_TTL_HOURS`
  (дефолт 24ч). Любое несовпадение — падает с точной причиной и готовой
  командой на починку.

`dept-approve` вызывает `policy-check` перед КАЖДЫМ открытием approval —
без исключений (флага пропуска нет). Смена правил или протухший ack между
предыдущим прочтением и попыткой approve → approve отказывает, воркер
обязан перечитать правила и повторить `policy-ack`.

## dept-approve — worker-only

Идентичность берётся ТОЛЬКО из `CLAUDE_AUTO_NAME` (ставит супервизор
воркера при adopt). Флага `--actor` больше нет — раньше был (вместе с
дефолтом `actor="${CLAUDE_AUTO_NAME:-operator}"`), но это была лазейка:
любой вызов без `CLAUDE_AUTO_NAME` тихо становился «operator» и мог
подписаться чужим именем, обходя policy-турникет. Теперь без
`CLAUDE_AUTO_NAME` в env команда отказывает сразу («запускается только из
сессии воркера») — исключения для оператора/кого угодно не осталось.

Поток: `policy-check --worker "$actor"` (турникет) → `approval-open
--kind-of <k> --summary <s> [--detail <d>] --actor "$actor"` (запись в
ledger, `open`) → `claude-auto-request --action dept-approval --event-id
<id> --summary <s> [--detail <d>]` (карточка оператору в @RnR_Workers).
Если постановка запроса оператору не удалась — команда падает НЕ молча:
аппрув остаётся `open` в ledger, воркеру велено эскалировать через
`claude-auto-tg` и повторить (открытый и никем не увиденный approval —
главный failure mode гейта).

**Воркер сам `approval-resolve` больше не вызывает** (конвенция «воркер
резолвит после ответа» отменена вместе с фазой 1) — решение в ledger
записывает бот (см. ниже), воркер только ждёт инжект готового исхода и
действует по нему.

## dept-approval в @RnR_Workers (бот сам резолвит)

`bot/rnr_workers_bot.py` + `bot/rnr_db.py` — closed catalog approve-действий
бота (`ALLOWED_ACTIONS`). `dept-approval` — такой же action, как
`whitelist-add`/`mcp-add`/`one-time-send`; `arg_value` = `event_id` аппрува
в ledger.

Карточка (`render_approval`): «🔐 Запрос одобрения · воркер «N»» + «Аппрув
отдела: `<event_id>`» + `detail` цитатой (если передан); кнопки — общие
✅ Одобрить / ❌ Отклонить.

**Оба исхода бот пишет в ledger сам** (`exec_dept_resolve` →
`dept-ledger approval-resolve <event_id> --status approved|denied --actor
operator`, идемпотентно на стороне ledger) и инжектит воркеру готовый
исход:

- ОДОБРИЛ → «Оператор ОДОБРИЛ: … решение записано в журнал отдела —
  выполняй утверждённое».
- ОТКЛОНИЛ → «Оператор ОТКЛОНИЛ запрос: … Не повторяй; действуй иначе или
  эскалируй.»

Запись в ledger ретраится (`APPR_MAX_ATTEMPTS`); если так и не удалась —
на **approved** воркер получает исход «выполнить не удалось, эскалируй»,
а на **denied**, наоборот, воркер **не уведомляется вовсе** (иначе решил
бы, что отказ финальный, пока в ledger аппрув всё ещё `open`) — вместо
этого алерт оператору чинить руками. Реальный ledger-статус в обоих
случаях виден в dept-inbox — бот не «изображает» состояние перед воркером.

## dept-inbox — read-only веб-инбокс

`bin/dept-inbox` — zero-dep Node HTTP-сервер, слушает ТОЛЬКО
`127.0.0.1:8377` (override `DEPT_INBOX_PORT`; `DEPT_LEDGER_BIN` — путь к
бинарю `dept-ledger`). Наружу — через Angie-vhost с basic auth (детали
проброса/сертификата — server_docs). Только читает
`dept-ledger list/registry-list/policy-current` — мутаций нет, решения
остаются кнопками в Telegram.

- `GET /` — открытые approval (когда/от кого/тип/summary со ссылкой),
  открытые инциденты (severity/о ком/что), последние 50 событий,
  количество воркеров в реестре, действующая версия правил; автообновление
  раз в 60с (`<meta http-equiv=refresh>`).
- `GET /a/<event_id>` — карточка approval: summary, `from`/`kind_of`/
  возраст/статус, `detail` цитатой (или «детали не приложены»), полная
  история статусов.
- `GET /healthz` — `ok` (для мониторинга).

Ошибка чтения ledger — **видимый баннер**, не тихая пустота: если вызов
`dept-ledger` упал при сборе списка, инбокс не выглядит как «нет открытых
approval» (это читалось бы как «всё разрешено» — опасная ложь для
gate-страницы). Для конкретной карточки при ошибке чтения — тоже НЕ
«не найдено» (двусмысленно с «уже закрыт»), а отдельная страница «не
удалось прочитать журнал, состояние неизвестно». Ошибка собирается
per-request (не общий mutable), иначе параллельные запросы затирали бы
чужую ошибку. Ответ — `Content-Security-Policy: default-src 'none'; style-src
'unsafe-inline'`, `Cache-Control: no-store`, `X-Robots-Tag: noindex`.

## Snapshot

`dept-ledger snapshot` — git-коммит каталога `DEPT_HOME` (init при первом
вызове, коммит только если `git status --porcelain` не пуст, автор
фиксирован `dept-ledger <dept@local>`) — независимый от самого JSONL
аудиторский след на случай порчи ledger/registry. Таймер
`dept-ledger-snapshot.timer` (`OnBootSec=10min`, `OnUnitActiveSec=1h`)
гоняет его раз в час через `dept-ledger-snapshot.service` (oneshot).

## Реестр ролей ≠ autonomous.json

`autonomous.json` — источник истины **запуска** (`state`, `cwd`,
`session_id`, `brain_path`), им управляет `claude-auto adopt/stop/start`.
`department/registry.json` — только **роли отдела** (`role`, `client`,
`escalates_to`, `mission_version`), пишется исключительно через
`registry-set` (RMW под тем же локом, что и аудит-событие
`registry_change`). **Синка между файлами нет и в фазе 2**: воркер может
быть active в одном и отсутствовать в другом — актуализация реестра под
фактический флот делается вручную (оператором) при онбординге/выводе
воркера.

`registry-set` валидирует `role` ∈ `руководитель, мк, архивариус, тп,
legacy` (иначе падает); роль `мк` требует `--client`. `mission_version` —
свободная строка (`v1`/`v2` — фактическая конвенция канона, не enum,
CLI её не проверяет).

## Штат отдела и пилот МК

Онбординг воркера отдела — операторская операция: `/go-autonomous` умеет
поднять только ТЕКУЩУЮ сессию (adopt наследует её cwd), автоматический
`claude-auto spawn` — фаза 3. Полный runbook (роли/рамки allow-deny/пробы/
смок по каждому типу воркера, включая критичный нюанс с анкором `//` для
абсолютных путей в файловых правилах) — `docs/department-onboarding.md`.

- **Штаб** (`mission_version: v2`, проба `dept-bus` = `ledger-messages
  --worker <имя>`): `dept-head` (руководитель, cwd `~/brain`, шину
  обрабатывает, файлы не пишет), `dept-archivist` (архивариус, cwd
  `~/brain`, единственный писатель БЗ sales-assistant + правил отдела +
  тп-знаний, публикация — только через `dept-approve --kind-of
  kb_change`), `dept-tp` (тп, cwd `~/server`, обращения — только
  `incident` из шины: Asana-задача → диагностика → чинит баг сам или
  approve на архитектурное изменение → `incident-resolve`).
- **Пилот МК** (`mission_version: v2`, пробы старые + `dept-bus`, cwd —
  папка клиента в brain): `prodmash`, `elektronika-deal`, `vam-mebel-deal`,
  `legion2`. Связь МК с ОПЕРАТОРОМ — напрямую бот-каналом
  (`claude-auto-ask`/`claude-auto-tg`, отчёты в @RnR_Workers), БЕЗ
  `dept-approve`: гейт нужен только для исходящих людям клиента.
  `diaverum-russ` остаётся `мк`/`v1`, в пилот не входит и не мигрирован.
- Остальные активные воркеры — `legacy` в реестре (вне отдела, миграция —
  фаза 2-3+).

## Адаптер `ledger-messages`

Контракт event-bridge проб: одна детерминированная строка на новое событие
в stdout, exit 0, дедуп — на стороне bridge. `ledger-messages --worker
<name>` эмитит `queued`-сообщения на воркера, каждое строкой со скрытым
маркером `\x1eebid=<event_id>\x1e` (control-char, ключ дедупа bridge).
Сообщение исчезает из выдачи после `dept-ledger ack <event_id>` — состояние
живёт в ledger, не в state-файле пробы (`--state-dir` принимается, но
игнорируется). Подключается как проба `dept-bus` в `probes.json` воркера
(см. «Штат отдела» — так подключены все штабные и пилотные МК).

## Liveness-watchdog

`claude-auto-liveness.timer` (каждые 5 мин) гоняет `bin/claude-auto-liveness`
по всем `state == active` из `autonomous.json`. hung = busy-маркер на
экране + неизменный screen-hash + не двигающийся транскрипт дольше
`LIVENESS_HUNG_MIN` (30 мин). Лестница (`decide()`, юнит-тестируется
отдельно): `none → alert → restart → incident`; повторный hang в пределах
`LIVENESS_REINCIDENT_MIN` (60 мин) после рестарта сразу даёт incident.

**`LIVENESS_ENFORCE=1`** — выключатель действий. Без него (дефолт, и в
фазе 2 остаётся дефолтом) — alert-only: на шагах restart/incident шлётся
разовый `[would-restart]`/`[would-incident]`, но `systemctl restart` /
`incident-open` не вызываются. С флагом — лестница исполняется
по-настоящему. State — `department/watchdog-state.json`; `--dry-run` —
только печать решений.

## Пути рантайма

| Что | Путь |
|---|---|
| Ledger | `~/.claude-control/department/events.jsonl` |
| Реестр ролей | `~/.claude-control/department/registry.json` |
| Liveness state | `~/.claude-control/department/watchdog-state.json` |
| Autonomous SoT | `~/.claude-control/autonomous.json` |
| Каталог правил (policy) | `~/brain/wiki/work/ai-dev/отдел/правила/` (override `DEPT_POLICY_DIR`) |

## Связанное

- Дизайн (16 решений): `~/brain/docs/superpowers/specs/2026-07-09-digital-department-design.md`
- Канон отдела: `~/brain/wiki/work/ai-dev/отдел/CLAUDE.md`
- Онбординг воркеров: `docs/department-onboarding.md`
- Autonomous-слой: `docs/autonomous.md`
