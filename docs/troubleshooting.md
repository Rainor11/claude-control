# Поломки и что с ними делать

## "Поднял проект пару часов назад, теперь его нет на телефоне"

Это нормальное поведение. Проектные сессии, которые поднимает `claude-rc`, гаснут на простое - если к ним никто не подключается, процесс `claude remote-control` сам выходит спустя какое-то время (порядка часов, точный таймаут не документирован). Как только процесс умер, `tmux` закрывает окно, и сессия пропадает из приложения Claude.

Control-сессия живет существенно дольше (плюс watchdog ее подстраховывает), а вот каждая `claude-<project>` - это обычное `tmux`-окно с одним `claude`-процессом внутри.

**Что делать:** поднимай проект непосредственно перед тем, как он понадобится, а не заранее. Если успела погаснуть - снова "подними `<имя>`": `claude-rc` увидит мертвый `tmux` и спокойно поднимет заново.

## Control-сессия пропала, а процесс-менеджер считает юнит здоровым

Это тот самый случай, ради которого существует watchdog. Процесс `claude remote-control` жив, но зарегистрированная сессия "ушла" со стороны роутинга. Симптом - `launchctl print gui/$UID/com.<user>.claude-control` (macOS) или `systemctl --user status claude-control` (Linux) показывает юнит здоровым, а на телефоне `control` пропал.

**Что смотреть в первую очередь:** `tail -n 30 ~/.claude-control/watchdog.log`. Если там свежие записи про `kickstart`/`restart` - watchdog работает, просто control-сессия валится быстрее, чем раз в 5 минут.

- **macOS:** подкрути `StartInterval` в watchdog plist'е и `launchctl bootout/bootstrap` его заново.
- **Linux:** подкрути `OnUnitActiveSec` в `~/.config/systemd/user/claude-control-watchdog.timer` и сделай `systemctl --user daemon-reload && systemctl --user restart claude-control-watchdog.timer`.

Если watchdog-лог давно пустой - значит сам watchdog сломан. Перезапусти `./install.sh` и посмотри `~/.claude-control/watchdog.err` (macOS) или `journalctl --user -u claude-control-watchdog --since='-1h'` (Linux).

## `claude-rc` пишет "Unknown project"

Либо опечатка в имени, либо строчка в `~/.claude-control/projects.yaml` не подходит под формат. Скрипт ищет ключ через `yq` по точному имени, так что опечатка в имени или лишние пробелы в YAML-ключе скрывают запись.

## tmux: "no server running" / "session not found"

`claude-rc` использует tmux-сервер по умолчанию (без `-L`). Если у тебя нестандартный tmux с именованными сокетами, либо выставь `TMUX_TMPDIR` / нужный сокет в окружении перед вызовом `claude-rc`, либо правь скрипт под себя - он умышленно простой и про сокеты ничего не знает.

## `claude` не находится при запуске из launchd/systemd

launchd запускает агентов с тощим PATH; systemd `--user` - тоже не наследует интерактивный PATH из shell. Оба наших скрипта (`claude-control-session`, `claude-control-watchdog`) сами добавляют в начало PATH `$HOME/.local/bin`, `$HOME/bin`, `/opt/homebrew/bin`, `/usr/local/bin` - этого хватает для типовых установок Claude Code и `tmux`. Если у тебя `claude` живет где-то еще (`mise`, `asdf`, кастомный prefix), есть два пути:

- Прописать абсолютный путь через env-переменную `CLAUDE_BIN=/custom/path/claude` (читается обеими entrypoint'ами и `claude-rc`).
- Положить файл `~/.config/claude-control/env` (используется systemd-юнитом через `EnvironmentFile=`):
  ```
  CLAUDE_BIN=/custom/path/claude
  PATH=/custom/path:/usr/local/bin:/usr/bin:/bin
  ```

## Linux: control-сессия не запускается после reboot

Скорее всего отключён `loginctl Linger`. systemd `--user` units стартуют только пока пользователь залогинен (через SSH/console). Чтобы они переживали logout и переживали reboot - нужен linger:

```
loginctl show-user "$USER" --value -p Linger   # должно быть "yes"
sudo loginctl enable-linger "$USER"            # если "no" - включить
```

`install.sh` падает с подсказкой если linger не включён.

## Linux: смотрю логи через `tail control.log` - там пусто

В Linux-варианте stdout/stderr control-сессии идут в systemd journal, а не в файл. Смотри их так:

```
journalctl --user -u claude-control -f             # follow
journalctl --user -u claude-control -n 100         # последние 100 строк
journalctl --user -u claude-control --since='-1h'  # за последний час
```

`~/.claude-control/control.log` существует только на macOS (launchd пишет туда напрямую).

## Linux: watchdog молчит

```
systemctl --user list-timers claude-control-watchdog  # видно ли таймер, когда стрельнёт
systemctl --user status claude-control-watchdog       # был ли последний запуск, что сказал
journalctl --user -u claude-control-watchdog -n 50    # логи самого watchdog'а
tail -n 30 ~/.claude-control/watchdog.log             # человекочитаемый журнал кикстартов
```

## Mac уходит в сон - все умирает (только macOS)

launchd не запускает пользовательских агентов во время сна Mac'а, и удаленные сессии вместе с ним. Если ты хочешь, чтобы машина была доступна с телефона круглосуточно, нужно держать ее неспящей самостоятельно - типовое решение - отдельный launchd-агент, гоняющий `caffeinate -i`. Этот репо умышленно его не ставит: способ держать Mac бодрым каждый выбирает сам.

На Linux эта проблема не возникает - server-style машины не уходят в сон.
