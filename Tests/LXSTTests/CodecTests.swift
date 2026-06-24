import XCTest
@testable import LXST

/// Tests for all codec implementations and their Python-parity constants.
final class CodecTests: XCTestCase {

    // MARK: - NullCodec

    func testNullCodecEncodeDecodeRoundTrip() throws {
        let codec = NullCodec()
        let frame = AudioFrame(samples: [0.1, -0.2, 0.3], channelCount: 1, sampleRate: 48000)
        let encoded = try codec.encode(frame)
        let decoded = try codec.decode(encoded)
        XCTAssertEqual(decoded.samples.count, 3)
        for (a, b) in zip(frame.samples, decoded.samples) {
            XCTAssertEqual(a, b, accuracy: 1e-6, "Null encode/decode must be identity")
        }
    }

    // MARK: - RawCodec

    func testRawCodecEncodeDecodeRoundTrip() throws {
        let codec = RawCodec(channels: 1, bitDepth: 32)
        let original = AudioFrame(samples: [0.5, -0.5, 0.25, -0.25],
                                  channelCount: 1, sampleRate: 48000)
        let encoded = try codec.encode(original)
        // Wire: 1-byte sub-header + 4 bytes per float32 sample
        XCTAssertEqual(encoded.count, 1 + 4 * 4, "Raw 32-bit mono: 1 sub-header + 4*4 bytes")

        let decoded = try codec.decode(encoded)
        XCTAssertEqual(decoded.channelCount, 1)
        for (a, b) in zip(original.samples, decoded.samples) {
            XCTAssertEqual(a, b, accuracy: 1e-6)
        }
    }

    func testRawCodecSubHeaderInWireBytes() throws {
        let codec = RawCodec(channels: 2, bitDepth: 32)
        let frame = AudioFrame(samples: [0.1, 0.2, 0.3, 0.4],
                               channelCount: 2, sampleRate: 48000)
        let encoded = try codec.encode(frame)
        let expectedSubHeader: UInt8 = (0x01 << 6) | 0x01  // float32, 2 channels
        XCTAssertEqual(encoded[encoded.startIndex], expectedSubHeader,
                       "First byte of Raw payload must be sub-header")
    }

    func testRawCodecInvalidFrameThrows() {
        let codec = RawCodec()
        XCTAssertThrowsError(try codec.decode(Data())) { error in
            XCTAssertEqual(error as? CodecError, .invalidFrame)
        }
    }

    // MARK: - Opus profile constants (Python: Opus.PROFILE_* values)

    func testOpusProfileRawValues() {
        XCTAssertEqual(OpusProfile.voiceLow.rawValue,    0x00) // PROFILE_VOICE_LOW
        XCTAssertEqual(OpusProfile.voiceMedium.rawValue, 0x01) // PROFILE_VOICE_MEDIUM
        XCTAssertEqual(OpusProfile.voiceHigh.rawValue,   0x02) // PROFILE_VOICE_HIGH
        XCTAssertEqual(OpusProfile.voiceMax.rawValue,    0x03) // PROFILE_VOICE_MAX
        XCTAssertEqual(OpusProfile.audioMin.rawValue,    0x04) // PROFILE_AUDIO_MIN
        XCTAssertEqual(OpusProfile.audioLow.rawValue,    0x05) // PROFILE_AUDIO_LOW
        XCTAssertEqual(OpusProfile.audioMedium.rawValue, 0x06) // PROFILE_AUDIO_MEDIUM
        XCTAssertEqual(OpusProfile.audioHigh.rawValue,   0x07) // PROFILE_AUDIO_HIGH
        XCTAssertEqual(OpusProfile.audioMax.rawValue,    0x08) // PROFILE_AUDIO_MAX
    }

    func testOpusProfileChannels() {
        // Python: Opus.profile_channels(profile)
        XCTAssertEqual(OpusProfile.voiceLow.channels,    1)
        XCTAssertEqual(OpusProfile.voiceMedium.channels, 1)
        XCTAssertEqual(OpusProfile.voiceHigh.channels,   1)
        XCTAssertEqual(OpusProfile.voiceMax.channels,    2)
        XCTAssertEqual(OpusProfile.audioMin.channels,    1)
        XCTAssertEqual(OpusProfile.audioLow.channels,    1)
        XCTAssertEqual(OpusProfile.audioMedium.channels, 2)
        XCTAssertEqual(OpusProfile.audioHigh.channels,   2)
        XCTAssertEqual(OpusProfile.audioMax.channels,    2)
    }

