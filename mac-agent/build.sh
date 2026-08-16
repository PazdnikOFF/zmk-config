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

swiftc -O -o "$APP/Contents/MacOS/SweepDongleAgent" SweepDongleAgent.swift

codesign --force --sign - --identifier ru.pazdnikoff.sweepdongle.agent "$APP"

echo "готово: $(pwd)/$APP"
