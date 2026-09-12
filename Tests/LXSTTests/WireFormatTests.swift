import XCTest
@testable import LXST

/// Tests for LXST wire-format constants, codec header bytes, and msgpack structure.
/// Every value is verified against the Python 0.4.6 reference.
final class WireFormatTests: XCTestCase {

    // MARK: - appName

    func testAppName() {
        XCTAssertEqual(appName, "lxst",
                       "appName must be 'lxst' (Python: LXST.APP_NAME = 'lxst')")
    }

    // MARK: - Field keys (Python: LXST.Network.FIELD_SIGNALLING / FIELD_FRAMES)

    func testFieldSignalling() {
        XCTAssertEqual(fieldSignalling, 0x00,
                       "fieldSignalling must be 0x00")
    }

    func testFieldFrames() {
        XCTAssertEqual(fieldFrames, 0x01,
                       "fieldFrames must be 0x01")
    }

    // MARK: - Codec header bytes (Python: LXST.Codecs.NULL/RAW/OPUS/CODEC2)

    func testCodecNullHeaderByte() {
        XCTAssertEqual(codecNull,   0xFF, "NULL codec header must be 0xFF")
    }
    func testCodecRawHeaderByte() {
        XCTAssertEqual(codecRaw,    0x00, "RAW codec header must be 0x00")
    }
    func testCodecOpusHeaderByte() {
        XCTAssertEqual(codecOpus,   0x01, "OPUS codec header must be 0x01")
    }
    func testCodecCodec2HeaderByte() {
        XCTAssertEqual(codecCodec2, 0x02, "CODEC2 codec header must be 0x02")
    }

    // MARK: - Codec type class headerByte properties

    func testNullCodecStaticHeaderByte() {
        XCTAssertEqual(NullCodec.headerByte,   codecNull)
    }
    func testRawCodecStaticHeaderByte() {
        XCTAssertEqual(RawCodec.headerByte,    codecRaw)
    }
    func testOpusCodecStaticHeaderByte() {
        XCTAssertEqual(OpusCodec.headerByte,   codecOpus)
    }
    func testCodec2CodecStaticHeaderByte() {
        XCTAssertEqual(Codec2Codec.headerByte, codecCodec2)
    }

    // MARK: - codecHeaderByte() / codecType() dispatch

    func testCodecHeaderByteDispatch() {
        XCTAssertEqual(codecHeaderByte(for: NullCodec.self),   codecNull)
        XCTAssertEqual(codecHeaderByte(for: RawCodec.self),    codecRaw)
        XCTAssertEqual(codecHeaderByte(for: OpusCodec.self),   codecOpus)
        XCTAssertEqual(codecHeaderByte(for: Codec2Codec.self), codecCodec2)
    }

    func testCodecTypeDispatch() {
        XCTAssertTrue(codecType(for: codecNull)   === NullCodec.self)
        XCTAssertTrue(codecType(for: codecRaw)    === RawCodec.self)
        XCTAssertTrue(codecType(for: codecOpus)   === OpusCodec.self)
        XCTAssertTrue(codecType(for: codecCodec2) === Codec2Codec.self)
    }

    func testCodecTypeReturnsNilForUnknown() {
        XCTAssertNil(codecType(for: 0x42), "unknown header byte must return nil")
    }

    // MARK: - Raw sub-header encoding

    func testRawSubHeaderFloat16Mono() {
        let h = RawCodec.subHeader(bitDepth: 16, channelCount: 1)
        // bits 7-6 = 00 (float16), bits 5-0 = 000000 (channels-1 = 0)
        XCTAssertEqual(h, 0x00, "Raw sub-header for 16-bit mono must be 0x00")
    }

    func testRawSubHeaderFloat32Stereo() {
        let h = RawCodec.subHeader(bitDepth: 32, channelCount: 2)
        // bits 7-6 = 01 (float32=0x01), bits 5-0 = 000001 (channels-1=1)
        XCTAssertEqual(h, (0x01 << 6) | 0x01, "Raw sub-header for 32-bit stereo")
    }

    func testRawSubHeaderFloat64FourChannel() {
        let h = RawCodec.subHeader(bitDepth: 64, channelCount: 4)
        // bits 7-6 = 10 (float64=0x02), bits 5-0 = 000011 (channels-1=3)
        XCTAssertEqual(h, (0x02 << 6) | 0x03)
    }

    func testRawSubHeaderFloat128MaxChannels() {
        let h = RawCodec.subHeader(bitDepth: 128, channelCount: 32)
        // bits 7-6 = 11 (float128=0x03), bits 5-0 = 011111 (31)
        XCTAssertEqual(h, (0x03 << 6) | 0x1F)
    }

    func testRawSubHeaderBitDepthRoundTrip() {
        // rawValue 0→16, 1→32, 2→64, 3→128  bits (16 * 2^rawValue)
        for depth in [RawBitDepth.float16, .float32, .float64, .float128] {
            let bits = 16 << Int(depth.rawValue)   // 16, 32, 64, 128
            let h    = RawCodec.subHeader(bitDepth: bits, channelCount: 1)
            XCTAssertEqual(RawCodec.bitDepth(fromSubHeader: h), depth,
                           "Round-trip for \(bits)-bit depth")
        }
    }

    func testRawSubHeaderChannelRoundTrip() {
        for ch in [1, 2, 8, 16, 32] {
            let h = RawCodec.subHeader(bitDepth: 16, channelCount: ch)
            XCTAssertEqual(RawCodec.channelCount(fromSubHeader: h), ch)
        }
    }

    // MARK: - Raw bitdepth constants (Python: Raw.BITDEPTH_*)

    func testRawBitDepthValues() {
        XCTAssertEqual(RawBitDepth.float16.rawValue,  0x00) // Python: BITDEPTH_16
        XCTAssertEqual(RawBitDepth.float32.rawValue,  0x01) // Python: BITDEPTH_32
        XCTAssertEqual(RawBitDepth.float64.rawValue,  0x02) // Python: BITDEPTH_64
        XCTAssertEqual(RawBitDepth.float128.rawValue, 0x03) // Python: BITDEPTH_128
    }

    func testRawBitDepthBytesPerSample() {
        XCTAssertEqual(RawBitDepth.float16.bytesPerSample,  2)
        XCTAssertEqual(RawBitDepth.float32.bytesPerSample,  4)
        XCTAssertEqual(RawBitDepth.float64.bytesPerSample,  8)
        XCTAssertEqual(RawBitDepth.float128.bytesPerSample, 16)
    }

    // MARK: - Raw max channels constant

    func testRawMaxChannels() {
        XCTAssertEqual(RawCodec.maxChannels, 32,
                       "Python: min(max(channels, 1), 32)")
    }
}
