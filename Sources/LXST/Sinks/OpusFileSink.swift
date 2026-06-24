import Foundation
import COpus

/// Writes audio to an Opus file.
/// Python: `LXST.Sinks.OpusFileSink`
///
/// Wire format on disk (v2):
///   - 8 bytes: magic "LXSTOPUS"
///   - 1 byte:  version (0x02)
///   - 4 bytes: sample rate as UInt32 little-endian
///   - 1 byte:  channel count as UInt8
///   - Repeated: 4-byte LE frame length + Opus encoded bytes
///
/// `OpusFileSource` reads both v1 (assumes 48000 Hz / 1 ch) and v2 headers.
public final class OpusFileSink: LocalSink {
    // MARK: - Python class constants
    /// Python: `OpusFileSink.AUTOSTART_MIN = 1`
    public static let autoStartMin: Int = 1
    /// Python: `OpusFileSink.MAX_FRAMES = 64`
    public static let maxFrames: Int = 64
    /// Python: `OpusFileSink.FINALIZE_TIMEOUT = 2`
    public static let finalizeTimeout: Int = 2

    // MARK: - File magic
    static let magic: [UInt8] = Array("LXSTOPUS".utf8)
    static let fileVersion: UInt8 = 0x02

    // MARK: - Properties

    public var outputPath: URL?
    public var autodigest: Bool     = true
    public var profile:    OpusProfile = .audioMax

    /// Number of frames waiting to be written.
    /// Python: `OpusFileSink.frames_waiting`
    public var framesWaiting: Int {
        lock.withLock { frameQueue.count }
    }

    // Set by Pipeline when wired. Python: `sink.source = source`
    public weak var source: (any Source)?

    // MARK: - Private state

    private let lock = NSLock()
    private var frameQueue: [AudioFrame] = []
    private var digestThread: Thread?
    private var encoder: OpaquePointer?
    private var fileHandle: FileHandle?
    private var isRunning = false
    private var recordingStopped = false
    private var finalized = false

    // MARK: - Init

    /// Python: `OpusFileSink.__init__(path=None, autodigest=True, profile=Opus.PROFILE_AUDIO_MAX)`
    public init(path: URL? = nil,
                autodigest: Bool = true,
                profile: OpusProfile = .audioMax) {
        self.outputPath = path
        self.autodigest = autodigest
        self.profile    = profile
        super.init()
    }

    deinit {
        if let enc = encoder { opus_encoder_destroy(enc); encoder = nil }
    }

    // MARK: - Sink protocol

    public override func handleFrame(_ frame: AudioFrame, from source: (any Source)?) {
        lock.withLock {
            guard !recordingStopped, frameQueue.count < Self.maxFrames else { return }
            frameQueue.append(frame)
        }
        if autodigest {
            var shouldAutoStart = false
            lock.withLock {
                shouldAutoStart = !isRunning && frameQueue.count >= Self.autoStartMin
            }
            if shouldAutoStart { start() }
        }
    }

    public override func start() {
        var alreadyRunning = false
        lock.withLock {
            alreadyRunning = isRunning
            if !isRunning {
                isRunning = true
                recordingStopped = false
                finalized = false
            }
        }
        guard !alreadyRunning else { return }
        let t = Thread { [weak self] in self?.digestJob() }
        t.name = "lxst.opusfilesink"
        t.qualityOfService = .utility
        t.start()
        digestThread = t
    }

