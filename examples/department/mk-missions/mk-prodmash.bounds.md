# Рамки воркера mk: prodmash (клиент «продмаш») — для /go-autonomous

Режим: auto. Видимость в Claude-приложении (remote-control): ДА.

## allow
- Bash(/opt/projects/active/claude-control/bin/dept-ledger:*)
- Bash(/opt/projects/active/claude-control/bin/dept-approve:*)
- Bash(/opt/projects/active/claude-control/bin/dept-withdraw:*)
- Bash(/opt/projects/active/claude-control/bin/claude-auto-self-probes:*)
- Edit(//home/rainor/brain/wiki/work/ai-dev/клиенты/продмаш/**)
- Write(//home/rainor/brain/wiki/work/ai-dev/клиенты/продмаш/**)

## deny
- Bash(sudo:*)
- AskUserQuestion
- Edit(//home/rainor/brain/wiki/work/ai-dev/отдел/**)
- Write(//home/rainor/brain/wiki/work/ai-dev/отдел/**)
- Edit(//home/rainor/brain/wiki/work/ai-dev/продукты/**)
- Write(//home/rainor/brain/wiki/work/ai-dev/продукты/**)
- Edit(//home/rainor/brain/wiki/work/ai-dev/партнёры/**)
- Write(//home/rainor/brain/wiki/work/ai-dev/партнёры/**)

## Не разрешать
Никаких прямых исходящих людям (email/TG/комменты клиентам) — только через
dept-approve. Чужие клиентские папки не читать и не писать (policy 4.1).
