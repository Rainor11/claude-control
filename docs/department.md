# Цифровой отдел — ядро (dept-ledger, dept-approve, заявки, dept-dispatcher, dept-inbox, liveness)

Субстрат «Цифрового отдела» — организация ролевых воркеров поверх
autonomous-слоя (`docs/autonomous.md`; там же — headless-механика
`spawn`/`rebase`/`mission-update`/`sleep`, на которую опираются заявки и
диспетчер). Канон отдела (роли, policy, дизайн) живёт в brain, не здесь —
см. «Связанное». Актуально на 2026-07-19 (фаза 4).

## Ledger

`~/.claude-control/department/events.jsonl` — append-only JSONL, единственный
писатель `bin/dept-ledger` (lockfile, живёт ≤10с на запись). Путь резолвится
по профилю `dept_only` (`lib/runtime-root.sh`): override `DEPT_HOME`, иначе
`<CONTROL_DIR>/department` — но это НЕ единый override для всего отдела,
другие части (`dept-inbox`, `dept-dispatcher`, `claude-auto-liveness`,
`dept-rebase-check`) резолвят корень отдельным профилем
(`auto_then_hardcoded` — override `CLAUDE_AUTO_HOME`, иначе фиксированный
боевой путь), `DEPT_HOME` на них не влияет. Полная таблица профилей —
`lib/runtime-root.sh`. Конверт: `{v, event_id, seq, ts, actor, kind, data}`.
`kind` ∈ `message, message_status, approval, approval_status, incident,
incident_status, agent_run, registry_change, policy_ack`. Статусные
`*_status` ссылаются на исходное событие через `data.ref = event_id` — сам
ledger неизменяем, эффективный статус выводится сверху (`effectiveStatus`).
`message.type` ∈ `question, proposal, incident, handoff,
kb_change_request, decision_request, policy_refresh` (последний — фаза 4,
рассылка планёрки, см. «Policy-refresh» и «Заявки руководителя»);
`message_status.status` ∈ `acked, handled, dead`; `approval_status.status`
∈ `approved, denied, executing, executed, exec_failed, withdrawn`
(`withdrawn` — фаза 4, пишет только `approval-withdraw`, см.
«dept-withdraw»). `executing` — промежуточный статус исполнения заявки
(диспетчер помечает ДО запуска раннера, дедуп повторного запуска);
`executed`/`exec_failed` — финал, который пишет `dept-exec-runner`.
`executing`/`executed`/`exec_failed`/`withdrawn` блокируют
`approval-resolve` («менять решение поздно» / «заявка отозвана автором —
решать нечего»).

## Команды

- `dept-ledger append --kind <k> --data '<json>'` — низкоуровневая запись.
- `dept-ledger list [--kind <k>] [--event-id <id>] [--filter k=v ...]
  [--status <s>] [--limit N]` — `--event-id` даёт точечное чтение одной
  записи (так карточки читает dept-inbox — не полный список).
- `dept-ledger send --type <question|proposal|incident|handoff|
  kb_change_request|decision_request|policy_refresh> --to <worker>
  --subject <s> [--body <b>] [--refs a,b] [--actor <w>]` — сахар над
  `append --kind message` (статус сразу `queued`); валидирует топологию
  отправителя/адресата (см. «Топология шины»); `policy_refresh` —
  дополнительно anti-forge гард на отправителя (см. там же).
- `dept-ledger ack <event_id>` / `resolve <event_id> --status <handled|dead>`.
- `dept-ledger approval-open --kind-of <k> --summary <s> [--detail <d>]
  [--request-json '<obj>']` — `--detail` обрезается до 20000 символов
  (22000 для `mission_change` — полный текст миссии не должен резаться);
  `--request-json` — исполняемые данные заявки (JSON-объект, ≤8000 байт,
  ≤22000 для `mission_change`; капы синхронны с detail — anti-forge-рендер
  исполнителя обязан совпасть байт-в-байт). Если каталог правил читаем,
  пишет `policy_version_seen` (аудит: какая версия правил действовала в
  момент открытия).
- `dept-ledger approval-resolve <event_id> --status <approved|denied>` —
  идемпотентно: повтор того же статуса не создаёт новую запись, возвращает
  `{"deduped":true}`. На заявке в `executing`/`executed`/`exec_failed` —
  отказ («менять решение поздно»); на `withdrawn` — отказ («заявка отозвана
  автором — решать нечего», защита от гонки withdraw ↔ ✅, см.
  «dept-withdraw»).
- `dept-ledger approval-exec <event_id> --status <executing|executed|
  exec_failed> [--note <s>]` — переходы исполнения: `executing` только из
  `approved`; `executed`/`exec_failed` — из `executing` (раннер) или
  напрямую из `approved` (операторский ручной путь, back-compat).
  Идемпотентен (повтор того же статуса → `{"deduped":true}` — на этом
  держится дедуп диспетчера); /proc-гард — из сессии воркера не вызывается.
  Базу ищет и в архивах ротации.
- `dept-ledger approval-withdraw <event_id> [--reason '<s>']` — отзыв СВОЕЙ
  открытой заявки автором (фаза 4); пишет `withdrawn`. Гард ИНВЕРСНЫЙ к
  остальным привилегированным командам: вызывается ТОЛЬКО из сессии
  воркера и только автором заявки (`data.from`), не оператором/раннером —
  у оператора для этого кнопка ❌ на карточке. Идемпотентен (повтор своим
  же вызовом → `{"deduped":true}`). Низкоуровневая; штатно вызывается
  через обёртку `dept-withdraw` (см. «dept-withdraw»), которая сперва
  гасит карточку у бота.
- `dept-ledger rotate [--days N]` — ротация журнала, см. «Snapshot и
  ротация».
- `dept-ledger incident-open --about <worker> --severity <s> --summary <s>` —
  пишет `incident`; если в реестре есть роль `тп` — сразу шлёт ей `message`
  типа `incident` со ссылкой.
