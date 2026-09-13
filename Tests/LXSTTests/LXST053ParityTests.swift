//===----------------------------------------------------------------------===//
// Copyright (c) 2026 LXSTSwift contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

import ReticulumSwift
import XCTest

@testable import LXST

// MARK: - AGC pause

/// `Filters.py:189`, `:202`.
final class AGCPauseTests: XCTestCase {

  private func quietFrame() -> AudioFrame {
    AudioFrame(
      samples: [Float](repeating: 0.01, count: 480), channelCount: 1, sampleRate: 48000)
  }

  func testAGCIsNotPausedByDefault() {
    XCTAssertFalse(AGC().paused, "Python: `self.paused = False` (Filters.py:189)")
  }

  func testAnUnpausedAGCDrivesTheLevel() {
    let frame = quietFrame()
    let out = AGC(targetLevel: -12).handleFrame(frame)
    XCTAssertNotEqual(
      out.samples[0], frame.samples[0],
      "precondition: the filter under test does change a quiet frame")
  }

  func testAPausedAGCReturnsTheFrameUntouched() {
    let agc = AGC(targetLevel: -12)
    agc.paused = true
    let frame = quietFrame()
    XCTAssertEqual(
      agc.handleFrame(frame).samples, frame.samples,
      "Python: `if self.paused: return frame` (Filters.py:202)")
  }

  func testResumingRestoresTheLevelDrive() {
    let agc = AGC(targetLevel: -12)
    agc.paused = true
    let frame = quietFrame()
    _ = agc.handleFrame(frame)
    agc.paused = false
    XCTAssertNotEqual(agc.handleFrame(frame).samples[0], frame.samples[0])
  }
}

// MARK: - OpusFileSource gain

/// `Sources.py:291-292`, `:326-332`, `:384`.
final class OpusFileSourceGainTests: XCTestCase {

  /// Collects every frame a source delivers.
  private final class Collector: Sink {
    var channels: Int? = nil
    var sampleRate: Double = 0
    private let lock = NSLock()
    private var unsafeSamples: [Float] = []

    var samples: [Float] { lock.withLock { unsafeSamples } }

    func handleFrame(_ frame: AudioFrame, from source: (any Source)?) {
      lock.withLock { unsafeSamples.append(contentsOf: frame.samples) }
    }
  }

  /// Writes ten frames of a 300 Hz tone at 8 kHz mono, and returns the file.
  ///
  /// A tone rather than silence: a gain multiplies the decoded samples, so a
  /// silent file measures the same at every setting.
  private func writeToneFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("lxst_gain_\(UUID().uuidString).lxstopus")
    let sink = OpusFileSink(path: url, autodigest: false, profile: .voiceLow)
    var phase = 0.0
    let step = 2.0 * Double.pi * 300.0 / 8000.0
    for _ in 0..<10 {
      var samples = [Float](repeating: 0, count: 160)
      for i in 0..<160 {
        samples[i] = Float(sin(phase)) * 0.05
        phase += step
      }
      sink.handleFrame(
        AudioFrame(samples: samples, channelCount: 1, sampleRate: 8000), from: nil)
    }
    sink.start()
    sink.stop()
    return url
  }

  private func rmsOfFile(_ url: URL, gain: Float) -> Float {
    let collector = Collector()
    let source = OpusFileSource(filePath: url, timed: false, gain: gain)
    source.sink = collector
    source.start()
    let deadline = Date().addingTimeInterval(2.0)
    while source.running && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    source.stop()
    let samples = collector.samples
    guard !samples.isEmpty else { return 0 }
    let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
    return (sum / Float(samples.count)).squareRoot()
  }

  func testDefaultGainIsZeroDecibels() {
    let source = OpusFileSource(filePath: URL(fileURLWithPath: "/dev/null"))
    XCTAssertEqual(source.gain, 0.0, "Python: `gain=0.0` (Sources.py:291)")
  }

  func testGainRoundTrips() {
    let source = OpusFileSource(filePath: URL(fileURLWithPath: "/dev/null"))
    source.gain = -6
    XCTAssertEqual(source.gain, -6, "Python: `gain` reads back the decibel value it was set")
  }

  func testGainScalesTheDecodedSamples() throws {
    let url = try writeToneFile()
    defer { try? FileManager.default.removeItem(at: url) }

    let unity = rmsOfFile(url, gain: 0)
    XCTAssertGreaterThan(unity, 0, "precondition: the file decodes to a non-silent signal")

    let raised = rmsOfFile(url, gain: 10)
    XCTAssertEqual(
      Double(raised / unity), DBGain.linear(10), accuracy: 0.01,
      "Python: `frame_samples *= self.__gain` with `10**(db/10)` (Sources.py:384, :293)")
  }
}

// MARK: - FilePlayer gain

/// `Players.py:13`, `:28-36`.
final class FilePlayerGainTests: XCTestCase {

