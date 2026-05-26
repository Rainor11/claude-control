# Архитектура

```
┌──────────────────┐         ┌──────────────────────────────┐
│  Claude mobile / │ ─────►  │  Anthropic remote-control    │
│  claude.ai/code  │         │  routing (claude.ai)         │
└──────────────────┘         └──────────────┬───────────────┘
                                            │
                                            ▼
                              ┌──────────────────────────────┐
                              │  Твоя машина (Mac или Linux) │
                              │                              │
   process manager:           │   ┌────────────────────────┐ │
   - macOS: launchd ──────────┼─► │ claude-control-session │ │
   - Linux: systemd --user    │   │  → claude remote-      │ │
                              │   │    control --name      │ │
                              │   │    control --capacity 1│ │
                              │   └────────────────────────┘ │
                              │                              │
   watchdog (раз в 5 мин):    │   ┌────────────────────────┐ │
   - macOS: StartInterval=300 │   │ claude-control-watchdog│ │
   - Linux: systemd timer ────┼─► │  читает recent log     │ │
                              │   │  (file или journalctl),│ │
                              │   │  при отсутствии        │ │
                              │   │  heartbeat'а делает    │ │
                              │   │  kickstart / restart   │ │
                              │   └────────────────────────┘ │
                              │                              │
                              │   когда ты говоришь          │
                              │   "подними X" в control:     │
                              │                              │
                              │   ┌────────────────────────┐ │
                              │   │ claude-rc X            │ │
                              │   │  → tmux new-session    │ │
                              │   │    -c $path -- claude  │ │
                              │   │    remote-control      │ │
                              │   │    --name X            │ │
                              │   └────────────────────────┘ │
                              └──────────────────────────────┘
```

## Компоненты

### `claude-control-session` (control)

Тонкая bash-обертка, которую процесс-менеджер держит живой. Внутри - `claude remote-control --name control --capacity 1`, запускается из `~/.claude-control/`. Эта папка для control-сессии - проектная директория, поэтому ее `CLAUDE.md` тоже подгружается как контекст. Назначение `CLAUDE.md` тут - научить control-сессию реагировать на "подними `<имя>`", "что запущено", "убей `<имя>`" соответствующими bash-командами и ничего больше в этой папке не делать.

`--capacity 1` потому что control-сессия одна и параллелизм ей не нужен.

Для нестандартных установок Claude Code путь к бинарю можно переопределить через переменную `CLAUDE_BIN` (по умолчанию - `claude` из PATH).

### `claude-rc <project>`

Bash-скрипт. Ищет `<project>` в `~/.claude-control/projects.yaml`, проверяет существование пути, поднимает detached `tmux`-сессию `claude-<project>` с `claude remote-control --name <project>` внутри нужной директории. Режим `--spawn` определяет автоматически: `worktree`, если каталог - git-репозиторий, `same-dir` иначе.

Если сессия с таким именем уже жива, скрипт делает no-op с сообщением, а не плодит дубль.

### `claude-control-watchdog`

Запускается каждые 5 минут (на macOS через `StartInterval=300`, на Linux через `systemd timer`). Смотрит recent-логи control-сессии и ищет heartbeat - строку, где имя сессии (`control`) присутствует как самостоятельный токен:

- **macOS:** читает последние 30 строк `~/.claude-control/control.log` (файл пишет launchd через `StandardOutPath`).
- **Linux:** читает `journalctl --user -u claude-control --since='-5min'` (stdout/stderr идут в systemd journal).

Если не нашел - пишет строку в `watchdog.log` и делает kickstart/restart соответствующего юнита:

- **macOS:** `launchctl kickstart -k gui/$UID/<label>`
- **Linux:** `systemctl --user restart <label>.service`

Бэкенд (Darwin/Linux) определяется через `uname -s`; можно переопределить через `CLAUDE_CONTROL_BACKEND=Linux|Darwin`.

Зачем это нужно: процесс `claude remote-control` может оставаться живым, при этом **зарегистрированная сессия** на стороне Anthropic-роутинга может исчезнуть (capacity падает до 0). Процесс-менеджер этого не видит - процесс-то жив; на телефоне же сессия `control` пропадает. Watchdog ловит это по логу и пинает процесс.

## Что где лежит после установки

### macOS

```
~/.local/bin/
  claude-rc                       # скрипт (или симлинк на репо при --link)
  claude-control-session          # launchd entrypoint
  claude-control-watchdog         # скрипт watchdog'а

~/Library/LaunchAgents/
  com.<user>.claude-control.plist            # control-сессия
  com.<user>.claude-control-watchdog.plist   # watchdog (раз в 5 минут)

~/.claude-control/
  projects.yaml                   # твой реестр (в .gitignore репо)
  CLAUDE.md                       # контекст control-сессии
  .claude/settings.local.json     # allow-list bash-команд
  control.log, control.err        # stdout/stderr control-сессии
  watchdog.log                    # история kickstart'ов watchdog'а
  watchdog.out, watchdog.err      # stdout/stderr watchdog'а
```

### Linux

```
~/.local/bin/
  claude-rc                       # скрипт (или симлинк на репо при --link)
  claude-control-session          # systemd ExecStart entrypoint
  claude-control-watchdog         # скрипт watchdog'а

~/.config/systemd/user/
  claude-control.service                     # control-сессия
  claude-control-watchdog.service            # one-shot проверка
  claude-control-watchdog.timer              # запускает .service каждые 5 минут

~/.config/claude-control/env                 # опциональный env-file (PATH, CLAUDE_BIN, proxy)

~/.claude-control/
  projects.yaml                   # твой реестр (в .gitignore репо)
  CLAUDE.md                       # контекст control-сессии
  .claude/settings.local.json     # allow-list bash-команд
  watchdog.log                    # история restart'ов watchdog'а
  # stdout/stderr control-сессии и watchdog'а — в systemd journal,
  # смотреть через `journalctl --user -u claude-control -f`
```
