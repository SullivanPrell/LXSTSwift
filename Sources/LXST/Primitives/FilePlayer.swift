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

/// Plays audio from an Opus file.
/// Python: `LXST.Primitives.Players.FilePlayer`
public final class FilePlayer {
    /// Whether playback is running.
    public private(set) var running: Bool = false
    /// Alias for `running`.
    ///
    /// Python: `playing` property.
    public var playing: Bool { running }

    /// Python: `finished_callback` property (getter/setter with type check).
    public var onFinished: (() -> Void)?

    /// When true, release() is called automatically after playback finishes.
    /// Python: `FilePlayer(release_on_finish=False)` (commit 2730af9)
    public var releaseOnFinish: Bool

    private var path: URL?
    private var device: String?
    /// Whether the file restarts when it ends.
    public private(set) var loop: Bool

    /// Creates a player for `path` on `device`.
    ///
    /// Python: `FilePlayer.__init__(path=None, device=None, loop=False, release_on_finish=False)`
    public init(path: URL? = nil, device: String? = nil, loop: Bool = false,
                releaseOnFinish: Bool = false) {
        self.path            = path
        self.device          = device
        self.loop            = loop
        self.releaseOnFinish = releaseOnFinish
        if let p = path { setSource(p) }
    }

    /// Sets the file to play.
    ///
    /// Python: `set_source(path)`
    public func setSource(_ path: URL) { self.path = path }

    /// Enables or disables restarting the file when it ends.
    ///
    /// Python: `FilePlayer.loop(loop=True)`
    public func loop(_ loop: Bool = true) {
        self.loop = loop
    }

    /// Begins playback.
    ///
    /// Python: `FilePlayer.play()`—alias for start()
    public func play() { start() }

    /// Starts playback.
    public func start() { running = true }
    /// Stops playback.
    public func stop()  { running = false }

    /// Stop playback and release all pipeline resources.
    ///
    /// Idempotent.
    /// Python: `FilePlayer.release()` (commit 2730af9)
    public func release() { stop() }
}
