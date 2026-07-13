# Онбординг воркеров отдела (фаза 2, до появления spawn)

Создание воркера — ОПЕРАТОРСКАЯ операция: `/go-autonomous` умеет превращать
в воркера только текущую сессию (adopt наследует её cwd). Автоматический
`claude-auto spawn` — фаза 3.

## Штабной воркер (dept-head / dept-archivist / dept-tp)

1. Открой НОВУЮ сессию в нужном cwd:
   - dept-head, dept-archivist: `cd /home/rainor/brain && claude`
   - dept-tp: `cd /home/rainor/server && claude`
2. В сессии: `/go-autonomous <имя>`; миссию вставь из
   `examples/department/<имя>/mission.md`. Рамки (bounds) задай в диалоге:
   - всем: allow `Bash(/opt/projects/active/claude-control/bin/dept-ledger:*)`,
     `Bash(/opt/projects/active/claude-control/bin/dept-approve:*)`; deny
     `Bash(sudo:*)`; исходящие людям — НЕ разрешать (гейт через dept-approve).
   - dept-head: + allow `Bash(/opt/projects/active/claude-control/bin/claude-auto-ask:*)`;
     Edit/Write НЕ разрешать (пишет только в шину).
   - dept-archivist: + Edit/Write в
     `/home/rainor/brain/wiki/work/ai-dev/продукты/alp-gpt/база-знаний/**`,
     `/home/rainor/brain/wiki/work/ai-dev/отдел/**`; прочее brain — read-only.
   - dept-tp: + Edit/Write в `/opt/projects/active/**`; ask на
     `Bash(systemctl:*)`; deny на правку `/opt/projects/active/claude-control/bin/**`,
     `bot/**`, `channels/event-bridge/**` (self-protection дополнит остальное).
3. Закрой origin-окно (правило adopt).
4. Пробы: `claude-auto set-probes <имя> examples/department/<имя>/probes.json`
5. Реестр: `dept-ledger registry-set <имя> --role <руководитель|архивариус|тп> --mission-version v2`
6. Смок: `dept-ledger send --type question --to <имя> --subject 'смок' --body
   'ответь ack и resolve' --actor operator` → в течение ~минуты воркер ack'ает
   (проверь `dept-ledger list --kind message --status queued` — пусто).

## МК (миграция существующего deal-воркера)

См. план фазы 2, Task 8: курация памяти → stop+remove старого → adopt из
папки клиента с миссией из mk-mission.template.md → set-probes (старые пробы
+ dept-bus) → registry-set --mission-version v2 → смоки.
