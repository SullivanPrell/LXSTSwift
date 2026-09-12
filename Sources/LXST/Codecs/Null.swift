//===----------------------------------------------------------------------===//
// Copyright (c) 2026 LXSTSwift contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

import Foundation

/// Pass-through codec — encode and decode are identity operations.
/// Python: `LXST.Codecs.Null` — header byte NULL = 0xFF
public final class NullCodec: Codec {
    /// Codec identifier carried in the frame header.
    public static let headerByte: UInt8 = codecNull

    /// Sample rate this codec prefers to be fed, in Hz.
    public var preferredSampleRate: Double? { nil }
    /// Frame duration this codec encodes, in milliseconds.
    public var frameQuantaMs: Double?       { nil }
    /// Longest frame this codec encodes, in milliseconds.
    public var frameMaxMs: Double?          { nil }
    /// Frame durations this codec accepts, in milliseconds.
    public var validFrameMs: [Double]       { [] }
    /// Channel count, or `nil` to follow the source.
    public var channels: Int? = nil
    /// Source feeding this codec.
    public weak var source: (any Source)? = nil
    /// Sink frames are handed to.
    public var sink:   (any Sink)?   = nil

    /// Creates a pass-through codec.
    public init() {}

    /// Passes the frame through without encoding it.
    ///
    /// Python: `Null.encode(frame) -> frame`
    public func encode(_ frame: AudioFrame) throws -> Data {
        // Serialise as raw Float32 (little-endian) for round-trip symmetry
        var data = Data(capacity: frame.samples.count * 4)
        for s in frame.samples {
            var v = s; data.append(Data(bytes: &v, count: 4))
        }
        return data
    }

    /// Passes the data through without decoding it.
    ///
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
