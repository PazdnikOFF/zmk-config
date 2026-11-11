import AudioToolbox
import CoreAudio
import Foundation

/*
 * Приглушение звука Mac на время записи: громкость выхода по умолчанию — до 1 %,
 * после — как было. Как mute_while_recording у Handy, только не в ноль: так
 * просил владелец.
 *
 * Возвращаем прежнюю громкость, только если её за время диктовки никто не
 * менял: подкрутил человек сам — его выбор не перетираем. Прежнее значение
 * сохраняется в UserDefaults: если агент упадёт посреди диктовки, при следующем
 * запуске громкость вернётся.
 *
 * Устройства без программной громкости (HDMI, часть USB-ЦАП) пропускаем молча.
 */
enum DictationVolume {
    static let duckLevel: Float32 = 0.01

    private static let savedKey = "dictation.savedVolume"
    private static var saved: Float32?
    private static var ours: Float32?

    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    private static func outputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static func volume(of device: AudioObjectID) -> Float32? {
        guard AudioObjectHasProperty(device, &volumeAddress) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    @discardableResult
    private static func setVolume(_ value: Float32, of device: AudioObjectID) -> Bool {
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &volumeAddress, &settable) == noErr, settable.boolValue
        else { return false }
        var value = value
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &volumeAddress, 0, nil, size, &value) == noErr
    }

    /// Играет ли что-то на Mac сейчас: какая-то программа держит устройство вывода запущенным.
    static func outputIsRunning() -> Bool {
        guard let device = outputDevice() else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running)
        return status == noErr && running != 0
    }

    /// Приглушить. Уже тише 1 % или громкость не управляется — ничего не делаем.
    static func duck() {
        guard saved == nil, let device = outputDevice(), let current = volume(of: device),
            current > duckLevel + 0.005
        else { return }
        guard setVolume(duckLevel, of: device) else { return }
        saved = current
        ours = volume(of: device) ?? duckLevel
        UserDefaults.standard.set(Double(current), forKey: savedKey)
        DictationLog.write("громкость Mac \(percent(current)) → \(percent(duckLevel))")
    }

    /// Вернуть как было. Можно звать сколько угодно раз.
    static func restore() {
        guard let previous = saved else { return }
        saved = nil
        UserDefaults.standard.removeObject(forKey: savedKey)
        guard let device = outputDevice(), let current = volume(of: device) else { return }
        // Человек сам поменял громкость во время записи — оставляем его значение.
        guard abs(current - (ours ?? duckLevel)) < 0.01 else {
            DictationLog.write("громкость Mac изменили вручную (\(percent(current))) — не возвращаю")
            return
        }
        setVolume(previous, of: device)
        DictationLog.write("громкость Mac → \(percent(previous))")
    }

    /// Агент упал посреди диктовки — вернуть громкость при запуске.
    static func recoverAfterCrash() {
        guard let value = UserDefaults.standard.object(forKey: savedKey) as? Double else { return }
        saved = Float32(value)
        ours = duckLevel
        restore()
    }

    private static func percent(_ value: Float32) -> String { "\(Int((value * 100).rounded())) %" }
}
