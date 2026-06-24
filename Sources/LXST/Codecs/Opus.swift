#if canImport(AVFAudio)
import AVFAudio
#endif
import Foundation
import COpus

// MARK: - Opus profile

/// Opus codec profile, matching Python `Opus.PROFILE_*` raw values exactly.
/// Python: `LXST.Codecs.Opus`
public enum OpusProfile: UInt8, CaseIterable {
    case voiceLow    = 0x00   // Python: PROFILE_VOICE_LOW
    case voiceMedium = 0x01   // Python: PROFILE_VOICE_MEDIUM
    case voiceHigh   = 0x02   // Python: PROFILE_VOICE_HIGH
    case voiceMax    = 0x03   // Python: PROFILE_VOICE_MAX
    case audioMin    = 0x04   // Python: PROFILE_AUDIO_MIN
    case audioLow    = 0x05   // Python: PROFILE_AUDIO_LOW
    case audioMedium = 0x06   // Python: PROFILE_AUDIO_MEDIUM
    case audioHigh   = 0x07   // Python: PROFILE_AUDIO_HIGH
    case audioMax    = 0x08   // Python: PROFILE_AUDIO_MAX

    // MARK: - Profile properties (Python: Opus.profile_channels/samplerate/bitrate_ceiling)

    /// Number of output channels. Python: `Opus.profile_channels(profile)`
    public var channels: Int {
        switch self {
        case .voiceLow, .voiceMedium, .voiceHigh,
             .audioMin, .audioLow:    return 1
        case .voiceMax, .audioMedium,
             .audioHigh, .audioMax:   return 2
        }
    }

    /// Output sample rate in Hz. Python: `Opus.profile_samplerate(profile)`
    public var sampleRate: Double {
        switch self {
        case .voiceLow, .audioMin:      return 8000
        case .audioLow:                 return 12000
        case .voiceMedium, .audioMedium: return 24000
        case .voiceHigh, .voiceMax,
             .audioHigh, .audioMax:     return 48000
        }
    }

    /// Bitrate ceiling in bits/second. Python: `Opus.profile_bitrate_ceiling(profile)`
    public var bitrateCeiling: Int {
        switch self {
        case .voiceLow:    return 6_000
        case .voiceMedium: return 8_000
        case .voiceHigh:   return 16_000
        case .voiceMax:    return 32_000
        case .audioMin:    return 8_000
        case .audioLow:    return 14_000
        case .audioMedium: return 28_000
        case .audioHigh:   return 56_000
        case .audioMax:    return 128_000
        }
    }

    /// Whether this is a "voip" (true) or "audio" (false) application type.
    /// Python: `Opus.profile_application(profile)` → "voip" / "audio"
    public var isVoip: Bool {
        switch self {
        case .voiceLow, .voiceMedium, .voiceHigh, .voiceMax: return true
        default: return false
        }
    }

    /// Libopus application constant for this profile.
    internal var cApplication: Int32 {
        isVoip ? OPUS_APPLICATION_VOIP : OPUS_APPLICATION_AUDIO
    }

    /// Maximum bytes per frame for this profile at a given duration.
    /// Python: `Opus.max_bytes_per_frame(bitrate_ceiling, frame_duration_ms)`
    public func maxBytesPerFrame(frameDurationMs: Double) -> Int {
        Int(ceil(Double(bitrateCeiling) / 8.0 * (frameDurationMs / 1000.0)))
    }
}

// MARK: - Opus codec constants (Python class-level)

/// Python: `Opus.FRAME_QUANTA_MS = 2.5`
public let OPUS_FRAME_QUANTA_MS: Double = 2.5
/// Python: `Opus.FRAME_MAX_MS = 60`
public let OPUS_FRAME_MAX_MS: Double = 60
/// Python: `Opus.VALID_FRAME_MS = [2.5, 5, 10, 20, 40, 60]`
public let OPUS_VALID_FRAME_MS: [Double] = [2.5, 5, 10, 20, 40, 60]

// MARK: - OpusCodec

