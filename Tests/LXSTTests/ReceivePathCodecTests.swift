import XCTest
@testable import LXST

/// The receive path builds its codec on the first frame that names one, and that codec has to
/// know its sink before it decodes anything.
///
/// `bugs/017`: `LinkSource` instantiates a bare `OpusCodec()` for any 0x01 frame and never calls
/// `setProfile`, so the codec's own rate is the 8 kHz default whatever the sender chose. That is
/// only harmless because `decode` now takes its rate from the sink — which means the sink must
/// already be attached at that point, for every codec type, forever.
final class ReceivePathCodecTests: XCTestCase {

    private func received(_ headerByte: UInt8, sink: any Sink) throws -> any Codec {
        try XCTUnwrap(LinkSource.makeReceiveCodec(for: headerByte, sink: sink, source: nil))
    }

    /// Every codec the receive path can build arrives with its sink attached. Enumerated from
    /// `codecType(for:)` rather than hand-listed, so a codec added to the wire table without
    /// being added here fails instead of going unchecked.
    func testEveryReceiveCodecIsBuiltWithItsSinkAttached() throws {
        let sink = RateSink(sampleRate: 48000, channels: 1)
        var built = 0
        for headerByte in UInt8.min...UInt8.max {
            guard let expected = codecType(for: headerByte) else {
                XCTAssertNil(LinkSource.makeReceiveCodec(for: headerByte, sink: sink, source: nil),
                             "0x\(String(headerByte, radix: 16)) names no codec")
                continue
            }
            let codec = try received(headerByte, sink: sink)
            XCTAssertTrue(type(of: codec) == expected,
                          "header 0x\(String(headerByte, radix: 16)) must build \(expected)")
            XCTAssertTrue(codec.sink === sink,
                          """
                          \(type(of: codec)) reached the receive path with no sink. Its first \
                          frame would decode at its own default rate (bugs/017).
                          """)
            built += 1
        }
        XCTAssertEqual(built, 4, "null, raw, opus and codec2 are the four wire codecs")
    }

    /// The worked example from `bugs/017`: a `qualityMedium` sender (Opus 24 kHz) reaching a
    /// receiver whose codec is the 8 kHz default, playing into a 48 kHz sink. Before the fix the
    /// receiver got 480 samples where the mixer expected 2880 — 10 ms of speech at six times
    /// pitch, then 50 ms of silence, with signalling reporting an established call throughout.
    func testAReceiveCodecDecodesAtTheSinkRateOnItsFirstFrame() throws {
        let sender = OpusCodec(profile: .voiceMedium)      // 24 kHz — Telephone .qualityMedium
        let n = Int(24000 * 0.060)                          // 60 ms
        let wire = try sender.encode(AudioFrame(samples: [Float](repeating: 0.1, count: n),
                                                channelCount: 1, sampleRate: 24000))

        let sink  = RateSink(sampleRate: 48000, channels: 1)
        let codec = try received(CODEC_OPUS, sink: sink)
        XCTAssertEqual((codec as? OpusCodec)?.profile, .voiceLow,
                       "sanity: nothing negotiates a profile onto the receive codec — Python "
                       + "builds `frame_codec()` bare too (Network.py:127-128)")

        assertDecoded(try codec.decode(wire), playableBy: sink,
                      codecRate: OpusProfile.voiceLow.sampleRate, durationMs: 60)
    }

    /// The same for Codec2, whose default mode is 2400 and whose rate is fixed at 8 kHz.
    func testACodec2ReceiveCodecDecodesAtTheSinkRateOnItsFirstFrame() throws {
        let sender = Codec2Codec(mode: .codec2_700c)        // Telephone .bandwidthUltraLow
        let wire = try sender.encode(AudioFrame(samples: [Float](repeating: 0.1, count: 3200),
                                                channelCount: 1, sampleRate: 8000))  // 400 ms

        let sink  = RateSink(sampleRate: 48000, channels: 1)
        let codec = try received(CODEC_CODEC2, sink: sink)

        assertDecoded(try codec.decode(wire), playableBy: sink,
                      codecRate: CODEC2_OUTPUT_RATE, durationMs: 400)
    }
}
