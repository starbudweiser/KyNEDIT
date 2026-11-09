import Foundation
import AVFoundation
import VideoToolbox
import CoreImage

enum ExportPreset: String, Codable, CaseIterable, Sendable {
    case proRes422HQ, h264, hevc

    var isProRes: Bool { self == .proRes422HQ }
    var codec: AVVideoCodecType { switch self { case .proRes422HQ: .proRes422HQ; case .h264: .h264; case .hevc: .hevc } }
    var fileType: AVFileType { isProRes ? .mov : .mp4 }
    var ext: String { isProRes ? "mov" : "mp4" }
    var label: String { switch self { case .proRes422HQ: "ProRes 422 HQ"; case .h264: "H.264"; case .hevc: "H.265 (HEVC)" } }
    var tag: String { switch self { case .proRes422HQ: "ProRes422HQ"; case .h264: "H264"; case .hevc: "HEVC" } }
}

struct ExportError: LocalizedError, Sendable { let message: String; var errorDescription: String? { message } }

/// Un transcodage : lit un clip (ou un sous-clip) avec AVAssetReader, réécrit avec AVAssetWriter (encodeurs matériels de la puce).
/// Écrit d'abord dans un fichier « .part », renommé à la fin ; supprimé en cas d'échec ou d'annulation.
/// Sortie du lecteur + entrée de l'écrivain, confiées à une seule file de distribution.
struct MediaPair: @unchecked Sendable { let out: AVAssetReaderTrackOutput; let input: AVAssetWriterInput }

final class Transcoder: @unchecked Sendable {
    private let path: String, tin: Double?, tout: Double?, preset: ExportPreset, output: URL, lutPath: String?
    private let lock = NSLock()
    private var cancelled = false
    private var reader: AVAssetReader?, writer: AVAssetWriter?

    init(path: String, tin: Double?, tout: Double?, preset: ExportPreset, output: URL, lutPath: String? = nil) {
        self.path = path; self.tin = tin; self.tout = tout; self.preset = preset; self.output = output; self.lutPath = lutPath
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        reader?.cancelReading(); writer?.cancelWriting()
    }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Retourne la durée écrite (secondes). `progress` reçoit 0…1.
    func run(progress: @escaping @Sendable (Double) -> Void) async throws -> Double {
        if ["braw", "r3d", "ari", "arx", "crm"].contains((path as NSString).pathExtension.lowercased()) && !Raw.decodable(ext: (path as NSString).pathExtension.lowercased()) { throw ExportError(message: L("export.raw")) }
        if Raw.decodable(ext: (path as NSString).pathExtension.lowercased()) { // AVFoundation ne lit pas le RAW : chemin SDK
            guard let clip = Raw.open(path) else { throw ExportError(message: L("err.rawSDK")) }
            let start = max(0, tin ?? 0), end = min(tout ?? clip.duration, clip.duration)
            let part = output.deletingLastPathComponent().appendingPathComponent(output.lastPathComponent + ".part")
            try? FileManager.default.removeItem(at: part)
            do {
                let written = try await runBRAW(start: start, end: end, part: part, progress: progress)
                return try finalize(part: part, written: written, fps: clip.fps)
            } catch { try? FileManager.default.removeItem(at: part); throw error }
        }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError(message: L("err.noVideo")) }
        let (size, fps, transform) = try await vTrack.load(.naturalSize, .nominalFrameRate, .preferredTransform)
        let total = try await asset.load(.duration).seconds
        let start = max(0, tin ?? 0), end = min(tout ?? total, total)
        guard end > start else { throw ExportError(message: L("err.emptyRange")) }
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        let span = range.duration.seconds
        let part = output.deletingLastPathComponent().appendingPathComponent(output.lastPathComponent + ".part")
        try? FileManager.default.removeItem(at: part)

