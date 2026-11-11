#!/usr/bin/env bash
#
# Подписи для окна подсказок раскладки: config/cradio.keymap -> keymap.json.
#
# Запускается на GMKtec после любой правки раскладки. keymap.json лежит в
# репозитории рядом с агентом, build.sh кладёт его в бандл. Чтобы обновить
# подписи на маке БЕЗ пересборки агента:
#
#   ./make-keymap.sh --push
#
# — файл уедет в ~/Library/Application Support/SweepDongleAgent/ на маке, и
# агент подхватит его при следующем обновлении окна (смотрит дату файла).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

python3 keymap_gen.py ../config/cradio.keymap keymap.json
echo "готово: $(pwd)/keymap.json"

if [[ "${1:-}" == "--push" ]]; then
  ssh mac 'mkdir -p "$HOME/Library/Application Support/SweepDongleAgent"'
  scp -q keymap.json 'mac:Library/Application\ Support/SweepDongleAgent/keymap.json'
  echo "отправлено на мак"
fi
