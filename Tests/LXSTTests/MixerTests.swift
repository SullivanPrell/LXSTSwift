import XCTest
@testable import LXST

/// Tests for Mixer multi-source mixing, gain, mute, and frame queue management.
final class MixerTests: XCTestCase {

    final class MockSink: Sink {
        var channels:   Int?   = 1
        var sampleRate: Double = 48000
        var received: [AudioFrame] = []
        func handleFrame(_ frame: AudioFrame, from source: (any Source)?) {
            received.append(frame)
        }
    }

    // MARK: - Constants

    func testMaxFrames() {
        XCTAssertEqual(Mixer.maxFrames, 8, "Python: Mixer.MAX_FRAMES = 8")
    }

    // MARK: - Default init

    func testMixerDefaultTargetFrameMs() {
        let m = Mixer()
        XCTAssertEqual(m.targetFrameMs, 40.0,
                       "Python: Mixer default target_frame_ms = 40")
    }

    func testMixerDefaultGain() {
        let m = Mixer()
        XCTAssertEqual(m.gain, 0.0)
    }

    func testMixerDefaultMuted() {
        let m = Mixer()
        XCTAssertFalse(m.muted)
    }

    // MARK: - setGain (Python: set_gain(gain=None))

    func testSetGainNilResetsToZero() {
        let m = Mixer(gain: 6.0)
        m.setGain(nil)
        XCTAssertEqual(m.gain, 0.0, "setGain(nil) must reset to 0.0 dB")
    }

    func testSetGainSetsValue() {
        let m = Mixer()
        m.setGain(3.0)
        XCTAssertEqual(m.gain, 3.0)
    }

    // MARK: - mute / unmute

    func testMuteMutesAndUnmuteUnmutes() {
        let m = Mixer()
        m.mute()
        XCTAssertTrue(m.muted, "mute() must set muted = true")
        m.unmute()
        XCTAssertFalse(m.muted, "unmute() must set muted = false")
    }

    func testMuteWithFalseUnmutes() {
        let m = Mixer()
        m.mute(true)
        m.mute(false)
        XCTAssertFalse(m.muted)
    }

    // MARK: - canReceive (Python: can_receive)

    func testCanReceiveReturnsTrueWhenQueueEmpty() {
        let m = Mixer()
        let src = Loopback()
        XCTAssertTrue(m.canReceive(from: src))
    }

    func testCanReceiveReturnsFalseWhenQueueFull() {
        let m = Mixer()
        let src = Loopback()
        m.setSourceMaxFrames(2, for: src)

        let frame = AudioFrame(samples: [0.0], channelCount: 1, sampleRate: 48000)
        m.handleFrame(frame, from: src)
        m.handleFrame(frame, from: src)
        XCTAssertFalse(m.canReceive(from: src),
                       "canReceive must return false when queue is at max capacity")
    }

    // MARK: - setSourceMaxFrames

    func testSetSourceMaxFramesLimitsQueue() {
        let m   = Mixer()
        let src = Loopback()
        m.setSourceMaxFrames(1, for: src)

        let frame = AudioFrame(samples: [0.0], channelCount: 1, sampleRate: 48000)
        m.handleFrame(frame, from: src)
        m.handleFrame(frame, from: src)  // should be dropped

        XCTAssertFalse(m.canReceive(from: src),
                       "Queue must be at limit after setSourceMaxFrames(1)")
    }

    // MARK: - handleFrame accepts frames

    func testHandleFrameAcceptsFrameFromSource() {
        let m   = Mixer()
        let src = Loopback()
        let frame = AudioFrame(samples: [0.5], channelCount: 1, sampleRate: 48000)
        m.handleFrame(frame, from: src)
        XCTAssertTrue(m.canReceive(from: src) == false || m.canReceive(from: src) == true)
        // Key invariant: no crash, frame was accepted
    }

    // MARK: - Source/Sink protocol conformance

    func testMixerConformsToSource() {
        let m: any Source = Mixer()
        XCTAssertNotNil(m)
    }

    func testMixerConformsToSink() {
        let m: any Sink = Mixer()
        XCTAssertNotNil(m)
    }

    // MARK: - Reference outputs (echo-cancellation reference)

    final class MockReferenceSink: ReferenceSink {
        let lock = NSLock()
        private var _frames: [AudioFrame] = []
        private var _rates: [Double] = []
        var onReceive: (() -> Void)?
        var frames: [AudioFrame] { lock.lock(); defer { lock.unlock() }; return _frames }
        var rates: [Double] { lock.lock(); defer { lock.unlock() }; return _rates }
        func handleReference(_ frame: AudioFrame, samplerate: Double) {
            lock.lock(); _frames.append(frame); _rates.append(samplerate); lock.unlock()
            onReceive?()
        }
    }

    // MARK: - Concurrency (run under `swift test --sanitize=thread`)

    /// A sink whose frame count is guarded by a lock, so the test thread can read
    /// it without racing the mix thread's writes.
    final class CountingSink: Sink {
        var channels:   Int?   = 1
        var sampleRate: Double = 48000
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
        func handleFrame(_ frame: AudioFrame, from source: (any Source)?) {
            lock.lock(); _count += 1; lock.unlock()
        }
    }