  func testDefaultGainIsZeroDecibels() {
    XCTAssertEqual(FilePlayer().gain, 0.0, "Python: `gain=0.0` (Players.py:13)")
  }

  func testGainRoundTrips() {
    let player = FilePlayer()
    player.gain = 3
    XCTAssertEqual(player.gain, 3)
  }

  func testGainIsSettableAtInit() {
    XCTAssertEqual(FilePlayer(gain: -12).gain, -12)
  }
}

// MARK: - Telephone harness

/// Builds a telephone and, where a test needs one, a call to hang it on.
class TelephoneCallTestCase: XCTestCase {

  var phone: Telephone!

  override func setUp() {
    super.setUp()
    phone = Telephone(identity: Identity(), transport: Transport())
  }

  override func tearDown() {
    phone.hangup()
    phone = nil
    super.tearDown()
  }

  /// Installs an established call on `phone` and returns it.
  func establishCall() throws -> ActiveCall {
    let destination = try Destination(
      identity: Identity(), direction: .out, kind: .single,
      appName: "lxst", aspects: ["telephony"])
    let call = ActiveCall(
      link: try Link.initiate(destination: destination, transport: Transport()))
    phone.testSetActiveCall(call)
    phone.testSetCallStatus(.established)
    return call
  }
}

// MARK: - Telephone loudspeaker

/// `Telephony.py:284-287`, `:468-471`, `:551-559`, `:676-688`.
final class TelephoneLoudspeakerTests: TelephoneCallTestCase {

  func testTheLoudspeakerIsOffByDefault() {
    XCTAssertFalse(phone.loudspeakerOn, "Python: `self.__loudspeaker_on = False`")
  }

  func testEnableLoudspeakerSetsTheFlag() {
    phone.enableLoudspeaker()
    XCTAssertTrue(phone.loudspeakerOn)
  }

  func testDisableLoudspeakerClearsTheFlag() {
    phone.enableLoudspeaker()
    phone.disableLoudspeaker()
    XCTAssertFalse(phone.loudspeakerOn)
  }

  func testEnableLoudspeakerFalseClearsTheFlag() {
    phone.enableLoudspeaker()
    phone.enableLoudspeaker(false)
    XCTAssertFalse(phone.loudspeakerOn, "Python: `enable_loudspeaker(enable=False)`")
  }

  func testTheOutputIsBuiltOnTheSpeakerWhileTheLoudspeakerIsOff() {
    phone.speakerDevice = "earpiece"
    phone.loudspeakerDevice = "loud"
    phone.testPreparePipelines()
    XCTAssertEqual(phone.testAudioOutputDevice(), "earpiece")
  }

  func testTheOutputIsBuiltOnTheLoudspeakerWhenItIsOn() {
    phone.speakerDevice = "earpiece"
    phone.loudspeakerDevice = "loud"
    phone.enableLoudspeaker()
    phone.testPreparePipelines()
    XCTAssertEqual(
      phone.testAudioOutputDevice(), "loud",
      "Python: `LineSink(preferred_device=self.loudspeaker_device)` when the flag is set")
  }

  func testEnablingMidCallRebuildsTheOutputOnTheOtherDevice() throws {
    phone.speakerDevice = "earpiece"
    phone.loudspeakerDevice = "loud"
    _ = try establishCall()
    phone.testPreparePipelines()
    let before = phone.testAudioOutputIdentity()
    XCTAssertNotNil(before, "precondition: an output exists to switch away from")

    phone.enableLoudspeaker()

    XCTAssertEqual(phone.testAudioOutputDevice(), "loud")
    XCTAssertNotEqual(
      phone.testAudioOutputIdentity(), before,
      "Python replaces the sink and the receive pipeline (Telephony.py:678-688)")
  }

  func testARepeatedEnableDoesNotRebuildTheOutput() throws {
    _ = try establishCall()
    phone.testPreparePipelines()
    phone.enableLoudspeaker()
    let after = phone.testAudioOutputIdentity()
    phone.enableLoudspeaker()
    XCTAssertEqual(
      phone.testAudioOutputIdentity(), after,
      "Python rebuilds only when the flag changed (`if was_on != self.__loudspeaker_on`)")
  }

  func testHangupClearsTheFlag() throws {
    _ = try establishCall()
    phone.enableLoudspeaker()
    phone.hangup()
    XCTAssertFalse(
      phone.loudspeakerOn,
      "Python clears it with the mute flags when the call ends (Telephony.py:522)")
  }
}

// MARK: - Telephone AGC squelch

/// `Telephony.py:561-570`, `:777-778`.
final class TelephoneAGCSquelchTests: TelephoneCallTestCase {

  private func callWithAGC() throws -> AGC {
    let call = try establishCall()
    let agc = AGC(targetLevel: -15)
    call.filterAGC = agc
    return agc
  }

