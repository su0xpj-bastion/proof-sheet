import AVFoundation
import CoreImage
import Foundation

/// 29.97 fps timing shared by the fixture, the edit, and the checks.
public enum Clock {
    public static let frameDuration = CMTime(value: 1001, timescale: 30000)
    public static let sampleRate = 48_000
    public static func time(frames n: Int) -> CMTime { CMTime(value: Int64(n) * 1001, timescale: 30000) }
    /// First audio sample of a frame: round(n * 1601.6).
    public static func sample(frame n: Int) -> Int64 { (Int64(n) * 16016 + 5) / 10 }
    public static func frame(at t: CMTime) -> Int { Int((t.seconds * 30000 / 1001).rounded()) }
}

public enum VideoError: Error { case writer(String), reader(String), export(String), noTrack(String), cancelled }

/// A clip whose every frame carries its own number (FrameCode), with a 3 kHz click on the first
/// audio sample of frames 5, 15, 25, ... Video and audio share one .mov, like a camera clip.
public enum VideoFixture {
    public static func clickFrames(_ frames: Int) -> [Int] { stride(from: 5, to: frames, by: 10).map { $0 } }

    /// ProRes on macOS (the fixture must survive re-encoding); H.264 on iOS, where ProRes encode is hardware-gated.
    #if os(macOS)
    public static let codec = AVVideoCodecType.proRes422
    #else
    public static let codec = AVVideoCodecType.h264
    #endif

