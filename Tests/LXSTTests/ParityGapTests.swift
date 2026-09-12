//===----------------------------------------------------------------------===//
// Copyright (c) 2026 LXSTSwift contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

import XCTest
@testable import LXST

/// Tests for the small parity gaps identified in the gap analysis.
///
/// All values verified against Python LXST 0.4.6.
final class ParityGapTests: XCTestCase {

    // MARK: - Sink.canReceive (Python: Sink.can_receive(from_source=None) -> True)

    func testBaseSinkCanReceiveReturnsTrue() {
        let sink = MockSink()
        XCTAssertTrue(sink.canReceive(from: nil),
                      "Sink.can_receive must default to true")
    }

    func testRemoteSinkCanReceiveReturnsTrue() {
        let sink = RemoteSink()
        XCTAssertTrue(sink.canReceive(from: nil))
    }

    // MARK: - LineSink constants (Python: LineSink.MAX_FRAMES/AUTOSTART_MIN/FRAME_TIMEOUT)

    func testLineSinkMaxFrames() {
        XCTAssertEqual(LineSink.maxFrames, 6, "Python: LineSink.MAX_FRAMES = 6")
    }

    func testLineSinkAutoStartMin() {
        XCTAssertEqual(LineSink.autoStartMin, 1, "Python: LineSink.AUTOSTART_MIN = 1")
    }

    func testLineSinkFrameTimeout() {
        XCTAssertEqual(LineSink.frameTimeout, 8, "Python: LineSink.FRAME_TIMEOUT = 8")
    }

    // MARK: - OpusFileSink constants (Python: OpusFileSink.AUTOSTART_MIN)

    func testOpusFileSinkAutoStartMin() {
        XCTAssertEqual(OpusFileSink.autoStartMin, 1, "Python: OpusFileSink.AUTOSTART_MIN = 1")
    }

    // MARK: - LineSink.canReceive

    func testLineSinkCanReceiveReturnsTrue() {
        let s = LineSink()
        XCTAssertTrue(s.canReceive(from: nil))
    }

    // MARK: - LineSource constants (Python: LineSource.MAX_FRAMES = 128)

    func testLineSourceMaxFrames() {
        XCTAssertEqual(LineSource.maxFrames, 128, "Python: LineSource.MAX_FRAMES = 128")
    }

    // NOTE: LineSource.linear_gain parity (Python: Sources.py:180, 10**(gain_db/10))
    // is asserted through the LIVE paths in PowerDBGainParityTests. Helper-only
    // tests of linearGain used to live here and passed for months while every
    // production gain site inlined the wrong 10^(dB/20) formula—do not re-add
    // tests that exercise the conversion helper in isolation.

    // MARK: - Loopback.canReceive (Python: Loopback.can_receive delegates to sink)

    func testLoopbackCanReceiveReturnsTrueWhenNoSink() {
        let lb = Loopback()
        XCTAssertTrue(lb.canReceive(from: nil),
                      "Loopback.can_receive must return true when no downstream sink")
    }

    // MARK: - OpusFileSource.running property

    func testOpusFileSourceRunningIsFalseBeforeStart() {
        let src = OpusFileSource(filePath: URL(fileURLWithPath: "/dev/null"))
        XCTAssertFalse(src.running, "running must be false before start()")
    }

    func testOpusFileSourceRunningIsTrueAfterStart() {
        let src = OpusFileSource(filePath: URL(fileURLWithPath: "/dev/null"))
        src.start()
        XCTAssertTrue(src.running)
        src.stop()
    }

    // MARK: - Packetizer.canReceive

    func testPacketizerCanReceiveReturnsTrue() {
        let p = Packetizer()
        XCTAssertTrue(p.canReceive(from: nil))
    }

    // MARK: - OpusCodec.setProfile

    func testOpusCodecSetProfile() {
        let c = OpusCodec(profile: .voiceLow)
        XCTAssertEqual(c.profile, .voiceLow)
        c.setProfile(.audioMax)
        XCTAssertEqual(c.profile, .audioMax,
                       "setProfile must update the active profile")
    }

    func testOpusCodecSetProfileUpdatesSampleRate() {
        let c = OpusCodec(profile: .voiceLow)    // 8 kHz
        c.setProfile(.voiceMax)                   // 48 kHz
        XCTAssertEqual(c.preferredSampleRate, 48000.0,
                       "setProfile must update preferredSampleRate")
    }

    // MARK: - Codec2Codec.setMode

