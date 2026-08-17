//
//  Агент для донгла Sweep: раз в 5 секунд собирает показатели мака и шлёт их
//  строкой вида
//
//      layout=RU cpu=23 mem=61 disk=142 batt=87 chg=1
//
//  Каналов два, и работают они одновременно:
//    * USB CDC — пока донгл воткнут кабелем. Порт ищется по VID/PID, а не по
//      имени: /dev/cu.usbmodemNNNNN меняется при перетыкании в другой разъём;
//    * BLE GATT — когда донгл живёт от батареи. Пишем в свою характеристику
//      на том же соединении, которым донгл отдаёт HID.
//
//  Дедупликацией не занимаемся — прошивка сама не перерисовывает e-paper,
//  если текст не изменился.
//
//  ВАЖНО про запуск: CoreBluetooth защищён TCC, и агент обязан быть
//  .app-бандлом с NSBluetoothAlwaysUsageDescription, запущенным через launchd.
//  Из терминала напрямую он падает с SIGABRT — «ответственным» процессом TCC
//  считает терминал, и описание из нашего Info.plist в расчёт не берётся.
//  Проверено: вшивание plist в секцию __TEXT,__info_plist не помогает даже с
//  ad-hoc подписью, а `open` такой бандл не запускает (-10825).
//

import Carbon
import CoreBluetooth
import CoreGraphics
import Darwin
import Foundation
import IOKit
import IOKit.ps
import IOKit.serial

// ZMK: см. CONFIG_ZMK_USB_VID / PID в Kconfig.defaults.
let kVendorID = 0x1D50
let kProductID = 0x615E
let kIntervalSeconds = 5.0

// Должно совпадать с dongle/src/host_gatt.c.
let kServiceUUID = CBUUID(string: "F1EF61B7-9C57-4CB7-904A-D76A71836D4C")
let kMetricsUUID = CBUUID(string: "A336BC14-26B6-4CB1-93B0-A6A0D71E9275")
let kHIDServiceUUID = CBUUID(string: "1812")
let kDongleName = "Sweep Dongle"

/*
 * Пауза в печати, после которой разрешено писать в GATT.
 *
 * Запись идёт по тому же BLE-соединению, по которому донгл отдаёт нажатия
 * хосту, и отнимает у них эфирное время — отсюда периодические задержки ввода.
 * Ни у одного донгла из тех, что удалось посмотреть, хост в устройство ничего
 * не пишет, так что готового решения не существует: канал наш, и уступать
 * должен он.
 *
 * Пропущенные обновления не копятся и не досылаются: показатели мака не та
 * величина, ради которой стоит лезть в эфир поперёк нажатий. Пауза в пару
 * секунд при обычной печати случается постоянно.
 */
let kTypingQuietSeconds: CFTimeInterval = 2.0

/// Секунд с последнего нажатия. Разрешений не требует — это та же функция,
/// которой меряют простой системы, а не перехват ввода.
func secondsSinceLastKeystroke() -> CFTimeInterval {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
}

/*
 * Порт хоста берётся ОДИН раз на весь процесс.
 *
 * mach_host_self() возвращает право отправки, которое обязан освободить
 * вызывающий. Звать его на каждой выборке и не освобождать — утечка примерно
 * полутора тысяч ссылок в час; в RSS она не видна, потому что память ядерная.
 */
let machHost: mach_port_t = mach_host_self()

func log(_ message: String) {
    FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
}

// MARK: - Поиск последовательного порта