  func testSquelchPausesTheCallAGC() throws {
    let agc = try callWithAGC()
    phone.squelchTransmit()
    XCTAssertTrue(agc.paused, "Python: `squelch_transmit` calls `pause_agc(squelch)`")
  }

  func testUnsquelchResumesIt() throws {
    let agc = try callWithAGC()
    phone.squelchTransmit()
    phone.unsquelchTransmit()
    XCTAssertFalse(agc.paused, "Python: `unsquelch_transmit` calls `resume_agc(unsquelch)`")
  }

  func testSquelchFalseResumesIt() throws {
    let agc = try callWithAGC()
    phone.squelchTransmit()
    phone.squelchTransmit(false)
    XCTAssertFalse(agc.paused, "Python: `pause_agc(False)` clears the flag")
  }

  func testSquelchingWithoutAnAGCIsHarmless() throws {
    _ = try establishCall()
    phone.squelchTransmit()
    phone.unsquelchTransmit()
  }

  func testTheCallAGCIsTheOneInTheMicFilterChain() throws {
    _ = try establishCall()
    phone.useAGC = true
    phone.testOpenPipelines(for: Identity())
    let agc = phone.activeCall?.filterAGC
    XCTAssertNotNil(agc, "Python: `self.active_call.filter_agc = AGC(target_level=-15.0)`")
    XCTAssertTrue(
      phone.activeCall?.filters.contains(where: { $0 === agc }) ?? false,
      "Python appends that same instance to the filter chain (Telephony.py:777-778)")
  }
}

// MARK: - Telephone remote mode follow

/// `Telephony.py:591-596`, `:599`.
final class TelephoneModeFollowTests: TelephoneCallTestCase {

  func testDisablingWithoutACallReportsFailure() {
    XCTAssertFalse(
      phone.disableRemoteModeFollow(),
      "Python: `if not self.active_call: return False`")
  }

  func testDisablingWithACallReportsSuccess() throws {
    _ = try establishCall()
    XCTAssertTrue(phone.disableRemoteModeFollow())
  }

  func testASignalledSwitchIsIgnoredOnceDisabled() throws {
    let call = try establishCall()
    call.callMode = .fullDuplex
    XCTAssertTrue(phone.disableRemoteModeFollow())

    phone.switchMode(.halfDuplex, fromSignalling: true)

    XCTAssertEqual(
      phone.activeMode, .fullDuplex,
      "Python returns before the mode is applied (Telephony.py:599)")
  }

  func testASignalledSwitchStillAppliesWhileFollowIsOn() throws {
    let call = try establishCall()
    call.callMode = .fullDuplex

    phone.switchMode(.halfDuplex, fromSignalling: true)

    XCTAssertEqual(
      phone.activeMode, .halfDuplex,
      "precondition: the gate under test is the only thing that blocks the switch")
  }

  func testALocalSwitchStillAppliesOnceDisabled() throws {
    let call = try establishCall()
    call.callMode = .fullDuplex
    XCTAssertTrue(phone.disableRemoteModeFollow())

    phone.switchMode(.halfDuplex)

    XCTAssertEqual(
      phone.activeMode, .halfDuplex,
      "Python gates on `from_signalling`, so the local side keeps control")
  }
}

// MARK: - Pipeline wiring for a Mixer source

/// `Pipeline.py:29` adds `source._sink = sink` for a `Mixer` source.
///
/// The setter it bypasses is `self._sink = sink` (`Mixer.py:186-188`), and the line
/// above it already ran `self.source.sink = sink`, so the addition changes nothing
/// upstream. This port has always assigned the sink unconditionally.
final class MixerSourcePipelineWiringTests: XCTestCase {

  private final class NullSink: Sink {
    var channels: Int? = nil
    var sampleRate: Double = 48000
    func handleFrame(_ frame: AudioFrame, from source: (any Source)?) {}
  }

  func testAPipelineSetsAMixerSourcesSink() throws {
    let mixer = Mixer()
    let sink = NullSink()
    _ = try Pipeline(source: mixer, codec: NullCodec(), sink: sink)
    XCTAssertTrue(mixer.sink === sink)
  }
}

// MARK: - Mixer re-entry

/// `Mixer.py:105`.
final class MixerJobReentryTests: XCTestCase {

  func testARestartNeverRunsTwoMixLoopsAtOnce() {
    let mixer = Mixer(targetFrameMs: 5, sampleRate: 48000)
    mixer.start()
    // Switching the call's playback device stops and restarts the mixer in one
    // breath; this is that, tightened until the window is reliably hit.
    for _ in 0..<500 {
      mixer.stop()
      mixer.start()
    }
    Thread.sleep(forTimeInterval: 0.05)
    mixer.stop()
    XCTAssertEqual(
      mixer.peakConcurrentJobs, 1,
      "a second job must return while the first still holds the loop")
  }
}
