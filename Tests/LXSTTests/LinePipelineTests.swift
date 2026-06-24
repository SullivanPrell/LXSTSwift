import XCTest
@testable import LXST

// MARK: - Mock AudioBackend

/// Mock audio backend that drives capture/playback without real hardware.
final class MockAudioBackend: AudioBackend {
    var sampleRate:   Double = 48000
    var channelCount: Int    = 1
    var bitDepth:     Int    = 32

    // Capture state
    var captureStarted:        Bool = false
    var captureStopped:        Bool = false
    var captureHandler:        ((AudioFrame) -> Void)?
    var captureFramesPerBuffer: Int = 0

    // Playback state
    var playbackStarted: Bool = false
    var playbackStopped: Bool = false
    private(set) var mockPlayer = MockAudioPlayer()

    func startCapture(framesPerBuffer: Int,
                      handler: @escaping (AudioFrame) -> Void) throws {
        captureStarted         = true
        captureFramesPerBuffer = framesPerBuffer
        captureHandler         = handler
    }

    func stopCapture() {
        captureStopped = true
    }

    func startPlayback(sampleRate: Double, channelCount: Int) throws -> any AudioPlayer {
        playbackStarted = true
        return mockPlayer
    }

    func stopPlayback() {
        playbackStopped = true
    }

    /// Inject a frame into the capture stream (simulates mic input).
    func injectFrame(_ frame: AudioFrame) {
        captureHandler?(frame)
    }
}

// MARK: - Mock AudioPlayer

final class MockAudioPlayer: AudioPlayer {
    private(set) var playedFrames: [AudioFrame] = []
    private(set) var flushed: Bool = false

    func play(_ frame: AudioFrame) {
        playedFrames.append(frame)
    }

    func flush() {
        flushed = true
    }
}

// MARK: - Mock Sink (records received frames)

private final class MockSink: Sink {
    var channels:   Int?   = 1
    var sampleRate: Double = 48000
    private(set) var received: [AudioFrame] = []

    func handleFrame(_ frame: AudioFrame, from source: (any Source)?) {
        received.append(frame)
    }
}

// MARK: - LineSource backend wiring tests

final class LineSourceBackendTests: XCTestCase {

    func testLineSourceStartCallsBackendStartCapture() {
        let backend = MockAudioBackend()
        let src = LineSource(backend: backend)
        src.start()
        XCTAssertTrue(backend.captureStarted,
                      "LineSource.start() must call backend.startCapture()")
        src.stop()
    }

    func testLineSourceStopCallsBackendStopCapture() {
        let backend = MockAudioBackend()
        let src = LineSource(backend: backend)
        src.start()
        src.stop()
        XCTAssertTrue(backend.captureStopped,
                      "LineSource.stop() must call backend.stopCapture()")
    }

    func testLineSourceDoubleStartIsNoOp() {
        let backend = MockAudioBackend()
        let src = LineSource(backend: backend)
        src.start()
        src.start()   // second start ignored
        XCTAssertTrue(backend.captureStarted)
        src.stop()
    }

    func testLineSourceCaptureFramesPerBufferMatchesTargetFrameMs() {
        let backend = MockAudioBackend()
        let src = LineSource(targetFrameMs: 80, backend: backend)
        src.start()
        // framesPerBuffer = sampleRate * targetFrameMs / 1000 = 48000 * 80 / 1000 = 3840
        let expected = Int(src.sampleRate * 80.0 / 1000.0)
        XCTAssertEqual(backend.captureFramesPerBuffer, expected,
                       "framesPerBuffer must match targetFrameMs")
        src.stop()
    }

    func testLineSourceDeliversCapturedFrameToSink() {
        let backend = MockAudioBackend()
        let sink = MockSink()
        let src = LineSource(sink: sink, backend: backend)
        src.start()

        let frame = AudioFrame(samples: [0.1, 0.2, 0.3], channelCount: 1, sampleRate: 48000)
        backend.injectFrame(frame)

        XCTAssertEqual(sink.received.count, 1,
                       "Captured frame must be delivered to downstream sink")
        src.stop()
    }

    func testLineSourceAppliesGainToFrame() {
        let backend = MockAudioBackend()
        let sink = MockSink()
        // gain = 20 dB → linear multiplier = 10.0 (20/20 formula in deliver())
        let src = LineSource(sink: sink, gain: 20.0, backend: backend)
        src.start()

        let frame = AudioFrame(samples: [0.5, -0.5], channelCount: 1, sampleRate: 48000)
        backend.injectFrame(frame)

        XCTAssertEqual(sink.received.count, 1)
        let received = sink.received[0]
        // gain of +20 dB → 10x amplitude
        XCTAssertEqual(received.samples[0], 5.0, accuracy: 0.01,
                       "Gain must be applied to captured frames")
        src.stop()
    }

