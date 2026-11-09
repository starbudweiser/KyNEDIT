import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import VideoToolbox
import AppKit

/// Moteur de conversion. Trois chemins, du plus rapide au plus souple :
///  1. direct : aucune retouche d'image, les images décodées par le matériel vont telles quelles à l'encodeur matériel (AVFoundation) ;
///     DNxHR/DNxHD sans retouche : ffmpeg lit la source lui-même (décodage VideoToolbox) ;
///  2. GPU : décodage → Core Image (Metal, demi-flottants : couleur, LUT, échelle, incrustations) → encodeur, en tuyau à plusieurs images d'avance ;
///  3. tuyau ffmpeg pour DNxHR/DNxHD quand des retouches Core Image sont nécessaires.
final class ConvertTranscoder: @unchecked Sendable {
    private let path: String, tin: Double?, tout: Double?, s: ConvertSettings, meta: SourceMeta, clipName: String, output: URL
    private let lock = NSLock()
    private var cancelled = false
    private var reader: AVAssetReader?, writer: AVAssetWriter?, proc: Process?

    init(path: String, tin: Double?, tout: Double?, settings: ConvertSettings, meta: SourceMeta, clipName: String, output: URL) {
        self.path = path; self.tin = tin; self.tout = tout; self.s = settings; self.meta = meta; self.clipName = clipName; self.output = output
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        reader?.cancelReading(); writer?.cancelWriting(); proc?.terminate()
    }
    fileprivate var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Retourne la durée écrite (secondes). `progress` reçoit 0…1.
    func run(progress: @escaping @Sendable (Double) -> Void) async throws -> Double {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Double, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { c.resume(returning: try self.runSync(progress: progress)) } catch { c.resume(throwing: error) }
            }
        }
    }

    // MARK: source

    fileprivate struct Source {
        var width: Int, height: Int, fps: Double, start: Double, end: Double
        var transform: CGAffineTransform = .identity
        var sourceTenBit = false
        var raw: RawDecoder?
        var asset: AVURLAsset?
        var vTrack: AVAssetTrack?
    }

    fileprivate func openSource() throws -> Source {
        let ext = (path as NSString).pathExtension.lowercased()
        if Raw.decodable(ext: ext) {
            guard let clip = Raw.open(path) else { throw ExportError(message: L("err.rawSDK")) }
            let start = max(0, tin ?? 0), end = min(tout ?? clip.duration, clip.duration)
            return Source(width: clip.width, height: clip.height, fps: clip.fps > 0 ? clip.fps : 24, start: start, end: end, raw: clip)
        }
        if ["braw", "r3d", "ari", "arx", "crm"].contains(ext) { throw ExportError(message: L("export.raw")) }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<Source, Error> = .failure(ExportError(message: L("err.read")))
        Task.detached {
            do {
                guard let v = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError(message: L("err.noVideo")) }
                let (size, fps, tr) = try await v.load(.naturalSize, .nominalFrameRate, .preferredTransform)
                let total = try await asset.load(.duration).seconds
                let o = size.applying(tr)
                var ten = false
                if let d = try await v.load(.formatDescriptions).first {
                    let bits = (CMFormatDescriptionGetExtension(d, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? Int) ?? 0
                    ten = bits >= 10 || ["apch", "apcn", "apcs", "apco", "ap4h", "ap4x"].contains(Prober.codecName(CMFormatDescriptionGetMediaSubType(d)).isEmpty ? "" : String(format: "%c%c%c%c", (CMFormatDescriptionGetMediaSubType(d) >> 24) & 255, (CMFormatDescriptionGetMediaSubType(d) >> 16) & 255, (CMFormatDescriptionGetMediaSubType(d) >> 8) & 255, CMFormatDescriptionGetMediaSubType(d) & 255))
                }
                let start = max(0, self.tin ?? 0), end = min(self.tout ?? total, total)
                result = .success(Source(width: Int(abs(o.width).rounded()), height: Int(abs(o.height).rounded()), fps: Double(fps) > 0 ? Double(fps) : 24, start: start, end: end,
                                         transform: tr, sourceTenBit: ten, asset: asset, vTrack: v))
            } catch { result = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return try result.get()
    }

    // MARK: dimensions

    private func even(_ v: Double) -> Int { max(2, Int(v.rounded()) / 2 * 2) }
    private func outputSize(_ w: Int, _ h: Int) -> (w: Int, h: Int, scale: Double) {
        if s.width == 0 { return (even(Double(w)), even(Double(h)), 1) }
        let sc = min(1, min(Double(s.width) / Double(w), Double(s.height) / Double(h)))
        if s.pad { return (s.width, s.height, sc) }
        return (even(Double(w) * sc), even(Double(h) * sc), sc)
    }
    fileprivate func rational(_ fps: Double) -> (Int, Int) {
        let n = fps.rounded()
        return abs(fps - n * 1000 / 1001) < 0.01 ? (Int(n) * 1000, 1001) : (Int((fps * 1000).rounded()), 1000)
    }

    // MARK: déroulement

    private func runSync(progress: @escaping @Sendable (Double) -> Void) throws -> Double {
        dlog("run")
        let src = try openSource()
        dlog("opened")
        let span = src.end - src.start
        guard span > 0 else { throw ExportError(message: L("err.emptyRange")) }
        try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = output.deletingLastPathComponent().appendingPathComponent(output.lastPathComponent + ".part")
        try? FileManager.default.removeItem(at: part)
        let (ow, oh, scale) = outputSize(src.width, src.height)
        let outFps = s.fps > 0 ? s.fps : src.fps
        if s.codec.isHD {
            guard ow == 1920, oh == 1080 else { throw ExportError(message: L("err.dnxhdSize")) }
            guard s.codec.dnxhdRate(fps: outFps) != nil else { throw ExportError(message: L("err.dnxhdRate")) }
        }
        do {
            if s.codec == .rewrap {
                try runRewrap(src: src, span: span, part: part, progress: progress)
                try move(part)
            } else if s.codec.isDNx {
                let direct = src.raw == nil && s.colorIn == .none && s.lutPath == nil && s.burn.isEmpty && s.logoPath == nil
                try runFFmpeg(src: src, ow: ow, oh: oh, outFps: outFps, span: span, direct: direct, part: part, progress: progress)
                if s.wrap == .mxfAtom { try finalizeAtom(part: part) } else { try move(part) }
            } else {
                try runAV(src: src, ow: ow, oh: oh, scale: scale, outFps: outFps, span: span, part: part, progress: progress)
                try move(part)
            }
        } catch {
            try? FileManager.default.removeItem(at: part); for n in 1...8 { try? FileManager.default.removeItem(at: audioPart(part, n)) }
            throw isCancelled ? ExportError(message: L("err.cancelled")) : error
        }
        progress(1)
        return span
    }

    private func move(_ part: URL) throws { try? FileManager.default.removeItem(at: output); try FileManager.default.moveItem(at: part, to: output) }
    private func audioPart(_ part: URL, _ n: Int = 1) -> URL { part.deletingLastPathComponent().appendingPathComponent(output.deletingPathExtension().lastPathComponent + "_A\(n).mxf.part") }
    private func finalizeAtom(part: URL) throws {
        try move(part)
        for n in 1...8 {
            let a = audioPart(part, n)
            guard FileManager.default.fileExists(atPath: a.path) else { break }
            let dest = output.deletingPathExtension().deletingLastPathComponent().appendingPathComponent(output.deletingPathExtension().lastPathComponent + "_A\(n).mxf")
            try? FileManager.default.removeItem(at: dest); try FileManager.default.moveItem(at: a, to: dest)
        }
    }

    // MARK: AVFoundation (ProRes, H.264, H.265)

    private func videoSettings(w: Int, h: Int, fps: Double, tenBit: Bool) -> [String: Any] {
        var d: [String: Any] = [AVVideoCodecKey: s.codec.avCodec!, AVVideoWidthKey: w, AVVideoHeightKey: h]
        if !s.codec.isProRes {
            let bpp = s.codec == .hevc ? 0.07 : 0.12
            var props: [String: Any] = [AVVideoAverageBitRateKey: max(4_000_000, Int(Double(w * h) * max(fps, 24) * bpp)), AVVideoExpectedSourceFrameRateKey: max(fps, 24)]
            if s.codec == .hevc { props[AVVideoProfileLevelKey] = (tenBit ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel) as String }
            else { props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel; props[AVVideoAllowFrameReorderingKey] = true }
            d[AVVideoCompressionPropertiesKey] = props
        }
        if s.colorIn != .none {   // sortie convertie : Rec.709
            d[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        }
        return d
    }

    private func audioOutputSettings() -> [String: Any] {
        s.codec.isProRes || s.wrap == .mov && !s.codec.isProRes && false
            ? [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48000]
            : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVEncoderBitRateKey: 192_000]
    }

    private func channelCount(_ native: Int) -> Int { switch s.channels { case .keep: max(1, min(native, 8)); case .stereo: 2; case .mono: 1 } }

    private func runAV(src: Source, ow: Int, oh: Int, scale: Double, outFps: Double, span: Double, part: URL, progress: @escaping @Sendable (Double) -> Void) throws {
        let direct = s.passthroughVideo && src.raw == nil
        let tenBit = s.codec.tenBit && (src.sourceTenBit || s.colorIn != .none || s.codec.isProRes)
        let hevc10 = s.codec == .hevc && (src.sourceTenBit)
        // Format des images échangées avec l'encodeur : celui que le matériel préfère.
        let pixel: OSType = s.codec.isProRes ? (s.codec == .proRes4444 || s.codec == .proRes4444XQ ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
            : (hevc10 ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        _ = tenBit
        let writer = try AVAssetWriter(outputURL: part, fileType: s.wrap == .mp4 ? .mp4 : .mov)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(w: ow, h: oh, fps: outFps, tenBit: hevc10))
        vIn.expectsMediaDataInRealTime = false
        if direct { vIn.transform = src.transform }
        guard writer.canAdd(vIn) else { throw ExportError(message: L("err.encoderSettings")) }
        writer.add(vIn)
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        if !direct {
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: pixel, kCVPixelBufferWidthKey as String: ow, kCVPixelBufferHeightKey as String: oh,
                kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        }
        self.writer = writer

        // Lecteur vidéo (matériel) : image d'origine dans le format le plus proche de la source.
        var vOut: AVAssetReaderTrackOutput?
        var audio: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        var rdr: AVAssetReader?
        let group = DispatchGroup()
        if let asset = src.asset, let vt = src.vTrack {
            let r = try AVAssetReader(asset: asset)
            r.timeRange = CMTimeRange(start: CMTime(seconds: src.start, preferredTimescale: 6000), end: CMTime(seconds: src.end, preferredTimescale: 6000))
            let readFormat: OSType = direct ? (s.codec.isProRes && pixel == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange ? kCVPixelFormatType_422YpCbCr10 : pixel) : (src.sourceTenBit ? kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            let o = AVAssetReaderTrackOutput(track: vt, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: readFormat, kCVPixelBufferMetalCompatibilityKey as String: true])
            o.alwaysCopiesSampleData = false
            guard r.canAdd(o) else { throw ExportError(message: L("err.videoFormat")) }
            r.add(o); vOut = o
            if s.audio != .none {
                let tracks = (try? syncLoad(asset, .audio)) ?? []
                for t in (s.audio == .first ? Array(tracks.prefix(1)) : tracks) {
                    let native = (try? syncChannels(t)) ?? 2
                    var ro: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48000]
                    ro[AVNumberOfChannelsKey] = channelCount(native)
                    var wo = audioOutputSettings(); wo[AVNumberOfChannelsKey] = channelCount(native)
                    let ao = AVAssetReaderTrackOutput(track: t, outputSettings: ro)
                    let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: wo)
                    ai.expectsMediaDataInRealTime = false
                    if r.canAdd(ao), writer.canAdd(ai) { r.add(ao); writer.add(ai); audio.append((ao, ai)) }
                }
            }
            self.reader = r; rdr = r
        }
        // Audio RAW : PCM du SDK (BRAWAudioJob), écrit tel quel (canaux et fréquence d'origine).
        var rawAudio: BRAWAudioJob?
        if let raw = src.raw, s.audio != .none, let a = raw.audio {
            var wo = audioOutputSettings(); wo[AVNumberOfChannelsKey] = a.channels; wo[AVSampleRateKey] = a.rate
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: wo)
            ai.expectsMediaDataInRealTime = false
            if writer.canAdd(ai) {
                writer.add(ai)
                rawAudio = BRAWAudioJob(clip: raw, input: ai, from: Int(src.start * Double(a.rate)), to: Int(src.end * Double(a.rate)))
            }
        }
        guard writer.startWriting() else { throw writer.error ?? ExportError(message: L("err.write")) }
        writer.startSession(atSourceTime: src.raw == nil ? CMTime(seconds: src.start, preferredTimescale: 6000) : .zero)
        if let rawAudio { group.enter(); Task.detached { await rawAudio.run(); group.leave() } }
        if let rdr { guard rdr.startReading() else { throw rdr.error ?? ExportError(message: L("err.read")) } }

        // Audio : une file par piste.
        for (i, (ao, ai)) in audio.enumerated() {
            group.enter()
            let q = DispatchQueue(label: "kynedit.convert.audio\(i)")
            nonisolated(unsafe) var done = false
            ai.requestMediaDataWhenReady(on: q) {
                while ai.isReadyForMoreMediaData && !done {
                    if self.isCancelled { done = true; ai.markAsFinished(); group.leave(); return }
                    if let b = ao.copyNextSampleBuffer(), ai.append(b) { continue }
                    done = true; ai.markAsFinished(); group.leave(); return
                }
            }
        }
        // Vidéo.
        let startT = src.start
        let report: @Sendable (Double) -> Void = { p in progress(min(0.999, max(0, p / span))) }
        if direct, let vOut {
            group.enter()
            let q = DispatchQueue(label: "kynedit.convert.video")
            nonisolated(unsafe) var done = false
            vIn.requestMediaDataWhenReady(on: q) {
                while vIn.isReadyForMoreMediaData && !done {
                    if self.isCancelled { done = true; vIn.markAsFinished(); group.leave(); return }
                    if let b = vOut.copyNextSampleBuffer() {
                        report(CMSampleBufferGetPresentationTimeStamp(b).seconds - startT)
                        if vIn.append(b) { continue }
                    }
                    done = true; vIn.markAsFinished(); group.leave(); return
                }
            }
        } else if let adaptor {
            group.enter()
            let pool = Box(v: adaptor), vBox = Box(v: vIn), vOutBox = Box(v: vOut)
            DispatchQueue.global(qos: .userInitiated).async {
                defer { vBox.v.markAsFinished(); group.leave() }
                do { try self.gpuLoop(src: src, vOut: vOutBox.v, ow: ow, oh: oh, scale: scale, outFps: outFps, span: span,
                                      makeBuffer: { var pb: CVPixelBuffer?; guard let p = pool.v.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, p, &pb) == kCVReturnSuccess else { return nil }; return pb },
                                      sink: { pb, t in
                                          while !vBox.v.isReadyForMoreMediaData { if self.isCancelled { return }; usleep(300) }
                                          if !pool.v.append(pb, withPresentationTime: t) { throw self.writer?.error ?? ExportError(message: L("err.writeRefused")) }
                                      }, report: report) }
                catch { self.loopError = error }
            }
        }
        group.wait()
        if isCancelled { writer.cancelWriting(); throw ExportError(message: L("err.cancelled")) }
        if let e = loopError { writer.cancelWriting(); throw e }
        if let rdr, rdr.status == .failed { writer.cancelWriting(); throw rdr.error ?? ExportError(message: L("err.readStopped")) }
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        guard writer.status == .completed else { throw writer.error ?? ExportError(message: L("err.writeStopped")) }
    }

    fileprivate var loopError: Error?

    private func syncLoad(_ asset: AVURLAsset, _ type: AVMediaType) throws -> [AVAssetTrack] {
        let sem = DispatchSemaphore(value: 0); nonisolated(unsafe) var r: [AVAssetTrack] = []
        let ab = Box(v: asset)
        Task.detached { r = (try? await ab.v.loadTracks(withMediaType: type)) ?? []; sem.signal() }
        sem.wait(); return r
    }
    private func syncChannels(_ t: AVAssetTrack) throws -> Int {
        let sem = DispatchSemaphore(value: 0); nonisolated(unsafe) var n = 2
        let tb = Box(v: t)
        Task.detached {
            let t = tb.v
            if let d = try? await t.load(.formatDescriptions).first, let a = CMAudioFormatDescriptionGetStreamBasicDescription(d) { n = Int(a.pointee.mChannelsPerFrame) }
            sem.signal()
        }
        sem.wait(); return n
    }
}

