import Foundation

// MARK: - Source protocol

/// A source of audio frames in an LXST pipeline.
/// Python: `LXST.Sources.Source`
public protocol Source: AnyObject {
    var codec:          (any Codec)?  { get set }
    var sink:           (any Sink)?   { get set }
    var pipeline:       Pipeline?     { get set }
    var sampleRate:     Double        { get }
    var channelCount:   Int           { get }
    var bitDepth:       Int           { get }      // Python: bitdepth (bits)
    var shouldRun:      Bool          { get }
    var targetFrameMs:  Double        { get }      // Python: target_frame_ms

    func start()
    func stop()
    /// Release all pipeline references and stop the source.
    /// Python: `Source.release()` (commit 2730af9)
    func release()
}

public extension Source {
    func release() { stop(); codec = nil; sink = nil }
}

// MARK: - LocalSource base class

/// Base for sources that produce audio from local hardware or files.
/// Python: `LXST.Sources.LocalSource`
open class LocalSource: Source {
    public var codec:          (any Codec)?  = nil
    public var sink:           (any Sink)?   = nil
    public weak var pipeline:  Pipeline?     = nil
    public var sampleRate:     Double        = 48000
    public var channelCount:   Int           = 1
    public var bitDepth:       Int           = 32
    public var targetFrameMs:  Double        = 80

    // `shouldRun` is the run flag: written by start()/stop() from control
    // threads — including stop() on the Reticulum callback thread during hangup —
    // while background job threads read it every iteration (e.g.
    // `OpusFileSource.ingestJob`) and `Pipeline.running` reads it from the app
    // thread. Guard it with a lock so the read/write can't race
    // (ThreadSanitizer-clean). Same pattern as `Mixer`.
    private let runLock = NSLock()
    private var _shouldRun = false
    public var shouldRun: Bool {
        get { runLock.lock(); defer { runLock.unlock() }; return _shouldRun }
        set { runLock.lock(); _shouldRun = newValue; runLock.unlock() }
    }

    public init() {}

    open func start() { shouldRun = true }
    open func stop()  { shouldRun = false }

    private var released = false
    open func release() {
        guard !released else { return }
        released = true
        stop()
        codec = nil
        sink  = nil
    }
}

// MARK: - RemoteSource base class

/// Base for sources that receive audio from the network.
/// Python: `LXST.Sources.RemoteSource`
open class RemoteSource: Source {
    public var codec:          (any Codec)?  = nil
    public var sink:           (any Sink)?   = nil
    public weak var pipeline:  Pipeline?     = nil
    public var sampleRate:     Double        = 48000
    public var channelCount:   Int           = 1
    public var bitDepth:       Int           = 32
    public var targetFrameMs:  Double        = 40

    // See `LocalSource.shouldRun` — the run flag is read from control threads
    // (`Pipeline.running`) while start()/stop() write it (stop() runs on the
    // Reticulum callback thread during hangup). Guard it with a lock.
    private let runLock = NSLock()
    private var _shouldRun = false
    public var shouldRun: Bool {
        get { runLock.lock(); defer { runLock.unlock() }; return _shouldRun }
        set { runLock.lock(); _shouldRun = newValue; runLock.unlock() }
    }

    public init() {}

    open func start() { shouldRun = true }
    open func stop()  { shouldRun = false }

    private var released = false
    open func release() {
        guard !released else { return }
        released = true
        stop()
        codec = nil
        sink  = nil
    }
}
