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
        if ["braw", "r3d", "ari", "arx", "crm"].contains((path as NSString).pathExtension.lowercased()) { throw ExportError(message: L("export.raw")) }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError(message: "Aucune piste vidéo.") }
        let (size, fps, transform) = try await vTrack.load(.naturalSize, .nominalFrameRate, .preferredTransform)
        let total = try await asset.load(.duration).seconds
        let start = max(0, tin ?? 0), end = min(tout ?? total, total)
        guard end > start else { throw ExportError(message: "Plage vide.") }
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
        var lastError: Error = ExportError(message: "Lecture impossible.")
        for pixel in pixels {
            do {
                let written = try await attempt(asset: asset, vTrack: vTrack, size: size, fps: Double(fps), transform: transform,
                                                range: range, span: span, pixel: pixel, hevc10: hevc10, part: part, progress: progress)
                try? FileManager.default.removeItem(at: output)
                try FileManager.default.moveItem(at: part, to: output)
                // Contrôle : la durée écrite doit correspondre à la plage demandée (à 2 images près).
                let outDuration = try await AVURLAsset(url: output).load(.duration).seconds
                let fps = Double((try? await vTrack.load(.nominalFrameRate)) ?? 25)
                if abs(outDuration - written) > 2.0 / max(fps, 24) + 0.05 {
                    try? FileManager.default.removeItem(at: output)
                    throw ExportError(message: String(format: "Durée écrite %.2f s au lieu de %.2f s.", outDuration, written))
                }
                return outDuration
            } catch {
                try? FileManager.default.removeItem(at: part)
                if isCancelled { throw ExportError(message: "Annulé.") }
                lastError = error
            }
        }
        throw lastError
    }

    private func attempt(asset: AVURLAsset, vTrack: AVAssetTrack, size: CGSize, fps: Double, transform: CGAffineTransform,
                         range: CMTimeRange, span: Double, pixel: OSType, hevc10: Bool, part: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> Double {
        let reader = try AVAssetReader(asset: asset); reader.timeRange = range
        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixel])
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else { throw ExportError(message: "Format vidéo non lisible.") }
        reader.add(vOut)

        let writer = try AVAssetWriter(outputURL: part, fileType: preset.fileType)
        var settings: [String: Any] = [AVVideoCodecKey: preset.codec, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)]
        if !preset.isProRes {
            let bpp = preset == .hevc ? 0.07 : 0.12
            let bitrate = max(4_000_000, Int(size.width * size.height * max(fps, 24) * bpp))
            var props: [String: Any] = [AVVideoAverageBitRateKey: bitrate, AVVideoExpectedSourceFrameRateKey: max(fps, 24)]
            if preset == .hevc { props[AVVideoProfileLevelKey] = (hevc10 ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel) as String }
            else { props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel; props[AVVideoAllowFrameReorderingKey] = true }
            settings[AVVideoCompressionPropertiesKey] = props
        }
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        vIn.transform = transform; vIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(vIn) else { throw ExportError(message: "Réglage vidéo refusé par l'encodeur.") }
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
        } else if lutPath != nil { throw ExportError(message: "LUT illisible.") }

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
        guard reader.startReading() else { throw reader.error ?? ExportError(message: "Lecture impossible.") }
        guard writer.startWriting() else { throw writer.error ?? ExportError(message: "Écriture impossible.") }
        writer.startSession(atSourceTime: range.start)

        let startSeconds = range.start.seconds
        let videoHandler = lutHandler
        await withTaskGroup(of: Void.self) { group in
            let vPair = MediaPair(out: vOut, input: vIn)
            group.addTask { await self.pump(vPair, queue: "video", handler: videoHandler) { pts in progress(min(1, max(0, (pts - startSeconds) / span))) } }
            if let aOut, let aIn { let aPair = MediaPair(out: aOut, input: aIn); group.addTask { await self.pump(aPair, queue: "audio", handler: nil) { _ in } } }
        }
        if isCancelled { writer.cancelWriting(); throw ExportError(message: "Annulé.") }
        if reader.status == .failed { writer.cancelWriting(); throw reader.error ?? ExportError(message: "Lecture interrompue.") }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ExportError(message: "Écriture interrompue.") }
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
