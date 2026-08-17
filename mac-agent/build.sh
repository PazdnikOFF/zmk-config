#!/usr/bin/env bash
#
# Собирается именно .app-бандл, а не голый бинарник.
#
# CoreBluetooth защищён TCC, и без NSBluetoothAlwaysUsageDescription процесс
# убивают на первом же обращении. Вшить plist в секцию __TEXT,__info_plist
# недостаточно — проверено, не помогает даже с ad-hoc подписью: TCC ищет
# Info.plist бандла. Поэтому бандл, и подпись после сборки.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

APP="SweepDongleAgent.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# -target обязателен. По умолчанию тулчейн ставит в Mach-O minos 28.0 — выше,
# чем сама система, — и LaunchServices отказывается запускать бандл с ошибкой
# -10825 (kLSIncompatibleApplicationVersionErr). В Info.plist это не лечится,
# потому что причина в load-команде LC_BUILD_VERSION, а не в бандле.
# 14.0 достаточно: SMAppService требует 13.0.
swiftc -O -target arm64-apple-macos14.0 -o "$APP/Contents/MacOS/SweepDongleAgent" *.swift

codesign --force --sign - --identifier ru.pazdnikoff.sweepdongle.agent "$APP"

echo "готово: $(pwd)/$APP"
