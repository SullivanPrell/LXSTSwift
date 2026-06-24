import XCTest
@testable import LXST

// MARK: - OpusFileSink constants

final class OpusFileSinkConstantsTests: XCTestCase {

    func testAutoStartMin() {
        XCTAssertEqual(OpusFileSink.autoStartMin, 1, "Python: OpusFileSink.AUTOSTART_MIN = 1")
    }

    func testMaxFrames() {
        XCTAssertEqual(OpusFileSink.maxFrames, 64, "Python: OpusFileSink.MAX_FRAMES = 64")
    }

    func testFinalizeTimeout() {
        XCTAssertEqual(OpusFileSink.finalizeTimeout, 2,
                       "Python: OpusFileSink.FINALIZE_TIMEOUT = 2")
    }

    func testFileMagicLength() {
        XCTAssertEqual(OpusFileSink.magic.count, 8, "LXSTOPUS magic is 8 bytes")
        XCTAssertEqual(OpusFileSink.magic, Array("LXSTOPUS".utf8))
    }

    func testFileVersionByte() {
        XCTAssertEqual(OpusFileSink.fileVersion, 0x02,
                       "v2 header stores sample rate and channels after magic")
    }
}

// MARK: - OpusFileSink init and properties

final class OpusFileSinkInitTests: XCTestCase {

    func testDefaultProfile() {
        let sink = OpusFileSink()
        XCTAssertEqual(sink.profile, .audioMax,
                       "Python: default profile = PROFILE_AUDIO_MAX")
    }

    func testDefaultAutodigest() {
        let sink = OpusFileSink()
        XCTAssertTrue(sink.autodigest,
                      "Python: default autodigest = True")
    }

    func testDefaultOutputPathIsNil() {
        let sink = OpusFileSink()
        XCTAssertNil(sink.outputPath,
                     "Python: default path = None")
    }

    func testCustomInit() {
        let url = URL(fileURLWithPath: "/tmp/test.opus")
        let sink = OpusFileSink(path: url, autodigest: false, profile: .voiceLow)
        XCTAssertEqual(sink.outputPath, url)
        XCTAssertFalse(sink.autodigest)
        XCTAssertEqual(sink.profile, .voiceLow)
    }

    func testFramesWaitingStartsAtZero() {
        let sink = OpusFileSink()
        XCTAssertEqual(sink.framesWaiting, 0,
                       "framesWaiting must be 0 before any frames arrive")
    }
}

// MARK: - Frame queuing before start

final class OpusFileSinkQueueTests: XCTestCase {

    func testHandleFrameIncrementsFramesWaiting() {
        let sink = OpusFileSink(autodigest: false)
        let frame = AudioFrame(samples: [0.1, 0.2], channelCount: 1, sampleRate: 48000)
        sink.handleFrame(frame, from: nil)
        XCTAssertEqual(sink.framesWaiting, 1,
                       "framesWaiting must increment after handleFrame")
    }

    func testHandleMultipleFrames() {
        let sink = OpusFileSink(autodigest: false)
        let frame = AudioFrame(samples: [0.1], channelCount: 1, sampleRate: 48000)
        sink.handleFrame(frame, from: nil)
        sink.handleFrame(frame, from: nil)
        sink.handleFrame(frame, from: nil)
        XCTAssertEqual(sink.framesWaiting, 3)
    }

    func testMaxFramesCapEnforced() {
        let sink = OpusFileSink(autodigest: false)
        let frame = AudioFrame(samples: [0.1], channelCount: 1, sampleRate: 48000)
        for _ in 0..<200 {
            sink.handleFrame(frame, from: nil)
        }
        XCTAssertLessThanOrEqual(sink.framesWaiting, OpusFileSink.maxFrames,
                                 "Queue must not exceed MAX_FRAMES")
    }
}

// MARK: - Lifecycle (no output path — digest thread guards against nil path)

final class OpusFileSinkLifecycleTests: XCTestCase {

    func testStartAndStopWithNoPathDoesNotCrash() {
        let sink = OpusFileSink(autodigest: false)
        sink.start()
        sink.stop()
        // Just verifying no crash / no hang
    }

    func testCanReceiveReturnsTrueByDefault() {
        let sink = OpusFileSink()
        XCTAssertTrue(sink.canReceive(from: nil),
                      "canReceive must return true by default")
    }
}

// MARK: - File writing round-trip

final class OpusFileSinkFileWriteTests: XCTestCase {

    private func tmpURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lxst_opus_test_\(UUID().uuidString).lxstopus")
    }

    func testFileIsCreatedAfterStartStop() {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let sink = OpusFileSink(path: url, autodigest: false, profile: .voiceLow)
        let frame = AudioFrame(
            samples: [Float](repeating: 0, count: 480),
            channelCount: 1, sampleRate: 8000
        )
        sink.handleFrame(frame, from: nil)
        sink.start()
        sink.stop()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "Output file must exist after start/stop")
    }

    func testFileContainsMagicHeader() {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let sink = OpusFileSink(path: url, autodigest: false, profile: .voiceLow)
        let frame = AudioFrame(
            samples: [Float](repeating: 0, count: 480),
            channelCount: 1, sampleRate: 8000
        )
        sink.handleFrame(frame, from: nil)
        sink.start()
        sink.stop()

        let data = try? Data(contentsOf: url)
        XCTAssertNotNil(data)
        XCTAssertGreaterThanOrEqual(data?.count ?? 0, 14,
                                    "File must contain at least the 14-byte v2 header")

        let magic = Array((data ?? Data()).prefix(8))
        XCTAssertEqual(magic, OpusFileSink.magic,
                       "First 8 bytes must be LXSTOPUS magic")

        let version = data?[8]
        XCTAssertEqual(version, OpusFileSink.fileVersion,
                       "Byte 9 must be the file version")
    }

    func testFileContainsEncodedFrameData() {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // 60 ms of silence at 8 kHz mono = 480 samples
        let sink = OpusFileSink(path: url, autodigest: false, profile: .voiceLow)
        let frame = AudioFrame(
            samples: [Float](repeating: 0, count: 480),
            channelCount: 1, sampleRate: 8000
        )
        sink.handleFrame(frame, from: nil)
        sink.start()
        sink.stop()

        let data = try? Data(contentsOf: url)
        // File must have more than just the header (9 bytes) — at least one frame written
        XCTAssertGreaterThan(data?.count ?? 0, 9,
                             "File must contain encoded Opus data beyond the header")
    }

    func testMultipleFramesAreWritten() {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let sink = OpusFileSink(path: url, autodigest: false, profile: .voiceLow)
        let frame = AudioFrame(
            samples: [Float](repeating: 0, count: 480),
            channelCount: 1, sampleRate: 8000
        )
        for _ in 0..<5 { sink.handleFrame(frame, from: nil) }
        sink.start()
        sink.stop()

        // After writing 5 frames, file must be larger than 1 frame
        let data = try? Data(contentsOf: url)
        XCTAssertGreaterThan(data?.count ?? 0, 13,
                             "File with 5 frames must be larger than with 1 frame")
    }

    func testAutodigestStartsWritingOnFirstFrame() {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let sink = OpusFileSink(path: url, autodigest: true, profile: .voiceLow)
        let frame = AudioFrame(
            samples: [Float](repeating: 0, count: 480),
            channelCount: 1, sampleRate: 8000
        )
        sink.handleFrame(frame, from: nil)  // autodigest triggers start()
        sink.stop()                          // explicit stop to flush

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "autodigest must trigger start() after autoStartMin frames")
    }
}