/// Opus audio codec backed by libopus (COpus XCFramework).
/// Python: `LXST.Codecs.Opus` — header byte OPUS = 0x01
///
/// Encode: resamples input PCM to the profile's sample rate, then calls
/// `opus_encode_float()` to produce a real Opus bitstream.
/// Decode: calls `opus_decode_float()` and returns an AudioFrame.
public final class OpusCodec: Codec {
    public static let headerByte: UInt8 = CODEC_OPUS

    public var preferredSampleRate: Double? { profile.sampleRate }
    public var frameQuantaMs:       Double? { OPUS_FRAME_QUANTA_MS }
    public var frameMaxMs:          Double? { OPUS_FRAME_MAX_MS }
    public var validFrameMs:        [Double] { OPUS_VALID_FRAME_MS }
    public var channels:  Int? { didSet { invalidateState() } }
    public weak var source: (any Source)? = nil
    public var sink:      (any Sink)?   = nil

    public private(set) var profile: OpusProfile
    public private(set) var outputSampleRate: Double
    public private(set) var bitrateCeiling: Int

    private var encoder: OpaquePointer?
    private var decoder: OpaquePointer?
    private let lock = NSLock()

    /// Python: `def __init__(self, profile=PROFILE_VOICE_LOW)`
    public init(profile: OpusProfile = .voiceLow) {
        self.profile          = profile
        self.channels         = profile.channels
        self.outputSampleRate = profile.sampleRate
        self.bitrateCeiling   = profile.bitrateCeiling
    }

    deinit {
        if let enc = encoder { opus_encoder_destroy(enc) }
        if let dec = decoder { opus_decoder_destroy(dec) }
    }

    /// Change the active profile. Invalidates any cached encoder/decoder state.
    /// Python: `Opus.set_profile(profile)`
    public func setProfile(_ newProfile: OpusProfile) {
        guard newProfile != profile else { return }
        profile          = newProfile
        channels         = newProfile.channels
        outputSampleRate = newProfile.sampleRate
        bitrateCeiling   = newProfile.bitrateCeiling
        invalidateState()
    }

    private func invalidateState() {
        lock.lock(); defer { lock.unlock() }
        if let enc = encoder { opus_encoder_destroy(enc); encoder = nil }
        if let dec = decoder { opus_decoder_destroy(dec); decoder = nil }
    }

    // MARK: - Lazy encoder setup

    private func ensureEncoder() throws {
        guard encoder == nil else { return }
        let ch = Int32(channels ?? profile.channels)
        let fs = Int32(profile.sampleRate)
        var err: Int32 = 0
        guard let enc = opus_encoder_create(fs, ch, profile.cApplication, &err),
              err == OPUS_OK else {
            throw CodecError.encoderNotConfigured
        }
        // Note: opus_encoder_ctl is variadic and not callable from Swift.
        // libopus will use auto-bitrate, which produces valid Opus output.
        // Bitrate ceiling is used for frame-size planning (maxBytesPerFrame) only.
        encoder = enc
    }

    // MARK: - Lazy decoder setup

    private func ensureDecoder() throws {
        guard decoder == nil else { return }
        let ch = Int32(channels ?? profile.channels)
        let fs = Int32(profile.sampleRate)
        var err: Int32 = 0
        guard let dec = opus_decoder_create(fs, ch, &err),
              err == OPUS_OK else {
            throw CodecError.decoderNotConfigured
        }
        decoder = dec
    }

    // MARK: - Encode

    /// Encode an AudioFrame to a real Opus bitstream.
    /// Resamples to the profile's sample rate if needed, then calls `opus_encode_float()`.
    public func encode(_ frame: AudioFrame) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        try ensureEncoder()
        guard let enc = encoder else { throw CodecError.encoderNotConfigured }

        let targetRate = profile.sampleRate
        let targetCh   = channels ?? profile.channels

        // Resample and mix to target channel count / rate
        let pcm = resample(frame: frame, toRate: targetRate, toChannels: targetCh)

        // Compute max output bytes: use profile bitrate ceiling + generous buffer
        let frameDurationMs = Double(pcm.count / targetCh) / targetRate * 1000.0
        let maxBytes = max(profile.maxBytesPerFrame(frameDurationMs: frameDurationMs) * 4, 4096)
        var outBuf = [UInt8](repeating: 0, count: maxBytes)