    public override func stop() {
        lock.withLock { recordingStopped = true }
        // Wait up to FINALIZE_TIMEOUT seconds for the digest thread to flush
        let deadline = Date().addingTimeInterval(Double(Self.finalizeTimeout))
        while Date() < deadline {
            let done = lock.withLock { finalized }
            if done { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        lock.withLock { isRunning = false }
    }

    // MARK: - Background digest

    private func digestJob() {
        guard let path = outputPath else {
            lock.withLock { finalized = true }
            return
        }
        guard setupEncoder() else {
            lock.withLock { finalized = true }
            return
        }
        createFile(at: path)

        while true {
            let (frames, stop) = lock.withLock { () -> ([AudioFrame], Bool) in
                let copy = frameQueue
                frameQueue.removeAll()
                return (copy, recordingStopped)
            }
            for frame in frames { encodeAndWrite(frame) }
            if stop && frames.isEmpty { break }
            if frames.isEmpty { Thread.sleep(forTimeInterval: 0.01) }
        }

        finalizeFile()
        lock.withLock { finalized = true }
    }

    // MARK: - Encoder lifecycle

    private func setupEncoder() -> Bool {
        let ch = Int32(profile.channels)
        let fs = Int32(profile.sampleRate)
        var err: Int32 = 0
        guard let enc = opus_encoder_create(fs, ch, profile.cApplication, &err),
              err == OPUS_OK else { return false }
        encoder = enc
        return true
    }

    // MARK: - File I/O

    private func createFile(at url: URL) {
        // v2 header: magic (8) + version (1) + sample rate UInt32 LE (4) + channels UInt8 (1) = 14 bytes
        let sr = UInt32(profile.sampleRate)
        let ch = UInt8(profile.channels)
        var srBytes = sr.littleEndian
        let srData = Data(bytes: &srBytes, count: 4)
        let header = Data(Self.magic) + Data([Self.fileVersion]) + srData + Data([ch])
        FileManager.default.createFile(atPath: url.path, contents: header)
        fileHandle = try? FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()
    }

    private func encodeAndWrite(_ frame: AudioFrame) {
        guard let enc = encoder, let fh = fileHandle else { return }

        let targetCh   = profile.channels
        let targetRate = profile.sampleRate
        let pcm        = resample(frame: frame, toRate: targetRate, toChannels: targetCh)
        let n          = pcm.count / targetCh   // samples per channel

        let maxBytes = max(profile.maxBytesPerFrame(frameDurationMs: 20) * 4, 4096)
        var outBuf = [UInt8](repeating: 0, count: maxBytes)

        let encoded = pcm.withUnsafeBufferPointer { ptr in
            opus_encode_float(enc, ptr.baseAddress!, Int32(n), &outBuf, Int32(maxBytes))
        }
        guard encoded > 0 else { return }

        var len = UInt32(encoded).littleEndian
        let lenData = Data(bytes: &len, count: 4)
        let frameData = Data(outBuf.prefix(Int(encoded)))
        fh.write(lenData + frameData)
    }

    private func finalizeFile() {
        fileHandle?.closeFile()
        fileHandle = nil
        if let enc = encoder { opus_encoder_destroy(enc); encoder = nil }
    }

    // MARK: - Resampling helper (same as OpusCodec)

    private func resample(frame: AudioFrame, toRate targetRate: Double, toChannels targetCh: Int) -> [Float] {
        let srcCh   = frame.channelCount
        let srcN    = frame.sampleCount
        let srcRate = frame.sampleRate

        // Channel conversion
        var channelConverted: [Float]
        if srcCh == targetCh {
            channelConverted = frame.samples
        } else if targetCh == 1 {
            channelConverted = (0..<srcN).map { i in
                (0..<srcCh).reduce(Float(0)) { $0 + frame.samples[i * srcCh + $1] } / Float(srcCh)
            }
        } else {
            let mono: [Float] = srcCh > 1
                ? (0..<srcN).map { i in
                    (0..<srcCh).reduce(Float(0)) { $0 + frame.samples[i * srcCh + $1] } / Float(srcCh)
                  }
                : frame.samples
            channelConverted = (0..<srcN).flatMap { i in (0..<targetCh).map { _ in mono[i] } }
        }

        guard srcRate != targetRate else { return channelConverted }

        let ratio  = targetRate / srcRate
        let outN   = Int(Double(srcN) * ratio)
        return (0..<outN * targetCh).map { idx in
            let i      = idx / targetCh
            let c      = idx % targetCh
            let srcF   = Double(i) / ratio
            let srcIdx = Int(srcF)
            let frac   = Float(srcF - Double(srcIdx))
            let a      = srcIdx < srcN ? channelConverted[srcIdx * targetCh + c] : 0
            let b      = (srcIdx + 1) < srcN ? channelConverted[(srcIdx + 1) * targetCh + c] : a
            return a + frac * (b - a)
        }
    }
}

// MARK: - NSLock convenience

extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