// MARK: - Chemin GPU (Core Image) partagé par l'encodeur AVFoundation et le tuyau ffmpeg

func dlog(_ m: String) {
    guard let p = ProcessInfo.processInfo.environment["KYNEDIT_LOG"] else { return }
    if let h = FileHandle(forWritingAtPath: p) { h.seekToEndOfFile(); h.write((m + "\n").data(using: .utf8)!); try? h.close() }
    else { try? (m + "\n").write(toFile: p, atomically: false, encoding: .utf8) }
}

fileprivate struct Box<T>: @unchecked Sendable { let v: T }

/// Incrustations : texte (timecode, bobine, nom, date, texte libre) et logo PNG.
fileprivate final class Burner {
    let items: [BurnItem], s: ConvertSettings, meta: SourceMeta, clipName: String, w: Int, h: Int
    var cache: [String: CIImage] = [:]
    var logo: CIImage?
    var staticImage: CIImage?
    let px: CGFloat

    init(s: ConvertSettings, meta: SourceMeta, clipName: String, w: Int, h: Int) {
        self.s = s; self.meta = meta; self.clipName = clipName; self.w = w; self.h = h; items = s.burn
        px = max(10, CGFloat(h) * CGFloat(s.fontPercent) / 100)
        if let p = s.logoPath, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            var img = CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
            let sc = CGFloat(w) * CGFloat(s.logoPercent) / 100 / img.extent.width
            img = img.transformed(by: CGAffineTransform(scaleX: sc, y: sc))
            if s.logoOpacity < 1 { img = img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(s.logoOpacity))]) }
            logo = place(img, s.logoPos)
        }
        // éléments fixes pendant toute la durée : tout sauf le timecode
        var acc: CIImage? = logo
        for it in items where it.field != .timecode {
            if let t = image(text(for: it.field, tc: ""), it.pos) { acc = acc.map { t.composited(over: $0) } ?? t }
        }
        staticImage = acc
    }

    private func text(for f: BurnField, tc: String) -> String {
        switch f {
        case .timecode: tc; case .reel: meta.reel; case .clipName: clipName; case .date: meta.date; case .custom: s.customText
        }
    }

    private func place(_ img: CIImage, _ pos: Pos) -> CIImage {
        let m = px * 0.6, e = img.extent
        let x: CGFloat = [.tl, .bl].contains(pos) ? m : [.tr, .br].contains(pos) ? CGFloat(w) - e.width - m : (CGFloat(w) - e.width) / 2
        let y: CGFloat = [.bl, .bc, .br].contains(pos) ? m : CGFloat(h) - e.height - m
        return img.transformed(by: CGAffineTransform(translationX: x - e.minX, y: y - e.minY))
    }

    private func image(_ str: String, _ pos: Pos) -> CIImage? {
        guard !str.isEmpty else { return nil }
        let key = str
        let base: CIImage
        if let c = cache[key] { base = c } else {
            let font = CTFontCreateWithName("Menlo-Bold" as CFString, px, nil)
            let attr = NSAttributedString(string: str, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true])
            let line = CTLineCreateWithAttributedString(attr)
            let b = CTLineGetBoundsWithOptions(line, [])
            let pad = px * 0.3
            let cw = Int(ceil(b.width + pad * 2)), ch = Int(ceil(b.height + pad * 2))
            guard let ctx = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.6))
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: cw, height: ch), cornerWidth: pad, cornerHeight: pad, transform: nil)); ctx.fillPath()
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.textPosition = CGPoint(x: pad - b.minX, y: pad - b.minY)
            CTLineDraw(line, ctx)
            guard let cg = ctx.makeImage() else { return nil }
            base = CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
            if cache.count > 400 { cache.removeAll() }
            cache[key] = base
        }
        return place(base, pos)
    }

    func overlay(timecode: String) -> CIImage? {
        var acc = staticImage
        for it in items where it.field == .timecode {
            if let t = image(timecode, it.pos) { acc = acc.map { t.composited(over: $0) } ?? t }
        }
        return acc
    }
}

