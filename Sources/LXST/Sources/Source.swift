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
    public var shouldRun:      Bool          = false
    public var targetFrameMs:  Double        = 80

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
    public var shouldRun:      Bool          = false
    public var targetFrameMs:  Double        = 40

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
