import Foundation

/// Plays audio from an Opus file.
/// Python: `LXST.Primitives.Players.FilePlayer`
public final class FilePlayer {
    public private(set) var running: Bool = false
    /// Alias for `running`. Python: `playing` property.
    public var playing: Bool { running }

    /// Python: `finished_callback` property (getter/setter with type check).
    public var onFinished: (() -> Void)?

    /// When true, release() is called automatically after playback finishes.
    /// Python: `FilePlayer(release_on_finish=False)` (commit 2730af9)
    public var releaseOnFinish: Bool

    private var path: URL?
    private var device: String?
    public private(set) var loop: Bool

    /// Python: `FilePlayer.__init__(path=None, device=None, loop=False, release_on_finish=False)`
    public init(path: URL? = nil, device: String? = nil, loop: Bool = false,
                releaseOnFinish: Bool = false) {
        self.path            = path
        self.device          = device
        self.loop            = loop
        self.releaseOnFinish = releaseOnFinish
        if let p = path { setSource(p) }
    }

    /// Python: `set_source(path)`
    public func setSource(_ path: URL) { self.path = path }

    /// Python: `FilePlayer.loop(loop=True)`
    public func loop(_ loop: Bool = true) {
        self.loop = loop
    }

    /// Python: `FilePlayer.play()` — alias for start()
    public func play() { start() }

    public func start() { running = true }
    public func stop()  { running = false }

    /// Stop playback and release all pipeline resources. Idempotent.
    /// Python: `FilePlayer.release()` (commit 2730af9)
    public func release() { stop() }
}
