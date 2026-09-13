//===----------------------------------------------------------------------===//
// Copyright (c) 2026 LXSTSwift contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

import COpus
import Foundation

/// Plays audio from an LXSTOPUS file written by `OpusFileSink`.
/// Python: `LXST.Sources.OpusFileSource`
/// Default frame_ms: 100 (Python: `DEFAULT_FRAME_MS = 100`)
public final class OpusFileSource: LocalSource {
  /// Default frame duration, in milliseconds.
  public static let defaultFrameMs: Double = 100
  /// Maximum frames buffered before delivery.
  ///
  /// Python: `OpusFileSource.MAX_FRAMES = 128`
  public static let maxFrames: Int = 128

  /// File audio is read from.
  public let filePath: URL
  /// Whether the file restarts when it ends.
  public let loop: Bool
  /// Whether frames are emitted in real time.
  public let timed: Bool

  /// Gain applied to decoded audio, in decibels.
  ///
  /// Settable mid-playback, so both it and the multiplier derived from it are
  /// read on the ingest thread under `gainLock`.
  /// Python: `OpusFileSource.gain` (`Sources.py:326-332`).
  public var gain: Float {
    get {
      gainLock.lock()
      defer { gainLock.unlock() }
      return unsafeGain
    }
    set {
      gainLock.lock()
      unsafeGain = newValue
      unsafeLinearGain = Self.linearGain(newValue)
      gainLock.unlock()
    }
  }
  private let gainLock = NSLock()
  private var unsafeGain: Float
  private var unsafeLinearGain: Float

  /// Converts a decibel gain to the linear multiplier applied to samples.
  ///
  /// Python: `@staticmethod linear_gain(gain_db): return 10**(gain_db/10)`
  /// (`Sources.py:291-292`—the power-dB seam, see DBGain).
  public static func linearGain(_ gainDB: Float) -> Float {
    DBGain.linear(gainDB)
  }

  private var ingestThread: Thread?

  /// Creates a source reading Opus from `filePath`.
  ///
  /// Python: `OpusFileSource.__init__(file_path, target_frame_ms, loop, codec, sink, timed, gain)`
  public init(
    filePath: URL,
    targetFrameMs: Double = OpusFileSource.defaultFrameMs,
    loop: Bool = false,
    codec: (any Codec)? = nil,
    sink: (any Sink)? = nil,
    timed: Bool = false,
    gain: Float = 0.0
  ) {
    self.filePath = filePath
    self.loop = loop
    self.timed = timed
    self.unsafeGain = gain
    self.unsafeLinearGain = Self.linearGain(gain)
    super.init()
    self.targetFrameMs = targetFrameMs
    self.codec = codec
    self.sink = sink
  }

  /// Whether the source is running.
  ///
  /// Python: `@property running`—alias for shouldRun
  public var running: Bool { shouldRun }

  public override func start() {
    guard !shouldRun else { return }
    super.start()
    let t = Thread { [weak self] in self?.ingestJob() }
    t.name = "lxst.opusfilesource"
    t.qualityOfService = .utility
    t.start()
    ingestThread = t
  }

  public override func stop() {
    super.stop()
    ingestThread = nil
  }

  // MARK: - File reading

  private struct FileContents {
    let sampleRate: Double
    let channels: Int
    let frames: [Data]
  }

  private func readFile() -> FileContents? {
    guard let data = try? Data(contentsOf: filePath) else { return nil }
    let magic = Array("LXSTOPUS".utf8)
    guard data.count >= 9, Array(data.prefix(8)) == magic else { return nil }

    let version = data[8]
    let headerSize: Int
    let sampleRate: Double
    let channels: Int

    if version == 0x02 {
      guard data.count >= 14 else { return nil }
      let sr =
        UInt32(data[9]) | UInt32(data[10]) << 8
        | UInt32(data[11]) << 16 | UInt32(data[12]) << 24
      sampleRate = Double(sr)
      channels = Int(data[13])
      headerSize = 14
    } else {
      // v1—no audio params stored; assume 48kHz mono
      sampleRate = 48000
      channels = 1
      headerSize = 9
    }

    var offset = headerSize
    var frames: [Data] = []
    while offset + 4 <= data.count {
      let len =
        Int(data[offset])
        | Int(data[offset + 1]) << 8
        | Int(data[offset + 2]) << 16
        | Int(data[offset + 3]) << 24
      offset += 4
      guard len > 0, offset + len <= data.count else { break }
      frames.append(data.subdata(in: offset..<(offset + len)))
      offset += len
    }

    return FileContents(sampleRate: sampleRate, channels: channels, frames: frames)
  }

  // MARK: - Ingest job

  private func ingestJob() {
    guard let file = readFile(), !file.frames.isEmpty else {
      shouldRun = false
      return
    }

    var err: Int32 = 0
    let sr = Int32(file.sampleRate)
    let ch = Int32(file.channels)
    guard let dec = opus_decoder_create(sr, ch, &err), err == OPUS_OK else {
      shouldRun = false
      return
    }
    defer { opus_decoder_destroy(dec) }

    // Max samples per channel for a 60 ms Opus frame
    let maxSamplesPerCh = Int(file.sampleRate * 0.060) + 64
    let frameTime = targetFrameMs / 1000.0

    var fi = 0
    while shouldRun {
      if fi >= file.frames.count {
        guard loop else {
          break
        }
        fi = 0
      }

      let encoded = file.frames[fi]
      fi += 1

      var decoded = [Float](repeating: 0, count: maxSamplesPerCh * Int(ch))
      let n = encoded.withUnsafeBytes { ptr -> Int32 in
        guard let base = ptr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
        return opus_decode_float(
          dec, base, Int32(encoded.count),
          &decoded, Int32(maxSamplesPerCh), 0)
      }
      guard n > 0 else { continue }

      var samples = Array(decoded.prefix(Int(n) * Int(ch)))
      // Python: `if self.__gain != 1.0: frame_samples *= self.__gain` (`Sources.py:384`).
      gainLock.lock()
      let g = unsafeLinearGain
      gainLock.unlock()
      if g != 1.0 { samples = samples.map { $0 * g } }
      let frame = AudioFrame(
        samples: samples,
        channelCount: Int(ch),
        sampleRate: file.sampleRate
      )
      sink?.handleFrame(frame, from: self)

      if timed {
        Thread.sleep(forTimeInterval: frameTime)
      }
    }

    shouldRun = false
  }
}
