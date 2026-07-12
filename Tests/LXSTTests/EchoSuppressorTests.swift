import XCTest
@testable import LXST

/// Validates the Swift EchoSuppressor port against reference vectors captured
/// from the Python `LXST.Filters.EchoSuppressor` (numpy) reference implementation.
final class EchoSuppressorTests: XCTestCase {

    // MARK: - Decimator design

    func testDecimatorTapsMatchReference() {
        // Python: EchoSuppressor()._decim_taps (Hamming-windowed sinc, 12 taps, fc=3700).
        let expected: [Float] = [
            0.002778940135613084, 0.011591588146984577, 0.04110066220164299,
            0.09417863190174103, 0.15478575229644775, 0.19556443393230438,
            0.19556443393230438, 0.15478575229644775, 0.09417863190174103,
            0.04110066220164299, 0.011591588146984577, 0.002778940135613084,
        ]
        let taps = EchoSuppressor.designDecimatorTaps(numTaps: 12, cutoffHz: 3700, samplerate: 48000)
        XCTAssertEqual(taps.count, expected.count)
        for (a, b) in zip(taps, expected) { XCTAssertEqual(a, b, accuracy: 1e-6) }
    }

    // MARK: - Streaming decimate

    func testDecimateMatchesReference() {
        // Two successive calls over a ramp exercise both filter state and the
        // phase (m = (-total) % factor) carry-over.
        let es = EchoSuppressor()
        var state = [Float](repeating: 0, count: 11)
        var total = 0
        let x1 = (0..<60).map { Float($0) * 0.01 }
        let y1 = es.decimate(x1, state: &state, total: &total)
        let x2 = (60..<120).map { Float($0) * 0.01 }
        let y2 = es.decimate(x2, state: &state, total: &total)

        let expY1: [Float] = [0.0, 0.010267061181366444, 0.0650000050663948, 0.1249999925494194,
                              0.1850000023841858, 0.24500000476837158, 0.3049999475479126,
                              0.36500000953674316, 0.42499998211860657, 0.48500001430511475]
        let expY2: [Float] = [0.5450000166893005, 0.6049999594688416, 0.6649999618530273,
                              0.7249999642372131, 0.7850000262260437, 0.8450000286102295,
                              0.9049999713897705, 0.9649999737739563, 1.0249998569488525,
                              1.0850000381469727]
        XCTAssertEqual(y1.count, expY1.count)
        XCTAssertEqual(y2.count, expY2.count)
        for (a, b) in zip(y1, expY1) { XCTAssertEqual(a, b, accuracy: 1e-5) }
        for (a, b) in zip(y2, expY2) { XCTAssertEqual(a, b, accuracy: 1e-5) }
    }

    // MARK: - Pre-emphasis

    func testPreemphMatchesReference() {
        let es = EchoSuppressor()
        let x: [Float] = [0.1, 0.2, -0.3, 0.4, 0.5, -0.1]
        let r = es.preemph(x, state: 0)
        let expected: [Float] = [0.1, 0.105, -0.49, 0.685, 0.12, -0.575]
        for (a, b) in zip(r.out, expected) { XCTAssertEqual(a, b, accuracy: 1e-6) }
        XCTAssertEqual(r.state, -0.1, accuracy: 1e-6)
    }

    // MARK: - Percentile (numpy linear interpolation)

    func testPercentileMatchesNumpy() {
        let es = EchoSuppressor()
        let arr: [Double] = [0.5, 0.1, 0.9, 0.3, 0.7, 0.2]
        XCTAssertEqual(es.percentile(arr, 15), 0.175, accuracy: 1e-9)
        XCTAssertEqual(es.percentile(arr, 50), 0.4, accuracy: 1e-9)
    }

    // MARK: - Comfort noise

    func testComfortNoiseRmsMatchesGain() {
        // Colored comfort noise should have RMS ≈ cng_gain regardless of color.
        let es = EchoSuppressor()
        let block = es.generateCngBlock(8192)
        var ss = 0.0
        for v in block { ss += Double(v) * Double(v) }
        let rms = (ss / Double(block.count)).squareRoot()
        XCTAssertEqual(rms, Double(EchoSuppressor.defaultCngGain), accuracy: 3e-4)
    }

    // MARK: - End-to-end delay estimation + gating

