import XCTest
@testable import AgentNotch

/// Covers the two pure functions that turn audio buffers into a bar height.
/// `extractSamples` and the ScreenCaptureKit stream itself need real system
/// audio and Screen Recording permission, so they're verified by hand.
final class AudioVisualizerTests: XCTestCase {
    func testRMSOfSilenceIsZero() {
        XCTAssertEqual(AudioVisualizer.rms(samples: [0, 0, 0, 0]), 0, accuracy: 0.0001)
    }

    func testRMSOfEmptyBufferIsZero() {
        XCTAssertEqual(AudioVisualizer.rms(samples: []), 0, accuracy: 0.0001)
    }

    /// RMS is sign-independent — a negative half-cycle is just as loud as a
    /// positive one, and treating it otherwise would make the meter pulse at
    /// the waveform's own frequency.
    func testRMSIgnoresSign() {
        let positive = AudioVisualizer.rms(samples: [0.2, 0.2, 0.2, 0.2])
        let alternating = AudioVisualizer.rms(samples: [0.2, -0.2, 0.2, -0.2])
        XCTAssertEqual(positive, alternating, accuracy: 0.0001)
    }

    func testRMSGrowsWithLoudness() {
        let quiet = AudioVisualizer.rms(samples: [0.05, -0.05])
        let loud = AudioVisualizer.rms(samples: [0.5, -0.5])
        XCTAssertLessThan(quiet, loud)
    }

    /// The 4× gain that maps a realistic listening level onto the bar's
    /// range must not let a loud passage push past full scale.
    func testRMSIsClampedToOne() {
        XCTAssertEqual(AudioVisualizer.rms(samples: [1, -1, 1, -1]), 1, accuracy: 0.0001)
        XCTAssertEqual(AudioVisualizer.rms(samples: [0.9, -0.9]), 1, accuracy: 0.0001)
    }

    func testSmoothedBlendsTowardTheNewReading() {
        let result = AudioVisualizer.smoothed(previous: 0, next: 1, factor: 0.75)
        XCTAssertEqual(result, 0.25, accuracy: 0.0001)
    }

    func testSmoothedWithFactorZeroTakesTheNewReadingOutright() {
        XCTAssertEqual(AudioVisualizer.smoothed(previous: 0.2, next: 0.9, factor: 0), 0.9, accuracy: 0.0001)
    }

    func testSmoothedWithFactorOneHoldsThePreviousReading() {
        XCTAssertEqual(AudioVisualizer.smoothed(previous: 0.2, next: 0.9, factor: 1), 0.2, accuracy: 0.0001)
    }

    /// `idleAmplitude` is a sentinel ("no live signal"), not a loudness.
    /// Blending from it would drag the first real reading below zero and
    /// flatten the bars for a moment on every start.
    func testSmoothedFromTheIdleSentinelTakesTheReadingDirectly() {
        let result = AudioVisualizer.smoothed(
            previous: AudioVisualizer.idleAmplitude,
            next: 0.6,
            factor: AudioVisualizer.smoothingFactor
        )
        XCTAssertEqual(result, 0.6, accuracy: 0.0001)
    }

    func testSmoothedClampsAnOutOfRangeFactor() {
        XCTAssertEqual(AudioVisualizer.smoothed(previous: 0.2, next: 0.9, factor: 5), 0.2, accuracy: 0.0001)
        XCTAssertEqual(AudioVisualizer.smoothed(previous: 0.2, next: 0.9, factor: -3), 0.9, accuracy: 0.0001)
    }

    /// The waveform tells "no signal" from "silence" by sign, so the
    /// sentinel has to stay outside the 0…1 range RMS can produce.
    func testIdleSentinelIsOutsideTheRealAmplitudeRange() {
        XCTAssertLessThan(AudioVisualizer.idleAmplitude, 0)
    }
}
