import Foundation
import CCodec2

// MARK: - Codec2 mode

/// Codec2 voice mode, matching Python `Codec2.CODEC2_*` constants exactly.
/// Python: `LXST.Codecs.Codec2`
public enum Codec2Mode: Int, CaseIterable {
    case codec2_700c = 700    // Python: CODEC2_700C
    case codec2_1200 = 1200   // Python: CODEC2_1200
    case codec2_1300 = 1300   // Python: CODEC2_1300
    case codec2_1400 = 1400   // Python: CODEC2_1400
    case codec2_1600 = 1600   // Python: CODEC2_1600
    case codec2_2400 = 2400   // Python: CODEC2_2400
    case codec2_3200 = 3200   // Python: CODEC2_3200

    /// C-library mode constant (codec2.h: CODEC2_MODE_*).
    /// Python: `Codec2.MODE_HEADERS` maps Python mode int → header byte,
    /// but the C library uses its own ordering. We map our enum → C constant.
    internal var cMode: Int32 {
        switch self {
        case .codec2_3200: return CODEC2_MODE_3200   // 0
        case .codec2_2400: return CODEC2_MODE_2400   // 1
        case .codec2_1600: return CODEC2_MODE_1600   // 2
        case .codec2_1400: return CODEC2_MODE_1400   // 3
        case .codec2_1300: return CODEC2_MODE_1300   // 4
        case .codec2_1200: return CODEC2_MODE_1200   // 5
        case .codec2_700c: return CODEC2_MODE_700C   // 8
        }
    }

    /// LXST wire sub-header byte for this mode.
    /// Python: `Codec2.MODE_HEADERS`
    public var headerByte: UInt8 {
        switch self {
        case .codec2_700c: return 0x00
        case .codec2_1200: return 0x01
        case .codec2_1300: return 0x02
        case .codec2_1400: return 0x03
        case .codec2_1600: return 0x04
        case .codec2_2400: return 0x05
        case .codec2_3200: return 0x06
        }
    }

    /// Decode a Codec2Mode from its LXST wire header byte.
    /// Python: `Codec2.HEADER_MODES`
    public static func from(headerByte: UInt8) -> Codec2Mode? {
        allCases.first { $0.headerByte == headerByte }
    }
}

// MARK: - Codec2 constants (Python class-level)

/// Python: `Codec2.INPUT_RATE = 8000`
public let CODEC2_INPUT_RATE: Double = 8000
/// Python: `Codec2.OUTPUT_RATE = 8000`
public let CODEC2_OUTPUT_RATE: Double = 8000
/// Python: `Codec2.FRAME_QUANTA_MS = 40`
public let CODEC2_FRAME_QUANTA_MS: Double = 40

// MARK: - Codec2Codec

/// Codec2 ultra-low-bandwidth voice codec backed by libcodec2 (CCodec2 XCFramework).
///
/// Python: `LXST.Codecs.Codec2` — LXST wire header byte CODEC2 = 0x02
///
/// Wire format for encoded bytes:
///   [mode_header_byte (1B)][codec2_encoded_bytes (N B)]
///
/// Default mode: `.codec2_2400` (Python: `def __init__(self, mode=CODEC2_2400)`)
public final class Codec2Codec: Codec {
    public static let headerByte: UInt8 = CODEC_CODEC2

    public var preferredSampleRate: Double? { CODEC2_INPUT_RATE }
    public var frameQuantaMs:       Double? { CODEC2_FRAME_QUANTA_MS }
    public var frameMaxMs:          Double? { nil }
    public var validFrameMs:        [Double] { [CODEC2_FRAME_QUANTA_MS] }
    public var channels: Int? = 1
    public weak var source: (any Source)? = nil
    public var sink:   (any Sink)?   = nil

    public private(set) var mode: Codec2Mode
    public private(set) var outputSampleRate: Double = CODEC2_OUTPUT_RATE

    private var state: OpaquePointer?
    private let lock = NSLock()

    // Cached frame geometry (determined at first use)
    private var samplesPerFrame: Int = 0
    private var bytesPerFrame:   Int = 0

    /// Python: `def __init__(self, mode=CODEC2_2400)`
    public init(mode: Codec2Mode = .codec2_2400) {
        self.mode = mode
    }

    /// Change the active mode. Resets the codec state.
    /// Python: `Codec2.set_mode(mode)`
    public func setMode(_ newMode: Codec2Mode) {
        guard newMode != mode else { return }
        lock.lock()
        if let s = state { codec2_destroy(s); state = nil }
        lock.unlock()
        mode = newMode
    }

    deinit {
        if let s = state { codec2_destroy(s); state = nil }
    }

    // MARK: - Lazy encoder/decoder setup

    private func ensureState() throws {
        guard state == nil else { return }
        guard let s = codec2_create(mode.cMode) else {
            throw CodecError.encoderNotConfigured
        }
        state = s
        samplesPerFrame = Int(codec2_samples_per_frame(s))
        let bits        = Int(codec2_bits_per_frame(s))
        bytesPerFrame   = (bits + 7) / 8   // round up to whole bytes
    }