        let n = Int(pcm.count / targetCh)   // samples per channel
        let encoded = pcm.withUnsafeBufferPointer { ptr in
            opus_encode_float(enc, ptr.baseAddress!, Int32(n), &outBuf, Int32(maxBytes))
        }
        guard encoded > 0 else { throw CodecError.invalidFrame }
        return Data(outBuf.prefix(Int(encoded)))
    }

    // MARK: - Decode

    /// Decode Opus bitstream bytes to an AudioFrame.
    public func decode(_ data: Data) throws -> AudioFrame {
        lock.lock(); defer { lock.unlock() }
        try ensureDecoder()
        guard let dec = decoder else { throw CodecError.decoderNotConfigured }
        guard !data.isEmpty else { throw CodecError.invalidFrame }

        let ch = channels ?? profile.channels
        let rate = profile.sampleRate
        // Max output: 60 ms at 48 kHz stereo = 5760 samples/ch
        let maxSamplesPerCh = Int(rate * OPUS_FRAME_MAX_MS / 1000.0) + 64
        let maxTotal = maxSamplesPerCh * ch
        var pcm = [Float](repeating: 0, count: maxTotal)

        let decoded = data.withUnsafeBytes { ptr in
            opus_decode_float(dec, ptr.bindMemory(to: UInt8.self).baseAddress!,
                              Int32(data.count), &pcm, Int32(maxSamplesPerCh), 0)
        }
        guard decoded > 0 else { throw CodecError.invalidFrame }

        let total = Int(decoded) * ch
        let samples = Array(pcm.prefix(total))
        let sinkRate = (sink as? LocalSink)?.sampleRate ?? rate
        return AudioFrame(samples: samples, channelCount: ch, sampleRate: sinkRate)
    }

    // MARK: - Private helpers

    /// Resample + channel-adapt an AudioFrame to the target rate and channel count.
    private func resample(frame: AudioFrame, toRate targetRate: Double, toChannels targetCh: Int) -> [Float] {
        let srcCh  = frame.channelCount
        let srcN   = frame.sampleCount   // samples per channel
        let srcRate = frame.sampleRate

        // Step 1: channel conversion
        var mono: [Float]
        if srcCh == targetCh {
            mono = frame.samples
        } else if targetCh == 1 {
            // Mix down to mono
            mono = [Float](repeating: 0, count: srcN)
            for i in 0..<srcN {
                var sum: Float = 0
                for c in 0..<srcCh { sum += frame.samples[i * srcCh + c] }
                mono[i] = sum / Float(srcCh)
            }
        } else {
            // Upmix mono to stereo (duplicate channel)
            var stereo = [Float](repeating: 0, count: srcN * targetCh)
            let srcMono = srcCh > 1 ? {
                var m = [Float](repeating: 0, count: srcN)
                for i in 0..<srcN {
                    var sum: Float = 0
                    for c in 0..<srcCh { sum += frame.samples[i * srcCh + c] }
                    m[i] = sum / Float(srcCh)
                }
                return m
            }() : frame.samples
            for i in 0..<srcN {
                for c in 0..<targetCh { stereo[i * targetCh + c] = srcMono[i] }
            }
            mono = stereo
        }

        // Step 2: sample-rate conversion (naive linear if needed)
        guard srcRate != targetRate else { return mono }

        let ratio   = targetRate / srcRate
        // Round (not truncate) to avoid off-by-one samples after resampling
        // (e.g. 882 @ 44.1 kHz → 48 kHz: 882 × 1.0884 = 959.97 → 960, not 959).
        // opus_encode_float rejects any count that isn't an exact Opus frame size.
        let outN    = Int((Double(srcN) * ratio).rounded())
        let outSize = outN * targetCh
        var out = [Float](repeating: 0, count: outSize)

        for i in 0..<outN {
            let srcF   = Double(i) / ratio
            let srcIdx = Int(srcF)
            let frac   = Float(srcF - Double(srcIdx))
            for c in 0..<targetCh {
                let a = srcIdx < srcN ? mono[srcIdx * targetCh + c] : 0
                let b = (srcIdx + 1) < srcN ? mono[(srcIdx + 1) * targetCh + c] : a
                out[i * targetCh + c] = a + frac * (b - a)
            }
        }
        return out
    }
}
