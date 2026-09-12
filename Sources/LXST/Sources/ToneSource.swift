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

/// Sine-wave tone generator source.
///
/// Python: `LXST.Generators.ToneSource`
public final class ToneSource: Source {
  // MARK: - Python class constants
  /// Default frame duration, in milliseconds.
  ///
  /// Python: `ToneSource.DEFAULT_FRAME_MS = 80`
  public static let defaultFrameMs: Double = 80
  /// Default sample rate, in Hz.
  ///
  /// Python: `ToneSource.DEFAULT_SAMPLERATE = 48000`
  public static let defaultSampleRate: Double = 48000
  /// Default tone frequency, in Hz.
  ///
  /// Python: `ToneSource.DEFAULT_FREQUENCY = 400`
  public static let defaultFrequency: Double = 400
  /// Fade length applied at start and stop, in milliseconds.
  ///
  /// Python: `ToneSource.EASE_TIME_MS = 20`
  public static let easeTimeMs: Double = 20

  // MARK: - Source protocol
  /// Codec frames are encoded with.
  public var codec: (any Codec)? = nil
  /// Sink frames are handed to.
  public var sink: (any Sink)? = nil
  /// Pipeline this stage belongs to.
  public weak var pipeline: Pipeline? = nil
  /// Sample rate this source produces, in Hz.
  public private(set) var sampleRate: Double
  /// Channel count produced.
  public private(set) var channelCount: Int = 1
  /// Sample depth in bits.
  public private(set) var bitDepth: Int = 32
  /// Target frame duration, in milliseconds.
  public private(set) var targetFrameMs: Double

  // The generate loop reads `shouldRun` every frame on the `lxst.tone` thread
  // while start()/stop() write it from control threads (the Telephone dial tone
  // is stopped from a different thread than the one running the loop). Guard it
  // with a lock so the read/write can't race. Same pattern as `Mixer`.
  private let runLock = NSLock()
  private var unsafeShouldRun = false
  /// Whether the tone is running.
  public private(set) var shouldRun: Bool {
    get {
      runLock.lock()
      defer { runLock.unlock() }
      return unsafeShouldRun
    }
    set {
      runLock.lock()
      unsafeShouldRun = newValue
      runLock.unlock()
    }
  }

  // MARK: - Tone parameters
  /// Tone frequency in Hz.
  public var frequency: Double
  /// Tone gain, in decibels.
  public var gain: Float

  private let ease: Bool
  private let easeMs: Double
  private let channels: Int
  private var theta: Double = 0
  private var easeGain: Float = 0
  private var genThread: Thread?

  /// Creates a tone source at `frequency`.
  ///
  /// Python: `ToneSource.__init__(frequency, gain, ease, ease_time_ms, target_frame_ms, codec, sink, channels)`
  public init(
    frequency: Double = defaultFrequency,
    gain: Float = 0.1,
    ease: Bool = true,
    easeTimeMs: Double = ToneSource.easeTimeMs,
    targetFrameMs: Double = ToneSource.defaultFrameMs,
    codec: (any Codec)? = nil,
    sink: (any Sink)? = nil,
    channels: Int = 1
  ) {
    self.frequency = frequency
    self.gain = gain
    self.ease = ease
    self.easeMs = easeTimeMs
    self.targetFrameMs = targetFrameMs
    self.sampleRate = Self.defaultSampleRate
    self.channelCount = channels
    self.channels = channels
    self.codec = codec
    self.sink = sink
  }

  /// Starts generating the tone.
  public func start() {
    guard !shouldRun else { return }
    shouldRun = true
    let t = Thread { [weak self] in self?.generateLoop() }
    t.name = "lxst.tone"
    t.start()
    genThread = t
  }

  /// Stops generating the tone.
  public func stop() { shouldRun = false }

  // MARK: - Generation loop

  private func generateLoop() {
    let samplesPerFrame = Int(sampleRate * targetFrameMs / 1000)
    let easeSamples = Int(sampleRate * easeMs / 1000)
    var easedCount = 0

    while shouldRun {
      let frameInterval = targetFrameMs / 1000
      var samples = [Float](repeating: 0, count: samplesPerFrame * channels)

      for i in 0..<samplesPerFrame {
        let thetaStep = 2.0 * Double.pi * frequency / sampleRate
        let rawSample = Float(sin(theta)) * gain

        // Ease-in: ramp gain from 0 → 1 over easeMs
        let appliedGain: Float
        if ease && easedCount < easeSamples {
          easeGain = Float(easedCount) / Float(easeSamples)
          appliedGain = rawSample * easeGain
          easedCount += 1
        } else {
          appliedGain = rawSample
        }

        for c in 0..<channels { samples[i * channels + c] = appliedGain }
        theta = fmod(theta + thetaStep, 2.0 * Double.pi)
      }

      let frame = AudioFrame(samples: samples, channelCount: channels, sampleRate: sampleRate)
      if let c = codec, let s = sink {
        if let encoded = try? c.encode(frame),
          let decoded = try? c.decode(encoded)
        {
          s.handleFrame(decoded, from: self)
        }
      } else {
        sink?.handleFrame(frame, from: self)
      }

      Thread.sleep(forTimeInterval: frameInterval)
    }
  }
}
