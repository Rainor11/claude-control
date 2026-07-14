# Рамки воркера mk: elektronika-deal (клиент «электроника») — для /go-autonomous

Режим: auto. Видимость в Claude-приложении (remote-control): ДА.

## allow
- Bash(/opt/projects/active/claude-control/bin/dept-ledger:*)
- Bash(/opt/projects/active/claude-control/bin/dept-approve:*)
- Edit(//home/rainor/brain/wiki/work/ai-dev/клиенты/электроника/**)
- Write(//home/rainor/brain/wiki/work/ai-dev/клиенты/электроника/**)

## deny
- Bash(sudo:*)
- Edit(//home/rainor/brain/wiki/work/ai-dev/отдел/**)
- Write(//home/rainor/brain/wiki/work/ai-dev/отдел/**)
- Edit(//home/rainor/brain/wiki/work/ai-dev/продукты/**)
- Write(//home/rainor/brain/wiki/work/ai-dev/продукты/**)
- Edit(//home/rainor/brain/wiki/work/ai-dev/партнёры/**)
- Write(//home/rainor/brain/wiki/work/ai-dev/партнёры/**)

## Не разрешать
Никаких прямых исходящих людям (email/TG/комменты клиентам) — только через
dept-approve. Чужие клиентские папки не читать и не писать (policy 4.1).