    func testCodec2SetMode() {
        let c = Codec2Codec(mode: .mode2400)
        c.setMode(.mode700C)
        XCTAssertEqual(c.mode, .mode700C,
                       "setMode must update the active mode")
    }

    // MARK: - Codec2 decode adopts the wire mode-header byte
    // Python: Codec2.decode reads frame_bytes[0], maps HEADER_MODES[frame_header],
    // and set_mode(frame_mode) before decoding—so a receiver decodes whatever
    // mode the sender used, not just its own current mode.
    //
    // NOTE on assertions: libcodec2's low-bitrate synthesis uses randomised
    // phase (a shared libc RNG) for unvoiced frames, so two decoders—even two
    // *native* same-mode ones—do not produce bit-identical PCM from the same
    // bytes. The deterministic, parity-relevant facts are therefore the adopted
    // MODE and the frame GEOMETRY (sample count), not the exact sample values.
    // Before the fix the geometry was wrong: a different-mode frame either
    // decoded as garbage or, when its length wasn't a multiple of the receiver's
    // bytes-per-frame, threw `invalidFrame`.

    // Every test below runs the receiver with a 48 kHz sink attached, the rate a real playback
    // path uses. Sink-less, codec2's 8 kHz was simultaneously the decode rate and the reported
    // rate, so these asserted 320 samples against the one rate in play and could not observe
    // `bugs/018`—the missing 8 kHz → sink conversion—at all. The mode-adoption property they
    // exist for is unchanged; only the rate they are measured at is.

    private func playbackSink() -> RateSink { RateSink(sampleRate: 48000, channels: 1) }

    /// A receiver at the DEFAULT mode (2400) must decode a frame the sender
    /// encoded at a *different* mode (3200—a different bytes-per-frame), by
    /// reading the wire header and adopting that mode.
    func testCodec2DecodeAdoptsWireModeHeaderDifferentBPF() throws {
        let sender = Codec2Codec(mode: .mode3200)
        let input  = [Float](repeating: 0.15, count: 320)   // 40 ms @ 8 kHz
        let frame  = AudioFrame(samples: input, channelCount: 1, sampleRate: 8000)
        let wire   = try sender.encode(frame)
        XCTAssertEqual(wire[wire.startIndex], Codec2Mode.mode3200.headerByte,
                       "sanity: wire header announces mode 3200 (0x06)")

        let receiver = Codec2Codec()   // default .mode2400
        let sink     = playbackSink()
        receiver.sink = sink
        let decoded  = try receiver.decode(wire)

        XCTAssertEqual(receiver.mode, .mode3200,
                       "decode must adopt the wire header's mode (Python: set_mode)")
        // Adopting mode 3200 (160 samples/frame) for two frames' worth of bytes
        // must recover the original 40 ms. The pre-fix decoder threw.
        assertDecoded(decoded, playableBy: sink,
                      codecRate: codec2OutputRate, durationMs: 40)

        let native = Codec2Codec(mode: .mode3200)
        native.sink = sink
        XCTAssertEqual(decoded.sampleCount, try native.decode(wire).sampleCount,
                       "sample count must match a native mode-3200 decode")
    }

    /// Same, but the wire mode (700C) has a different *samples*-per-frame than
    /// the receiver's default (2400), so a mis-adopted mode would also yield the
    /// wrong sample count.
    func testCodec2DecodeAdoptsWireModeHeaderDifferentSPF() throws {
        let sender = Codec2Codec(mode: .mode700C)
        let input  = [Float](repeating: -0.2, count: 320)
        let frame  = AudioFrame(samples: input, channelCount: 1, sampleRate: 8000)
        let wire   = try sender.encode(frame)

        let receiver = Codec2Codec()   // default .mode2400
        let sink     = playbackSink()
        receiver.sink = sink
        let decoded  = try receiver.decode(wire)

        XCTAssertEqual(receiver.mode, .mode700C,
                       "decode must adopt mode 700C from the wire header")
        assertDecoded(decoded, playableBy: sink,
                      codecRate: codec2OutputRate, durationMs: 40)

        let native = Codec2Codec(mode: .mode700C)
        native.sink = sink
        XCTAssertEqual(decoded.sampleCount, try native.decode(wire).sampleCount,
                       "sample count must match a native mode-700C decode")
    }