    // MARK: - Encode

    /// Python: `Codec2.encode(frame)` — resample to 8 kHz, encode to Codec2 bytes.
    /// Wire output: `[mode_header_byte][codec2_encoded_bytes]`
    public func encode(_ frame: AudioFrame) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        try ensureState()

        // Resample to 8 kHz mono if needed
        let pcm16 = toInt16Mono(frame: frame, targetRate: CODEC2_INPUT_RATE)

        // Encode one frame at a time
        var encoded = Data([mode.headerByte])   // prepend mode header byte
        let stride = samplesPerFrame
        var offset = 0
        while offset + stride <= pcm16.count {
            var outBytes = [UInt8](repeating: 0, count: bytesPerFrame)
            pcm16[offset ..< offset + stride].withUnsafeBufferPointer { ptr in
                codec2_encode(state!, &outBytes, UnsafeMutablePointer(mutating: ptr.baseAddress!))
            }
            encoded.append(contentsOf: outBytes)
            offset += stride
        }

        return encoded
    }

    // MARK: - Decode

    /// Python: `Codec2.decode(frame_bytes)` — decode Codec2 bytes to PCM Float32.
    /// Input: `[mode_header_byte][codec2_encoded_bytes]`
    public func decode(_ data: Data) throws -> AudioFrame {
        lock.lock(); defer { lock.unlock() }

        guard data.count > 1 else { throw CodecError.invalidFrame }

        // Adopt the sender's mode from the wire header byte, exactly like Python
        // `Codec2.decode` (HEADER_MODES[frame_header] → set_mode(frame_mode)):
        // a receiver decodes whatever mode the sender used, not just its own.
        // An unrecognised header keeps the current mode (Python: `else frame_mode
        // = self.mode`). This MUST run before `ensureState()` so the codec
        // geometry (samples/bytes-per-frame) matches the wire mode — otherwise
        // a different-mode frame is mis-sliced (garbage audio, or an
        // `invalidFrame` throw when its length isn't a multiple of our BPF).
        let frameHeader = data[data.startIndex]
        let frameMode = Codec2Mode.from(headerByte: frameHeader) ?? mode
        if frameMode != mode {
            if let s = state { codec2_destroy(s); state = nil }
            mode = frameMode
        }

        try ensureState()

        // Drop the mode-header byte; the remainder is the codec2 payload.
        let payload = Data(data.dropFirst())
        guard payload.count % bytesPerFrame == 0 else { throw CodecError.invalidFrame }

        var allSamples = [Float]()
        let frames = payload.count / bytesPerFrame

        for f in 0..<frames {
            let chunk = Data(payload[(f * bytesPerFrame) ..< ((f + 1) * bytesPerFrame)])
            var pcm16 = [Int16](repeating: 0, count: samplesPerFrame)
            chunk.withUnsafeBytes { ptr in
                codec2_decode(state!,
                              &pcm16,
                              UnsafePointer(ptr.bindMemory(to: UInt8.self).baseAddress!))
            }
            // Convert Int16 → Float32 normalised to [-1, 1]
            allSamples.append(contentsOf: pcm16.map { Float($0) / 32768.0 })
        }

        let sinkRate = (sink as? LocalSink)?.sampleRate ?? CODEC2_OUTPUT_RATE
        return AudioFrame(samples: allSamples, channelCount: 1, sampleRate: sinkRate)
    }

    // MARK: - Helpers

    /// Resample and convert AudioFrame → mono Int16 at `targetRate` Hz.
    private func toInt16Mono(frame: AudioFrame, targetRate: Double) -> [Int16] {
        // Mix down to mono
        var mono = [Float](repeating: 0, count: frame.sampleCount)
        let ch = frame.channelCount
        for i in 0..<frame.sampleCount {
            var sum: Float = 0
            for c in 0..<ch { sum += frame.samples[i * ch + c] }
            mono[i] = sum / Float(ch)
        }

        // Naive linear resampling if needed
        if frame.sampleRate != targetRate {
            let ratio  = targetRate / frame.sampleRate
            let outLen = Int(Double(mono.count) * ratio)
            var resampled = [Float](repeating: 0, count: outLen)
            for i in 0..<outLen {
                let srcF   = Double(i) / ratio
                let srcIdx = Int(srcF)
                let frac   = Float(srcF - Double(srcIdx))
                let a      = srcIdx < mono.count ? mono[srcIdx] : 0
                let b      = srcIdx + 1 < mono.count ? mono[srcIdx + 1] : a
                resampled[i] = a + frac * (b - a)
            }
            mono = resampled
        }

        // Convert Float32 → Int16
        return mono.map { Int16(max(-32768, min(32767, $0 * 32768.0))) }
    }
}