    func testOpusProfileSampleRates() {
        // Python: Opus.profile_samplerate(profile)
        XCTAssertEqual(OpusProfile.voiceLow.sampleRate,    8000)
        XCTAssertEqual(OpusProfile.voiceMedium.sampleRate, 24000)
        XCTAssertEqual(OpusProfile.voiceHigh.sampleRate,   48000)
        XCTAssertEqual(OpusProfile.voiceMax.sampleRate,    48000)
        XCTAssertEqual(OpusProfile.audioMin.sampleRate,    8000)
        XCTAssertEqual(OpusProfile.audioLow.sampleRate,    12000)
        XCTAssertEqual(OpusProfile.audioMedium.sampleRate, 24000)
        XCTAssertEqual(OpusProfile.audioHigh.sampleRate,   48000)
        XCTAssertEqual(OpusProfile.audioMax.sampleRate,    48000)
    }

    func testOpusProfileBitrateCeilings() {
        // Python: Opus.profile_bitrate_ceiling(profile)
        XCTAssertEqual(OpusProfile.voiceLow.bitrateCeiling,      6_000)
        XCTAssertEqual(OpusProfile.voiceMedium.bitrateCeiling,   8_000)
        XCTAssertEqual(OpusProfile.voiceHigh.bitrateCeiling,    16_000)
        XCTAssertEqual(OpusProfile.voiceMax.bitrateCeiling,     32_000)
        XCTAssertEqual(OpusProfile.audioMin.bitrateCeiling,      8_000)
        XCTAssertEqual(OpusProfile.audioLow.bitrateCeiling,     14_000)
        XCTAssertEqual(OpusProfile.audioMedium.bitrateCeiling,  28_000)
        XCTAssertEqual(OpusProfile.audioHigh.bitrateCeiling,    56_000)
        XCTAssertEqual(OpusProfile.audioMax.bitrateCeiling,    128_000)
    }

    func testOpusProfileVoipClassification() {
        // Python: Opus.profile_application(profile) → "voip" / "audio"
        for p in [OpusProfile.voiceLow, .voiceMedium, .voiceHigh, .voiceMax] {
            XCTAssertTrue(p.isVoip, "\(p) must be voip")
        }
        for p in [OpusProfile.audioMin, .audioLow, .audioMedium, .audioHigh, .audioMax] {
            XCTAssertFalse(p.isVoip, "\(p) must be audio (not voip)")
        }
    }

    func testOpusMaxBytesPerFrame() {
        // Python: Opus.max_bytes_per_frame(bitrate_ceiling, frame_duration_ms)
        // = ceil((bitrate_ceiling / 8) * (frame_duration_ms / 1000))
        let p = OpusProfile.voiceLow   // ceiling = 6000 bps
        let mb = p.maxBytesPerFrame(frameDurationMs: 60)
        let expected = Int(ceil(Double(6000) / 8.0 * (60.0 / 1000.0)))
        XCTAssertEqual(mb, expected, "maxBytesPerFrame must use Python formula")
    }

    func testOpusFrameConstants() {
        XCTAssertEqual(OPUS_FRAME_QUANTA_MS, 2.5)
        XCTAssertEqual(OPUS_FRAME_MAX_MS,    60.0)
        XCTAssertEqual(OPUS_VALID_FRAME_MS,  [2.5, 5.0, 10.0, 20.0, 40.0, 60.0])
    }

    func testOpusCodecDefaultProfile() {
        // Python: `def __init__(self, profile=PROFILE_VOICE_LOW)`
        let c = OpusCodec()
        XCTAssertEqual(c.profile, .voiceLow)
    }

    func testOpusCodecFrameQuantaMs() {
        let c = OpusCodec()
        XCTAssertEqual(c.frameQuantaMs, OPUS_FRAME_QUANTA_MS)
        XCTAssertEqual(c.frameMaxMs,    OPUS_FRAME_MAX_MS)
        XCTAssertEqual(c.validFrameMs,  OPUS_VALID_FRAME_MS)
    }