extension ConvertTranscoder {
    fileprivate func gpuLoop(src: Source, vOut: AVAssetReaderTrackOutput?, ow: Int, oh: Int, scale: Double, outFps: Double,
                             span: Double, makeBuffer: @escaping () -> CVPixelBuffer?, sink: @escaping (CVPixelBuffer, CMTime) throws -> Void,
                             report: @escaping @Sendable (Double) -> Void) throws {
        let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false, .workingFormat: CIFormat.RGBAh.rawValue])

        // Cubes : conversion log → Rec.709, puis LUT de l'utilisateur.
        func cubeFilter(_ size: Int, _ data: Data) -> CIFilter? { let f = CIFilter.colorCube(); f.cubeDimension = Float(size); f.cubeData = data; return f }
        dlog("gpuLoop")
        let logCube = s.colorIn == .none ? nil : cubeFilter(33, Colour.cube(s.colorIn))
        var lutCube: CIFilter?
        if let p = s.lutPath {
            guard let c = PlayerModel.parseCube(URL(fileURLWithPath: p)) else { throw ExportError(message: L("err.lutRead")) }
            lutCube = cubeFilter(c.size, c.data)
        }
        dlog("cubes built")
        let burner = (s.burn.isEmpty && s.logoPath == nil) ? nil : Burner(s: s, meta: meta, clipName: clipName, w: ow, h: oh)
        let outRect = CGRect(x: 0, y: 0, width: ow, height: oh)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: outRect)
        let srcTransform = src.transform

        // Source d'images
        let nextFrame: () -> (CVPixelBuffer, Double)?
        if let raw = src.raw {
            let fpsR = raw.fps > 0 ? raw.fps : 24
            let first = max(0, Int((src.start * fpsR).rounded(.down))), last = min(raw.frameCount, Int((src.end * fpsR).rounded(.down)))
            let w = raw.width, h = raw.height
            let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h * 4 + 4096)
            nonisolated(unsafe) var i = first
            nextFrame = {
                guard i < last, !self.isCancelled else { return nil }
                var pb: CVPixelBuffer?
                guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb) == kCVReturnSuccess, let pb,
                      raw.decode(i, scale: 0, into: scratch, capacity: w * h * 4 + 4096) != nil else { return nil }
                CVPixelBufferLockBaseAddress(pb, [])
                let dst = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(pb)
                for y in 0..<h { memcpy(dst + y * stride, scratch + y * w * 4, w * 4) }
                CVPixelBufferUnlockBaseAddress(pb, [])
                defer { i += 1 }
                return (pb, Double(i - first) / fpsR)
            }
        } else if let vOut {
            let start = src.start
            nextFrame = {
                guard !self.isCancelled, let b = vOut.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(b) else { return nil }
                return (pb, CMSampleBufferGetPresentationTimeStamp(b).seconds - start)
            }
        } else { throw ExportError(message: L("err.source")) }

        func render(_ pb: CVPixelBuffer, rel: Double) throws -> (CVPixelBuffer, CIRenderTask?) {
            guard let out = makeBuffer() else { throw ExportError(message: L("err.buffers")) }
            CVBufferPropagateAttachments(pb, out)
            if s.colorIn != .none || src.raw != nil {
                CVBufferSetAttachment(out, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(out, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(out, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            }
            var img = CIImage(cvPixelBuffer: pb, options: [.colorSpace: NSNull()])
            if !srcTransform.isIdentity {
                img = img.transformed(by: srcTransform)
                img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
            }
            if let f = logCube { f.setValue(img, forKey: kCIInputImageKey); guard let o = f.outputImage else { throw ExportError(message: L("err.colorFail")) }; img = o }
            if let f = lutCube { f.setValue(img, forKey: kCIInputImageKey); guard let o = f.outputImage else { throw ExportError(message: L("err.lutApply")) }; img = o }
            if scale < 0.9999 {
                img = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            }
            let e = img.extent
            if s.pad || e.width != CGFloat(ow) || e.height != CGFloat(oh) {
                img = img.transformed(by: CGAffineTransform(translationX: (CGFloat(ow) - e.width) / 2 - e.minX, y: (CGFloat(oh) - e.height) / 2 - e.minY))
                img = img.composited(over: black)
            }
            if let burner {
                let frames = meta.startFrames + Int(((src.start + rel) * Double(meta.tcFps)).rounded(.down))
                if let o = burner.overlay(timecode: Timecode.string(frames: frames, fps: meta.tcFps)) { img = o.composited(over: img) }
            }
            img = img.cropped(to: outRect)
            // Rendu synchrone : startTask(toRender:) se bloque ici ; le GPU reste occupé pendant que l'encodeur écrit l'image précédente (file consumeQ).
            ctx.render(img, to: out)
            return (out, nil)
        }

        // Tuyau : plusieurs images en vol (le GPU travaille pendant que l'encodeur écrit).
        let depth = DispatchSemaphore(value: 4)
        let consumeQ = DispatchQueue(label: "kynedit.convert.consume")
        let inflight = DispatchGroup()
        nonisolated(unsafe) var failure: Error?
        func submit(_ pb: CVPixelBuffer, rel: Double, pts: CMTime) throws {
            depth.wait()
            if failure != nil || isCancelled { depth.signal(); return }
            let (out, task): (CVPixelBuffer, CIRenderTask?)
            do { (out, task) = try render(pb, rel: rel) } catch { depth.signal(); throw error }
            let bx = Box(v: (out, task))
            inflight.enter()
            consumeQ.async {
                defer { depth.signal(); inflight.leave() }
                if failure != nil { return }
                do { _ = try bx.v.1?.waitUntilCompleted(); try sink(bx.v.0, pts); if Int(rel * 30) % 30 == 0 { dlog("sunk \(rel)") }; report(rel) } catch { failure = error }
            }
        }

        let startT = src.raw == nil ? CMTime(seconds: src.start, preferredTimescale: 6000) : CMTime.zero
        var cur = nextFrame()
        if s.fps == 0 {
            while let f = cur, failure == nil, !isCancelled {
                try submit(f.0, rel: f.1, pts: CMTimeAdd(startT, CMTime(seconds: f.1, preferredTimescale: 6000)))
                cur = nextFrame()
            }
        } else {
            let (num, den) = rationalFps(outFps)
            var nx = nextFrame(), k = 0
            let tol = 0.5 / max(src.fps, 1)
            while let c = cur, failure == nil, !isCancelled {
                let t = Double(k) * Double(den) / Double(num)
                if t >= span { break }
                while let n = nx, n.1 <= t + tol { cur = n; nx = nextFrame() }
                let f = cur ?? c
                try submit(f.0, rel: t, pts: CMTimeAdd(startT, CMTime(value: CMTimeValue(k * den), timescale: CMTimeScale(num))))
                k += 1
                if nx == nil && Double(k) * Double(den) / Double(num) > f.1 + 1.0 / max(src.fps, 1) { break }
            }
        }
        inflight.wait()
        if let failure { throw failure }
    }

    fileprivate func rationalFps(_ fps: Double) -> (Int, Int) {
        let n = fps.rounded()
        return abs(fps - n * 1000 / 1001) < 0.01 ? (Int(n) * 1000, 1001) : (Int((fps * 1000).rounded()), 1000)
    }
}

// MARK: - ffmpeg (DNxHR / DNxHD)

extension ConvertTranscoder {
    fileprivate func runFFmpeg(src: Source, ow: Int, oh: Int, outFps: Double, span: Double, direct: Bool, part: URL, progress: @escaping @Sendable (Double) -> Void) throws {
        guard let ff = FFmpegTool.ffmpeg else { throw ExportError(message: L("err.ffmpegDNx")) }
        let (num, den) = rationalFps(outFps)
        let tcStart = meta.startFrames + Int((src.start * Double(meta.tcFps)).rounded())
        var a: [String] = ["-hide_banner", "-y", "-loglevel", "error", "-nostdin"]
        let sixteen = s.codec.tenBit
        var rawAudioFile: URL?
        defer { if let rawAudioFile { try? FileManager.default.removeItem(at: rawAudioFile) } }
        if direct {
            if src.start > 0 { a += ["-ss", String(format: "%.6f", src.start)] }
            a += ["-hwaccel", "videotoolbox", "-i", path]
        } else {
            a += ["-f", "rawvideo", "-pix_fmt", sixteen && s.codec != .dnxhr444 ? "p210le" : "bgra", "-s", "\(ow)x\(oh)", "-framerate", "\(num)/\(den)", "-i", "pipe:0"]
            if s.audio != .none {
                if let raw = src.raw {   // RAW : le SDK fournit le PCM, déposé dans un fichier temporaire lu par ffmpeg
                    if let a1 = raw.audio, let f = dumpRawAudio(raw, a1, from: src.start, to: src.end) { rawAudioFile = f; a += ["-f", "s16le", "-ar", "\(a1.rate)", "-ac", "\(a1.channels)", "-i", f.path] }
                } else { if src.start > 0 { a += ["-ss", String(format: "%.6f", src.start)] }; a += ["-i", path] }
            }
        }
        let aIn = direct ? 0 : 1
        let hasAudio = s.audio != .none && (src.raw == nil || rawAudioFile != nil)
        // vidéo
        var v: [String] = ["-map", "0:v:0"]
        if direct {
            var vf: [String] = []
            if s.width > 0 {
                vf.append(s.pad ? "scale='min(\(ow),iw)':'min(\(oh),ih)':force_original_aspect_ratio=decrease:flags=bicubic,pad=\(ow):\(oh):(ow-iw)/2:(oh-ih)/2" : "scale=\(ow):\(oh):flags=bicubic")
            }
            if s.fps > 0 { vf.append("fps=\(num)/\(den)") }
            if !vf.isEmpty { v += ["-vf", vf.joined(separator: ",")] }
        } else if s.fps > 0 || true { v += [] }
        v += ["-c:v", "dnxhd"]
        switch s.codec {
        case .dnxhdHQ: v += ["-b:v", "\(s.codec.dnxhdRate(fps: outFps) ?? 145)M", "-pix_fmt", "yuv422p"]
        case .dnxhdHQX: v += ["-b:v", "\(s.codec.dnxhdRate(fps: outFps) ?? 220)M", "-pix_fmt", "yuv422p10le"]
        case .dnxhrHQX: v += ["-profile:v", "dnxhr_hqx", "-pix_fmt", "yuv422p10le"]
        case .dnxhr444: v += ["-profile:v", "dnxhr_444", "-pix_fmt", "yuv444p10le"]
        default: v += ["-profile:v", s.codec.ffProfile, "-pix_fmt", "yuv422p"]
        }
        v += ["-threads", "0"]
        if s.wrap != .mxfAtom { v += ["-timecode", Timecode.string(frames: tcStart, fps: meta.tcFps)] }
        v += ["-t", String(format: "%.6f", span)]
        var au: [String] = []
        if hasAudio {
            au += ["-map", "\(aIn):a:0", "-c:a", "pcm_s24le", "-ar", "48000"]
            if s.audio == .all && s.wrap != .mxfAtom { au = ["-map", "\(aIn):a?", "-c:a", "pcm_s24le", "-ar", "48000"] }
            if s.channels == .stereo { au += ["-ac", "2"] } else if s.channels == .mono { au += ["-ac", "1"] }
        }
        if s.wrap == .mxfAtom {
            a += v + ["-f", "mxf_opatom", part.path]
            if hasAudio {   // OP-Atom : un fichier audio mono par canal (A1, A2)
                let native = src.asset.flatMap { asset in (try? syncLoad(asset, .audio))?.first }.flatMap { try? syncChannels($0) } ?? 2
                let n = s.channels == .mono ? 1 : min(2, max(1, native))
                for ch in 0..<n {
                    a += ["-map", "\(aIn):a:0", "-af", "pan=mono|c0=c\(min(ch, max(0, native - 1)))", "-c:a", "pcm_s24le", "-ar", "48000", "-t", String(format: "%.6f", span), "-f", "mxf_opatom", audioPart(part, ch + 1).path]
                }
            }
        } else {
            a += v + (hasAudio ? au : ["-an"]) + ["-f", s.wrap == .mxf ? "mxf" : "mov", part.path]
        }
        if direct { a.insert(contentsOf: ["-progress", "pipe:1"], at: 2) }

        let p = Process()
        p.executableURL = ff; p.arguments = a
        let errFile = FileManager.default.temporaryDirectory.appendingPathComponent("kynedit-ff-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errFile.path, contents: nil)
        let errH = try FileHandle(forWritingTo: errFile)
        p.standardError = errH
        let outPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = direct ? outPipe : FileHandle.nullDevice
        p.standardInput = direct ? FileHandle.nullDevice : inPipe
        proc = p
        if direct {
            outPipe.fileHandleForReading.readabilityHandler = { h in
                guard let t = String(data: h.availableData, encoding: .utf8) else { return }
                for l in t.split(separator: "\n") where l.hasPrefix("out_time_us=") { if let us = Double(l.dropFirst(12)) { progress(min(0.999, us / 1e6 / span)) } }
            }
        }
        try p.run()
        defer { try? errH.close(); try? FileManager.default.removeItem(at: errFile); outPipe.fileHandleForReading.readabilityHandler = nil }
        if !direct {
            let w = inPipe.fileHandleForWriting
            let tight = sixteen && s.codec != .dnxhr444
            let pixel: OSType = tight ? kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, [kCVPixelBufferPixelFormatTypeKey as String: pixel, kCVPixelBufferWidthKey as String: ow, kCVPixelBufferHeightKey as String: oh,
                kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pool)
            guard let pool else { throw ExportError(message: L("err.buffers")) }
            let rd = src.asset.flatMap { try? $0 }  // asset déjà ouvert
            _ = rd
            // lecteur vidéo matériel pour les images d'origine
            var vOut: AVAssetReaderTrackOutput?
            if let asset = src.asset, let vt = src.vTrack {
                let r = try AVAssetReader(asset: asset)
                r.timeRange = CMTimeRange(start: CMTime(seconds: src.start, preferredTimescale: 6000), end: CMTime(seconds: src.end, preferredTimescale: 6000))
                let o = AVAssetReaderTrackOutput(track: vt, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: src.sourceTenBit ? kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelBufferMetalCompatibilityKey as String: true])
                o.alwaysCopiesSampleData = false
                r.add(o); vOut = o; reader = r
                guard r.startReading() else { throw r.error ?? ExportError(message: L("err.read")) }
            }
            let (_, scale, _) = (0, outputScale(src, ow, oh), 0)
            try gpuLoop(src: src, vOut: vOut, ow: ow, oh: oh, scale: scale, outFps: outFps, span: span,
                        makeBuffer: { var pb: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb); return pb },
                        sink: { pb, _ in
                            CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
                            var data = Data()
                            let planes = CVPixelBufferGetPlaneCount(pb)
                            if planes == 0 {
                                let st = CVPixelBufferGetBytesPerRow(pb), base = CVPixelBufferGetBaseAddress(pb)!
                                if st == ow * 4 { data = Data(bytes: base, count: st * oh) } else { for y in 0..<oh { data.append(Data(bytes: base + y * st, count: ow * 4)) } }
                            } else {
                                for pl in 0..<planes {
                                    let st = CVPixelBufferGetBytesPerRowOfPlane(pb, pl), hh = CVPixelBufferGetHeightOfPlane(pb, pl), base = CVPixelBufferGetBaseAddressOfPlane(pb, pl)!
                                    let rowBytes = ow * 2
                                    for y in 0..<hh { data.append(Data(bytes: base + y * st, count: rowBytes)) }
                                }
                            }
                            try w.write(contentsOf: data)
                        }, report: { t in progress(min(0.999, t / span)) })
            try? w.close()
        }
        p.waitUntilExit()
        if isCancelled { throw ExportError(message: L("err.cancelled")) }
        if p.terminationStatus != 0 {
            let log = (try? String(contentsOf: errFile, encoding: .utf8)) ?? ""
            throw ExportError(message: L("err.ffmpeg") + log.split(separator: "\n").suffix(2).joined(separator: " "))
        }
    }

    /// PCM 16 bits entrelacé d'un clip RAW, écrit dans un fichier temporaire.
    fileprivate func dumpRawAudio(_ raw: RawDecoder, _ a: (channels: Int, rate: Int, bits: Int, samples: Int), from: Double, to: Double) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kynedit-raw-\(UUID().uuidString).pcm")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        defer { try? h.close() }
        var pos = Int(from * Double(a.rate)); let end = min(Int(to * Double(a.rate)), a.samples)
        let bps = a.bits / 8
        while pos < end, !isCancelled {
            guard let d = raw.readAudio(from: pos, maxSamples: min(16384, end - pos)) else { break }
            let count = d.count / bps
            var out = Data(count: count * 2)
            d.withUnsafeBytes { p in out.withUnsafeMutableBytes { o in for i in 0..<count { o[i * 2] = p[i * bps + bps - 2]; o[i * 2 + 1] = p[i * bps + bps - 1] } } }
            try? h.write(contentsOf: out)
            pos += count / a.channels
        }
        return url
    }

    /// Rewrap : les flux sont copiés tels quels dans un nouveau conteneur (très rapide, sans perte). Les sous-clips sont coupés à l'image clé précédente.
    fileprivate func runRewrap(src: Source, span: Double, part: URL, progress: @escaping @Sendable (Double) -> Void) throws {
        guard src.raw == nil else { throw ExportError(message: L("export.raw")) }
        guard let ff = FFmpegTool.ffmpeg else { throw ExportError(message: L("err.ffmpegRewrap")) }
        var a = ["-hide_banner", "-y", "-loglevel", "error", "-nostdin", "-progress", "pipe:1"]
        if src.start > 0 { a += ["-ss", String(format: "%.6f", src.start)] }
        a += ["-i", path, "-t", String(format: "%.6f", span), "-map", "0:v:0"]
        if s.audio != .none { a += ["-map", s.audio == .first ? "0:a:0?" : "0:a?"] }
        a += ["-c", "copy", "-map_metadata", "0", "-f", s.wrap == .mp4 ? "mp4" : s.wrap == .mxf ? "mxf" : "mov"]
        if s.wrap != .mp4 { a += ["-timecode", Timecode.string(frames: meta.startFrames + Int((src.start * Double(meta.tcFps)).rounded()), fps: meta.tcFps)] }
        a.append(part.path)
        let p = Process(); p.executableURL = ff; p.arguments = a
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { h in
            guard let t = String(data: h.availableData, encoding: .utf8) else { return }
            for l in t.split(separator: "\n") where l.hasPrefix("out_time_us=") { if let us = Double(l.dropFirst(12)) { progress(min(0.999, us / 1e6 / span)) } }
        }
        proc = p
        try p.run(); p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        if isCancelled { throw ExportError(message: L("err.cancelled")) }
        if p.terminationStatus != 0 { throw ExportError(message: L("err.rewrapFail")) }
    }

    fileprivate func outputScale(_ src: Source, _ ow: Int, _ oh: Int) -> Double {
        s.width == 0 ? 1 : min(1, min(Double(s.width) / Double(src.width), Double(s.height) / Double(src.height)))
    }
}