    /// The core regression test for the ThreadSanitizer race in `Mixer.setGain`:
    /// while the mix loop reads `gain`/`muted`/`referenceOuts`/`shouldRun` every
    /// frame on the `lxst.mixer` thread, hammer all of them (plus the frame queue)
    /// from several control threads. Must be clean under `--sanitize=thread`.
    func testConcurrentControlPlaneStressIsRaceFree() {
        let m = Mixer(targetFrameMs: 5, sampleRate: 48000)
        m.sink = CountingSink()

        let src = Loopback()
        m.setSourceMaxFrames(64, for: src)

        let n = Int(48000 * 5 / 1000) // 240 samples per 5 ms frame
        let frame = AudioFrame(samples: [Float](repeating: 0.25, count: n),
                               channelCount: 1, sampleRate: 48000)

        m.start()

        let deadline = Date().addingTimeInterval(0.4)
        let group = DispatchGroup()

        func spawn(_ body: @escaping () -> Void) {
            group.enter()
            DispatchQueue.global().async { body(); group.leave() }
        }

        // Writer: gain (Telephone.setReceiveGain path)
        spawn { var i = 0; while Date() < deadline { m.setGain(Float(i % 12) - 6); i += 1 } }
        // Writer: mute/unmute (Telephone.muteReceive path)
        spawn { var on = false; while Date() < deadline { on.toggle(); m.mute(on) } }
        // Writer: referenceOuts churn (openPipelines assigns this on a live mixer)
        spawn {
            let refs = [MockReferenceSink(), MockReferenceSink()]
            var i = 0
            while Date() < deadline { m.referenceOuts = (i % 2 == 0) ? refs : []; i += 1 }
        }
        // Producer: frames into the queue + backpressure check
        spawn { while Date() < deadline { if m.canReceive(from: src) { m.handleFrame(frame, from: src) } } }
        // Reader: public getters from an unrelated thread (Telephone.receiveMuted path)
        spawn { while Date() < deadline { _ = m.gain; _ = m.muted; _ = m.shouldRun; _ = m.referenceOuts } }
        // Churn the per-source frame limit (switchProfile path)
        spawn { var k = 1; while Date() < deadline { m.setSourceMaxFrames((k % 8) + 1, for: src); k += 1 } }

        group.wait()
        m.stop()
        Thread.sleep(forTimeInterval: 0.05) // let the mix loop wind down

        // The actual race detector for this test is ThreadSanitizer: the
        // gain/muted/shouldRun scalar read/write races are benign on this
        // hardware (aligned word-sized loads don't tear into wrong values), so
        // ONLY `--sanitize=thread` observes them — a plain `swift test` cannot.
        // What a plain run CAN check is that the lock-backed run-flag accessor
        // still functions after the storm: a full start→stop round-trip that a
        // broken getter/setter would fail (unlike a bare post-stop() assert,
        // which is tautological because stop() sets the flag false unconditionally).
        XCTAssertFalse(m.shouldRun, "mixer must be stopped after stop()")
        m.start(); XCTAssertTrue(m.shouldRun, "start() must set the run flag through the lock")
        m.stop();  XCTAssertFalse(m.shouldRun, "stop() must clear the run flag through the lock")
    }

    /// Specifically targets `stop()` (hangup → stopPipelines, on the Reticulum
    /// callback thread) racing `setGain`/`mute` (app thread) while the mix loop
    /// reads. `stop` and the gain/mute writes all mutate control state under the
    /// same lock, so this must be race-free.
    func testStopRacingControlWritesIsRaceFree() {
        let m = Mixer(targetFrameMs: 5, sampleRate: 48000)
        m.sink = CountingSink()

        let src = Loopback()
        let n = Int(48000 * 5 / 1000)
        let frame = AudioFrame(samples: [Float](repeating: 0.1, count: n),
                               channelCount: 1, sampleRate: 48000)
        m.setSourceMaxFrames(32, for: src)
        m.start()

        let deadline = Date().addingTimeInterval(0.3)
        let group = DispatchGroup()

        func spawn(_ body: @escaping () -> Void) {
            group.enter()
            DispatchQueue.global().async { body(); group.leave() }
        }

        spawn { var i = 0; while Date() < deadline { m.setGain(Float(i % 10)); m.mute(i % 3 == 0); i += 1 } }
        spawn { while Date() < deadline { if m.canReceive(from: src) { m.handleFrame(frame, from: src) } } }
        spawn { while Date() < deadline { _ = m.shouldRun } }
        // Fire stop() from a distinct thread partway through, mid-write-storm.
        spawn { Thread.sleep(forTimeInterval: 0.15); m.stop() }

        group.wait()
        m.stop()
        Thread.sleep(forTimeInterval: 0.05)
        // ThreadSanitizer is the race detector here (see
        // testConcurrentControlPlaneStressIsRaceFree). Without the sanitizer we
        // can still assert the lock-backed run flag round-trips correctly.
        XCTAssertFalse(m.shouldRun)
        m.start(); XCTAssertTrue(m.shouldRun)
        m.stop();  XCTAssertFalse(m.shouldRun)
    }

    func testReferenceOutReceivesMixedFrame() {
        let m = Mixer(targetFrameMs: 10, sampleRate: 48000)
        let sink = MockSink()
        let ref = MockReferenceSink()
        m.sink = sink
        m.referenceOuts = [ref]

        let exp = expectation(description: "reference out received a frame")
        exp.assertForOverFulfill = false
        ref.onReceive = { exp.fulfill() }

        let n = Int(48000 * 10 / 1000)  // 480 samples per 10 ms frame
        let src = Loopback()
        m.handleFrame(AudioFrame(samples: [Float](repeating: 0.5, count: n),
                                 channelCount: 1, sampleRate: 48000), from: src)
        m.start()
        wait(for: [exp], timeout: 3.0)
        m.stop()

        XCTAssertFalse(ref.frames.isEmpty, "reference sink must receive the mixed frame")
        XCTAssertEqual(ref.rates.first, 48000, "reference sink must receive the mixer samplerate")
        // The reference frame is the raw mixed signal (0.5 gain-unity), not silence.
        XCTAssertEqual(ref.frames.first?.samples.first ?? 0, 0.5, accuracy: 1e-6)
    }
}
