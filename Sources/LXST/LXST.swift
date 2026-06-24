import Foundation
@_exported import ReticulumSwift

// MARK: - Module constants

/// Application name for LXST destinations.
/// Python: `LXST.APP_NAME = "lxst"`
public let APP_NAME = "lxst"

// MARK: - Wire-format field keys

/// Msgpack dict key for in-band signalling data.
/// Python: `LXST.Network.FIELD_SIGNALLING = 0x00`
public let FIELD_SIGNALLING: UInt8 = 0x00

/// Msgpack dict key for encoded audio frame bytes.
/// Python: `LXST.Network.FIELD_FRAMES = 0x01`
public let FIELD_FRAMES: UInt8 = 0x01

// MARK: - Codec type header bytes

/// Codec header byte for the Null (pass-through) codec.
/// Python: `LXST.Codecs.NULL = 0xFF`
public let CODEC_NULL:   UInt8 = 0xFF

/// Codec header byte for the Raw PCM codec.
/// Python: `LXST.Codecs.RAW = 0x00`
public let CODEC_RAW:    UInt8 = 0x00

/// Codec header byte for the Opus codec.
/// Python: `LXST.Codecs.OPUS = 0x01`
public let CODEC_OPUS:   UInt8 = 0x01

/// Codec header byte for the Codec2 codec.
/// Python: `LXST.Codecs.CODEC2 = 0x02`
public let CODEC_CODEC2: UInt8 = 0x02

// MARK: - Platform audio backend factory

/// Returns the appropriate platform audio backend.
/// Python: `LXST.Sources.get_backend()` / `LXST.Sinks.get_backend()`
/// On Apple platforms returns `AVAudioEngineBackend`; elsewhere returns nil.
public func getBackend() -> (any AudioBackend)? {
#if canImport(AVFAudio)
    return AVAudioEngineBackend()
#else
    return nil
#endif
}

// MARK: - Codec type dispatch

/// Returns the wire header byte for a codec type.
/// Python: `LXST.Codecs.codec_header_byte(codec_type)`
public func codecHeaderByte(for codecType: any Codec.Type) -> UInt8 {
    return codecType.headerByte
}

/// Returns the codec type for a given header byte, or nil if unknown.
/// Python: `LXST.Codecs.codec_type(header_byte)`
public func codecType(for headerByte: UInt8) -> (any Codec.Type)? {
    switch headerByte {
    case CODEC_NULL:   return NullCodec.self
    case CODEC_RAW:    return RawCodec.self
    case CODEC_OPUS:   return OpusCodec.self
    case CODEC_CODEC2: return Codec2Codec.self
    default:           return nil
    }
}