/// Essai de conversion sans interface (KYNEDIT_HEADLESS=<préréglage>, KYNEDIT_IN=<fichier>, KYNEDIT_OUT=<dossier>, KYNEDIT_RESULT=<fichier journal>).
enum HeadlessConvert {
    @MainActor static func startIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if let src = env["KYNEDIT_OFFLOAD"], let outs = env["KYNEDIT_OUT"], let resPath = env["KYNEDIT_RESULT"] {   // essai de copie vérifiée
            Task { @MainActor in
                let m = OffloadModel(); m.source = URL(fileURLWithPath: src); m.destinations = outs.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
                m.run(); try? await Task.sleep(for: .milliseconds(300))
                while m.running { try? await Task.sleep(for: .milliseconds(200)) }
                try? ("\(m.done)/\(m.total) " + m.results.map { "\($0.file):\($0.ok):\($0.note)" }.joined(separator: ",")).write(toFile: resPath, atomically: true, encoding: .utf8)
                exit(0)
            }
            return
        }
        guard let id = env["KYNEDIT_HEADLESS"], let inPath = env["KYNEDIT_IN"], let outDir = env["KYNEDIT_OUT"], let resPath = env["KYNEDIT_RESULT"] else { return }
        Task { @MainActor in
            func log(_ m: String) { if let h = FileHandle(forWritingAtPath: resPath) { h.seekToEndOfFile(); h.write((m + "\n").data(using: .utf8)!); try? h.close() } else { try? (m + "\n").write(toFile: resPath, atomically: false, encoding: .utf8) } }
            guard var st = Presets.builtin.first(where: { $0.id == id })?.settings else { log("préréglage inconnu"); exit(2) }
            if let l = env["KYNEDIT_LUT"] { st.lutPath = l }
            if let f = env["KYNEDIT_CONVERT_FPS"], let v = Double(f) { st.fps = v }
            if env["KYNEDIT_CONVERT_BURN"] != nil { st.burn = [BurnItem(field: .timecode, pos: .bl), BurnItem(field: .clipName, pos: .tl)] }
            if env["KYNEDIT_ASSEMBLE"] != nil { st.assemble = true }
            let urls = inPath.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
            let url = urls[0]
            let list = urls.map { Clip(path: $0.path, name: $0.lastPathComponent, ext: $0.pathExtension.lowercased(), size: 0, mtime: 0, kind: .video) }
            let q = ExportQueue()
            q.jobs.removeAll()
            let t0 = Date()
            await q.addConvert(clips: list, settings: st, outputDir: outDir, root: url.deletingLastPathComponent().path, subclips: { _ in [] })
            while q.pendingCount > 0 { try? await Task.sleep(for: .milliseconds(200)) }
            for j in q.jobs { log("\(id) : \(j.state.rawValue) \(String(format: "%.2f", Date().timeIntervalSince(t0))) s \(j.error ?? "") \(j.outputPath ?? "")") }
            exit(0)
        }
    }
}