        // Formats de pixels essayés dans l'ordre : le plus proche de la cible, puis BGRA (universel).
        // HEVC en 10 bits quand la source est en 10 bits ou plus (ProRes compris), sinon 8 bits.
        var tenBit = false
        if let d = try await vTrack.load(.formatDescriptions).first {
            let bits = (CMFormatDescriptionGetExtension(d, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? Int) ?? 0
            let sub = CMFormatDescriptionGetMediaSubType(d)
            tenBit = bits >= 10 || [kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422Proxy, kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ].contains(sub)
        }
        let hevc10 = preset == .hevc && tenBit
        var pixels: [OSType]
        if lutPath != nil { pixels = [kCVPixelFormatType_32BGRA] }   // le filtre Core Image travaille en BGRA
        else if preset.isProRes { pixels = [kCVPixelFormatType_422YpCbCr10, kCVPixelFormatType_32BGRA] }
        else if hevc10 { pixels = [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_32BGRA] }
        else { pixels = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA] }
        var lastError: Error = ExportError(message: L("err.read"))
        for pixel in pixels {
            do {
                let written = try await attempt(asset: asset, vTrack: vTrack, size: size, fps: Double(fps), transform: transform,
                                                range: range, span: span, pixel: pixel, hevc10: hevc10, part: part, progress: progress)
                return try finalize(part: part, written: written, fps: Double(fps))
            } catch {
                try? FileManager.default.removeItem(at: part)
                if isCancelled { throw ExportError(message: L("err.cancelled")) }
                lastError = error
            }
        }
        throw lastError
    }

    /// Renomme le fichier partiel et contrôle que sa durée correspond à la plage demandée (à 2 images près).
    private func finalize(part: URL, written: Double, fps: Double) throws -> Double {
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: part, to: output)
        let outDuration = AVURLAsset(url: output).duration.seconds
        if abs(outDuration - written) > 2.0 / max(fps, 24) + 0.05 {
            try? FileManager.default.removeItem(at: output)
            throw ExportError(message: L("err.duration", outDuration, written))
        }
        return outDuration
    }

    /// Réglages de l'encodeur vidéo du préréglage.
    private func videoSettings(size: CGSize, fps: Double, hevc10: Bool) -> [String: Any] {
        var settings: [String: Any] = [AVVideoCodecKey: preset.codec, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)]
        if !preset.isProRes {
            let bpp = preset == .hevc ? 0.07 : 0.12
            let bitrate = max(4_000_000, Int(size.width * size.height * max(fps, 24) * bpp))
            var props: [String: Any] = [AVVideoAverageBitRateKey: bitrate, AVVideoExpectedSourceFrameRateKey: max(fps, 24)]
            if preset == .hevc { props[AVVideoProfileLevelKey] = (hevc10 ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel) as String }
            else { props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel; props[AVVideoAllowFrameReorderingKey] = true }
            settings[AVVideoCompressionPropertiesKey] = props
        }
        return settings
    }

    fileprivate var cancelledNow: Bool { isCancelled }

    /// Export d'un clip Blackmagic RAW : images décodées par le SDK (BGRA 8 bits, pleine résolution), audio converti en PCM 16 bits.
    private func runBRAW(start: Double, end: Double, part: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Double {
        guard let clip = Raw.open(path) else { throw ExportError(message: L("err.rawSDK")) }
        let fps = clip.fps > 0 ? clip.fps : 24
        let first = max(0, Int((start * fps).rounded(.down))), last = min(clip.frameCount, Int((end * fps).rounded(.down)))
        guard last > first else { throw ExportError(message: L("err.emptyRange")) }
        let span = Double(last - first) / fps
        let writer = try AVAssetWriter(outputURL: part, fileType: preset.fileType)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(size: CGSize(width: clip.width, height: clip.height), fps: fps, hevc10: false))
        vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: clip.width, kCVPixelBufferHeightKey as String: clip.height])
        guard writer.canAdd(vIn) else { throw ExportError(message: L("err.encoderSettings")) }
        writer.add(vIn)
        var aIn: AVAssetWriterInput?
        if let a = clip.audio {
            let fmt: [String: Any] = preset.isProRes
                ? [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: a.rate, AVNumberOfChannelsKey: a.channels]
                : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: a.rate, AVNumberOfChannelsKey: a.channels, AVEncoderBitRateKey: 256_000]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: fmt)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); aIn = input }
        }
        self.writer = writer
        guard writer.startWriting() else { throw writer.error ?? ExportError(message: L("err.write")) }
        writer.startSession(atSourceTime: .zero)
        let videoJob = BRAWVideoJob(clip: clip, input: vIn, adaptor: adaptor, first: first, last: last, fps: fps, transcoder: self)
        var audioJob: BRAWAudioJob?
        if let aIn, let a = clip.audio {
            audioJob = BRAWAudioJob(clip: clip, input: aIn, from: Int(Double(first) / fps * Double(a.rate)), to: Int(Double(last) / fps * Double(a.rate)))
        }
        let aj = audioJob
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await videoJob.run(progress: progress) }
            if let aj { group.addTask { await aj.run() } }
        }
        if isCancelled { writer.cancelWriting(); throw ExportError(message: L("err.cancelled")) }
        if let e = videoJob.error { writer.cancelWriting(); throw e }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ExportError(message: L("err.writeStopped")) }
        progress(1)
        return span
    }

    private func attempt(asset: AVURLAsset, vTrack: AVAssetTrack, size: CGSize, fps: Double, transform: CGAffineTransform,
                         range: CMTimeRange, span: Double, pixel: OSType, hevc10: Bool, part: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> Double {
        let reader = try AVAssetReader(asset: asset); reader.timeRange = range
        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixel])
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else { throw ExportError(message: L("err.videoFormat")) }
        reader.add(vOut)

        let writer = try AVAssetWriter(outputURL: part, fileType: preset.fileType)
        let settings = videoSettings(size: size, fps: fps, hevc10: hevc10)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        vIn.transform = transform; vIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(vIn) else { throw ExportError(message: L("err.encoderSettings")) }
        writer.add(vIn)
        // LUT : chaque image passe par Core Image (même filtre que l'aperçu), puis dans le tampon de l'encodeur.
        var lutHandler: (@Sendable (CMSampleBuffer) -> Bool)?
        if let lutPath, let cube = PlayerModel.parseCube(URL(fileURLWithPath: lutPath)) {
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height)])
            let ctx = CIContext(options: nil), space = CGColorSpace(name: CGColorSpace.sRGB)!
            let dim = cube.size, data = cube.data
            nonisolated(unsafe) let adaptorRef = adaptor
            lutHandler = { buf in
                guard let src = CMSampleBufferGetImageBuffer(buf), let pool = adaptorRef.pixelBufferPool else { return false }
                var out: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return false }
                let img = CIImage(cvPixelBuffer: src).applyingFilter("CIColorCubeWithColorSpace", parameters: ["inputCubeDimension": dim, "inputCubeData": data, "inputColorSpace": space])
                ctx.render(img, to: out)
                return adaptorRef.append(out, withPresentationTime: CMSampleBufferGetPresentationTimeStamp(buf))
            }
        } else if lutPath != nil { throw ExportError(message: L("err.lutRead")) }

        // Audio : décodé en PCM puis AAC (MP4) ou PCM (MOV).
        var aOut: AVAssetReaderTrackOutput?, aIn: AVAssetWriterInput?
        if let aTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let out = AVAssetReaderTrackOutput(track: aTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2])
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: preset.isProRes
                ? [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2]
                : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000])
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(out), writer.canAdd(input) { reader.add(out); writer.add(input); aOut = out; aIn = input }
        }
        self.reader = reader; self.writer = writer
        guard reader.startReading() else { throw reader.error ?? ExportError(message: L("err.read")) }
        guard writer.startWriting() else { throw writer.error ?? ExportError(message: L("err.write")) }
        writer.startSession(atSourceTime: range.start)

        let startSeconds = range.start.seconds
        let videoHandler = lutHandler
        await withTaskGroup(of: Void.self) { group in
            let vPair = MediaPair(out: vOut, input: vIn)
            group.addTask { await self.pump(vPair, queue: "video", handler: videoHandler) { pts in progress(min(1, max(0, (pts - startSeconds) / span))) } }
            if let aOut, let aIn { let aPair = MediaPair(out: aOut, input: aIn); group.addTask { await self.pump(aPair, queue: "audio", handler: nil) { _ in } } }
        }
        if isCancelled { writer.cancelWriting(); throw ExportError(message: L("err.cancelled")) }
        if reader.status == .failed { writer.cancelWriting(); throw reader.error ?? ExportError(message: L("err.readStopped")) }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ExportError(message: L("err.writeStopped")) }
        progress(1)
        return span
    }

    /// Copie les échantillons d'une sortie du lecteur vers une entrée de l'écrivain, à son rythme.
    private func pump(_ pair: MediaPair, queue name: String, handler: (@Sendable (CMSampleBuffer) -> Bool)?, pts: @escaping @Sendable (Double) -> Void) async {
        let out = pair.out, input = pair.input
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let q = DispatchQueue(label: "kynedit.export.\(name)")
            nonisolated(unsafe) var done = false
            input.requestMediaDataWhenReady(on: q) {
                while input.isReadyForMoreMediaData && !done {
                    if self.isCancelled { done = true; input.markAsFinished(); c.resume(); return }
                    if let buf = out.copyNextSampleBuffer() {
                        pts(CMSampleBufferGetPresentationTimeStamp(buf).seconds)
                        if !(handler?(buf) ?? input.append(buf)) { done = true; input.markAsFinished(); c.resume(); return }
                    } else { done = true; input.markAsFinished(); c.resume(); return }
                }
            }
        }
    }
}