/// Идёт вверх по дереву IORegistry, пока не найдёт узел с idVendor/idProduct.
private func usbIDs(startingAt service: io_object_t) -> (vid: Int, pid: Int)? {
    var node = service
    IOObjectRetain(node)
    defer { IOObjectRelease(node) }

    for _ in 0..<12 {
        let vid = IORegistryEntryCreateCFProperty(node, "idVendor" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Int
        let pid = IORegistryEntryCreateCFProperty(node, "idProduct" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Int

        if let vid, let pid {
            return (vid, pid)
        }

        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(node, kIOServicePlane, &parent) == KERN_SUCCESS else {
            return nil
        }

        IOObjectRelease(node)
        node = parent
    }

    return nil
}

func findDonglePort() -> String? {
    guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) as NSMutableDictionary? else {
        return nil
    }
    matching[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes

    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
        return nil
    }
    defer { IOObjectRelease(iterator) }

    while case let service = IOIteratorNext(iterator), service != 0 {
        defer { IOObjectRelease(service) }

        guard
            let callout = IORegistryEntryCreateCFProperty(
                service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? String
        else { continue }

        if let ids = usbIDs(startingAt: service), ids.vid == kVendorID, ids.pid == kProductID {
            return callout
        }
    }

    return nil
}

// MARK: - Метрики

/// Загрузка CPU считается по дельте тиков между вызовами.
final class CPUSampler {
    private var previous: (busy: UInt64, total: UInt64)?

    func sample() -> Int {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(machHost, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let busy = UInt64(info.cpu_ticks.0) + UInt64(info.cpu_ticks.1) + UInt64(info.cpu_ticks.3)
        let total = busy + UInt64(info.cpu_ticks.2)

        defer { previous = (busy, total) }

        guard let prev = previous, total > prev.total else { return 0 }

        return Int((Double(busy - prev.busy) / Double(total - prev.total) * 100).rounded())
    }
}

/// Занятая память: active + wired + compressed. Именно эти три категории
/// формируют то, что «Мониторинг системы» показывает как использованную.
func memoryUsedPercent() -> Int {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(
        MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)

    let result = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(machHost, HOST_VM_INFO64, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }

    let pageSize = UInt64(vm_kernel_page_size)
    let used =
        (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count))
        * pageSize
    let total = ProcessInfo.processInfo.physicalMemory
    guard total > 0 else { return 0 }

    return Int((Double(used) / Double(total) * 100).rounded())
}

/// Свободное место так, как его понимает Finder: с учётом вытесняемого
/// «очищаемого» пространства.
func diskFreeGigabytes() -> Int {
    let url = URL(fileURLWithPath: "/")
    guard
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
        let bytes = values.volumeAvailableCapacityForImportantUsage
    else { return 0 }

    return Int(bytes / 1_000_000_000)
}

func batteryState() -> (percent: Int, charging: Bool) {
    guard
        let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
        let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
    else { return (0, false) }

    for source in sources {
        guard
            let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                as? [String: Any],
            let current = info[kIOPSCurrentCapacityKey as String] as? Int,
            let maximum = info[kIOPSMaxCapacityKey as String] as? Int,
            maximum > 0
        else { continue }

        let charging = (info[kIOPSIsChargingKey as String] as? Bool) ?? false
        return (Int((Double(current) / Double(maximum) * 100).rounded()), charging)
    }

    return (0, false)
}

/// Двухбуквенный код текущей раскладки. Берём язык источника ввода, а не его
/// идентификатор: у «Русской — ПК» и «Русской» идентификаторы разные, а язык
/// один.
func currentLayout() -> String {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
        return "--"
    }

    guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else {
        return "--"
    }

    let languages = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String]
    guard let first = languages?.first, !first.isEmpty else { return "--" }

    return String(first.prefix(2)).uppercased()
}

// MARK: - Канал по USB

final class SerialLink {
    private var fd: Int32 = -1

    private func openPort() -> Bool {
        guard let candidate = findDonglePort() else { return false }

        let handle = open(candidate, O_WRONLY | O_NOCTTY | O_NONBLOCK)
        guard handle >= 0 else { return false }

        var options = termios()
        if tcgetattr(handle, &options) == 0 {
            cfmakeraw(&options)
            cfsetspeed(&options, speed_t(B115200))
            _ = tcsetattr(handle, TCSANOW, &options)
        }

        fd = handle
        log("USB: подключился к \(candidate)")
        return true
    }

    private func closePort() {
        if fd >= 0 { close(fd) }
        fd = -1
    }

    var isConnected: Bool { fd >= 0 }

    func send(_ line: String) {
        if fd < 0, !openPort() { return }

        let payload = Array((line + "\n").utf8)
        let written = payload.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }

        // Донгл переткнули или перепрошили — переоткроем на следующем тике.
        if written < 0 {
            log("USB: порт отвалился")
            closePort()
        }
    }
}

// MARK: - Канал по BLE