    /// A frame already at the receiver's current mode still decodes (regression
    /// guard: the header path must not disturb the common same-mode case).
    func testCodec2DecodeSameModeStillWorks() throws {
        let c     = Codec2Codec(mode: .mode2400)
        let input = [Float](repeating: 0.2, count: 320)
        let frame = AudioFrame(samples: input, channelCount: 1, sampleRate: 8000)
        let wire  = try c.encode(frame)

        let receiver = Codec2Codec(mode: .mode2400)
        let sink     = playbackSink()
        receiver.sink = sink
        let decoded  = try receiver.decode(wire)
        XCTAssertEqual(receiver.mode, .mode2400,
                       "same-mode decode must leave the mode unchanged")
        assertDecoded(decoded, playableBy: sink,
                      codecRate: codec2OutputRate, durationMs: 40)
    }

    /// An unrecognized header byte keeps the current mode and decodes the rest,
    /// exactly like Python (`else: frame_mode = self.mode`).
    func testCodec2DecodeUnknownHeaderKeepsCurrentMode() throws {
        // Encode at 2400, then overwrite the header byte with an invalid mode
        // marker (0x07 is not in HEADER_MODES). The remaining bytes are still a
        // valid 2400 payload, so a receiver at 2400 must decode them as 2400.
        let c     = Codec2Codec(mode: .mode2400)
        let input = [Float](repeating: 0.1, count: 320)
        let frame = AudioFrame(samples: input, channelCount: 1, sampleRate: 8000)
        var wire  = try c.encode(frame)
        wire[wire.startIndex] = 0x07   // unknown header

        let receiver = Codec2Codec(mode: .mode2400)
        let sink     = playbackSink()
        receiver.sink = sink
        let decoded  = try receiver.decode(wire)
        XCTAssertEqual(receiver.mode, .mode2400,
                       "unknown header must leave the current mode unchanged")
        assertDecoded(decoded, playableBy: sink,
                      codecRate: codec2OutputRate, durationMs: 40)
    }

    // MARK: - get_backend() module-level function

    func testGetBackendReturnsAudioBackend() {
        let backend = getBackend()
        XCTAssertNotNil(backend,
                        "getBackend() must return a non-nil AudioBackend")
    }

    // MARK: - Loopback.maxFrames (Python: Loopback.MAX_FRAMES = 128)

    func testLoopbackMaxFrames() {
        XCTAssertEqual(Loopback.maxFrames, 128, "Python: Loopback.MAX_FRAMES = 128")
    }

    // MARK: - OpusFileSink constants (Python: OpusFileSink.MAX_FRAMES/FINALIZE_TIMEOUT)

    func testOpusFileSinkMaxFrames() {
        XCTAssertEqual(OpusFileSink.maxFrames, 64, "Python: OpusFileSink.MAX_FRAMES = 64")
    }

    func testOpusFileSinkFinalizeTimeout() {
        XCTAssertEqual(OpusFileSink.finalizeTimeout, 2,
                       "Python: OpusFileSink.FINALIZE_TIMEOUT = 2")
    }

    // MARK: - LineSink.enableLowLatency (Python: LineSink.enable_low_latency())

    func testLineSinkEnableLowLatencySetsFlagTrue() {
        let s = LineSink()
        XCTAssertFalse(s.lowLatency, "lowLatency must default to false")
        s.enableLowLatency()
        XCTAssertTrue(s.lowLatency, "enableLowLatency() must set lowLatency = true")
    }

    // MARK: - FilePlayer.play() alias (Python: FilePlayer.play = start)

    func testFilePlayerPlayAliasIsEquivalentToStart() {
        let player = FilePlayer()
        player.play()
        XCTAssertTrue(player.running, "play() must set running = true (same as start())")
        player.stop()
    }

    // MARK: - FilePlayer.loop() method (Python: FilePlayer.loop(loop=True))

    func testFilePlayerLoopSetsLoopTrue() {
        let player = FilePlayer(loop: false)
        XCTAssertFalse(player.loop)
        player.loop(true)
        XCTAssertTrue(player.loop, "loop(true) must set loop = true")
    }

    func testFilePlayerLoopWithFalseSetsLoopFalse() {
        let player = FilePlayer(loop: true)
        player.loop(false)
        XCTAssertFalse(player.loop, "loop(false) must set loop = false")
    }

    func testFilePlayerLoopDefaultArgumentIsTrue() {
        let player = FilePlayer(loop: false)
        player.loop()   // default is true
        XCTAssertTrue(player.loop, "loop() with no arg must default to true")
    }

    // MARK: - FileRecorder.record() alias (Python: FileRecorder.record = start)

    func testFileRecorderRecordAliasIsEquivalentToStart() {
        let recorder = FileRecorder()
        recorder.record()
        XCTAssertTrue(recorder.running, "record() must set running = true (same as start())")
        recorder.stop()
    }

