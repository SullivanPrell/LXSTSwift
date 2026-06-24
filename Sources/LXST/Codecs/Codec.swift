import Foundation

// MARK: - Codec protocol

/// Base protocol for all LXST audio codecs.
///
/// Python: `LXST.Codecs.Codec`
public protocol Codec: AnyObject {
    /// Wire header byte identifying this codec type.
    /// Python: module-level `NULL`, `RAW`, `OPUS`, `CODEC2` constants.
    static var headerByte: UInt8 { get }

    /// Preferred input/output sample rate for this codec.
    /// Python: `preferred_samplerate` class attribute.
    var preferredSampleRate: Double? { get }

    /// Minimum frame granularity in milliseconds.
    /// Python: `frame_quanta_ms`
    var frameQuantaMs: Double? { get }

    /// Maximum valid frame duration in milliseconds.
    /// Python: `frame_max_ms`
    var frameMaxMs: Double? { get }

    /// List of valid frame durations in milliseconds.
    /// Python: `valid_frame_ms`
    var validFrameMs: [Double] { get }

    /// Number of audio channels this codec outputs/expects.
    var channels: Int? { get set }

    /// Upstream source connected to this codec.
    var source: (any Source)? { get set }

    /// Downstream sink this codec feeds.
    var sink: (any Sink)? { get set }

    /// Encode an `AudioFrame` to wire bytes (no header byte prepended).
    /// Python: `Codec.encode(frame) -> bytes`
    func encode(_ frame: AudioFrame) throws -> Data

    /// Decode wire bytes (no header byte) to an `AudioFrame`.
    /// Python: `Codec.decode(frame) -> numpy.array`
    func decode(_ data: Data) throws -> AudioFrame
}

// MARK: - Codec errors

public enum CodecError: Error, Equatable {
    /// Profile or mode value is not supported.
    case unsupportedProfile
    /// Encoder has not been configured yet.
    case encoderNotConfigured
    /// Decoder has not been configured yet.
    case decoderNotConfigured
    /// Input frame is invalid (wrong size, 0 channels, etc.).
    case invalidFrame
    /// Codec is not yet fully implemented (placeholder for Codec2 stub).
    case notImplemented
}

// MARK: - Raw bitdepth constants

/// Raw PCM bitdepth identifier byte, packed into the Raw sub-header.
/// Python: `Raw.BITDEPTH_16 = 0x00`, `BITDEPTH_32 = 0x01`, etc.
public enum RawBitDepth: UInt8, CaseIterable {
    case float16  = 0x00   // Python: BITDEPTH_16
    case float32  = 0x01   // Python: BITDEPTH_32
    case float64  = 0x02   // Python: BITDEPTH_64
    case float128 = 0x03   // Python: BITDEPTH_128

    /// Number of bytes per sample for this depth.
    public var bytesPerSample: Int {
        switch self {
        case .float16:  return 2
        case .float32:  return 4
        case .float64:  return 8
        case .float128: return 16
        }
    }
}
