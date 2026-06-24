import XCTest
@testable import LXST

/// Tests for Pipeline wiring, lifecycle, and dynamic codec switching.
final class PipelineTests: XCTestCase {

    // MARK: - Helpers

    final class MockSink: Sink {
        var channels:   Int?   = 1
        var sampleRate: Double = 48000
        var received: [AudioFrame] = []

        func handleFrame(_ frame: AudioFrame, from source: (any Source)?) {
            received.append(frame)
        }
    }

    final class MockSource: LocalSource {
        func feed(_ frame: AudioFrame) {
            sink?.handleFrame(frame, from: self)
        }
    }

    // MARK: - Pipeline basic wiring

    func testPipelineConnectsSourceSinkAndCodec() throws {
        let src   = MockSource()
        let codec = NullCodec()
        let sink  = MockSink()
        let pipe  = try Pipeline(source: src, codec: codec, sink: sink)

        // Check that pipeline wired the codec and sink correctly
        XCTAssertTrue(src.codec is NullCodec,
                      "Source.codec must be the NullCodec passed to Pipeline")
        XCTAssertTrue(src.sink is MockSink,
                      "Source.sink must be the MockSink passed to Pipeline")
        XCTAssertFalse(pipe.running)
    }

    func testPipelineStartStop() throws {
        let src  = MockSource()
        let pipe = try Pipeline(source: src, codec: NullCodec(), sink: MockSink())

        pipe.start()
        XCTAssertTrue(pipe.running, "Pipeline.running must be true after start()")

        pipe.stop()
        XCTAssertFalse(pipe.running, "Pipeline.running must be false after stop()")
    }

    func testFrameFlowsSourceToSink() throws {
        let src  = MockSource()
        let sink = MockSink()
        _    = try Pipeline(source: src, codec: NullCodec(), sink: sink)

        let frame = AudioFrame(samples: [0.1, 0.2], channelCount: 1, sampleRate: 48000)
        src.feed(frame)

        XCTAssertEqual(sink.received.count, 1, "Frame must flow from source to sink")
    }

    // MARK: - Loopback

    func testLoopbackDefaultTargetFrameMs() {
        let lb = Loopback()
        XCTAssertEqual(lb.targetFrameMs, 70.0,
                       "Python: Loopback default target_frame_ms = 70")
    }

    func testLoopbackPipelineWiring() throws {
        let lb   = Loopback()
        let sink = MockSink()
        _    = try Pipeline(source: lb, codec: NullCodec(), sink: sink)
        XCTAssertTrue(lb._sink === sink as AnyObject,
                      "Pipeline must wire loopback._sink = sink")
    }

    // MARK: - Dynamic codec switch mid-stream (Python: @codec.setter)

    func testDynamicCodecSwitch() throws {
        let src   = MockSource()
        let sink  = MockSink()
        let pipe  = try Pipeline(source: src, codec: NullCodec(), sink: sink)

        // Switch to RawCodec mid-stream
        let rawCodec = RawCodec()
        pipe.codec = rawCodec
        XCTAssertTrue(src.codec === rawCodec,
                      "Pipeline codec switch must update source.codec")
    }

    // MARK: - PipelineError

    func testPipelineExposesSourceSinkCodec() throws {
        let src   = MockSource()
        let codec = NullCodec()
        let sink  = MockSink()
        let pipe  = try Pipeline(source: src, codec: codec, sink: sink)

        XCTAssertTrue(pipe.source === src   as AnyObject)
        XCTAssertTrue(pipe.sink   === sink  as AnyObject)
    }

    // MARK: - Memory lifecycle (no retain cycles)
    //
    // Pipeline wiring creates several back-references (source.pipeline,
    // codec.source, sink.source on Packetizer/OpusFileSink). These must be
    // `weak` — Swift's ARC has no cyclic collector, so a strong back-reference
    // here is a permanent leak (unlike Python, where the cyclic GC eventually
    // reclaims the equivalent reference loops that `release()` was added to
    // pre-empt).

    func testPipelineSourceSinkCodecDeallocateTogether() throws {
        weak var weakPipeline: Pipeline?
        weak var weakSource:   AnyObject?
        weak var weakSink:     AnyObject?
        weak var weakCodec:    AnyObject?

        try {
            let source   = ToneSource()
            let sink     = Loopback()
            let codec    = RawCodec()
            let pipeline = try Pipeline(source: source, codec: codec, sink: sink)
            weakPipeline = pipeline
            weakSource   = source
            weakSink     = sink
            weakCodec    = codec
        }()

        XCTAssertNil(weakPipeline, "Pipeline must deallocate once its owner releases it")
        XCTAssertNil(weakSource,   "Source must not be retained by a Pipeline ↔ Source cycle")
        XCTAssertNil(weakSink,     "Sink must not be retained by a Pipeline ↔ Sink cycle")
        XCTAssertNil(weakCodec,    "Codec must not be retained by a Source ↔ Codec cycle")
    }

    func testPacketizerDoesNotRetainSourceCyclically() throws {
        weak var weakSource: AnyObject?
        weak var weakPkt:    AnyObject?

        try {
            let source = ToneSource()
            let pkt    = Packetizer()
            _ = try Pipeline(source: source, codec: RawCodec(), sink: pkt)
            weakSource = source
            weakPkt    = pkt
        }()

        XCTAssertNil(weakSource, "Packetizer.source must be weak — Source ↔ Sink would otherwise cycle")
        XCTAssertNil(weakPkt,    "Packetizer must deallocate once its owner releases it")
    }
}
