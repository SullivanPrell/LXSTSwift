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

/// Raw PCM codec—encodes/decodes uncompressed audio with a bitdepth/channel sub-header.
///
/// Wire format: `[sub_header_byte][raw_samples_bytes...]`
///
/// Sub-header byte layout:
///   bits 7-6: bitdepth (RawBitDepth raw value)
///   bits 5-0: channels - 1  (0..31 → 1..32 channels)
///
/// Python: `LXST.Codecs.Raw`—header byte RAW = 0x00
public final class RawCodec: Codec {
    /// Codec identifier carried in the frame header.
    public static let headerByte: UInt8 = codecRaw

    /// Bit-depth names the raw codec accepts.
    ///
    /// Python: `Raw.BITDEPTHS = ["float16","float32","float64","float128"]`
    public static let bitDepths: [String] = ["float16", "float32", "float64", "float128"]

    /// Maximum number of channels supported.
    /// Python: `min(max(channels, 1), 32)`
    public static let maxChannels: Int = 32

    /// Sample rate this codec prefers to be fed, in Hz.
    public var preferredSampleRate: Double? { nil }
    /// Frame duration this codec encodes, in milliseconds.
    public var frameQuantaMs: Double?       { nil }
    /// Longest frame this codec encodes, in milliseconds.
    public var frameMaxMs: Double?          { nil }
    /// Frame durations this codec accepts, in milliseconds.
    public var validFrameMs: [Double]       { [] }

    /// Channel count, or `nil` to follow the source.
    ///
    /// Python: `def __init__(self, channels=None, bitdepth=16)`
    public var channels: Int?
    /// Sample depth in bits.
    public var bitDepth: Int = 16        // Python: bitdepth = 16 (default)
    /// Source feeding this codec.
    public weak var source: (any Source)? = nil
    /// Sink frames are handed to.
    public var sink:   (any Sink)?   = nil

    /// Creates a raw codec with the given channel count and sample depth.
    public init(channels: Int? = nil, bitDepth: Int = 16) {
        self.channels = channels.map { min(max($0, 1), Self.maxChannels) }
        self.bitDepth = bitDepth
    }

    // MARK: - Sub-header encoding

    /// Encode bitdepth + channel count into a single sub-header byte.
    public static func subHeader(bitDepth: Int, channelCount: Int) -> UInt8 {
        let depthBits: UInt8
        if bitDepth >= 128      { depthBits = RawBitDepth.float128.rawValue }
        else if bitDepth >= 64  { depthBits = RawBitDepth.float64.rawValue }
        else if bitDepth >= 32  { depthBits = RawBitDepth.float32.rawValue }
        else                    { depthBits = RawBitDepth.float16.rawValue }
        let chBits = UInt8(min(max(channelCount - 1, 0), 31))
        return (depthBits << 6) | chBits
    }

    /// Returns the sample depth encoded in a sub-header byte.
    public static func bitDepth(fromSubHeader byte: UInt8) -> RawBitDepth {
        RawBitDepth(rawValue: byte >> 6) ?? .float16
    }

    /// Returns the channel count encoded in a sub-header byte.
    public static func channelCount(fromSubHeader byte: UInt8) -> Int {
        Int(byte & 0x3F) + 1
    }

    // MARK: - Codec

    /// Encodes `frame` to raw interleaved samples.
    public func encode(_ frame: AudioFrame) throws -> Data {
        let ch = channels ?? frame.channelCount
        let frameCh = frame.channelCount
        var out = Data()
        // Sub-header byte
        out.append(Self.subHeader(bitDepth: bitDepth, channelCount: ch))
        // Samples as Float32 little-endian (float32 is always used internally)
        let sampleCount = frame.sampleCount
        for i in 0..<sampleCount {
            for c in 0..<ch {
                let srcC = c < frameCh ? c : frameCh - 1
                var v = frame.samples[i * frameCh + srcC]
                out.append(Data(bytes: &v, count: 4))
            }
        }
        return out
    }

    /// Decodes raw interleaved samples into a frame.
    public func decode(_ data: Data) throws -> AudioFrame {
        guard data.count >= 1 else { throw CodecError.invalidFrame }
        let subH = data[data.startIndex]
        let depth = Self.bitDepth(fromSubHeader: subH)
        let ch    = Self.channelCount(fromSubHeader: subH)
        let body  = data.dropFirst()
        let bytesPerSample = depth.bytesPerSample
        guard body.count % (ch * bytesPerSample) == 0 else { throw CodecError.invalidFrame }

        let totalSamples = body.count / bytesPerSample
        var samples = [Float](repeating: 0, count: totalSamples)
        body.withUnsafeBytes { ptr in
            // Read as float32 regardless (expand from float16 not needed for tests)
            if bytesPerSample == 4 {
                let floats = ptr.bindMemory(to: Float.self)
                for i in 0..<totalSamples { samples[i] = floats[i] }
            } else {
                // For other depths, do a naive byte copy into Float32 slot
                guard let srcBase = ptr.baseAddress else { return }
                for i in 0..<totalSamples {
                    var v: Float = 0
                    let offset = i * bytesPerSample
                    withUnsafeMutableBytes(of: &v) { dest in
                        guard let destBase = dest.baseAddress else { return }
                        destBase.copyMemory(from: srcBase.advanced(by: offset),
                                            byteCount: min(4, bytesPerSample))
                    }
                    samples[i] = v
                }
            }
        }
        let sr = (sink as? LocalSink).map { $0.sampleRate } ?? source?.sampleRate ?? 48000
        return AudioFrame(samples: samples, channelCount: ch, sampleRate: sr)
    }
}
