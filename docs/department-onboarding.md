# Онбординг воркеров отдела

**Штатный путь найма МК (с фазы 3, 2026-07-16)** — заявка Руководителя:
`dept-spawn-request --client <slug> --name <имя> --asana-gid <GID>` →
карточка → ✅ оператора → диспетчер → `dept-spawn-exec` (детерминированный
bootstrap: скелет папки клиента в brain, миссия из
`examples/department/mk-mission.template.md`, bounds/probes из шаблонов
`mk-*.template.*`, `claude-auto spawn` + kickoff, `registry-set --role мк
--mission-version v3`; идемпотентен — повторный прогон достраивает).
Контракт заявок — `docs/department.md`, механика spawn —
`docs/autonomous.md`.

**Ручной онбординг ниже** остаётся для ШТАБНЫХ воркеров и нестандартных
случаев: `/go-autonomous` превращает в воркера текущую сессию (adopt
наследует её cwd).

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
     `Bash(/opt/projects/active/claude-control/bin/dept-approve:*)`,
     `Bash(/opt/projects/active/claude-control/bin/claude-auto-self-probes:*)` (свои датчики — self-service); deny
     `Bash(sudo:*)`, `AskUserQuestion` (интерактивный вопрос в сессии — оператор
     его не увидит; вопросы оператору только через claude-auto-ask, кнопки в TG);
     исходящие людям — НЕ разрешать (гейт через dept-approve).
   - dept-head: deny `Edit(//home/rainor/brain/**)`, `Write(//home/rainor/brain/**)`
     — руководитель ничего не пишет в файлы, только шина.
   - dept-archivist: allow Edit/Write ТОЛЬКО 4 базы —
     `//home/rainor/brain/wiki/work/ai-dev/продукты/alp-gpt/база-знаний/sales-assistant/**`,
     `//home/rainor/brain/wiki/work/ai-dev/отдел/правила/**`,
     `//home/rainor/brain/wiki/work/ai-dev/отдел/тп-знания.md`,
     `//home/rainor/brain/wiki/work/ai-dev/отдел/роли/**` (карточки ролей —
     4-я база с 16.07/policy-v5: правки ТОЛЬКО через `dept-approve --kind-of
     role_change`, применяет сам Архивариус после ✅ — диспетчер role_change
     не исполняет); deny Edit/Write
     `//home/rainor/brain/wiki/work/ai-dev/продукты/alp-gpt/база-знаний/consultant-alp-gpt/**`
     (БЗ Ивана, «НЕ ТВОЁ» по миссии — пояс и подтяжки к зауженному allow),
     `//home/rainor/brain/wiki/work/ai-dev/отдел/CLAUDE.md`,
     `//home/rainor/brain/wiki/work/ai-dev/клиенты/**` (манифест отдела,
     состав ролей и спека — только Оракул-сессия; клиентские папки пишут
     МК). Неизменяемость старых policy-vN — правило канона (механически не
     выражается): новая версия = только новый файл policy-vN+1.md.
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
5. Реестр: `/opt/projects/active/claude-control/bin/dept-ledger registry-set <имя> --role <руководитель|архивариус|тп> --mission-version v3`
   (актуальное поколение миссий — v3, шаблоны в `examples/department/`)
6. Смок: `/opt/projects/active/claude-control/bin/dept-ledger send --type question
   --to <имя> --subject 'смок' --body 'ответь ack и resolve' --actor operator` →
   в течение ~минуты воркер ack'ает (проверь
   `/opt/projects/active/claude-control/bin/dept-ledger list --kind message
   --filter to=<имя> --status queued` — пусто).

## МК

**Новый МК** — только через заявку `dept-spawn-request` (см. шапку),
руками не создаётся.

**Миграция существующего v1/v2-воркера на v3** — тоже через spawn-заявку
(боевой прецедент: `diaverum-russ`, 16.07):

1. Убедись, что память сделки докурирована (`claude-auto status <имя>` —
   не STALE): spawn рождает fresh-сессию, вся память — из файлов папки
   клиента.
2. `claude-auto stop <имя>` → `claude-auto remove <имя>` (старый воркер;
   имя должно освободиться — `dept-spawn-request` отказывает на занятом).
3. Руководитель подаёт `dept-spawn-request` → ✅ → bootstrap: папка клиента
   уже существует — скелет пропускается (идемпотентность), воркер получает
   миссию v3, пробы `dept-bus` + `asana-deal`, реестр `--mission-version v3`.
4. Kickoff-инжект даёт стартовый контекст (правила → CLAUDE.md клиента →
   timeline → decisions → открытые вопросы → policy-ack).