    public static func write(frames: Int, to url: URL, contentID: String? = nil) throws {
        let dir = url.deletingLastPathComponent().appendingPathComponent(".fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let v = dir.appendingPathComponent("v.mov"), a = dir.appendingPathComponent("a.wav")
        try writeVideo(frames: frames, url: v)
        try writeAudio(frames: frames, url: a)

        // Mux by passthrough: no re-encode, sample timing kept.
        let comp = AVMutableComposition()
        let vAsset = AVURLAsset(url: v), aAsset = AVURLAsset(url: a)
        let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let at = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        vt.naturalTimeScale = 30000
        let range = CMTimeRange(start: .zero, duration: Clock.time(frames: frames))
        try vt.insertTimeRange(range, of: vAsset.tracks(withMediaType: .video)[0], at: .zero)
        try at.insertTimeRange(range, of: aAsset.tracks(withMediaType: .audio)[0], at: .zero)
        try? FileManager.default.removeItem(at: url)
        guard let s = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { throw VideoError.export("mux") }
        s.outputURL = url
        s.outputFileType = .mov
        if let id = contentID { s.metadata = [LivePhoto.movieMetadata(id: id)] }
        try VideoExport.run(s)
    }

    static func writeVideo(frames: Int, url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec, AVVideoWidthKey: FrameCode.width, AVVideoHeightKey: FrameCode.height,
        ])
        input.expectsMediaDataInRealTime = false
        // The .mov default track timescale (600) cannot hold 1001/30000.
        input.mediaTimeScale = 30000
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: FrameCode.width, kCVPixelBufferHeightKey as String: FrameCode.height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw VideoError.writer("\(String(describing: writer.error))") }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { usleep(500) }
            var buf: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buf)
            guard let pb = buf else { throw VideoError.writer("no pixel buffer") }
            CVPixelBufferLockBaseAddress(pb, [])
            FrameCode.draw(id: i, into: CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self),
                           bytesPerRow: CVPixelBufferGetBytesPerRow(pb))
            CVPixelBufferUnlockBaseAddress(pb, [])
            guard adaptor.append(pb, withPresentationTime: Clock.time(frames: i)) else {
                throw VideoError.writer("append \(i): \(String(describing: writer.error))")
            }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw VideoError.writer("\(String(describing: writer.error))") }
    }

    static func writeAudio(frames: Int, url: URL) throws {
        let total = Int(Clock.sample(frame: frames))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Clock.sampleRate), channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        let ch = buffer.floatChannelData![0]
        for i in 0..<total { ch[i] = 0 }
        for f in clickFrames(frames) {
            let s = Int(Clock.sample(frame: f))
            for k in 0..<96 where s + k < total {
                ch[s + k] = 0.8 * Float(sin(2 * Double.pi * 3000 * Double(k) / Double(Clock.sampleRate) + Double.pi / 2))
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Clock.sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}

public struct BuiltVideo {
    public let composition: AVMutableComposition
    public let videoComposition: AVVideoComposition
    public let audioMix: AVAudioMix
}

/// Region (top-left origin) where a title card draws a white plate.
public enum TitleRegion {
    public static let rect = CGRect(x: 16, y: 296, width: 320, height: 48)
    public static let probe = (x: 40, y: 320)
}

public enum VideoEditor {
    public static func build(_ r: VideoRecipe, source: URL) throws -> BuiltVideo {
        let asset = AVURLAsset(url: source)
        guard let srcV = asset.tracks(withMediaType: .video).first else { throw VideoError.noTrack("video") }
        guard let srcA = asset.tracks(withMediaType: .audio).first else { throw VideoError.noTrack("audio") }
        let comp = AVMutableComposition()
        let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let a = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        v.naturalTimeScale = 30000
        var cursor = CMTime.zero
        for s in r.segments {
            let extra = FaultInjection.on(.trimIncludesOutFrame) ? 1 : 0
            let range = CMTimeRange(start: Clock.time(frames: s.sourceIn), duration: Clock.time(frames: s.sourceOut - s.sourceIn + extra))
            try v.insertTimeRange(range, of: srcV, at: cursor)
            try a.insertTimeRange(range, of: srcA, at: cursor)
            if s.isRetimed {
                let out = Clock.time(frames: s.outputLength)
                let inserted = CMTimeRange(start: cursor, duration: range.duration)
                v.scaleTimeRange(inserted, toDuration: out)
                a.scaleTimeRange(inserted, toDuration: out)
                cursor = cursor + out
            } else {
                cursor = cursor + range.duration
            }
        }

        let params = AVMutableAudioMixInputParameters(track: a)
        params.setVolume(r.muted ? 0 : Float(r.volume), at: .zero)
        params.audioTimePitchAlgorithm = .spectral
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]

        let vc: AVMutableVideoComposition
        if r.filter != .none || r.title != nil {
            let filter = r.filter, title = r.title
            vc = AVMutableVideoComposition(asset: comp) { request in
                var img = Renderer.filter(request.sourceImage, filter)
                if let t = title {
                    let f = Clock.frame(at: request.compositionTime)
                    if f >= t.outputIn && f < t.outputOut { img = TitleCard.draw(t.text, over: img) }
                }
                request.finish(with: img.cropped(to: request.sourceImage.extent), context: nil)
            }
        } else {
            vc = AVMutableVideoComposition(propertiesOf: comp)
        }
        vc.frameDuration = Clock.frameDuration
        vc.renderSize = CGSize(width: FrameCode.width, height: FrameCode.height)
        return BuiltVideo(composition: comp, videoComposition: vc, audioMix: mix)
    }
}

extension TitleCard {
    static func draw(_ text: String, over img: CIImage) -> CIImage {
        let h = CGFloat(FrameCode.height), r = TitleRegion.rect
        let plateRect = CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
        let plate = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: plateRect)
        var out = plate.composited(over: img)
        if let gen = CIFilter(name: "CITextImageGenerator", parameters: ["inputText": text, "inputFontSize": 22, "inputScaleFactor": 1]),
           let textImg = gen.outputImage {
            // Force the glyphs black, keep their alpha, then lay them on the right of the plate.
            let black = textImg.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
            out = black.transformed(by: CGAffineTransform(translationX: plateRect.minX + 120, y: plateRect.minY + 8))
                .cropped(to: plateRect).composited(over: out)
        }
        return out
    }
}

