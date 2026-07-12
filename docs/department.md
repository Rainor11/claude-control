# Цифровой отдел — ядро (dept-ledger, dept-approve, liveness)

Субстрат «Цифрового отдела» — организация ролевых воркеров поверх
autonomous-слоя (`docs/autonomous.md`). Канон отдела (роли, policy, дизайн)
живёт в brain, не здесь — см. «Связанное».

## Ledger

`~/.claude-control/department/events.jsonl` (override `DEPT_HOME`) —
append-only JSONL, единственный писатель `bin/dept-ledger` (lockfile,
живёт ≤10с на запись). Конверт: `{v, event_id, seq, ts, actor, kind, data}`.
`kind` ∈ `message, message_status, approval, approval_status, incident,
incident_status, agent_run, registry_change`. Статусные `*_status` ссылаются
на исходное событие через `data.ref = event_id` — сам ledger неизменяем,
эффективный статус выводится сверху (`effectiveStatus`). `message.type` ∈
`question, proposal, incident, handoff`; `message_status.status` ∈
`acked, handled, dead`; `approval_status.status` ∈ `approved, denied`.

## Команды

- `dept-ledger append --kind <k> --data '<json>'` — низкоуровневая запись.
- `dept-ledger list [--kind <k>] [--filter k=v ...] [--status <s>] [--limit N]`.
- `dept-ledger send --type <question|proposal|incident|handoff> --to <worker>
  --subject <s> [--body <b>] [--refs a,b]` — сахар над `append --kind message`
  (статус сразу `queued`).
- `dept-ledger ack <event_id>` / `resolve <event_id> --status <handled|dead>`.
- `dept-ledger approval-open --kind-of <k> --summary <s>` /
  `approval-resolve <event_id> --status <approved|denied>`.
- `dept-ledger incident-open --about <worker> --severity <s> --summary <s>` —
  пишет `incident`; если в реестре есть роль `тп` — сразу шлёт ей `message`
  типа `incident` со ссылкой.
- `dept-ledger registry-set <worker> --role <r> [--client <c>]
  [--escalates-to <w>] [--mission-version <v>]` / `registry-get` / `registry-list`.
- `dept-approve --kind-of <k> --summary <s> [--detail <d>]` — открывает
  `approval` и зовёт оператора через `claude-auto-ask` (TG-кнопки). Воркер
  сам закрывает аппрув после ответа (`approval-resolve`); если уведомление
  не ушло — команда падает (аппрув не должен висеть незамеченным).

## Реестр ролей ≠ autonomous.json

`autonomous.json` — источник истины **запуска** (`state`, `cwd`,
`session_id`, `brain_path`), им управляет `claude-auto adopt/stop/start`.
`department/registry.json` — только **роли отдела** (`role`, `client`,
`escalates_to`, `mission_version`), пишется исключительно через
`registry-set` (RMW под тем же локом, что и аудит-событие
`registry_change`). **Синка между файлами в фазе 1 нет**: воркер может быть
active в одном и отсутствовать в другом. Роль `мк` (менеджер клиента,
требует `--client`) — единственная осмысленно используемая; `legacy` —
метка «вне отдела, мигрирует в фазе 2-3», CLI роли не валидирует (валидация
— фаза 2, когда появятся штабные воркеры).

## Адаптер `ledger-messages`

Контракт event-bridge проб: одна детерминированная строка на новое событие
в stdout, exit 0, дедуп — на стороне bridge. `ledger-messages --worker
<name>` эмитит `queued`-сообщения на воркера, каждое строкой со скрытым
маркером `\x1eebid=<event_id>\x1e` (control-char, ключ дедупа bridge).
Сообщение исчезает из выдачи после `dept-ledger ack <event_id>` — состояние
живёт в ledger, не в state-файле пробы (`--state-dir` принимается, но
игнорируется). Подключается как обычная проба в `event-bridge.config.json`;
по умолчанию не подключена никому.

## Liveness-watchdog

`claude-auto-liveness.timer` (каждые 5 мин) гоняет `bin/claude-auto-liveness`
по всем `state == active` из `autonomous.json`. hung = busy-маркер на
экране + неизменный screen-hash + не двигающийся транскрипт дольше
`LIVENESS_HUNG_MIN` (30 мин). Лестница (`decide()`, юнит-тестируется
отдельно): `none → alert → restart → incident`; повторный hang в пределах
`LIVENESS_REINCIDENT_MIN` (60 мин) после рестарта сразу даёт incident.

**`LIVENESS_ENFORCE=1`** — выключатель действий. Без него (дефолт) —
alert-only: на шагах restart/incident шлётся разовый `[would-restart]`/
`[would-incident]`, но `systemctl restart` / `incident-open` не вызываются.
С флагом — лестница исполняется по-настоящему. State —
`department/watchdog-state.json`; `--dry-run` — только печать решений.

## Пути рантайма

| Что | Путь |
|---|---|
| Ledger | `~/.claude-control/department/events.jsonl` |
| Реестр ролей | `~/.claude-control/department/registry.json` |
| Liveness state | `~/.claude-control/department/watchdog-state.json` |
| Autonomous SoT | `~/.claude-control/autonomous.json` |

## Связанное

- Дизайн (16 решений): `~/brain/docs/superpowers/specs/2026-07-09-digital-department-design.md`
- Канон отдела: `~/brain/wiki/work/ai-dev/отдел/CLAUDE.md`
- Autonomous-слой: `docs/autonomous.md`
