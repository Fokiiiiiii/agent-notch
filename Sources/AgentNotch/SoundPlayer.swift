import AppKit

enum AppSound: String, CaseIterable {
    case done, permission, approve, deny, navigation, action
}

/// A tiny local sound studio. Each cue is synthesized once at launch, so the
/// app has its own restrained sonic identity without bundled or downloaded
/// audio assets.
@MainActor
final class SoundPlayer {
    static let shared = SoundPlayer()

    private struct Tone {
        let start: Double
        let duration: Double
        let from: Double
        let to: Double
        let gain: Double

        init(_ start: Double, _ duration: Double, _ from: Double, _ to: Double? = nil, _ gain: Double) {
            self.start = start
            self.duration = duration
            self.from = from
            self.to = to ?? from
            self.gain = gain
        }
    }

    private var lastPlayedAt: [AppSound: Date] = [:]
    private var sounds: [AppSound: NSSound] = [:]

    private init() {
        for cue in AppSound.allCases {
            sounds[cue] = NSSound(data: Self.makeWave(tones: Self.tones(for: cue)))
        }
    }

    func play(_ sound: AppSound) {
        let now = Date()
        if let last = lastPlayedAt[sound], now.timeIntervalSince(last) < debounce(for: sound) {
            return
        }
        lastPlayedAt[sound] = now

        guard let cue = sounds[sound] else { return }
        if cue.isPlaying { cue.stop() }
        cue.volume = volume(for: sound)
        cue.play()
    }

    private func debounce(for sound: AppSound) -> TimeInterval {
        switch sound {
        case .done, .permission: return 0.9
        case .approve, .deny: return 0.18
        case .navigation: return 0.08
        case .action: return 0.12
        }
    }

    private func volume(for sound: AppSound) -> Float {
        switch sound {
        case .done: return 0.34
        case .permission: return 0.28
        case .approve: return 0.30
        case .deny: return 0.22
        case .navigation: return 0.12
        case .action: return 0.16
        }
    }

    private static func tones(for sound: AppSound) -> [Tone] {
        switch sound {
        case .permission:
            return [
                Tone(0.00, 0.12, 587, 659, 0.50),
                Tone(0.075, 0.17, 880, 988, 0.42)
            ]
        case .approve:
            return [
                Tone(0.00, 0.11, 740, 830, 0.48),
                Tone(0.065, 0.18, 988, 1175, 0.44)
            ]
        case .deny:
            return [
                Tone(0.00, 0.19, 246, 185, 0.48),
                Tone(0.025, 0.15, 123, 110, 0.20)
            ]
        case .navigation:
            return [Tone(0.00, 0.055, 1320, 960, 0.34)]
        case .action:
            return [
                Tone(0.00, 0.075, 680, 760, 0.34),
                Tone(0.018, 0.060, 1360, 1520, 0.12)
            ]
        case .done:
            return [
                Tone(0.00, 0.14, 523, 587, 0.38),
                Tone(0.085, 0.17, 784, 880, 0.36),
                Tone(0.175, 0.23, 1047, 1319, 0.31)
            ]
        }
    }

    private static func makeWave(tones: [Tone]) -> Data {
        let sampleRate = 44_100
        let duration = (tones.map { $0.start + $0.duration }.max() ?? 0.1) + 0.025
        let sampleCount = Int(duration * Double(sampleRate))
        var samples = [Int16](repeating: 0, count: sampleCount)

        for index in samples.indices {
            let time = Double(index) / Double(sampleRate)
            var mixed = 0.0
            for tone in tones {
                let local = time - tone.start
                guard local >= 0, local < tone.duration else { continue }

                let attack = min(local / 0.006, 1)
                let release = pow(max(0, 1 - local / tone.duration), 2.25)
                let sweep = tone.to - tone.from
                let phase = 2 * Double.pi * (tone.from * local + 0.5 * sweep * local * local / tone.duration)
                let body = sin(phase) + 0.11 * sin(phase * 2 + 0.35)
                mixed += body * attack * release * tone.gain
            }
            let softened = tanh(mixed * 0.82) * 0.72
            samples[index] = Int16(max(-1, min(1, softened)) * Double(Int16.max))
        }

        var data = Data()
        let dataByteCount = UInt32(samples.count * MemoryLayout<Int16>.size)
        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(36) + dataByteCount)
        data.appendASCII("WAVEfmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate * 2))
        data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt16(16))
        data.appendASCII("data")
        data.appendLittleEndian(dataByteCount)
        for sample in samples {
            data.appendLittleEndian(UInt16(bitPattern: sample))
        }
        return data
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
