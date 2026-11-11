import AppKit

/*
 * Короткие звуки начала и конца записи. Играют на Mac, не на колонке.
 *
 * Синтезируются при запуске в WAV в памяти: два мягких тона по 45 мс
 * (начало — вверх, конец — вниз), без файлов в бандле. NSSound из готовых
 * данных стартует без заметной задержки.
 */
enum DictationSounds {
    private static let rate = 44_100

    private static let startSound = make(notes: [784, 1046.5])  // G5 → C6
    private static let stopSound = make(notes: [1046.5, 784])  // C6 → G5

    /// Синтез заранее, чтобы первый звук не ждал.
    static func prepare() { _ = (startSound, stopSound) }

    static func playStart() { play(startSound) }
    static func playStop() { play(stopSound) }

    private static func play(_ sound: NSSound?) {
        guard DictationSettings.shared.sounds, let sound else { return }
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    private static func make(notes: [Double]) -> NSSound? {
        let noteSamples = rate * 45 / 1000
        var samples: [Int16] = []
        samples.reserveCapacity(noteSamples * notes.count)
        for frequency in notes {
            for n in 0..<noteSamples {
                let t = Double(n) / Double(rate)
                let attack = min(1.0, Double(n) / (Double(rate) * 0.004))
                let decay = exp(-t * 38)
                let value = sin(2 * .pi * frequency * t) * attack * decay * 0.22
                samples.append(Int16(value * Double(Int16.max)))
            }
        }
        return NSSound(data: wav(samples))
    }

    private static func wav(_ samples: [Int16]) -> Data {
        var data = Data()
        func put32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        put32(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        put32(16)
        put16(1)  // PCM
        put16(1)  // моно
        put32(UInt32(rate))
        put32(UInt32(rate * 2))
        put16(2)
        put16(16)
        data.append(contentsOf: Array("data".utf8))
        put32(bytes)
        for sample in samples { put16(UInt16(bitPattern: sample)) }
        return data
    }
}
