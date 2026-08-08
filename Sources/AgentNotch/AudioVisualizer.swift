import AVFoundation
import Combine
import ScreenCaptureKit

/// Drives the compact waveform from what's actually coming out of the
/// speakers, instead of the `sin()` animation it falls back to.
///
/// ScreenCaptureKit is the only supported way to tap system audio output on
/// macOS without a virtual audio device, which is why this needs Screen
/// Recording permission despite never looking at the screen: the stream is
/// configured for audio and its video frames are ignored.
///
/// Scope is deliberately one number — overall loudness. Per-band FFT would
/// buy nothing at the size this renders (four bars, 16pt wide).
@MainActor
final class AudioVisualizer: NSObject, ObservableObject {
    static let shared = AudioVisualizer()

    /// 0…1 loudness, smoothed. Stays at `idleAmplitude` whenever capture
    /// isn't running, which is what makes the waveform fall back to its
    /// synthetic animation unchanged.
    @Published private(set) var amplitude: Double = idleAmplitude
    @Published private(set) var isRunning = false
    /// Non-nil when capture couldn't start — almost always Screen Recording
    /// permission. Surfaced in Settings rather than in the notch.
    @Published private(set) var errorMessage: String?

    /// The value that means "no live signal". `CompactMediaWaveform` treats
    /// it as "animate synthetically", so it must not be 0 (silence) — 0 is a
    /// real reading that should flatten the bars.
    static let idleAmplitude: Double = -1

    /// How much of the previous reading survives into the next one. Audio
    /// buffers arrive far faster than the 0.16s the waveform redraws at, so
    /// without smoothing the bars would jitter at a rate nobody can read.
    static let smoothingFactor: Double = 0.72

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "com.chaos.agent-notch.audio-visualizer")
    private var isStarting = false

    private override init() {
        super.init()
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            Task { await start() }
        } else {
            stop()
        }
    }

    func start() async {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        do {
            // Also the permission check: this throws when Screen Recording
            // hasn't been granted.
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            guard let display = content.displays.first else {
                errorMessage = String(localized: "visualizer.noDisplay", defaultValue: "No display available")
                return
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            // Video can't be switched off, so it's shrunk to the cheapest
            // thing the API accepts and its frames are never handled.
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()
            self.stream = stream
            isRunning = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            isRunning = false
        }
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        isRunning = false
        amplitude = Self.idleAmplitude
        Task {
            try? await stream.stopCapture()
        }
    }

    /// Root-mean-square of one buffer, normalized so typical playback lands
    /// in the upper half of 0…1. RMS rather than peak: peak jumps on a
    /// single transient, which reads as a glitch rather than as loudness.
    nonisolated static func rms(samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        let raw = (sumOfSquares / Double(samples.count)).squareRoot()
        // Music sits well below full scale, so raw RMS would keep the bars
        // near the floor. This maps a realistic listening range onto 0…1.
        return min(1, raw * 4)
    }

    /// Exponential smoothing between consecutive readings. `factor` is how
    /// much of `previous` is kept.
    nonisolated static func smoothed(previous: Double, next: Double, factor: Double) -> Double {
        let clamped = min(max(factor, 0), 1)
        // A previous value of `idleAmplitude` isn't a loudness at all —
        // starting from it would drag the first real reading negative.
        guard previous >= 0 else { return next }
        return previous * clamped + next * (1 - clamped)
    }
}

extension AudioVisualizer: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, let samples = Self.extractSamples(from: sampleBuffer) else { return }
        let level = Self.rms(samples: samples)
        Task { @MainActor in
            AudioVisualizer.shared.apply(level)
        }
    }

    private func apply(_ level: Double) {
        guard isRunning else { return }
        amplitude = Self.smoothed(previous: amplitude, next: level, factor: Self.smoothingFactor)
    }

    /// Flattens a buffer's (possibly multi-channel) float PCM into one array.
    /// Returns nil for any format that isn't 32-bit float, rather than
    /// reinterpreting bytes that might be integer PCM.
    private nonisolated static func extractSamples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32
        else { return nil }

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        var samples: [Float] = []
        let buffers = UnsafeMutableAudioBufferListPointer(&audioBufferList)
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let pointer = data.bindMemory(to: Float.self, capacity: count)
            samples.append(contentsOf: UnsafeBufferPointer(start: pointer, count: count))
        }
        return samples.isEmpty ? nil : samples
    }
}