    func testLineSourceAppliesFilters() {
        let backend = MockAudioBackend()
        let sink = MockSink()
        // A filter that zeroes out all samples
        let zeroFilter = ZeroFilter()
        let src = LineSource(filters: [zeroFilter], backend: backend)
        src.start()
        src.sink = sink

        let frame = AudioFrame(samples: [1.0, 0.5], channelCount: 1, sampleRate: 48000)
        backend.injectFrame(frame)

        XCTAssertEqual(sink.received.count, 1)
        XCTAssertEqual(sink.received[0].samples[0], 0.0,
                       "Filters must be applied before delivery")
        src.stop()
    }

    func testLineSourceDefaultFrameMsIsEighty() {
        let src = LineSource()
        XCTAssertEqual(src.targetFrameMs, LineSource.defaultFrameMs,
                       "Default targetFrameMs must be 80 ms (Python: DEFAULT_FRAME_MS = 80)")
    }
}

// MARK: - LineSink backend wiring tests

final class LineSinkBackendTests: XCTestCase {

    func testLineSinkStartCallsBackendStartPlayback() {
        let backend = MockAudioBackend()
        let sink = LineSink(backend: backend)
        sink.start()
        XCTAssertTrue(backend.playbackStarted,
                      "LineSink.start() must call backend.startPlayback()")
        sink.stop()
    }

    func testLineSinkStopCallsBackendStopPlayback() {
        let backend = MockAudioBackend()
        let sink = LineSink(backend: backend)
        sink.start()
        sink.stop()
        XCTAssertTrue(backend.playbackStopped,
                      "LineSink.stop() must call backend.stopPlayback()")
    }

    func testLineSinkStopFlushesPlayer() {
        let backend = MockAudioBackend()
        let sink = LineSink(backend: backend)
        sink.start()
        sink.stop()
        XCTAssertTrue(backend.mockPlayer.flushed,
                      "LineSink.stop() must flush the audio player")
    }

    func testLineSinkHandleFrameCallsPlayerPlay() {
        let backend = MockAudioBackend()
        let sink = LineSink(backend: backend)
        sink.start()

        let frame = AudioFrame(samples: [0.1, 0.2], channelCount: 1, sampleRate: 48000)
        sink.handleFrame(frame, from: nil)

        XCTAssertEqual(backend.mockPlayer.playedFrames.count, 1,
                       "LineSink.handleFrame must pass the frame to the player")
        sink.stop()
    }

    func testLineSinkHandleFrameWithoutStartIsNoOp() {
        let backend = MockAudioBackend()
        let sink = LineSink(backend: backend)
        // No start() — player is nil
        let frame = AudioFrame(samples: [0.5], channelCount: 1, sampleRate: 48000)
        sink.handleFrame(frame, from: nil)  // must not crash
    }
}

// MARK: - Full line pipeline round-trip

final class LinePipelineIntegrationTests: XCTestCase {

    func testLineSourceToLineSinkRoundTrip() {
        let captureBackend  = MockAudioBackend()
        let playbackBackend = MockAudioBackend()
        let src  = LineSource(backend: captureBackend)
        let sink = LineSink(backend: playbackBackend)

        src.sink = sink
        src.start()
        sink.start()

        let frame = AudioFrame(samples: [0.1, 0.2, 0.3], channelCount: 1, sampleRate: 48000)
        captureBackend.injectFrame(frame)

        XCTAssertEqual(playbackBackend.mockPlayer.playedFrames.count, 1,
                       "Frame injected into LineSource must reach LineSink player")
        src.stop()
        sink.stop()
    }

    func testLineSourceThroughNullCodecToLineSink() throws {
        let captureBackend  = MockAudioBackend()
        let playbackBackend = MockAudioBackend()
        let src   = LineSource(backend: captureBackend)
        let codec = NullCodec()
        let sink  = LineSink(backend: playbackBackend)
        _  = try Pipeline(source: src, codec: codec, sink: sink)

        src.start()
        sink.start()

        let frame = AudioFrame(samples: [0.5, -0.5], channelCount: 1, sampleRate: 48000)
        captureBackend.injectFrame(frame)

        XCTAssertEqual(playbackBackend.mockPlayer.playedFrames.count, 1,
                       "Frame must flow through Pipeline from LineSource to LineSink")
        src.stop()
        sink.stop()
    }

    func testLineSourceShouldRunStateManagement() {
        let backend = MockAudioBackend()
        let src = LineSource(backend: backend)
        XCTAssertFalse(src.shouldRun, "shouldRun must be false before start()")
        src.start()
        XCTAssertTrue(src.shouldRun,  "shouldRun must be true after start()")
        src.stop()
        XCTAssertFalse(src.shouldRun, "shouldRun must be false after stop()")
    }
}

// MARK: - Helper: a filter that zeroes all samples

private final class ZeroFilter: Filter {
    func handleFrame(_ frame: AudioFrame) -> AudioFrame {
        AudioFrame(samples: [Float](repeating: 0.0, count: frame.samples.count),
                   channelCount: frame.channelCount,
                   sampleRate: frame.sampleRate)
    }
}