    // MARK: - Codec2 constants (Python: Codec2.CODEC2_* and MODE_HEADERS)

    func testCodec2ModeValues() {
        XCTAssertEqual(Codec2Mode.codec2_700c.rawValue, 700)
        XCTAssertEqual(Codec2Mode.codec2_1200.rawValue, 1200)
        XCTAssertEqual(Codec2Mode.codec2_1300.rawValue, 1300)
        XCTAssertEqual(Codec2Mode.codec2_1400.rawValue, 1400)
        XCTAssertEqual(Codec2Mode.codec2_1600.rawValue, 1600)
        XCTAssertEqual(Codec2Mode.codec2_2400.rawValue, 2400)
        XCTAssertEqual(Codec2Mode.codec2_3200.rawValue, 3200)
    }

    func testCodec2ModeHeaderBytes() {
        // Python: Codec2.MODE_HEADERS
        XCTAssertEqual(Codec2Mode.codec2_700c.headerByte, 0x00)
        XCTAssertEqual(Codec2Mode.codec2_1200.headerByte, 0x01)
        XCTAssertEqual(Codec2Mode.codec2_1300.headerByte, 0x02)
        XCTAssertEqual(Codec2Mode.codec2_1400.headerByte, 0x03)
        XCTAssertEqual(Codec2Mode.codec2_1600.headerByte, 0x04)
        XCTAssertEqual(Codec2Mode.codec2_2400.headerByte, 0x05)
        XCTAssertEqual(Codec2Mode.codec2_3200.headerByte, 0x06)
    }

    func testCodec2ModeFromHeaderByte() {
        // Python: Codec2.HEADER_MODES
        XCTAssertEqual(Codec2Mode.from(headerByte: 0x00), .codec2_700c)
        XCTAssertEqual(Codec2Mode.from(headerByte: 0x06), .codec2_3200)
        XCTAssertNil(Codec2Mode.from(headerByte: 0x07))
    }

    func testCodec2Constants() {
        XCTAssertEqual(CODEC2_INPUT_RATE,     8000.0)  // Python: Codec2.INPUT_RATE
        XCTAssertEqual(CODEC2_OUTPUT_RATE,    8000.0)  // Python: Codec2.OUTPUT_RATE
        XCTAssertEqual(CODEC2_FRAME_QUANTA_MS, 40.0)  // Python: Codec2.FRAME_QUANTA_MS
    }

    func testCodec2DefaultMode() {
        // Python: `def __init__(self, mode=CODEC2_2400)`
        let c = Codec2Codec()
        XCTAssertEqual(c.mode, .codec2_2400)
    }

    func testCodec2EncodeProducesNonEmptyData() throws {
        let c = Codec2Codec(mode: .codec2_2400)
        // One 40 ms frame @ 8 kHz = 320 samples
        let samples = [Float](repeating: 0.1, count: 320)
        let frame   = AudioFrame(samples: samples, channelCount: 1, sampleRate: 8000)
        let encoded = try c.encode(frame)
        XCTAssertGreaterThan(encoded.count, 1,
                             "Codec2 encode must produce at least the mode header byte + encoded data")
    }

    func testCodec2EncodedFirstByteIsModeHeader() throws {
        let c = Codec2Codec(mode: .codec2_2400)
        let samples = [Float](repeating: 0.0, count: 320)
        let frame   = AudioFrame(samples: samples, channelCount: 1, sampleRate: 8000)
        let encoded = try c.encode(frame)
        XCTAssertEqual(encoded[encoded.startIndex], Codec2Mode.codec2_2400.headerByte,
                       "First byte of encoded data must be the mode header byte (0x05 for 2400)")
    }

    func testCodec2EncodeDecodeRoundTripPreservesFrameLength() throws {
        let c = Codec2Codec(mode: .codec2_2400)
        // One 40 ms frame @ 8 kHz = 320 samples
        let samples = [Float](repeating: 0.2, count: 320)
        let frame   = AudioFrame(samples: samples, channelCount: 1, sampleRate: 8000)
        let encoded = try c.encode(frame)
        let decoded = try c.decode(encoded)
        // Decoded frame should have the same number of samples
        XCTAssertEqual(decoded.sampleCount, 320,
                       "Codec2 decode must produce the same number of samples as input (40 ms @ 8 kHz)")
        XCTAssertEqual(decoded.channelCount, 1)
    }

