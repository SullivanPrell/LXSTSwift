import Foundation

/// Pass-through codec — encode and decode are identity operations.
/// Python: `LXST.Codecs.Null` — header byte NULL = 0xFF
public final class NullCodec: Codec {
    public static let headerByte: UInt8 = CODEC_NULL

    public var preferredSampleRate: Double? { nil }
    public var frameQuantaMs: Double?       { nil }
    public var frameMaxMs: Double?          { nil }
    public var validFrameMs: [Double]       { [] }
    public var channels: Int? = nil
    public weak var source: (any Source)? = nil
    public var sink:   (any Sink)?   = nil

    public init() {}

    /// Python: `Null.encode(frame) -> frame`
    public func encode(_ frame: AudioFrame) throws -> Data {
        // Serialise as raw Float32 (little-endian) for round-trip symmetry
        var data = Data(capacity: frame.samples.count * 4)
        for s in frame.samples {
            var v = s; data.append(Data(bytes: &v, count: 4))
        }
        return data
    }

    /// Python: `Null.decode(frame) -> frame`
    public func decode(_ data: Data) throws -> AudioFrame {
        guard data.count % 4 == 0 else { throw CodecError.invalidFrame }
        let ch = channels ?? 1
        let count = data.count / 4
        var samples = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { ptr in
            let floats = ptr.bindMemory(to: Float.self)
            for i in 0..<count { samples[i] = floats[i] }
        }
        let sr = (sink as? LocalSink).map { $0.sampleRate } ?? 48000
        return AudioFrame(samples: samples, channelCount: ch, sampleRate: sr)
    }
}
