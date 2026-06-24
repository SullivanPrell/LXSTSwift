import XCTest
@testable import LXST

/// Tests for Packetizer wire output and ToneSource/AudioFrame basics.
final class NetworkTests: XCTestCase {

    // MARK: - AudioFrame basics

    func testAudioFrameSampleCount() {
        let f = AudioFrame(samples: [0.1, 0.2, 0.3, 0.4],
                           channelCount: 2, sampleRate: 48000)
        XCTAssertEqual(f.sampleCount, 2, "sampleCount = samples.count / channelCount")
    }

    func testAudioFrameDurationMs() {
        // 480 samples @ 48000 Hz = 10 ms
        let samples = [Float](repeating: 0, count: 480)
        let f = AudioFrame(samples: samples, channelCount: 1, sampleRate: 48000)
        XCTAssertEqual(f.durationMs, 10.0, accuracy: 0.01)
    }

    func testAudioFrameSilenceFactory() {
        let f = AudioFrame.silence(sampleCount: 100, channelCount: 2, sampleRate: 48000)
        XCTAssertEqual(f.samples.count, 200)
        XCTAssertTrue(f.samples.allSatisfy { $0 == 0.0 })
    }

    // MARK: - ToneSource constants

    func testToneSourceDefaultFrequency() {
        XCTAssertEqual(ToneSource.defaultFrequency, 400.0,
                       "Python: ToneSource.DEFAULT_FREQUENCY = 400")
    }

    func testToneSourceDefaultFrameMs() {
        XCTAssertEqual(ToneSource.defaultFrameMs, 80.0,
                       "Python: ToneSource.DEFAULT_FRAME_MS = 80")
    }

    func testToneSourceDefaultSampleRate() {
        XCTAssertEqual(ToneSource.defaultSampleRate, 48000.0,
                       "Python: ToneSource.DEFAULT_SAMPLERATE = 48000")
    }

    func testToneSourceEaseTimeMs() {
        XCTAssertEqual(ToneSource.easeTimeMs, 20.0,
                       "Python: ToneSource.EASE_TIME_MS = 20")
    }

    // MARK: - LineSource constants

    func testLineSourceDefaultFrameMs() {
        XCTAssertEqual(LineSource.defaultFrameMs, 80.0,
                       "Python: LineSource.DEFAULT_FRAME_MS = 80")
    }

    // MARK: - OpusFileSource constants

    func testOpusFileSourceDefaultFrameMs() {
        XCTAssertEqual(OpusFileSource.defaultFrameMs, 100.0,
                       "Python: OpusFileSource.DEFAULT_FRAME_MS = 100")
    }

    // MARK: - Packetizer init

    func testPacketizerInitNilDestination() {
        let p = Packetizer()
        XCTAssertNil(p.destination)
        XCTAssertFalse(p.transmitFailure)
    }

    func testPacketizerConformsToSink() {
        let p: any Sink = Packetizer()
        XCTAssertNotNil(p)
    }

    // MARK: - SignallingReceiver

    func testSignallingReceiverInit() {
        let s = SignallingReceiver()
        XCTAssertNil(s.proxy)
    }

    // MARK: - Signalling wire round-trip
    //
    // These exercise the real on-the-wire signalling codec (encode → decode →
    // dispatch). The pre-fix code msgpack-encoded an EMPTY array on send and
    // substituted empty strings on receive, so no signal value ever crossed the
    // wire — a Swift↔Python call could never progress past link establishment.

    /// Wire bytes for `{FIELD_SIGNALLING:[STATUS_RINGING]}` must match Python
    /// `mp.packb({0x00:[0x04]})` exactly: map(1) key(0x00) array(1) value(0x04).
    func testSignallingEncodeStatusCodeWireBytes() {
        let data = SignallingReceiver.encodeSignals([Int(SignallingStatus.ringing.rawValue)])
        XCTAssertEqual([UInt8](data), [0x81, 0x00, 0x91, 0x04],
                       "Signalling packet must be msgpack {0x00:[0x04]}")
    }

