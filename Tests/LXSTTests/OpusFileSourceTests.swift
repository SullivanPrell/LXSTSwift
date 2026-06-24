import XCTest
@testable import LXST

// MARK: - OpusFileSource constants

final class OpusFileSourceConstantsTests: XCTestCase {

    func testDefaultFrameMs() {
        XCTAssertEqual(OpusFileSource.defaultFrameMs, 100.0,
                       "Python: OpusFileSource.DEFAULT_FRAME_MS = 100")
    }

    func testMaxFrames() {
        XCTAssertEqual(OpusFileSource.maxFrames, 128,
                       "Python: OpusFileSource.MAX_FRAMES = 128")
    }
}

// MARK: - OpusFileSource init

final class OpusFileSourceInitTests: XCTestCase {

    func testRunningIsFalseBeforeStart() {
        let src = OpusFileSource(filePath: URL(fileURLWithPath: "/dev/null"))
        XCTAssertFalse(src.running)
    }

    func testDefaultLoop() {
        let src = OpusFileSource(filePath: URL(fileURLWithPath: "/dev/null"))
        XCTAssertFalse(src.loop)
    }

    func testDefaultTimed() {
        let src = URL(fileURLWithPath: "/dev/null")
        let source = OpusFileSource(filePath: src)
        XCTAssertFalse(source.timed)
    }

    func testCustomInit() {
        let url = URL(fileURLWithPath: "/tmp/test.lxstopus")
        let src = OpusFileSource(filePath: url, targetFrameMs: 20, loop: true, timed: true)
        XCTAssertEqual(src.filePath, url)
        XCTAssertTrue(src.loop)
        XCTAssertTrue(src.timed)
    }
}

// MARK: - OpusFileSource running lifecycle

final class OpusFileSourceLifecycleTests: XCTestCase {

    func testRunningIsTrueAfterStart() {
        let src = OpusFileSource(filePath: URL(fileURLWithPath: "/dev/null"))
        src.start()
        XCTAssertTrue(src.running)
        src.stop()
    }

    func testRunningIsFalseAfterStop() {
        let src = OpusFileSource(filePath: URL(fileURLWithPath: "/dev/null"))
        src.start()
        src.stop()
        // Give the ingest thread a moment to observe shouldRun = false
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertFalse(src.running)
    }

    func testDoubleStartIsIdempotent() {
        let src = OpusFileSource(filePath: URL(fileURLWithPath: "/dev/null"))
        src.start()
        src.start()  // second call must be a no-op
        XCTAssertTrue(src.running)
        src.stop()
    }
}

// MARK: - LXSTOPUS v2 header format (written by OpusFileSink)

final class LXSTOPUSHeaderTests: XCTestCase {

    func testFileVersionIsTwo() {
        XCTAssertEqual(OpusFileSink.fileVersion, 0x02,
                       "v2 header stores sample rate and channels after version byte")
    }

    func testHeaderContainsSampleRateAndChannels() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hdrtest_\(UUID().uuidString).lxstopus")
        defer { try? FileManager.default.removeItem(at: url) }

        let sink = OpusFileSink(path: url, autodigest: false, profile: .voiceLow)
        let frame = AudioFrame(samples: [Float](repeating: 0, count: 160),
                               channelCount: 1, sampleRate: 8000)
        sink.handleFrame(frame, from: nil)
        sink.start()
        sink.stop()

        guard let data = try? Data(contentsOf: url), data.count >= 14 else {
            XCTFail("File must have at least 14 bytes (v2 header)")
            return
        }
        // Bytes 9–12: sample rate as UInt32 LE
        let sr = UInt32(data[9]) | UInt32(data[10]) << 8 | UInt32(data[11]) << 16 | UInt32(data[12]) << 24
        XCTAssertEqual(sr, 8000, "voiceLow sample rate is 8000 Hz")
        // Byte 13: channel count
        XCTAssertEqual(data[13], 1, "voiceLow channel count is 1")
    }

    func testHeaderStereoProfile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hdrtest2_\(UUID().uuidString).lxstopus")
        defer { try? FileManager.default.removeItem(at: url) }

        let sink = OpusFileSink(path: url, autodigest: false, profile: .audioMax)
        let frame = AudioFrame(samples: [Float](repeating: 0, count: 960),
                               channelCount: 2, sampleRate: 48000)
        sink.handleFrame(frame, from: nil)
        sink.start()
        sink.stop()

        guard let data = try? Data(contentsOf: url), data.count >= 14 else {
            XCTFail("File must have at least 14 bytes (v2 header)")
            return
        }
        let sr = UInt32(data[9]) | UInt32(data[10]) << 8 | UInt32(data[11]) << 16 | UInt32(data[12]) << 24
        XCTAssertEqual(sr, 48000, "audioMax sample rate is 48000 Hz")
        XCTAssertEqual(data[13], 2, "audioMax channel count is 2")
    }
}

