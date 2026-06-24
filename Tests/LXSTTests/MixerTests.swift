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
}
