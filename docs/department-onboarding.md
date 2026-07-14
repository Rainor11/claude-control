# Онбординг воркеров отдела (фаза 2, до появления spawn)

Создание воркера — ОПЕРАТОРСКАЯ операция: `/go-autonomous` умеет превращать
в воркера только текущую сессию (adopt наследует её cwd). Автоматический
`claude-auto spawn` — фаза 3.

## Штабной воркер (dept-head / dept-archivist / dept-tp)

1. Открой НОВУЮ сессию в нужном cwd:
   - dept-head, dept-archivist: `cd /home/rainor/brain && claude`
   - dept-tp: `cd /home/rainor/server && claude`
2. В сессии: `/go-autonomous <имя>`; миссию вставь из
   `examples/department/<имя>/mission.md`. Рамки (bounds) задай в диалоге.
   ВАЖНО: в auto-режиме воркера отсутствие allow НЕ равно запрету — Edit/Write
   вне allow проходят молча. Гарантия — только явные deny-правила; задавай их
   в диалоге /go-autonomous вместе с allow. `claude-auto-ask` уже в
   baseline-allow каждого воркера (добавляет adopt автоматически) — отдельно
   разрешать не нужно. Файловые правила — с анкором `//` (абсолютный путь);
   одинарный `/` в Claude Code означает путь от корня проекта и НЕ сматчит
   абсолютный.
   - всем: allow `Bash(/opt/projects/active/claude-control/bin/dept-ledger:*)`,
     `Bash(/opt/projects/active/claude-control/bin/dept-approve:*)`; deny
     `Bash(sudo:*)`; исходящие людям — НЕ разрешать (гейт через dept-approve).
   - dept-head: deny `Edit(//home/rainor/brain/**)`, `Write(//home/rainor/brain/**)`
     — руководитель ничего не пишет в файлы, только шина.
   - dept-archivist: allow Edit/Write ТОЛЬКО
     `//home/rainor/brain/wiki/work/ai-dev/продукты/alp-gpt/база-знаний/sales-assistant/**`,
     `//home/rainor/brain/wiki/work/ai-dev/отдел/правила/**`,
     `//home/rainor/brain/wiki/work/ai-dev/отдел/тп-знания.md`; deny Edit/Write
     `//home/rainor/brain/wiki/work/ai-dev/продукты/alp-gpt/база-знаний/consultant-alp-gpt/**`
     (БЗ Ивана, «НЕ ТВОЁ» по миссии — пояс и подтяжки к зауженному allow),
     `//home/rainor/brain/wiki/work/ai-dev/отдел/роли/**`,
     `//home/rainor/brain/wiki/work/ai-dev/отдел/CLAUDE.md`,
     `//home/rainor/brain/wiki/work/ai-dev/клиенты/**` (роли и манифест отдела
     меняет только Оракул-сессия; клиентские папки пишут МК). Неизменяемость
     старых policy-vN — правило канона (механически не выражается): новая
     версия = только новый файл policy-vN+1.md.
   - dept-tp: + allow `Edit(//opt/projects/active/**)`,
     `Write(//opt/projects/active/**)`; ask на `Bash(systemctl:*)`; явные deny
     `Edit(//opt/projects/active/claude-control/bin/**)`,
     `Write(//opt/projects/active/claude-control/bin/**)`, то же для
     `//opt/projects/active/claude-control/bot/**` и
     `//opt/projects/active/claude-control/channels/event-bridge/**`;
     плюс deny записи секретов и канала алертов: `Edit(**/.env*)`,
     `Write(**/.env*)`, `Edit(//home/rainor/server/server_monitor/**)`,
     `Write(//home/rainor/server/server_monitor/**)` — чтение `.env*` уже
     закрыто baseline-deny adopt; значения секретов воркеру не светим,
     ротацию токенов делает оператор.
     Автоматический self-protection (adopt) закрывает `~/.claude-control/`,
     собственный workers-каталог И весь репозиторий
     `/opt/projects/active/claude-control/**` целиком — три явных deny выше
     дублируют его как документация рамок, не единственный забор.
3. Закрой origin-окно (правило adopt).
4. Пробы: `claude-auto set-probes <имя> /opt/projects/active/claude-control/examples/department/<имя>/probes.json`
5. Реестр: `/opt/projects/active/claude-control/bin/dept-ledger registry-set <имя> --role <руководитель|архивариус|тп> --mission-version v2`
6. Смок: `/opt/projects/active/claude-control/bin/dept-ledger send --type question
   --to <имя> --subject 'смок' --body 'ответь ack и resolve' --actor operator` →
   в течение ~минуты воркер ack'ает (проверь
   `/opt/projects/active/claude-control/bin/dept-ledger list --kind message
   --filter to=<имя> --status queued` — пусто).

## МК (миграция существующего deal-воркера)

См. план фазы 2, Task 8: курация памяти → stop+remove старого → adopt из
папки клиента с миссией из mk-mission.template.md → set-probes (старые пробы
+ dept-bus) → registry-set --mission-version v2 → смоки.