// MARK: - OpusFileSource round-trip

final class OpusFileSourceRoundTripTests: XCTestCase {

    private func tmpURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lxst_rtrip_\(UUID().uuidString).lxstopus")
    }

    /// Write N frames of silence to a file, read them back, verify delivery.
    func testDecodesFramesFromFile() {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Write 3 frames of silence at voiceLow (8kHz, mono, 20ms → 160 samples/frame)
        let sink = OpusFileSink(path: url, autodigest: false, profile: .voiceLow)
        for _ in 0..<3 {
            sink.handleFrame(AudioFrame(samples: [Float](repeating: 0, count: 160),
                                        channelCount: 1, sampleRate: 8000),
                             from: nil)
        }
        sink.start()
        sink.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "Prerequisite: file must be written")

        // Read back with OpusFileSource
        let collector = FrameCollector()
        let src = OpusFileSource(filePath: url, timed: false)
        src.sink = collector
        src.start()

        // Wait up to 1 second for all frames to be delivered
        let deadline = Date().addingTimeInterval(1.0)
        while collector.frameCount < 3 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        src.stop()

        XCTAssertGreaterThanOrEqual(collector.frameCount, 3,
                                    "Source must deliver at least 3 decoded frames")
    }

    func testDecodedFrameHasCorrectSampleRate() {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let sink = OpusFileSink(path: url, autodigest: false, profile: .voiceLow)
        sink.handleFrame(AudioFrame(samples: [Float](repeating: 0, count: 160),
                                    channelCount: 1, sampleRate: 8000),
                         from: nil)
        sink.start()
        sink.stop()

        let collector = FrameCollector()
        let src = OpusFileSource(filePath: url, timed: false)
        src.sink = collector
        src.start()

        let deadline = Date().addingTimeInterval(1.0)
        while collector.frameCount < 1 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        src.stop()

        XCTAssertGreaterThanOrEqual(collector.frameCount, 1, "Must receive at least one frame")
        XCTAssertEqual(collector.lastFrame?.sampleRate, 8000.0,
                       "Decoded frame must carry the original sample rate")
    }

    func testSourceStopsWhenFileExhausted() {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Write 1 frame
        let sink = OpusFileSink(path: url, autodigest: false, profile: .voiceLow)
        sink.handleFrame(AudioFrame(samples: [Float](repeating: 0, count: 160),
                                    channelCount: 1, sampleRate: 8000),
                         from: nil)
        sink.start()
        sink.stop()

        let src = OpusFileSource(filePath: url, loop: false, timed: false)
        src.start()

        // After a short wait, the source should have exhausted the file and stopped
        let deadline = Date().addingTimeInterval(2.0)
        while src.running && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertFalse(src.running,
                       "Source must stop spontaneously after exhausting a non-loop file")
    }

    func testEmptyOrMissingFileDoesNotCrash() {
        let url = URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString).lxstopus")
        let src = OpusFileSource(filePath: url, timed: false)
        src.start()
        Thread.sleep(forTimeInterval: 0.1)
        src.stop()
        // Must not crash — running transitions to false cleanly
        XCTAssertFalse(src.running)
    }
}

// MARK: - Helpers

private final class FrameCollector: Sink {
    var channels:   Int?   = nil
    var sampleRate: Double = 0

    private let lock = NSLock()
    private var _frameCount = 0
    private var _lastFrame: AudioFrame?

    var frameCount: Int {
        lock.withLock { _frameCount }
    }
    var lastFrame: AudioFrame? {
        lock.withLock { _lastFrame }
    }

    func handleFrame(_ frame: AudioFrame, from source: (any Source)?) {
        lock.withLock {
            _frameCount += 1
            _lastFrame = frame
        }
    }
}

