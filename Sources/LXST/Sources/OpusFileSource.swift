import Foundation
import COpus

/// Plays audio from an LXSTOPUS file written by `OpusFileSink`.
/// Python: `LXST.Sources.OpusFileSource`
/// Default frame_ms: 100 (Python: `DEFAULT_FRAME_MS = 100`)
public final class OpusFileSource: LocalSource {
    public static let defaultFrameMs: Double = 100
    /// Python: `OpusFileSource.MAX_FRAMES = 128`
    public static let maxFrames: Int = 128

    public let filePath: URL
    public let loop: Bool
    public let timed: Bool

    private var ingestThread: Thread?

    /// Python: `OpusFileSource.__init__(file_path, target_frame_ms, loop, codec, sink, timed)`
    public init(filePath: URL,
                targetFrameMs: Double = OpusFileSource.defaultFrameMs,
                loop: Bool = false,
                codec: (any Codec)? = nil,
                sink: (any Sink)? = nil,
                timed: Bool = false) {
        self.filePath = filePath
        self.loop     = loop
        self.timed    = timed
        super.init()
        self.targetFrameMs = targetFrameMs
        self.codec = codec
        self.sink  = sink
    }

    /// Python: `@property running` — alias for shouldRun
    public var running: Bool { shouldRun }

    public override func start() {
        guard !shouldRun else { return }
        super.start()
        let t = Thread { [weak self] in self?.ingestJob() }
        t.name = "lxst.opusfilesource"
        t.qualityOfService = .utility
        t.start()
        ingestThread = t
    }

    public override func stop() {
        super.stop()
        ingestThread = nil
    }

    // MARK: - File reading

    private struct FileContents {
        let sampleRate: Double
        let channels: Int
        let frames: [Data]
    }

    private func readFile() -> FileContents? {
        guard let data = try? Data(contentsOf: filePath) else { return nil }
        let magic = Array("LXSTOPUS".utf8)
        guard data.count >= 9, Array(data.prefix(8)) == magic else { return nil }

        let version = data[8]
        let headerSize: Int
        let sampleRate: Double
        let channels: Int

        if version == 0x02 {
            guard data.count >= 14 else { return nil }
            let sr = UInt32(data[9]) | UInt32(data[10]) << 8
                   | UInt32(data[11]) << 16 | UInt32(data[12]) << 24
            sampleRate = Double(sr)
            channels   = Int(data[13])
            headerSize = 14
        } else {
            // v1 — no audio params stored; assume 48kHz mono
            sampleRate = 48000
            channels   = 1
            headerSize = 9
        }

        var offset = headerSize
        var frames: [Data] = []
        while offset + 4 <= data.count {
            let len = Int(data[offset])
                    | Int(data[offset + 1]) << 8
                    | Int(data[offset + 2]) << 16
                    | Int(data[offset + 3]) << 24
            offset += 4
            guard len > 0, offset + len <= data.count else { break }
            frames.append(data.subdata(in: offset ..< (offset + len)))
            offset += len
        }

        return FileContents(sampleRate: sampleRate, channels: channels, frames: frames)
    }

    // MARK: - Ingest job

    private func ingestJob() {
        guard let file = readFile(), !file.frames.isEmpty else {
            shouldRun = false
            return
        }

        var err: Int32 = 0
        let sr = Int32(file.sampleRate)
        let ch = Int32(file.channels)
        guard let dec = opus_decoder_create(sr, ch, &err), err == OPUS_OK else {
            shouldRun = false
            return
        }
        defer { opus_decoder_destroy(dec) }

        // Max samples per channel for a 60ms Opus frame
        let maxSamplesPerCh = Int(file.sampleRate * 0.060) + 64
        let frameTime = targetFrameMs / 1000.0

        var fi = 0
        while shouldRun {
            if fi >= file.frames.count {
                if loop {
                    fi = 0
                } else {
                    break
                }
            }

            let encoded = file.frames[fi]
            fi += 1

            var decoded = [Float](repeating: 0, count: maxSamplesPerCh * Int(ch))
            let n = encoded.withUnsafeBytes { ptr -> Int32 in
                guard let base = ptr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return opus_decode_float(dec, base, Int32(encoded.count),
                                        &decoded, Int32(maxSamplesPerCh), 0)
            }
            guard n > 0 else { continue }

            let frame = AudioFrame(
                samples: Array(decoded.prefix(Int(n) * Int(ch))),
                channelCount: Int(ch),
                sampleRate: file.sampleRate
            )
            sink?.handleFrame(frame, from: self)

            if timed {
                Thread.sleep(forTimeInterval: frameTime)
            }
        }

        shouldRun = false
    }
}