- `dept-ledger incident-resolve <event_id> --status <resolved|wontfix|
  duplicate> [--ref-main <event_id>]` — закрывает инцидент; при `duplicate`
  `--ref-main` ОБЯЗАТЕЛЕН и должен указывать на существующее событие kind
  `incident` (иначе падает); с остальными статусами `--ref-main` запрещён.
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
- **Руководителю — только `question`/`proposal`/`decision_request`/
  `policy_refresh`** — остальные типы (`incident`, `handoff`) `send`
  отклоняет с подсказкой: `incident` — через `incident-open` (сам
  маршрутизирует на роль `тп`), `handoff` — адресату напрямую.
  `policy_refresh` включён в исключение фазой 4 — Руководитель перечитывает
  правила наравне со всеми (см. «Заявки руководителя» → «Планёрка»).
- **`policy_refresh` — отправитель ограничен** (фаза 4, anti-forge): если
  вызов реально идёт из сессии воркера (`/proc`-детект), отправитель обязан
  быть роли `руководитель`, а `--actor`, если задан, обязан совпасть с
  реальным именем вызывающего — подделать `policy_refresh` за Руководителя
  нельзя. Раннер планёрки (`dept-planerka-exec`, вызывается из
  systemd-юнита, не из сессии воркера) под этот гард не попадает.
- **`kb_change_request` — только роли `архивариус`** (dept-archivist;
  policy 3.4) — иным адресатам `send` отклоняет.
- **`decision_request` — только роли `руководитель`** (dept-head) — иным
  адресатам `send` отклоняет.

Если хотя бы одна роль не резолвится (воркер не в реестре) — проверка не
срабатывает, `send` пропускает сообщение.

## Policy-refresh (турникет правил)

Канон правил — `wiki/work/ai-dev/отдел/правила/policy-vN.md` в brain
(override `DEPT_POLICY_DIR`); **действующая версия = файл с наибольшим
`vN` в каталоге** (на 19.07 — v9), фиксированный номер здесь не
поддерживается — смотри каталог. История версий — в changelog-frontmatter
самого файла правил (v5 — role_change как 4-я база Архивариуса + граница
«внутреннего коллеги» + уточнение §3.1; v6 — формат сообщений оператору,
п. 3.7; v7 — п. 4.7 «кастом-проект нормальным роадмапом»; v8 — квалификация
кастома в п. 4.7; v9, фаза 4 — планёрка стала рассылкой `policy_refresh`
вместо пересборки сессий (п. 8.3), новый п. 1.5 «нечего фиксировать —
строка в timeline», новый п. 8.5 — контроль ack'ов Руководителем через
датчик ack-drift).

- `dept-ledger policy-current` — `{version, file}` действующей версии.
- `dept-ledger policy-ack --version vN [--actor <w>]` — подтверждение
  прочтения; версия ДОЛЖНА совпасть с действующей (иначе падает с прямой
  подсказкой перечитать файл и повторить). Пишет событие `policy_ack`.
  `--actor` за другого воркера из сессии воркера запрещён (фаза 4,
  anti-forge: тот же `/proc`-гард, что у `policy_refresh`-отправителя и
  `dept-withdraw`) — ack пишет тот, кто реально прочитал правила, иначе
  можно было бы погасить датчик `ack-drift` за молчащего коллегу. Раннер/
  оператор/self-ack (без `--actor` или `--actor` = себе) свободны.
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

Идентичность — spoof-resistant `resolve_name()` (дословная копия функции
из `claude-auto-request`): подъём по `/proc`-предкам до процесса с
`--resume` в cmdline и exe внутри доверенного `CLAUDE_INSTALL`, оттуда
читается `CLAUDE_AUTO_NAME` из ЕГО СОБСТВЕННОГО `/proc/<pid>/environ`.
Флага `--actor` нет — раньше идентичность бралась из env `CLAUDE_AUTO_NAME`
ТЕКУЩЕГО процесса, а это была лазейка: `CLAUDE_AUTO_NAME=чужое dept-approve
…` подписывался чужим именем, обходя policy-турникет. Теперь подмена
переменной в своём окружении ничего не даёт — читается env предка, не
текущего процесса. Без подходящего предка (не сессия воркера) команда
отказывает сразу («запускается только из сессии воркера»);
`DEPT_APPROVE_TEST_ACTOR` — bypass только для тестов (боевые рамки его не
выставляют).

Поток: `policy-check --worker "$actor"` (турникет) → `approval-open
--kind-of <k> --summary <s> [--detail <d>] [--request-json <j>] --actor
"$actor"` (запись в ledger, `open`; `--summary` пре-валидируется ≤400
символов ДО записи — иначе orphan-open аппрув) → `claude-auto-request
--action dept-approval --event-id <id> --summary <s> [--detail <d>]`
(карточка оператору в @RnR_Workers; `request` дальше НЕ передаётся —
карточка строится из detail). `kind_of` — свободная строка: гейт общий
для `kb_change`, `role_change`, исходящих и заявок руководителя
(`worker_spawn`/`mission_change`/`planerka`/`sleep` — см. «Заявки
руководителя»); из них диспетчер исполняет ТОЛЬКО четыре последних. Пятый
исполняемый kind_of — `liveness_restart` — идёт МИМО `dept-approve`
(подающий не сессия воркера — см. «Liveness-watchdog»).
`claude-auto-request` этим `--summary`/`--detail` не доверяет буквально —
карточка строится из КАНОНИЧЕСКОЙ записи в ledger по `event_id`
(`dept-ledger list --kind approval --status open`); расхождение с тем, что
передал вызывающий, — warning в stderr, побеждает всегда ledger. Это
анти-forge: бот резолвит именно по `event_id`, а не по тексту карточки, так
что вызывающий не может показать оператору одно, а зарезолвить другое.
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
✅ Одобрить / ❌ Отклонить. Без «дубля» summary/detail (фидбэк 16.07):
если первая строка detail совпадает с summary (trim, case-insensitive) —
summary-префикс в payload не дублируется, уходит только detail.

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

Решение по dept-approval-карточке оператор принимает ТОЛЬКО кнопкой в
@RnR_Workers (или отзывом автором через `dept-withdraw`, см. ниже): прямой
`dept-ledger approval-resolve` в обход бота пишет исход в ledger, но не
гасит карточку в SQLite бота (`rnr_db.py`) — карточка и ledger рассинхронизируются,
и оператор может повторно нажать кнопку на уже «решённой» вне бота заявке.

