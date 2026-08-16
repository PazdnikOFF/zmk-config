# mac-agent

Агент, который раз в 5 секунд собирает показатели мака и отдаёт их донглу.

## Что шлёт

Одна ASCII-строка, ключи в произвольном порядке:

```
layout=RU cpu=23 mem=61 disk=142 batt=87 chg=1
```

| Ключ | Что | Откуда |
|---|---|---|
| `layout` | код языка раскладки | `TISCopyCurrentKeyboardInputSource`, берётся язык, а не идентификатор источника: у «Русской» и «Русской — ПК» идентификаторы разные, а язык один |
| `cpu` | загрузка, % | `host_statistics(HOST_CPU_LOAD_INFO)`, по дельте тиков между тиками таймера |
| `mem` | занятая память, % | `host_statistics64`, active + wired + compressed |
| `disk` | свободно на `/`, ГБ | `volumeAvailableCapacityForImportantUsage` — то же число, что показывает Finder |
| `batt` | заряд мака, % | `IOPSCopyPowerSourcesInfo` |
| `chg` | идёт ли зарядка | там же |

Дедупликацией агент не занимается: прошивка сама не перерисовывает e-paper,
если текст не изменился.

## Два канала одновременно

- **USB CDC** — пока донгл воткнут кабелем. Порт ищется по VID/PID
  `0x1D50:0x615E`, а не по имени: `/dev/cu.usbmodemNNNNN` меняется при
  перетыкании в другой разъём.
- **BLE GATT** — когда донгл живёт от батареи. Пишем в характеристику
  `a336bc14-…` сервиса `f1ef61b7-…` на том же соединении, которым донгл отдаёт
  HID. Донгл уже подключён системой и ничего не рекламирует, поэтому обычный
  скан его не найдёт — ищем через `retrieveConnectedPeripherals`, сначала по
  своему сервису, потом по HID-сервису `0x1812` с фильтром по имени.

Данные уходят в оба канала: какой из них живой, зависит от кабеля, а
дублирование безвредно.

## Запускать только через launchd

Это не стилистическое предпочтение, а требование TCC. CoreBluetooth —
защищённый API, и агент обязан быть `.app`-бандлом с
`NSBluetoothAlwaysUsageDescription`, запущенным launchd.

Что проверено и **не** работает:

- голый бинарник с plist в секции `__TEXT,__info_plist` — SIGABRT от TCC, даже
  после ad-hoc подписи;
- запуск исполняемого файла бандла напрямую из терминала — тот же SIGABRT:
  «ответственным» процессом TCC считает терминал, а не наш бандл;
- `open ./SweepDongleAgent.app` — LaunchServices отказывается, `-10825`.

Под launchd всё поднимается штатно.

## Установка

```bash
./build.sh
cp ru.pazdnikoff.sweepdongle.agent.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ru.pazdnikoff.sweepdongle.agent.plist
```

Лог — `/tmp/sweep-dongle-agent.log`. Перезапуск после пересборки:

```bash
launchctl kickstart -k gui/$(id -u)/ru.pazdnikoff.sweepdongle.agent
```

Снять:

```bash
launchctl bootout gui/$(id -u)/ru.pazdnikoff.sweepdongle.agent
rm ~/Library/LaunchAgents/ru.pazdnikoff.sweepdongle.agent.plist
```

Путь к бандлу в plist прописан абсолютным — если репозиторий переедет, plist
надо перегенерировать.

Это именно LaunchAgent, а не LaunchDaemon: `TISCopyCurrentKeyboardInputSource`
читается только внутри GUI-сессии пользователя.