public struct DecodedFrame: Equatable {
    public let pts: CMTime
    /// nil when the barcode failed its CRC.
    public let id: Int?
    public let titleVisible: Bool
    /// Background tint is neutral (R == G == B): a mono filter reached this frame.
    public let neutral: Bool
}

public struct DecodedVideo {
    public let frames: [DecodedFrame]
    public let audio: [Float]
    public var ids: [Int?] { frames.map { $0.id } }
    public var peak: Float { audio.map { abs($0) }.max() ?? 0 }
}

/// Reads what a viewer would see and hear.
public enum VideoDecoder {
    static let bgra: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    static let pcm: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Clock.sampleRate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
    ]

    /// The edit as the player renders it (no file written).
    public static func preview(_ b: BuiltVideo) throws -> DecodedVideo {
        let comp = b.composition
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: comp.tracks(withMediaType: .video), videoSettings: bgra)
        vOut.videoComposition = b.videoComposition
        let aOut = AVAssetReaderAudioMixOutput(audioTracks: comp.tracks(withMediaType: .audio), audioSettings: pcm)
        aOut.audioMix = b.audioMix
        aOut.audioTimePitchAlgorithm = .spectral
        return DecodedVideo(frames: try frames(comp, vOut), audio: try samples(comp, aOut))
    }

    public static func file(_ url: URL) throws -> DecodedVideo {
        let asset = AVURLAsset(url: url)
        guard let v = asset.tracks(withMediaType: .video).first else { throw VideoError.noTrack("video in \(url.lastPathComponent)") }
        let audio = try asset.tracks(withMediaType: .audio).first.map { try samples(asset, AVAssetReaderTrackOutput(track: $0, outputSettings: pcm)) } ?? []
        return DecodedVideo(frames: try frames(asset, AVAssetReaderTrackOutput(track: v, outputSettings: bgra)), audio: audio)
    }

    public static func codec(_ url: URL) -> String? {
        guard let t = AVURLAsset(url: url).tracks(withMediaType: .video).first,
              let fd = t.formatDescriptions.first else { return nil }
        let c = CMFormatDescriptionGetMediaSubType(fd as! CMFormatDescription)
        return String(bytes: [24, 16, 8, 0].map { UInt8((c >> $0) & 0xFF) }, encoding: .ascii)
    }

    static func frames(_ asset: AVAsset, _ out: AVAssetReaderOutput) throws -> [DecodedFrame] {
        let reader = try AVAssetReader(asset: asset)
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { throw VideoError.reader("\(String(describing: reader.error))") }
        var result: [DecodedFrame] = []
        while let sb = out.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self), row = CVPixelBufferGetBytesPerRow(pb)
            let id = FrameCode.read(from: p, bytesPerRow: row)
            func bgr(_ x: Int, _ y: Int) -> (Int, Int, Int) { let o = y * row + x * 4; return (Int(p[o]), Int(p[o + 1]), Int(p[o + 2])) }
            let probe = bgr(TitleRegion.probe.x, TitleRegion.probe.y)
            let tint = bgr(20, 20)
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            result.append(DecodedFrame(pts: CMSampleBufferGetPresentationTimeStamp(sb), id: id,
                                       titleVisible: probe.0 > 240 && probe.1 > 240 && probe.2 > 240,
                                       neutral: abs(tint.0 - tint.2) <= 3 && abs(tint.1 - tint.2) <= 3))
        }
        guard reader.status == .completed else { throw VideoError.reader("\(String(describing: reader.error))") }
        return result
    }

    static func samples(_ asset: AVAsset, _ out: AVAssetReaderOutput) throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        reader.add(out)
        guard reader.startReading() else { throw VideoError.reader("\(String(describing: reader.error))") }
        var result: [Float] = []
        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let n = CMBlockBufferGetDataLength(bb) / MemoryLayout<Float>.size
            var chunk = [Float](repeating: 0, count: n)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
            result += chunk
        }
        return result
    }

    /// Sample index where each click starts: |x| > 0.1 after at least 1,000 quiet samples.
    public static func onsets(_ audio: [Float], threshold: Float = 0.1) -> [Int64] {
        var result: [Int64] = [], quiet = 1000
        for (i, x) in audio.enumerated() {
            if abs(x) > threshold {
                if quiet >= 1000 { result.append(Int64(i)) }
                quiet = 0
            } else {
                quiet += 1
            }
        }
        return result
    }
}