## Заявки руководителя (worker_spawn / mission_change / planerka / sleep)

Worker-only обёртки (идентичность — тот же spoof-resistant `resolve_name`,
роль обязана быть «руководитель», policy-турникет перед открытием):

- `dept-spawn-request --client <slug> --name <mk-имя> --asana-gid <GID>
  [--asana-url <url>] [--note '<s>']` — найм нового МК (kind_of
  `worker_spawn`). Отказывает, если имя воркера уже занято.
- `dept-mission-request --worker <w> --reason '<s>'` — смена миссии
  (kind_of `mission_change`); полный новый текст миссии — на stdin
  (≤16000 симв.).
- `dept-planerka-request --reason '<s>'` — плановая рассылка правил
  активным воркерам (kind_of `planerka`); **сессии НЕ пересобирает** (фаза
  4, решение оператора 17.07 — см. «Планёрка» ниже).
- `dept-sleep-request --worker <w> --reason '<s>'` — усыпить МК (kind_of
  `sleep`).

Поток: обёртка строит `request_json` и рендерит `detail` ТОЛЬКО через
`dept-request-render <kind_of> '<json>'` (единственный источник
форматирования) → `dept-approve --kind-of <k> --request-json …` → карточка
оператору → ✅ → `dept-dispatcher` помечает `executing` и запускает
`dept-exec-runner` в отдельном юните → исполнитель `dept-*-exec` →
`executed`/`exec_failed`.

**Anti-forge — три забора** (Codex-аудит К3/К4): (1) /proc-гард в
`dept-ledger` — воркер не может сам записать `approval_status approved`;
(2) ролевой фильтр диспетчера — исполняются только заявки от
руководителя/operator; (3) исполнитель перед работой рендерит detail
ЗАНОВО из `data.request` тем же `dept-request-render` и сверяет
байт-в-байт с `data.detail` из ledger — расхождение = «заявка подделана
или повреждена», exit 1 до любых побочных эффектов.

**Исполнители идемпотентны** (повторный `--approval` после hard-kill
безопасен): `dept-spawn-exec` — каждый шаг «уже сделано → пропустить»
(скелет папки клиента в brain из `_template.md` + timeline/decisions —
только если папки нет; рендер миссии из `examples/department/
mk-mission.template.md` в `$DEPT_HOME/missions/<name>.md` + bounds/probes/
kickoff в `$DEPT_HOME/render/`; `claude-auto spawn`; `registry-set --role
мк --client <slug> --mission-version v3`); `dept-mission-exec` →
`claude-auto mission-update`; `dept-sleep-exec` — уже спящий → no-op;
`dept-planerka-exec` — повторная рассылка безвредна (воркер, получивший
второй `policy_refresh`, просто перечитает правила ещё раз —
`policy-ack` идемпотентен по версии).

