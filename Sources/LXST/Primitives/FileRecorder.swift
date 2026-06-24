import Foundation

/// Records audio to an Opus file.
/// Python: `LXST.Primitives.Recorders.FileRecorder`
public final class FileRecorder {
    public private(set) var running: Bool = false
    /// Alias for `running`. Python: `recording` property.
    public var recording: Bool { running }

    private var path: URL?
    private var device: String?
    private var profile: OpusProfile
    private var gain: Float
    private var easeIn: Double
    private var skip: Double
    private var filters: [any Filter]

    /// Python: `FileRecorder.__init__(path, device, profile, gain, ease_in, skip, filters)`
    public init(path:    URL?            = nil,
                device:  String?         = nil,
                profile: OpusProfile     = .audioMax,
                gain:    Float           = 0.0,
                easeIn:  Double          = 0.125,
                skip:    Double          = 0.075,
                filters: [any Filter]    = [BandPass(lowCut: 25, highCut: 24000)]) {
        self.path    = path
        self.device  = device
        self.profile = profile
        self.gain    = gain
        self.easeIn  = easeIn
        self.skip    = skip
        self.filters = filters
    }

    /// Python: `set_source(device=None)`
    public func setSource(_ device: String?) { self.device = device }

    /// Python: `set_output_path(path)`
    public func setOutputPath(_ path: URL) { self.path = path }

    /// Python: `FileRecorder.record()` — alias for start()
    public func record() { start() }

    public func start() { running = true }
    public func stop()  { running = false }
}