final class BluetoothLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private var dongle: CBPeripheral?
    private var metrics: CBCharacteristic?
    private var didLogFirstWrite = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    var isConnected: Bool { metrics != nil }

    func send(_ line: String) {
        guard let dongle, let metrics, let data = line.data(using: .utf8) else { return }

        /*
         * Без подтверждения: запись с ответом занимает эфир дважды и держит
         * ATT-канал до прихода ACK, а нажатия летят по нему же. Права на запись
         * уже проверены на этапе внедрения, диагностика тут больше не нужна.
         */
        let type: CBCharacteristicWriteType =
            metrics.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        dongle.writeValue(data, for: metrics, type: type)
    }

    /*
     * Донгл уже подключён системой как HID-клавиатура и ничего не рекламирует,
     * поэтому обычный скан его не найдёт. Правильный путь —
     * retrieveConnectedPeripherals. Сначала спрашиваем по нашему сервису; если
     * система ещё не вычитала GATT-базу и по нему ничего не отдаёт, заходим со
     * стороны HID-сервиса и фильтруем по имени. Скан оставлен на случай, когда
     * донгл не сопряжён вовсе.
     */
    private func locate() {
        guard central.state == .poweredOn, dongle == nil else { return }

        var candidates = central.retrieveConnectedPeripherals(withServices: [kServiceUUID])

        if candidates.isEmpty {
            candidates = central.retrieveConnectedPeripherals(withServices: [kHIDServiceUUID])
                .filter { $0.name == kDongleName }
        }

        if let found = candidates.first {
            log("BLE: нашёл \(found.name ?? "донгл") среди подключённых")
            dongle = found
            found.delegate = self
            central.connect(found, options: nil)
            return
        }

        if !central.isScanning {
            log("BLE: подключённого донгла нет, сканирую")
            central.scanForPeripherals(withServices: [kServiceUUID], options: nil)
        }
    }

    func poll() { locate() }

    func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        if manager.state == .poweredOn {
            locate()
        } else {
            dongle = nil
            metrics = nil
        }
    }

    func centralManager(
        _ manager: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        manager.stopScan()
        dongle = peripheral
        peripheral.delegate = self
        manager.connect(peripheral, options: nil)
    }

    func centralManager(_ manager: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("BLE: соединение установлено, ищу сервис")
        peripheral.discoverServices([kServiceUUID])
    }

    func centralManager(
        _ manager: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        log("BLE: не удалось подключиться: \(error?.localizedDescription ?? "без причины")")
        dongle = nil
        metrics = nil
    }

    func centralManager(
        _ manager: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        log("BLE: соединение потеряно")
        dongle = nil
        metrics = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == kServiceUUID }) else {
            log("BLE: сервиса метрик нет — донгл прошит без CONFIG_SWEEP_DONGLE_HOST_LINK_GATT?")
            return
        }

        peripheral.discoverCharacteristics([kMetricsUUID], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        if let error {
            log("BLE: запись отбита — \(error.localizedDescription)")
        } else if !didLogFirstWrite {
            didLogFirstWrite = true
            log("BLE: запись прошла, канал по воздуху рабочий")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        metrics = service.characteristics?.first(where: { $0.uuid == kMetricsUUID })
        log(metrics != nil ? "BLE: канал готов" : "BLE: характеристика не найдена")
    }
}

// MARK: - Основной цикл

let serial = SerialLink()
let bluetooth = BluetoothLink()
let cpu = CPUSampler()

// Первая выборка CPU задаёт базу для дельты и сама по себе смысла не несёт.
_ = cpu.sample()

/*
 * Загрузка и память округляются до 5%. Это не косметика: каждое изменение
 * текста на панели стоит полного цикла обновления e-paper, а сырые проценты
 * дребезжат на каждой выборке и держали бы панель в непрерывном refresh.
 */
func rounded5(_ value: Int) -> Int { (value + 2) / 5 * 5 }

func tick() {
    bluetooth.poll()

    let battery = batteryState()
    let line = [
        "layout=\(currentLayout())",
        "cpu=\(rounded5(cpu.sample()))",
        "mem=\(rounded5(memoryUsedPercent()))",
        "disk=\(diskFreeGigabytes())",
        "batt=\(battery.percent)",
        "chg=\(battery.charging ? 1 : 0)",
    ].joined(separator: " ")

    // USB эфир ни с кем не делит, туда пишем всегда.
    serial.send(line)

    // А по радио — только когда в печати есть пауза. Приоритет за нажатиями.
    if secondsSinceLastKeystroke() >= kTypingQuietSeconds {
        bluetooth.send(line)
    }
}

Timer.scheduledTimer(withTimeInterval: kIntervalSeconds, repeats: true) { _ in tick() }
RunLoop.main.run()