/// Boucle vidéo BRAW : décode chaque image avec le SDK et l'écrit dans un tampon de l'encodeur.
final class BRAWVideoJob: @unchecked Sendable {
    private let clip: RawDecoder, input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let first: Int, last: Int, fps: Double
    private unowned let transcoder: Transcoder
    var error: Error?

    init(clip: RawDecoder, input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor, first: Int, last: Int, fps: Double, transcoder: Transcoder) {
        self.clip = clip; self.input = input; self.adaptor = adaptor; self.first = first; self.last = last; self.fps = fps; self.transcoder = transcoder
    }

    func run(progress: @escaping @Sendable (Double) -> Void) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let q = DispatchQueue(label: "kynedit.export.braw.video")
            let w = clip.width, h = clip.height
            let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h * 4 + 4096)
            nonisolated(unsafe) var next = first
            nonisolated(unsafe) var finished = false
            func stop() { if !finished { finished = true; scratch.deallocate(); input.markAsFinished(); c.resume() } }
            input.requestMediaDataWhenReady(on: q) {
                while self.input.isReadyForMoreMediaData && !finished {
                    if self.transcoder.cancelledNow || next >= self.last { stop(); return }
                    guard let pool = self.adaptor.pixelBufferPool else { self.error = ExportError(message: L("err.buffers")); stop(); return }
                    var pb: CVPixelBuffer?
                    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let pb else { self.error = ExportError(message: L("err.memory")); stop(); return }
                    guard let size = self.clip.decode(next, scale: 0, into: scratch, capacity: w * h * 4 + 4096), size.width == w, size.height == h else {
                        self.error = ExportError(message: L("err.brawDecode", next))
                        stop(); return
                    }
                    CVPixelBufferLockBaseAddress(pb, [])
                    let dst = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(pb)
                    for y in 0..<h { memcpy(dst + y * stride, scratch + y * w * 4, w * 4) }
                    CVPixelBufferUnlockBaseAddress(pb, [])
                    let t = CMTime(value: CMTimeValue(next - self.first), timescale: CMTimeScale(self.fps.rounded()))
                    if !self.adaptor.append(pb, withPresentationTime: t) { self.error = ExportError(message: L("err.frameWrite", next)); stop(); return }
                    next += 1
                    progress(Double(next - self.first) / Double(self.last - self.first))
                }
            }
        }
    }
}