    /// Deterministic LCG noise reference stream (bit-identical to the Python
    /// vector generator). `state = (state*1103515245 + 12345) & 0x7fffffff`.
    private func lcgStream(count: Int, seed: Int) -> [Float] {
        var state = seed
        var out = [Float](repeating: 0, count: count)
        let mask = 0x7fffffff
        for i in 0..<count {
            state = (state &* 1103515245 &+ 12345) & mask
            let u = Float(Double(state) / Double(mask) * 2.0 - 1.0)
            out[i] = u * Float(0.2)
        }
        return out
    }

    func testPureEchoIsDetectedAndGated() {
        // Reproduces the Python end-to-end vector: mic = attenuated (0.25),
        // delayed (1200 samples @48k = 25 ms) copy of the reference — pure echo,
        // no near-end speech. The suppressor must lock the delay and gate the mic.
        let sr = 48000.0
        let n = 1920                // 40 ms frame
        let trueDelay = 1200
        let coupling: Float = 0.25
        let totalFrames = 80

        let es = EchoSuppressor()
        let stream = lcgStream(count: n * (totalFrames + 2), seed: 22222)

        var lastGain = 1.0
        for f in 0..<totalFrames {
            let refFrame = Array(stream[f * n ..< (f + 1) * n])
            es.handleReference(AudioFrame(samples: refFrame, channelCount: 1, sampleRate: sr),
                               samplerate: sr)

            let micStart = f * n - trueDelay
            var micFrame = [Float](repeating: 0, count: n)
            if micStart >= 0 {
                for i in 0..<n { micFrame[i] = stream[micStart + i] * coupling }
            }
            let out = es.handleFrame(AudioFrame(samples: micFrame, channelCount: 1, sampleRate: sr))
            XCTAssertEqual(out.samples.count, n)
            lastGain = es.gain
        }

        // Delay locked near the true 1200-sample echo delay.
        XCTAssertNotNil(es.delaySamples)
        XCTAssertEqual(es.delaySamples ?? 0, Double(trueDelay), accuracy: 60,
                       "estimated echo delay should lock near the true 1200-sample delay")
        // Coupling estimate ≈ 10*log10(0.25^2) = -12.04 dB.
        XCTAssertEqual(es.couplingDb, -12.04, accuracy: 1.5)
        // Pure echo → the mic is gated closed.
        XCTAssertLessThan(lastGain, 0.05, "pure echo must drive the output gain toward zero")
    }

    func testNearEndSpeechIsNotGated() {
        // Reference present, but the mic carries strong independent (near-end)
        // audio uncorrelated with the reference: the suppressor must NOT gate it.
        let sr = 48000.0
        let n = 1920
        let totalFrames = 60

        let es = EchoSuppressor()
        let refStream = lcgStream(count: n * (totalFrames + 2), seed: 22222)
        let micStream = lcgStream(count: n * (totalFrames + 2), seed: 99999)

        var lastGain = 1.0
        for f in 0..<totalFrames {
            let refFrame = Array(refStream[f * n ..< (f + 1) * n])
            es.handleReference(AudioFrame(samples: refFrame, channelCount: 1, sampleRate: sr),
                               samplerate: sr)
            let micFrame = Array(micStream[f * n ..< (f + 1) * n])
            _ = es.handleFrame(AudioFrame(samples: micFrame, channelCount: 1, sampleRate: sr))
            lastGain = es.gain
        }
        // No echo correlation → gate stays open (gain ~ 1.0).
        XCTAssertGreaterThan(lastGain, 0.5, "uncorrelated near-end audio must not be gated")
    }

    // MARK: - Protocol conformance

    func testEchoSuppressorIsAFilterAndReferenceSink() {
        let es = EchoSuppressor()
        XCTAssertTrue((es as Any) is Filter)
        XCTAssertTrue((es as Any) is ReferenceSink)
    }

    func testPassthroughBeforeReferenceAvailable() {
        // With no reference fed yet, the mic frame passes through unchanged.
        let es = EchoSuppressor()
        let n = 1920
        let mic = (0..<n).map { Float(sin(Double($0) * 0.05)) * 0.3 }
        let out = es.handleFrame(AudioFrame(samples: mic, channelCount: 1, sampleRate: 48000))
        XCTAssertEqual(out.samples, mic)
    }
}
