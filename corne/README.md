# Corne v4 keymap (ported from Ferris Sweep / cradio)

Отдельная папка с конфигом для Corne. Пока не подключена к основному билду —
когда решим коммитить, файлы переносятся в `config/` репозитория, а
`build.yaml` из этой папки заменяет корневой (или в него добавляются
строки `corne_left` / `corne_right`).

Файлы:
- `config/corne.keymap` — раскладка, 5 слоёв (порт со Sweep + расширение до 42 клавиш)
- `config/corne.conf`   — настройки BT (как в cradio)
- `build.yaml`          — сборка на nice_nano_v2 + shield corne_left/right

Board по умолчанию `nice_nano_v2`. Если у Corne v4 другой контроллер —
поменять строки `board:` в `build.yaml` (сама раскладка не меняется).
