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

// MARK: - Sink protocol

/// A destination for audio frames in an LXST pipeline.
/// Python: `LXST.Sinks.Sink`
public protocol Sink: AnyObject {
  var channels: Int? { get }
  var sampleRate: Double { get }

  /// Receive and process an audio frame.
  /// Python: `Sink.handle_frame(frame, source, decoded=False)`
  func handleFrame(_ frame: AudioFrame, from source: (any Source)?)

  /// Whether this sink can accept a frame from `source`.
  /// Python: `Sink.can_receive(from_source=None) -> True`
  func canReceive(from source: (any Source)?) -> Bool

  func start()
  func stop()
  /// Release sink resources and stop.
  /// Python: `Sink.release()` (commit 2730af9)
  func release()
}

// MARK: - Default implementations

extension Sink {
  public func start() {}
  public func stop() {}
  public func release() { stop() }
  public func canReceive(from source: (any Source)?) -> Bool { true }
}

// MARK: - LocalSink base class

/// Base for sinks that deliver audio to local hardware or files.
/// Python: `LXST.Sinks.LocalSink`
open class LocalSink: Sink {
  /// Channel count, or `nil` to follow the source.
  public var channels: Int? = nil
  /// Sample rate this sink consumes, in Hz.
  public var sampleRate: Double = 48000

  /// Creates a local sink.
  public init() {}

  open func handleFrame(_ frame: AudioFrame, from source: (any Source)?) {}
  open func start() {}
  open func stop() {}
}

// MARK: - RemoteSink base class

/// Base for sinks that send audio over the network.
/// Python: `LXST.Sinks.RemoteSink`
open class RemoteSink: Sink {
  /// Channel count, or `nil` to follow the source.
  public var channels: Int? = nil
  /// Sample rate this sink consumes, in Hz.
  public var sampleRate: Double = 48000

  /// Creates a remote sink.
  public init() {}

  open func handleFrame(_ frame: AudioFrame, from source: (any Source)?) {}
  open func start() {}
  open func stop() {}
}