/// Boucle audio BRAW : PCM du SDK converti en 16 bits, par blocs de 4096 échantillons.
final class BRAWAudioJob: @unchecked Sendable {
    private let clip: RawDecoder, input: AVAssetWriterInput, from: Int, to: Int

    init(clip: RawDecoder, input: AVAssetWriterInput, from: Int, to: Int) {
        self.clip = clip; self.input = input; self.from = from; self.to = min(to, clip.audio?.samples ?? 0)
    }

    private func sampleBuffer(_ pcm: [Int16], channels: Int, rate: Int, start: Int) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(2 * channels), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(2 * channels), mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
        var fd: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd) == noErr, let fd else { return nil }
        let bytes = pcm.count * 2
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr, let block else { return nil }
        pcm.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var sb: CMSampleBuffer?
        let pts = CMTime(value: CMTimeValue(start - from), timescale: CMTimeScale(rate))
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: fd, sampleCount: pcm.count / channels, presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }

    func run() async {
        guard let a = clip.audio else { input.markAsFinished(); return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let q = DispatchQueue(label: "kynedit.export.braw.audio")
            nonisolated(unsafe) var pos = from
            nonisolated(unsafe) var finished = false
            func stop() { if !finished { finished = true; input.markAsFinished(); c.resume() } }
            input.requestMediaDataWhenReady(on: q) {
                while self.input.isReadyForMoreMediaData && !finished {
                    if pos >= self.to { stop(); return }
                    let n = min(4096, self.to - pos)
                    guard let raw = self.clip.readAudio(from: pos, maxSamples: n) else { stop(); return }
                    let bps = a.bits / 8, count = raw.count / bps
                    var pcm = [Int16](repeating: 0, count: count)
                    raw.withUnsafeBytes { p in
                        for i in 0..<count { // garde les 16 bits de poids fort de chaque échantillon (petit-boutiste)
                            let o = i * bps; pcm[i] = Int16(bitPattern: UInt16(p[o + bps - 2]) | UInt16(p[o + bps - 1]) << 8)
                        }
                    }
                    guard let sb = self.sampleBuffer(pcm, channels: a.channels, rate: a.rate, start: pos), self.input.append(sb) else { stop(); return }
                    pos += count / a.channels
                }
            }
        }
    }
}
