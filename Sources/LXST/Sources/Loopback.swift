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

/// A combined Source+Sink that routes frames back through itself.
///
/// Useful for testing pipelines and as a pass-through stage.
///
/// Python: `LXST.Sources.Loopback`
/// Default target_frame_ms: 70 (Python: `def __init__(self, target_frame_ms=70, ...)`)
public final class Loopback: Source, Sink {
    /// Maximum frames buffered before delivery.
    ///
    /// Python: `Loopback.MAX_FRAMES = 128`
    public static let maxFrames: Int = 128

    // MARK: - Source protocol
    /// Codec frames are encoded with.
    public var codec:          (any Codec)?  = nil
    /// Sink frames are handed to.
    public var sink:           (any Sink)?   = nil
    /// Pipeline this stage belongs to.
    public weak var pipeline:  Pipeline?     = nil
    /// Sample rate this source produces, in Hz.
    public private(set) var sampleRate:    Double = 48000
    /// Channel count produced.
    public private(set) var channelCount:  Int    = 1
    /// Sample depth in bits.
    public private(set) var bitDepth:      Int    = 32
    /// Whether the loopback is running.
    public private(set) var shouldRun:     Bool   = false
    /// Target frame duration, in milliseconds.
    public private(set) var targetFrameMs: Double

    // MARK: - Sink protocol
    /// Channel count, or `nil` to follow the source.
    public var channels: Int? = nil

    // Internal downstream sink (set by Pipeline when wired as a sink)
    internal var downstreamSink: (any Sink)?

    /// Creates a loopback producing frames of `targetFrameMs`.
    ///
    /// Python: `def __init__(self, target_frame_ms=70, codec=None, sink=None)`
    public init(targetFrameMs: Double = 70,
                codec: (any Codec)? = nil,
                sink: (any Sink)? = nil) {
        self.targetFrameMs = targetFrameMs
        self.codec  = codec
        self.downstreamSink  = sink
    }

    // MARK: - Source lifecycle

    /// Starts the loopback.
    public func start() { shouldRun = true }
    /// Stops the loopback.
    public func stop()  { shouldRun = false }
    /// Stops the loopback and drops its codec and sinks.
    public func release() { stop(); codec = nil; sink = nil; downstreamSink = nil }

    // MARK: - Sink protocol

    /// Returns whether the downstream sink can take frames from `source`.
    ///
    /// Python: `Loopback.can_receive(from_source=None)` — delegates to downstream sink
    public func canReceive(from source: (any Source)?) -> Bool {
        downstreamSink?.canReceive(from: source) ?? true
    }

    /// Passes `frame` straight to the downstream sink.
    public func handleFrame(_ frame: AudioFrame, from source: (any Source)?) {
        downstreamSink?.handleFrame(frame, from: self)
    }
}

// Internal setter for sampleRate — used by Pipeline wiring.
// Python: `if isinstance(sink, Loopback): sink.samplerate = source.samplerate`
extension Loopback {
    internal func setSampleRate(_ rate: Double) { sampleRate = rate }
}