    func testCodec2AllModesEncodeWithoutError() throws {
        for mode in Codec2Mode.allCases {
            let c = Codec2Codec(mode: mode)
            // 40 ms @ 8 kHz = 320 samples per quanta
            let samples = [Float](repeating: 0.0, count: 320)
            let frame   = AudioFrame(samples: samples, channelCount: 1, sampleRate: 8000)
            XCTAssertNoThrow(try c.encode(frame),
                             "Codec2 mode \(mode) must encode without error")
        }
    }

    // MARK: - Opus libopus encode/decode round-trip tests

    func testOpusEncodeProducesNonEmptyData() throws {
        let codec = OpusCodec(profile: .voiceLow)
        // 20 ms of silence at 8 kHz mono = 160 samples
        let frame = AudioFrame(samples: [Float](repeating: 0, count: 160),
                               channelCount: 1, sampleRate: 8000)
        let encoded = try codec.encode(frame)
        XCTAssertGreaterThan(encoded.count, 0,
                             "OpusCodec.encode must return non-empty Opus bitstream")
    }

    func testOpusEncodeOutputIsCompact() throws {
        // Real Opus output is smaller than raw PCM — verifies libopus is linked
        let codec = OpusCodec(profile: .voiceLow)
        let frame = AudioFrame(samples: [Float](repeating: 0.1, count: 160),
                               channelCount: 1, sampleRate: 8000)
        let encoded = try codec.encode(frame)
        // 160 Float32 samples = 640 bytes raw; Opus at 6 kbps / 20 ms ≈ 15 bytes
        XCTAssertLessThan(encoded.count, 640,
                          "Opus-encoded output must be smaller than raw PCM")
    }

    func testOpusDecodeRoundTrip() throws {
        let codec = OpusCodec(profile: .voiceLow)
        // 20 ms of a low-amplitude tone at 8 kHz
        let freq: Double = 400
        let rate: Double = 8000
        let n = 160
        let samples = (0..<n).map { Float(sin(2 * .pi * freq * Double($0) / rate)) * 0.5 }
        let frame = AudioFrame(samples: samples, channelCount: 1, sampleRate: rate)

        let encoded = try codec.encode(frame)
        let decoded = try codec.decode(encoded)

        XCTAssertEqual(decoded.channelCount, 1)
        XCTAssertGreaterThan(decoded.sampleCount, 0,
                             "Decoded frame must contain samples")
    }

    func testOpusDecodeOutputHasCorrectChannelCount() throws {
        // voiceMax profile = stereo
        let codec = OpusCodec(profile: .voiceMax)
        let frame = AudioFrame(samples: [Float](repeating: 0, count: 960),
                               channelCount: 2, sampleRate: 48000)
        let encoded = try codec.encode(frame)
        let decoded = try codec.decode(encoded)
        XCTAssertEqual(decoded.channelCount, 2,
                       "Decoded frame must have the same channel count as profile")
    }

    func testOpusEncodeDecodeWithResampledInput() throws {
        // Input at 48 kHz, profile at 8 kHz → encode resamples down
        let codec = OpusCodec(profile: .voiceLow)
        let frame = AudioFrame(samples: [Float](repeating: 0.3, count: 960),
                               channelCount: 1, sampleRate: 48000)
        let encoded = try codec.encode(frame)
        XCTAssertGreaterThan(encoded.count, 0,
                             "Encoding after resampling must still produce output")
    }

    func testOpusAllProfilesEncodeWithoutError() throws {
        for p in OpusProfile.allCases {
            let codec = OpusCodec(profile: p)
            let ch = p.channels
            let n = Int(p.sampleRate * 0.020)   // 20 ms frame
            let frame = AudioFrame(samples: [Float](repeating: 0, count: n * ch),
                                   channelCount: ch, sampleRate: p.sampleRate)
            XCTAssertNoThrow(try codec.encode(frame),
                             "Profile \(p) must encode without error")
        }
    }
}