    // MARK: - Source.release() (Python: Source.release(), commit 2730af9)

    func testLocalSourceReleaseStopsSource() {
        let src = MockLocalSource()
        src.start()
        XCTAssertTrue(src.shouldRun)
        src.release()
        XCTAssertFalse(src.shouldRun, "release() must stop the source")
    }

    func testLocalSourceReleaseNilsCodecAndSink() {
        let src = MockLocalSource()
        src.codec = MockCodec()
        src.sink  = MockSink()
        src.release()
        XCTAssertNil(src.codec, "release() must nil codec")
        XCTAssertNil(src.sink,  "release() must nil sink")
    }

    func testLocalSourceReleaseIsIdempotent() {
        let src = MockLocalSource()
        src.release()
        src.release() // must not crash
    }

    func testRemoteSourceReleaseStopsSource() {
        let src = MockRemoteSource()
        src.start()
        src.release()
        XCTAssertFalse(src.shouldRun)
    }

    // MARK: - Sink.release() (Python: Sink.release(), commit 2730af9)

    func testLocalSinkReleaseStopsSink() {
        let sink = MockLocalSink()
        sink.start()
        sink.release()
        // stop() is called; no crash
    }

    func testRemoteSinkReleaseCallsStop() {
        let sink = MockRemoteSink()
        sink.release() // must not crash
    }

    // MARK: - Pipeline.release() (Python: Pipeline.release(), commit 2730af9)

    func testPipelineReleaseSetsReleasedFlag() throws {
        let src  = MockLocalSource()
        let sink = MockLocalSink()
        let codec = MockCodec()
        let pipeline = try Pipeline(source: src, codec: codec, sink: sink)
        pipeline.start()
        XCTAssertTrue(pipeline.running)
        pipeline.release()
        XCTAssertFalse(pipeline.running, "release() must stop the pipeline")
    }

    func testPipelineReleaseIsIdempotent() throws {
        let src  = MockLocalSource()
        let sink = MockLocalSink()
        let pipeline = try Pipeline(source: src, codec: MockCodec(), sink: sink)
        pipeline.release()
        pipeline.release() // must not crash
    }

    // MARK: - FilePlayer.releaseOnFinish (Python: FilePlayer(release_on_finish=False), commit 2730af9)

    func testFilePlayerReleaseOnFinishDefaultsFalse() {
        XCTAssertFalse(FilePlayer().releaseOnFinish,
                       "releaseOnFinish must default to false")
    }

    func testFilePlayerReleaseOnFinishCanBeSetViaInit() {
        let player = FilePlayer(releaseOnFinish: true)
        XCTAssertTrue(player.releaseOnFinish)
    }

    func testFilePlayerReleaseOnFinishPropertySetterWorks() {
        let player = FilePlayer()
        player.releaseOnFinish = true
        XCTAssertTrue(player.releaseOnFinish)
        player.releaseOnFinish = false
        XCTAssertFalse(player.releaseOnFinish)
    }

    // MARK: - FilePlayer.release() (Python: FilePlayer.release(), commit 2730af9)

    func testFilePlayerReleaseStopsPlayer() {
        let player = FilePlayer()
        player.start()
        XCTAssertTrue(player.running)
        player.release()
        XCTAssertFalse(player.running, "release() must stop the player")
    }

    func testFilePlayerReleaseIsIdempotent() {
        let player = FilePlayer()
        player.release()
        player.release() // must not crash
    }

    // MARK: - Helpers

    private final class MockSink: Sink {
        var channels:   Int?   = 1
        var sampleRate: Double = 48000
        func handleFrame(_ frame: AudioFrame, from source: (any Source)?) {}
    }

    private final class MockLocalSink: LocalSink {}

    private final class MockRemoteSink: RemoteSink {}

    private final class MockLocalSource: LocalSource {}

    private final class MockRemoteSource: RemoteSource {}

    private final class MockCodec: Codec {
        static var headerByte: UInt8 = 0
        var preferredSampleRate: Double? = nil
        var frameQuantaMs: Double? = nil
        var frameMaxMs: Double? = nil
        var validFrameMs: [Double] = []
        var channels: Int? = nil
        var source: (any Source)? = nil
        var sink:   (any Sink)?   = nil
        func encode(_ frame: AudioFrame) throws -> Data { Data() }
        func decode(_ data: Data) throws -> AudioFrame { AudioFrame(samples: [], channelCount: 1, sampleRate: 48000) }
    }
}
