import XCTest
@testable import LXST

/// dB → linear gain convention parity, asserted through the LIVE audio paths.
///
/// Python converts dB to a linear multiplier with the POWER-dB formula
/// `10 ** (dB / 10)` and applies the result directly to amplitude samples —
/// nonstandard (the amplitude convention would be dB/20) but authoritative
/// for parity, and used identically at all three Python gain sites:
///   - Sources.py:180     `linear_gain(gain_db): return 10**(gain_db/10)`,
///     applied to mic samples at Sources.py:270 before codec.encode
///   - Mixer.py:102       `_mixing_gain`: `return 10**(self.gain/10)`,
///     applied to every mixed frame at Mixer.py:113-114
///   - Filters.py:187-188 AGC `target_linear` / `max_gain_linear`
///
/// Every expected value below is a hardcoded literal evaluated from Python's
/// formula (e.g. `10**(10/10)` = 10.0) — never computed by calling the Swift
/// code under test. Each test drives real frames through a production path
/// (LineSource.deliver, the Mixer mix loop, AGC.handleFrame); none tests a
/// conversion helper in isolation — helper-only tests previously passed while
/// all three live paths shipped with 10^(dB/20).
final class PowerDBGainParityTests: XCTestCase {

    /// Records delivered frames under a lock so the test thread can read them
    /// without racing the mixer thread's writes.
    private final class CaptureSink: Sink {
        var channels:   Int?   = 1
        var sampleRate: Double = 48000
        private let lock = NSLock()
        private var unsafeFrames: [AudioFrame] = []
        var onReceive: (() -> Void)?
        var frames: [AudioFrame] { lock.lock(); defer { lock.unlock() }; return unsafeFrames }
        func handleFrame(_ frame: AudioFrame, from source: (any Source)?) {
            lock.lock(); unsafeFrames.append(frame); lock.unlock()
            onReceive?()
        }
    }

    // MARK: - LineSource.deliver (mic gain; Python: Sources.py:180,:199,:270)

    func testLineSourceDeliverAppliesPowerDBGainToMicSamples() {
        let backend = MockAudioBackend()
        let sink    = CaptureSink()
        let src     = LineSource(sink: sink, gain: 10.0, backend: backend)
        src.start()
        backend.injectFrame(AudioFrame(samples: [0.05, -0.05],
                                       channelCount: 1, sampleRate: 48000))
        src.stop()

        let received = sink.frames
        XCTAssertEqual(received.count, 1)
        // Python: 0.05 * 10**(10/10) = 0.05 * 10.0 = 0.5
        XCTAssertEqual(received[0].samples[0], 0.5, accuracy: 1e-4,
                       "+10 dB mic gain must multiply samples by 10**(10/10) = 10.0 (Sources.py:180)")
        XCTAssertEqual(received[0].samples[1], -0.5, accuracy: 1e-4)
    }

    // MARK: - Mixer mix loop (mixing gain; Python: Mixer.py:102,:113-114)

    func testMixerMixLoopAppliesPowerDBMixingGain() {
        let m    = Mixer(targetFrameMs: 10, sampleRate: 48000, gain: -10.0)
        let sink = CaptureSink()
        m.sink = sink

        let exp = expectation(description: "mixed frame delivered")
        exp.assertForOverFulfill = false
        sink.onReceive = { exp.fulfill() }

        let n   = Int(48000 * 10 / 1000)  // 480 samples per 10 ms frame
        let src = Loopback()
        m.handleFrame(AudioFrame(samples: [Float](repeating: 0.05, count: n),
                                 channelCount: 1, sampleRate: 48000), from: src)
        m.start()
        wait(for: [exp], timeout: 3.0)
        m.stop()

        // Python: 0.05 * 10**(-10/10) = 0.05 * 0.1 = 0.005
        XCTAssertEqual(sink.frames.first?.samples.first ?? .nan, 0.005, accuracy: 1e-4,
                       "-10 dB mixing gain must multiply the mixed frame by 10**(-10/10) = 0.1 (Mixer.py:102)")
    }

    // MARK: - AGC target level (Python: Filters.py:187)

    func testAGCNormalizesToPowerDBTargetLevel() {
        // The default call transmit chain runs AGC(target_level=-15.0) over the
        // mic signal (Python Telephony.py:711; Swift Telephony.swift:993), so
        // this constant sets the loudness of every transmitted payload.
        let agc   = AGC(targetLevel: -15.0)
        let frame = AudioFrame(samples: [Float](repeating: 0.5, count: 480),
                               channelCount: 1, sampleRate: 48000)
        var out = frame
        for _ in 0..<200 { out = agc.handleFrame(frame) }

        // Steady state: constant input at RMS 0.5 is scaled to
        // target_linear = 10**(-15/10) = 0.0316228 (Filters.py:187).
        XCTAssertEqual(out.samples[0], 0.0316228, accuracy: 0.001,
                       "AGC must normalize toward 10**(target_level/10) (Filters.py:187)")
    }

    // MARK: - AGC max gain (Python: Filters.py:188)

    func testAGCMaxGainUsesPowerDBConvention() {
        // releaseTime shortened only so the release-smoothed gain converges
        // within the test; the constants under test are targetLevel/maxGain.
        let agc   = AGC(targetLevel: -12.0, maxGain: 12.0, releaseTime: 0.0001)
        let frame = AudioFrame(samples: [Float](repeating: 0.0035, count: 480),
                               channelCount: 1, sampleRate: 48000)
        var out = frame
        for _ in 0..<200 { out = agc.handleFrame(frame) }

        // Desired gain 10**(-12/10)/0.0035 = 18.03 exceeds
        // max_gain_linear = 10**(12/10) = 15.8489 (Filters.py:188), so the
        // output settles at 0.0035 * 15.8489 = 0.0554712.
        XCTAssertEqual(out.samples[0], 0.0554712, accuracy: 0.001,
                       "AGC gain must cap at 10**(max_gain/10) (Filters.py:188)")
    }
}