    /// The composite `PREFERRED_PROFILE + profile` (0xFF + 0x40 = 0x13F) exceeds a
    /// single byte and must encode as a msgpack uint16, matching Python.
    func testSignallingEncodeProfileCompositeWireBytes() {
        let composite = Int(SIGNALLING_PREFERRED_PROFILE) + Int(TelephonyProfile.qualityMedium.rawValue)
        XCTAssertEqual(composite, 0x13F)
        let data = SignallingReceiver.encodeSignals([composite])
        // map(1) key(0x00) array(1) uint16(0xCD) 0x01 0x3F
        XCTAssertEqual([UInt8](data), [0x81, 0x00, 0x91, 0xCD, 0x01, 0x3F])
    }

    func testSignallingRoundTripStatusCode() {
        let data = SignallingReceiver.encodeSignals([Int(SignallingStatus.established.rawValue)])
        XCTAssertEqual(SignallingReceiver.decodeSignals(data), [0x06],
                       "Status code must survive encode → decode (not be dropped)")
    }

    /// The key regression: a `PREFERRED_PROFILE + profile` composite must survive
    /// the wire as a plain int. The old code forced it through UInt8, so 0x13F
    /// wrapped to 0x3F and the profile signal was lost.
    func testSignallingRoundTripProfileComposite() {
        let composite = Int(SIGNALLING_PREFERRED_PROFILE) + Int(TelephonyProfile.qualityHigh.rawValue) // 0x14F
        XCTAssertGreaterThan(composite, 0xFF, "Composite must exceed a single byte")
        let data = SignallingReceiver.encodeSignals([composite])
        let decoded = SignallingReceiver.decodeSignals(data)
        XCTAssertEqual(decoded, [0x14F])
        // And it must decode back to the originating profile (Telephone's logic):
        XCTAssertEqual(decoded?.first.map { $0 - Int(SIGNALLING_PREFERRED_PROFILE) },
                       Int(TelephonyProfile.qualityHigh.rawValue))
    }

    func testSignallingRoundTripMultipleSignals() {
        let composite = Int(SIGNALLING_PREFERRED_PROFILE) + Int(TelephonyProfile.latencyLow.rawValue)
        let data = SignallingReceiver.encodeSignals([Int(SignallingStatus.ringing.rawValue), composite])
        XCTAssertEqual(SignallingReceiver.decodeSignals(data), [0x04, composite])
    }

    /// Python wraps a scalar `FIELD_SIGNALLING` value in a single-element list.
    func testSignallingDecodeScalarWrapsInList() {
        let data = MsgPack.encode(.map([
            (.int(Int64(FIELD_SIGNALLING)), .uint(UInt64(SignallingStatus.busy.rawValue)))
        ]))
        XCTAssertEqual(SignallingReceiver.decodeSignals(data), [0x00])
    }

    func testSignallingDecodeNonSignallingReturnsNil() {
        // A frames packet carries no FIELD_SIGNALLING field.
        let data = MsgPack.encode(.map([
            (.int(Int64(FIELD_FRAMES)), .bytes(Data([0xFF, 0x01])))
        ]))
        XCTAssertNil(SignallingReceiver.decodeSignals(data))
    }

    /// End-to-end receive path: encoded packet → decode → `signallingReceived`
    /// must deliver the actual integer signals (including a composite), not
    /// placeholders.
    func testSignallingReceiveDispatchDeliversInts() {
        final class Capturing: SignallingReceiver {
            var received: [Int] = []
            override func signallingReceived(_ signals: [Int], from source: (any Source)?) {
                received.append(contentsOf: signals)
            }
        }
        let receiver = Capturing()
        let composite = Int(SIGNALLING_PREFERRED_PROFILE) + Int(TelephonyProfile.qualityMax.rawValue)
        let data = SignallingReceiver.encodeSignals([Int(SignallingStatus.ringing.rawValue), composite])

        receiver.processSignallingData(data, from: nil)

        XCTAssertEqual(receiver.received, [0x04, composite],
                       "Dispatched signals must be the decoded integers, not empty strings")
    }
}