**Планёрка** (`dept-planerka-exec`, фаза 4 — переписана целиком по решению
оператора 17.07): **рассылка правил, не пересборка флота.** Было (фазы
2-3): `claude-auto rebase` всего активного флота — у МК с живым
клиентским контекстом это упиралось в STALE-гард (🔴-сегмент «ошибки,
разберись» на каждой планёрке — штатная защита читалась как сбой), а
успешный rebase сбрасывал контекст живого обсуждения ради перечитывания
правил. Стало: типизированное сообщение шины `policy_refresh` «перечитай
policy-vN + ack» каждому активному воркеру отдела (роль ∈ руководитель/
мк/архивариус/тп); сессии не трогаются. Спящие пропускаются (не будятся) —
догоняют турникетом (`policy-check`) при первом `dept-approve` после
пробуждения. Rebase остаётся ТОЛЬКО гигиене (`dept-rebase-check`:
возраст/компакции) и `mission-update`. Отправитель рассылки — Руководитель
(даже прямой `--reason` оператора уходит от его имени — он же трекает
ack'и через датчик `ack-drift`, см. ниже). Частичная доставка — НЕ
успех: exit 1 → раннер пишет `exec_failed` и шлёт 🔴 «НЕ исполнено» (не
молчаливая сводка с ошибкой внутри текста); полный повтор идемпотентен
(см. выше). Busy-воркеров отдельно не обрабатывает — доставку берёт на
себя `event-bridge-watch` адресата (backoff/карантин).

**role_change** (16.07, статус подтверждён 17.07 — см. ниже): карточки
ролей `отдел/роли/*.md` — 4-я писательская база Архивариуса, правки
СТРОГО через `dept-approve --kind-of role_change` (дифф на карточке → ✅
оператора → применяет САМ Архивариус). Диспетчер `role_change` намеренно
НЕ исполняет (нет в `EXEC_KINDS`) — гейт процедурный, уровень enforcement
тот же, что у `kb_change`. Состав ролей, структура отдела, спека —
Оракул (запросы — оператору).

**Механический гейт `role_change` рассмотрен и СНЯТ со скоупа фазы 4**
(решение оператора 17.07 — фиксируется явно, чтобы не всплывало снова).
Аргумент: механический замок (`/proc`-гард вида approval-resolve) пишет
тот же ИИ, что и обходимый им сценарий — ошибка переезжает, а не
исчезает. Класс риска у `role_change` другой, чем у настоящих замков
(anti-forge на `approval-resolve`/`policy_refresh`-отправителе,
`assertNotWorkerSession` на privileged `append`/`registry-set`): те стоят
против **эскалации прав**, а `role_change` — воркер правит текстовый файл,
который ему и так разрешено читать/писать; новых прав он не получает,
дифф оператор видит на карточке ДО применения, расхождение с фактом ловит
`git diff` в snapshot постфактум. Подтверждено фактами фазы 3: защитные
механизмы сами породили 3 инцидента (detached-раннер убил первый боевой
найм, dry-run диспетчера съедал событие пробуждения, STALE-гард давал
100% ложных срабатываний) — новый механический замок на процедурном гейте
имел бы тот же профиль риска. Единственный боевой `role_change` (16.07)
прошёл чисто; однотипный `kb_change` отработал многократно без промаха.

## Датчик ack-drift (Руководитель, фаза 4)

Раз рассылка `policy_refresh` не пересобирает сессии, кто-то должен
отдельно следить, что молчуны действительно перечитали правила — это
`channels/event-bridge/adapters/ledger-policy-drift`, проба `ack-drift`
у Руководителя (`probes.json`, `interval_sec: 600`).

Контракт адаптера — детерминированная строка на состояние, дедуп на
стороне `event-bridge-watch` (по хэшу видимой строки). Отсюда ключевое
решение: **строка НЕ содержит ни имён молчунов, ни их счётчика** — иначе
каждый прилетевший ack менял бы строку → новый хэш → повторный инжект, и
Руководитель получал бы до N-1 нуджей на одну рассылку. Строка = (версия
правил, бакет времени) → максимум **3 нуджа на версию**: через 30 минут,
6 часов и сутки после публикации версии (mtime файла правил). Имена
молчунов Руководитель добывает сам (`registry-list` + `policy-check
--worker <имя>` по каждой роли отдела) — это и есть его работа по
контролю (policy 8.5).

Дрейф = версия ack ≠ действующей ИЛИ ack старше mtime файла правил — **не
TTL** (TTL 24ч — отдельный ленивый энфорсмент турникета на `dept-approve`,
к планёрке отношения не имеет: датчик на TTL флагал бы весь флот
ежедневно, включая тех, кто ack'нул действующую версию). Молчуном
считается **только активный** воркер (роль ∈ руководитель/мк/архивариус/
тп, `autonomous.json` state=`active`) — спящий не подтвердит никогда,
рассылка его намеренно пропускает (см. «Планёрка»), правила он догонит
турникетом при пробуждении.

## dept-withdraw — отзыв заявки автором (фаза 4)

`bin/dept-withdraw --event-id <evt_...> --reason '<s>'` — воркер отзывает
СВОЮ открытую заявку (кейс: оператор решил вопрос напрямую в сессии,
заявка утратила смысл). Кнопка ❌ технически сработала бы, но врёт
семантически: воркер получил бы «ОТКЛОНИЛ» и скорректировал бы поведение,
хотя решение просто стало неактуально. Идентичность — тот же
spoof-resistant `resolve_name`, что у `dept-approve`; авторизация
ИНВЕРСНАЯ: только из сессии воркера и **только автору** заявки
(`data.from`), не оператору/раннеру.

Порядок шагов фиксирован (защита от гонки withdraw ↔ нажатие ✅):
(1) гасим карточку у бота — `rnr_db.py claim_withdraw`, атомарный claim по
`status='open'`, keyed по `event_id`; (2) только потом пишем `withdrawn` в
`dept-ledger approval-withdraw`. Шаг 1 fail-closed: без погашенной
карточки в журнал ничего не пишется. Обратный порядок дал бы окно «ledger
withdrawn + карточка ещё живая» → оператор жмёт ✅ → бот пишет `approved`
→ last-write-wins → воркер исполняет отозванное; `approval-resolve` и
`approval-exec` дополнительно отказывают на эффективном статусе
`withdrawn` вторым ремнём той же гонки. Оба шага идемпотентны — повтор той
же командой после сбоя между шагами безопасен.

Бот гасит карточку меткой «🚫 Отозвано автором». `withdrawn` — финальный
статус approval: рассылка `send`, `dept-inbox`, `rotate` (см. «Snapshot и
ротация») учитывают его наравне с `denied`/`executed`/`exec_failed`.

## dept-dispatcher — контурный диспетчер

`bin/dept-dispatcher tick [--dry-run]` под `dept-dispatcher.timer`
(каждые 2 мин, `OnBootSec=3min`; env-оверрайды — `~/.config/
claude-control/env`). Best-effort lock (`dispatcher.lock`, протухание
20 мин), timeout на каждый подпроцесс, `--dry-run` строго read-only.
Четыре обязанности:

1. **Пробы спящих контуров** (`autonomous.json` state=`sleeping`): гоняет
   пробы из `event-bridge.config.json` воркера с их же интервалами
   (свой lastrun `.dispatcher-lastrun-<probe>`), НЕ трогая `.seen`/`.dead`
   — на новое необработанное событие `claude-auto start` (wake, один на
   воркера за тик) + `agent_run wake` + TG «🌅 контур разбужен». Доставку
   события делает штатный `event-bridge-watch` проснувшегося воркера
   (адаптеры детерминированно перепечатают неподтверждённое).
2. **Исполнение утверждённых заявок**: `list --kind approval --status
   approved` → `pickExecutable` (kind_of ∈ EXEC_KINDS И from —
   руководитель/operator; ИСКЛЮЧЕНИЕ — `liveness_restart` исполняется
   ТОЛЬКО если `from === 'watchdog'`, см. «Liveness-watchdog») → пометить
   `executing` (дедуп в ledger: второй
   тик/прогон получает `{deduped:true}` и пропускает) → запустить
   `dept-exec-runner` в СОБСТВЕННОМ transient-юните `systemd-run --user
   --collect --unit=dept-runner-<event_id>` — тик НЕ ждёт исполнения.
   P3-CRITICAL-2 (16.07, первый боевой найм): detached-ребёнок умирал от
   cgroup-зачистки oneshot-тика (KillMode=control-group) — потому
   отдельный юнит; журнал раннера — `journalctl --user -u
   'dept-runner-*'`, занятое имя юнита = доп. слой дедупа. systemd-run не
   наследует env — прокидывается whitelist (`--setenv`): PATH, DEPT_HOME,
   DEPT_POLICY_DIR, CLAUDE_CONTROL_DIR, BRAIN_CLIENTS, TELEGRAM_NOTIFY,
   DEPT_EXEC_RUNNER_TIMEOUT_MS. **Recovery:** заявка в `executing` дольше
   `DEPT_EXEC_MAX_MIN` (20 мин; держать ≥ таймаута раннера) — алерт
   оператору с человеческой меткой (summary + автор заявки, не голый
   event_id — фидбэк 16.07), БЕЗ авто-рестарта; дедуп алерта —
   маркер-файл `exec-stuck-<event_id>` в DEPT_HOME.
3. **Детект неактивности МК**: роль `мк` + state `active`, якорь
   активности = max(mtime транскрипта, последнее ledger-событие);
   `idle ≥ DEPT_SLEEP_IDLE_DAYS` (7) и нет открытых approval/queued/STALE
   → `decision_request` Руководителю («предложи усыпить или обоснуй»,
   дедуп на эпизод в `sleep-check-state.json`); с `DEPT_SLEEP_AUTO=1` —
   сразу `claude-auto sleep` + `agent_run auto_sleep`.
4. **Напоминание о зависших open-заявках** (фаза 4): `list --kind approval
   --status open` старше `DEPT_OPEN_APPROVAL_REMIND_MIN` (дефолт 240 мин)
   → «⏳ заявка висит без решения — реши кнопкой или попроси автора
   отозвать (`dept-withdraw`)» с человеческой меткой (summary + автор, не
   голый `event_id`). Один пинг на эпизод — состояние JSON-файл
   (`open-approval-reminders.json`) с уборкой закрытых записей КАЖДЫЙ тик
   (не маркер-файлы, как у `exec-stuck-*` — тот подход копится вечно, см.
   ниже «rotate»). Фильтр общий по kind_of — карточки `liveness_restart`
   сторожа попадают под то же напоминание, если оператор не решил кнопкой.

`dept-exec-runner --approval <id> --executor <path>`: whitelist
исполнителей (basename ∈ dept-{spawn,mission,planerka,sleep,liveness}-exec
И каталог = каталог раннера), исполняет под `timeout` (числовая защита
`DEPT_EXEC_RUNNER_TIMEOUT_MS`, дефолт 900000 мс, мусор/0 → дефолт;
`--kill-after=10s`), сам пишет финал `approval-exec executed/exec_failed`
НЕЗАВИСИМО от диспетчера, лог — `$DEPT_HOME/runner-<event_id>.log`.
TG-алерты исхода («✅ Исполнено» / «🔴 НЕ исполнено» / «🚨 финал не
записан — зависнет в executing») — с человеческой меткой из ledger.

## dept-rebase-check — автопороги пересборки сессий

`bin/dept-rebase-check [--dry-run]` под `dept-rebase-check.timer` (раз в
час, `OnBootSec=15min`). Проходит воркеров отдела (роль ∈ руководитель/
мк/архивариус/тп, state=`active`) и считает триггеры: возраст сессии ≥
`DEPT_REBASE_MAX_AGE_DAYS` (14 дн), компакций ≥
`DEPT_REBASE_MAX_COMPACTIONS` (3, по `state/compactions`), STALE-память.
Свежесть памяти — через `bin/dept-memory-freshness` (см. ниже), не
собственная эвристика.

**Семантика STALE — модификатор порога, а не самостоятельный триггер**
(фаза 4, `decide()`, юнит-тестируется отдельно): нет порога (возраст/
компакции) → `none`, молчим — даже если память формально STALE (воркеру
может быть нечего фиксировать, и вечный STALE не должен вечно жить в
эпизод-стейте). Порог есть И память STALE → `stale_alert`: rebase
запрещён (стёр бы контекст, которого нет в файлах — `ENFORCE` это НЕ
обходит, инвариант курируемой памяти policy 1.1 сильнее автопорога),
вместо этого код шлёт воркеру `question` по шине с просьбой докурировать
(манифест/timeline/decisions) — «автодокурация», а не только алерт
оператору. Порог есть И память свежая → `rebase`: **без
`DEPT_REBASE_ENFORCE=1`** (текущий режим, обкатка) — только
`[would-rebase]`-алерт; с флагом — реально вызывает `claude-auto rebase
<name>`. Эпизод-дедуп (`rebase-check-state.json`) различает фазы
`stale_alerted`/`rebase_alerted` — докурированная память (stale→false) с
ещё активным порогом возраста получает свежий `rebase`-алерт, а не
молчит по старому `stale_alerted` чужой фазы; эпизод сбрасывается при
уходе воркера из active. Битый реестр — алерт, не тихое падение.

**`bin/dept-memory-freshness`** — единственный источник истины о свежести
памяти клиента (фаза 4; было — 4 разошедшиеся копии эвристики в
`claude-auto status_memory`/`cmd_rebase`/`dept-rebase-check`/
`dept-dispatcher`, ни одна не видела манифест клиента и трек-файлы
многотрековой схемы). Две функции: `memoryFreshnessFromTx(brainPath,
txMtimeMs, staleAfterMs)` — ядро (сравнивает mtime самого свежего файла
памяти с mtime транскрипта); `memoryFreshness(brainPath, sessionId,
staleAfterMs)` — обёртка, сама ищет транскрипт по `sessionId` в
`~/.claude/projects`. `dept-dispatcher` использует ядро напрямую (у него
уже есть `txMtime`, подстановка `sessionId` туда дала бы вечный `fresh` —
STALE-гард авто-сна отключился бы молча). Файлы памяти — глоб `CLAUDE.md,
timeline*, decisions*, open-questions*, открытые-вопросы*` в
`brain_path` клиента (каталоги с такими именами не считаются — только
файлы).

## dept-inbox — read-only веб-дашборд «Офис»

`bin/dept-inbox` — zero-dep Node HTTP-сервер (http-роутинг + `dl()` +
сборщики данных), слушает ТОЛЬКО `127.0.0.1:8377` (override
`DEPT_INBOX_PORT`; `DEPT_LEDGER_BIN` — путь к бинарю `dept-ledger`;
`DEPT_INBOX_EXEC_TIMEOUT_MS` — timeout на `execFile` подпроцессов, дефолт
15000, читается заново при каждом вызове). Наружу — `https://dept.alp-ai.ru`
(vhost с basic auth; детали проброса/сертификата — server_docs). Весь HTML — в
`bin/dept-inbox-render.js` (чистые data→html функции, дизайн по скиллу
dataviz: CSS-переменные light+dark, карточки-воркеры, meter, inline-SVG
sparkline). Только читает `dept-ledger list/registry-list/policy-current`,
`autonomous.json`, `workers/<w>/{state/context.json,state/compactions,
event-bridge.config.json}`, `systemctl --user is-active` — мутаций нет,
решения остаются кнопками в Telegram.

- `GET /` — «Офис»: сводная строка (правила/открытые аппрувы/инциденты/
  спящие) + сетка карточек воркеров отдела (роль ∈ {руководитель, мк,
  архивариус, тп}: аватар, статус-бейджик 🔴/⏳/😴/⛔/🟢, поле «Миссия» =
  `mission_version` из реестра (поколение миссии; версию ПРАВИЛ показывают
  шапка и Policy-ack — лейбл переименован 16.07, чтобы не сталкивать оси),
  policy-ack, контекст-meter, компакции, последняя активность, датчики) +
  компакт-счётчик legacy-контуров (без карточек).
- `GET /approvals` — открытые approval + открытые инциденты + исполнение
  заявок (executed/exec_failed за 7 дней) + последние 50 событий; ссылки на
  каждую карточку.
- `GET /a/<event_id>` — карточка approval: summary, `from`/`kind_of`/
  возраст/статус, блок «Заявка (исполняемые данные)» из `data.request`
  (если есть — оператор видит РОВНО то, что исполнит диспетчер), `detail`
  цитатой (или «детали не приложены»), полная история статусов. Читается
  через `dept-ledger list --kind approval --event-id <id>` (не полный список).
- `GET /w/<name>` — таймлайн воркера: шапка-карточка + последние 100
  событий ledger, где воркер — actor/to/from/worker/about_worker.
- `GET /incidents` — открытые инциденты + закрытые за 14 дней.
- `GET /activity` — «бюджеты» v1 (активность-прокси, НЕ токены): события/
  компакции/wake·rebase·spawn за 7 дней + sparkline по дням за 14 дней.
- `GET /healthz` — `ok` (для мониторинга).

Ошибка чтения ledger — **видимый баннер**, не тихая пустота: если вызов
`dept-ledger` упал при сборе списка, страница не выглядит как «нет открытых
approval» (это читалось бы как «всё разрешено» — опасная ложь для
gate-страницы). Для конкретной карточки при ошибке чтения — тоже НЕ
«не найдено» (двусмысленно с «уже закрыт»), а отдельная страница «не
удалось прочитать журнал, состояние неизвестно». Ошибка собирается
per-request (не общий mutable), иначе параллельные запросы затирали бы
чужую ошибку; в HTML попадает только generic-текст («журнал недоступен —
см. лог сервиса» / «N строк пропущено при разборе»), полные детали
(stderr/ENOENT) — только в `console.error` (journald). Ответ —
`Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'`,
`Cache-Control: no-store`, `X-Robots-Tag: noindex`.

## Snapshot и ротация

`dept-ledger snapshot` — git-коммит каталога `DEPT_HOME` (init при первом
вызове, коммит только если `git status --porcelain` не пуст, автор
фиксирован `dept-ledger <dept@local>`) — независимый от самого JSONL
аудиторский след на случай порчи ledger/registry. Таймер
`dept-ledger-snapshot.timer` (`OnBootSec=10min`, `OnUnitActiveSec=1h`)
гоняет его раз в час через `dept-ledger-snapshot.service` (oneshot);
юнит в репо (`systemd/dept-ledger-snapshot.service`) перед snapshot гоняет
`ExecStartPre=dept-ledger rotate`.

`dept-ledger rotate [--days N]` (дефолт 30, env `DEPT_ROTATE_DAYS`) —
уносит из активного `events.jsonl` в `archive/events-YYYY-MM.jsonl`
ЗАКРЫТЫЕ цепочки, целиком старше порога: message `handled`/`dead`;
approval `denied`/`executed`/`exec_failed`/`withdrawn` (а `approved` —
только для НЕисполняемых kind_of: заявку, ждущую диспетчера, ротировать
нельзя — он читает только активный файл; `executing` не ротируется
никогда); incident `resolved`/`wontfix`/`duplicate`; `policy_ack` кроме
последнего на воркера; `agent_run`/`registry_change` — безусловно. `seq`
строго монотонен через ротацию (`rotate-state.json`), порядок
crash-безопасный (архив с дедупом по event_id → rotate-state → атомарный
rename активного файла). Читатели цепочек (`approval-resolve`/
`approval-exec`/`incident-resolve --ref-main`) ищут базу и в архивах.

`rotate` ДОПОЛНИТЕЛЬНО чистит рантайм-мусор ВНЕ лока ledger (фаза 4):
маркеры зависших заявок `exec-stuck-<event_id>` (dispatcher, п. 2 выше) и
логи раннеров `runner-<event_id>.log` (`dept-exec-runner`) — их не чистил
никто, они копились вечно и попадали в snapshot-коммиты. Удаляются по
строгим regexp-именам (никаких glob'ов по каталогу, где живут
`registry.json` и стейты юнитов) старше того же cutoff, что и ротация
событий — гарантия, что in-flight раннер не лишится своего лога.

## Реестр ролей ≠ autonomous.json

`autonomous.json` — источник истины **запуска** (`state`, `cwd`,
`session_id`, `brain_path`), им управляет `claude-auto adopt/stop/start`.
`department/registry.json` — только **роли отдела** (`role`, `client`,
`escalates_to`, `mission_version`), пишется исключительно через
`registry-set` (RMW под тем же локом, что и аудит-событие
`registry_change`). **Автоматического синка между файлами нет**: воркер
может быть active в одном и отсутствовать в другом. При найме МК через
заявку `worker_spawn` реестр пишет сам `dept-spawn-exec` (роль `мк`,
client, `v3`); для штабных/нестандартных случаев актуализация реестра под
фактический флот — по-прежнему ручная операция оператора.

`registry-set` валидирует `role` ∈ `руководитель, мк, архивариус, тп,
legacy` (иначе падает); роль `мк` требует `--client`. `mission_version` —
свободная строка (`v1`/`v2`/`v3` — фактическая конвенция канона, не enum,
CLI её не проверяет).

## Штат отдела и МК

Штатный путь найма МК — заявка Руководителя `dept-spawn-request` → ✅
оператора → диспетчер → `dept-spawn-exec` (headless-bootstrap через
`claude-auto spawn`). Ручной онбординг через `/go-autonomous` остаётся
для ШТАБНЫХ воркеров и нестандартных случаев — полный runbook (роли/рамки
allow-deny/пробы/смок, включая критичный нюанс с анкором `//` для
абсолютных путей в файловых правилах) — `docs/department-onboarding.md`.

- **Штаб** (`mission_version: v3`, проба `dept-bus` = `ledger-messages
  --worker <имя>`): `dept-head` (руководитель, cwd `~/brain`, шину
  обрабатывает, файлы не пишет; подаёт заявки spawn/mission/планёрка/
  sleep), `dept-archivist` (архивариус, cwd `~/brain`, писатель 4 баз:
  БЗ sales-assistant, правила отдела, тп-знания, карточки ролей
  `отдел/роли/*.md` — публикация только через `dept-approve --kind-of
  kb_change`/`role_change`), `dept-tp` (тп, cwd `~/server`, обращения —
  только `incident` из шины: Asana-задача → диагностика → чинит баг сам
  или approve на архитектурное изменение → `incident-resolve`).
- **МК** (`mission_version: v3`, пробы `dept-bus` + клиентские, cwd —
  папка клиента в brain): `prodmash`, `elektronika-deal`, `vam-mebel-deal`,
  `legion2`, `diaverum-russ` (мигрирован с v1 боевой spawn-заявкой
  16.07; обкатал спящий режим — спит, контур под диспетчером). Связь МК с
  ОПЕРАТОРОМ — напрямую бот-каналом (`claude-auto-ask`/`claude-auto-tg`,
  отчёты в @RnR_Workers), БЕЗ `dept-approve`: гейт нужен только для
  исходящих людям клиента.
- Остальные активные воркеры — `legacy` в реестре (вне отдела; миграция
  v1→v3 — через spawn-заявку по прецеденту diaverum-russ: курация памяти
  → `stop`+`remove` старого → `dept-spawn-request`).

## Адаптер `ledger-messages`

Контракт event-bridge проб: одна детерминированная строка на новое событие
в stdout, exit 0, дедуп — на стороне bridge. `ledger-messages --worker
<name>` эмитит `queued`-сообщения на воркера, каждое строкой со скрытым
маркером `\x1eebid=<event_id>\x1e` (control-char, ключ дедупа bridge).
Сообщение исчезает из выдачи после `dept-ledger ack <event_id>` — состояние
живёт в ledger, не в state-файле пробы (`--state-dir` принимается, но
игнорируется). Подключается как проба `dept-bus` в `probes.json` воркера
(см. «Штат отдела и МК» — так подключены все штабные воркеры и МК).

## Liveness-watchdog

`claude-auto-liveness.timer` (каждые 5 мин) гоняет `bin/claude-auto-liveness`
по всем `state == active` из `autonomous.json` (спящих не трогает). hung =
busy-маркер на экране + неизменный screen-hash + не двигающийся транскрипт
дольше `LIVENESS_HUNG_MIN` (30 мин).

**Лестница (решение оператора 19.07 — авто-рестарт отменён навсегда,
флаг `LIVENESS_ENFORCE` удалён из кода целиком, никакого дефолта/выключателя
больше нет; единственное осознанное исключение — ветка `#rc`, оператор 22.07:
отвалившийся Remote Control у ЖИВОГО idle-воркера авто-рестартится, см.
docs/autonomous.md § RC-сторож — зависших это не касается):**
`none → alert → карточка → incident` (`decide()`,
юнит-тестируется отдельно). На шаге `alert` — разовое ⚠️ в Telegram
(«следующий шаг — заявка на перезапуск оператору»). Если экран остаётся
замершим на следующих тиках, сторож подаёт заявку `dept-liveness-request
--worker <w> --frozen-min <N> --transcript-min <M>` через гейт отдела —
это НЕ worker-only обёртка (сторож — systemd-таймер, а не сессия воркера:
spoof-resistant `resolve_name()` отсюда не резолвился бы), поэтому она
открывает `dept-ledger approval-open` и шлёт карточку боту напрямую через
`bot/rnr_db.py insert-approval`, минуя `dept-approve`/`claude-auto-request`.
`actor`/`from` заявки фиксирован буквально литералом `watchdog` — защита от
подделки не здесь, а в ролевом фильтре диспетчера (`pickExecutable`
исполняет `liveness_restart` ТОЛЬКО если `from === 'watchdog'`) и в том, что
`dept-liveness-request` не входит в allow воркеров.

Карточка в @RnR_Workers: **✅** → `dept-dispatcher` помечает `executing` и
запускает исполнитель `dept-liveness-exec` (в whitelist `dept-exec-runner`
наравне с `dept-{spawn,mission,planerka,sleep}-exec`) → тот сверяет detail
байт-в-байт с `data.request` (anti-forge, как у остальных исполнителей) и
вызывает `systemctl --user restart claude-auto@<worker>.service` —
перезапуск продолжает ТУ ЖЕ сессию (память клиента не трогается).
`dept-liveness-exec` запускается ТОЛЬКО через `--approval <event_id>`
диспетчером — в отличие от `dept-sleep-exec` у него намеренно нет флага
`--worker` для ручного вызова оператором: легитимного пути «оператор жмёт
руками» здесь нет, ручной перезапуск вне гейта — просто `systemctl --user
restart claude-auto@<name>`. **❌** → сторож молчит,
пока screen-hash воркера не изменится.

**Повторное зависание после ИСПОЛНЕННОЙ карточки** в пределах
`LIVENESS_REINCIDENT_MIN` (60 мин) → `incident-open` (severity high, actor
`watchdog`) для ТП безусловно, без карточки/кнопки. Якорь reincident-окна —
`ts` события `executed` ИЗ LEDGER (не момент, когда сторож это заметил).

**Дедуп заявок — два независимых слоя:** (1) состояние воркера
(`cardEventId` в `watchdog-state.json`) — пока карточка отслеживается,
КАЖДЫЙ тик сторож перечитывает её эффективный `approval_status`
(`open`/`approved`/`executing` → ждать; `executed` → закрыть эпизод и
взвести reincident-якорь; `denied`/`withdrawn` на НЕИЗМЕНИВШЕМСЯ экране →
молчать, не переподавать; экран сменился или заявка ушла из вида
(архивация) → снять карточку и разрешить лестнице подать заново). (2)
активный журнал ledger (`findExistingCardForWorker`) — перед подачей
НОВОЙ заявки сторож ищет уже нерешённую `liveness_restart` на этого же
воркера (страховка от потери/повреждения state-файла) и «усыновляет» её
вместо дубля.

**Вторичный сигнал «анимированное зависание» (anim-эпизод):** экран
ЖИВЁТ (screen-hash меняется — спиннер/анимация), а транскрипт стоит ≥
`LIVENESS_ANIM_HUNG_MIN` (90 мин) → один `anim`-алерт на эпизод, **всегда
alert-only** (в лестницу не входит). screenHash в anim-эпизоде продвигается
на каждом тике — если экран после анимации замер, основная лестница
начинает свой отсчёт с нуля, anim-эпизод её не глушит. Ожившим экраном
(hash сменился) сбрасывается «уже оповещал» (alerted) — устаревший алерт
про старый кадр не должен глушить новый эпизод.

**Вторая ветка: «жив, но тихо мёртв» (протухшая авторизация хоста).**
Инцидент 21.07: на хосте истёк логин Claude Code, у четырёх воркеров сессии
и юниты остались живы, на экранах висело `Login expired · Please run /login`,
ни одно событие не обрабатывалось ~8 часов. Основная лестница это НЕ ловит
by design — её первая строка отсеивает не-busy сессии, а мёртвый логин не
busy. Ветка независима от `decide()` и проверяется РАНЬШЕ, чем гейт
транскрипта и lifecycle карточки `liveness_restart` (обе делают `continue`,
и воркер иначе выпадал бы из проверки вовсе).

Признак требует ДВА ключа: маркер `AUTH_RE` на экране И машинный вердикт из
транскрипта (`authVerdictFromFile` — идём с конца и сравниваем, что новее:
запись `isApiErrorMessage:true` с auth-текстом или обычный ответ ассистента;
окно расширяется 64 КБ → 512 КБ → 4 МБ, потому что после отказа датчики
дописывают в транскрипт user-записи часами). Один экран доказательством не
считается: воркер отдела, обсуждающий этот самый инцидент, процитирует ту же
строку. `busy` в этой ветке берётся по ХВОСТУ экрана (12 строк), а не по
всему pane, иначе остаточный `esc to interrupt` из истории маскировал бы
отказ навсегда. Сбой чтения = `unknown`, это НЕ выздоровление.

Подтверждение — 2 подряд тика со статичным экраном (таймер ходит раз в
5 мин). Дальше — ОДИН групповой алерт со списком всех пострадавших
(протухший логин бьёт по хосту, а не по воркеру: N отдельных сообщений
оператору бесполезны). **Карточка `liveness_restart` на этой ветке не
подаётся и инцидент не открывается** (решение оператора 21.07): рестарт с
мёртвыми креденшелами поднимет воркера в ту же ошибку, лечит только `/login`
на хосте. Вместо эскалации — напоминание раз в `LIVENESS_AUTH_REMIND_MIN`
(60 мин), пока эпизод не рассосётся.

Состояние эпизода живёт в ОДНОМ месте — служебный ключ `#auth` в
`watchdog-state.json` (`#` невозможен в имени воркера, коллизия исключена;
из cleanup-петли ключ исключён явно). В per-worker state auth-флаги не
пишутся намеренно: `nextState('reset')` конструирует запись заново, а ветки
`close_executed`/`incident` заменяют её целиком — флаги бы там терялись.
Пометка «уведомлён» ставится ТОЛЬКО после успешной доставки (иначе сетевой
сбой съест групповой алерт целиком). Воркер, который ожил и упал снова,
считается новым участником — иначе повторный отказ прошёл бы молча.

**Видимые сбои:** провал чтения ledger/registry, провал доставки
notify (30с таймаут) ИЛИ провал подачи заявки/открытия инцидента
(`actionFailures`) → `process.exitCode = 1` — юнит виден в systemd как
`failed`, не тонет молча в логах. `--dry-run` строго read-only: лок не
берёт, `watchdog-state.json` не пишет, только печатает решения. State —
`department/watchdog-state.json` (+ best-effort lock `liveness.lock`,
протухание 15 мин).

## Пути рантайма

| Что | Путь |
|---|---|
| Ledger | `~/.claude-control/department/events.jsonl` |
| Архив ротации | `~/.claude-control/department/archive/events-YYYY-MM.jsonl` (+ `rotate-state.json`) |
| Реестр ролей | `~/.claude-control/department/registry.json` |
| Liveness state | `~/.claude-control/department/watchdog-state.json` |
| Rebase-check state | `~/.claude-control/department/rebase-check-state.json` |
| Dispatcher state | `~/.claude-control/department/sleep-check-state.json` (+ `dispatcher.lock`, маркеры `exec-stuck-<event_id>`, `open-approval-reminders.json`) |
| Миссии (аудит-копии) | `~/.claude-control/department/missions/<worker>.md` |
| Рендеры заявок spawn | `~/.claude-control/department/render/` (bounds/probes/kickoff) |
| Логи раннера заявок | `~/.claude-control/department/runner-<event_id>.log` (+ `journalctl --user -u 'dept-runner-*'`) |
| Autonomous SoT | `~/.claude-control/autonomous.json` |
| Каталог правил (policy) | `~/brain/wiki/work/ai-dev/отдел/правила/` (override `DEPT_POLICY_DIR`) |

## Связанное

- Дизайн (16 решений): `~/brain/docs/superpowers/specs/2026-07-09-digital-department-design.md`
- Канон отдела: `~/brain/wiki/work/ai-dev/отдел/CLAUDE.md`
- Онбординг воркеров: `docs/department-onboarding.md`
- Autonomous-слой: `docs/autonomous.md`