public struct VideoExportPreset: Equatable {
    public let name: String
    public let avPreset: String
    /// Expected codec FourCC of the written video track.
    public let codec: String
    /// Rough bytes per second, for the free-space gate.
    public let bytesPerSecond: Int64

    public static var all: [VideoExportPreset] {
        var p = [VideoExportPreset(name: "H.264", avPreset: AVAssetExportPresetHighestQuality, codec: "avc1", bytesPerSecond: 2_000_000),
                 VideoExportPreset(name: "HEVC", avPreset: AVAssetExportPresetHEVCHighestQuality, codec: "hvc1", bytesPerSecond: 1_500_000)]
        #if os(macOS)
        p.append(VideoExportPreset(name: "ProRes 422", avPreset: AVAssetExportPresetAppleProRes422LPCM, codec: "apcn", bytesPerSecond: 20_000_000))
        #endif
        return p
    }
}

public enum VideoExport {
    public static func session(_ b: BuiltVideo, preset: VideoExportPreset, to url: URL, disk: DiskBudget = .system,
                               fileType: AVFileType = .mov) throws -> AVAssetExportSession {
        let needed = Int64(b.composition.duration.seconds * Double(preset.bytesPerSecond))
        try disk.require(needed, at: url.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: url)
        guard let s = AVAssetExportSession(asset: b.composition, presetName: preset.avPreset) else { throw VideoError.export("no session for \(preset.name)") }
        s.outputURL = url
        s.outputFileType = fileType
        s.videoComposition = b.videoComposition
        s.audioMix = b.audioMix
        s.audioTimePitchAlgorithm = .spectral
        return s
    }

    public static func export(_ b: BuiltVideo, preset: VideoExportPreset, to url: URL, disk: DiskBudget = .system,
                              fileType: AVFileType = .mov) throws {
        try run(try session(b, preset: preset, to: url, disk: disk, fileType: fileType))
    }

    /// Run to completion. A cancelled export leaves no partial file behind.
    public static func run(_ s: AVAssetExportSession, cancelAtProgress: Float? = nil) throws {
        let done = DispatchSemaphore(value: 0)
        s.exportAsynchronously { done.signal() }
        if let p = cancelAtProgress {
            while done.wait(timeout: .now() + .milliseconds(5)) == .timedOut {
                if s.progress >= p { s.cancelExport() }
            }
        } else {
            done.wait()
        }
        if s.status == .cancelled {
            if let u = s.outputURL { try? FileManager.default.removeItem(at: u) }
            throw VideoError.cancelled
        }
        guard s.status == .completed else { throw VideoError.export("\(String(describing: s.error))") }
    }
}

extension DecodedVideo {
    /// Constant-rate view of a decode: output frame k shows the last decoded frame at or before
    /// k * 1001/30000 s (+1 ms slack). Retimed segments decode one frame per source frame,
    /// so this is what a 29.97 display actually shows.
    public func conformed(_ count: Int) -> [Int?] {
        var out: [Int?] = [], j = 0
        for k in 0..<count {
            let edge = Clock.time(frames: k).seconds + 0.001
            while j + 1 < frames.count && frames[j + 1].pts.seconds <= edge { j += 1 }
            out.append(frames.isEmpty ? nil : frames[j].id)
        }
        return out
    }
}
