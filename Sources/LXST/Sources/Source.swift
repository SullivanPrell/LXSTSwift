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

// MARK: - Source protocol

/// A source of audio frames in an LXST pipeline.
/// Python: `LXST.Sources.Source`
public protocol Source: AnyObject {
  var codec: (any Codec)? { get set }
  var sink: (any Sink)? { get set }
  var pipeline: Pipeline? { get set }
  var sampleRate: Double { get }
  var channelCount: Int { get }
  var bitDepth: Int { get }  // Python: bitdepth (bits)
  var shouldRun: Bool { get }
  var targetFrameMs: Double { get }  // Python: target_frame_ms

  func start()
  func stop()
  /// Release all pipeline references and stop the source.
  /// Python: `Source.release()` (commit 2730af9)
  func release()
}

// The members below are default implementations of documented protocol requirements.
// swift-format-ignore: AllPublicDeclarationsHaveDocumentation
extension Source {
  public func release() {
    stop()
    codec = nil
    sink = nil
  }
}

// MARK: - LocalSource base class

/// Base for sources that produce audio from local hardware or files.
/// Python: `LXST.Sources.LocalSource`
open class LocalSource: Source {
  /// Codec frames are encoded with.
  public var codec: (any Codec)? = nil
  /// Sink frames are handed to.
  public var sink: (any Sink)? = nil
  /// Pipeline this stage belongs to.
  public weak var pipeline: Pipeline? = nil
  /// Sample rate this source produces, in Hz.
  public var sampleRate: Double = 48000
  /// Channel count produced.
  public var channelCount: Int = 1
  /// Sample depth in bits.
  public var bitDepth: Int = 32
  /// Target frame duration, in milliseconds.
  public var targetFrameMs: Double = 80

  // `shouldRun` is the run flag: written by start()/stop() from control
  // threads—including stop() on the Reticulum callback thread during hangup—while
  // background job threads read it every iteration (for example,
  // `OpusFileSource.ingestJob`) and `Pipeline.running` reads it from the app
  // thread. Guard it with a lock so the read/write can't race
  // (ThreadSanitizer-clean). Same pattern as `Mixer`.
  private let runLock = NSLock()
  private var unsafeShouldRun = false
  /// Whether the source is running.
  public var shouldRun: Bool {
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

  /// Creates a local source.
  public init() {}

  open func start() { shouldRun = true }
  open func stop() { shouldRun = false }

  private var released = false
  open func release() {
    guard !released else { return }
    released = true
    stop()
    codec = nil
    sink = nil
  }
}

// MARK: - RemoteSource base class

/// Base for sources that receive audio from the network.
/// Python: `LXST.Sources.RemoteSource`
open class RemoteSource: Source {
  /// Codec frames are encoded with.
  public var codec: (any Codec)? = nil
  /// Sink frames are handed to.
  public var sink: (any Sink)? = nil
  /// Pipeline this stage belongs to.
  public weak var pipeline: Pipeline? = nil
  /// Sample rate this source produces, in Hz.
  public var sampleRate: Double = 48000
  /// Channel count produced.
  public var channelCount: Int = 1
  /// Sample depth in bits.
  public var bitDepth: Int = 32
  /// Target frame duration, in milliseconds.
  public var targetFrameMs: Double = 40

  // See `LocalSource.shouldRun`—the run flag is read from control threads
  // (`Pipeline.running`) while start()/stop() write it (stop() runs on the
  // Reticulum callback thread during hangup). Guard it with a lock.
  private let runLock = NSLock()
  private var unsafeShouldRun = false
  /// Whether the source is running.
  public var shouldRun: Bool {
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

  /// Creates a remote source.
  public init() {}

  open func start() { shouldRun = true }
  open func stop() { shouldRun = false }

  private var released = false
  open func release() {
    guard !released else { return }
    released = true
    stop()
    codec = nil
    sink = nil
  }
}
