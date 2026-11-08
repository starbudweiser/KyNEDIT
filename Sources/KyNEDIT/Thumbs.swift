import Foundation
import AVFoundation
import ImageIO
import AppKit
import UniformTypeIdentifiers

/// Limite le nombre de tâches lourdes simultanées (vignettes). Sera réglé par le profil matériel (étape 5).
actor AsyncLimiter {
    private var free: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ n: Int) { free = n }
    func acquire() async {
        if free > 0 { free -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { free += 1 } else { waiters.removeFirst().resume() }
    }
}

struct Loaded: Sendable { var jpeg: Data?; var info: MediaInfo? }

/// Vignettes et en-têtes des clips : cache mémoire, cache disque (JPEG), puis génération (décodage matériel pour la vidéo).
final class ThumbService: @unchecked Sendable {
    private let catalog: Catalog
    private let memory = NSCache<NSString, NSData>()
    private let infoMemory = NSCache<NSString, InfoBox>()
    private let limiter = AsyncLimiter(Scheduler.thumbSlots)
    private let dir: URL
    static let maxSide = 480

    final class InfoBox { let info: MediaInfo?; init(_ i: MediaInfo?) { info = i } }

    init(catalog: Catalog) {
        self.catalog = catalog
        memory.totalCostLimit = 256 * 1024 * 1024
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("kYNEDIT/thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func key(_ c: Clip) -> String {
        // FNV-1a 64 bits de chemin + date + taille : une modification du fichier invalide la vignette.
        var h: UInt64 = 0xcbf29ce484222325
        for b in "\(c.path)|\(c.mtime)|\(c.size)".utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// Diagnostic (banc d'essai) : motif de l'échec de la vignette d'un clip.
    func debugError(_ clip: Clip, duration: Double) async -> String {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: clip.path)))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: Self.maxSide, height: Self.maxSide)
        gen.requestedTimeToleranceBefore = .positiveInfinity; gen.requestedTimeToleranceAfter = .positiveInfinity
        do { _ = try await gen.image(at: CMTime(seconds: duration * 0.1, preferredTimescale: 600)); return "ok au 2e essai" }
        catch { return "\(error.localizedDescription)" }
    }

    func clearMemory() { memory.removeAllObjects(); infoMemory.removeAllObjects() }

    func load(_ clip: Clip) async -> Loaded {
        if clip.isRaw && !clip.rawDecodable { return Loaded() } // pas de décodeur RAW : inutile d'essayer AVFoundation et ffmpeg
        let k = key(clip)
        // 1. en-têtes : mémoire puis base
        var info: MediaInfo?
        if let box = infoMemory.object(forKey: k as NSString) { info = box.info }
        else {
            if let cached = await catalog.info(path: clip.path, mtime: clip.mtime) { info = cached }
            else if Task.isCancelled { return Loaded() }
            else {
                await limiter.acquire()
                info = await Prober.probe(clip)
                await limiter.release()
                if let info { await catalog.saveInfo(info, path: clip.path, mtime: clip.mtime) }
            }
            infoMemory.setObject(InfoBox(info), forKey: k as NSString)
        }
        if Task.isCancelled { return Loaded(jpeg: nil, info: info) }
        // 2. vignette : mémoire, disque, génération
        if let d = memory.object(forKey: k as NSString) { return Loaded(jpeg: d as Data, info: info) }
        let file = dir.appendingPathComponent(k + ".jpg")
        if let d = try? Data(contentsOf: file) { memory.setObject(d as NSData, forKey: k as NSString, cost: d.count); return Loaded(jpeg: d, info: info) }
        guard clip.kind != .audio else { return Loaded(jpeg: nil, info: info) }
        await limiter.acquire()
        defer { Task { await limiter.release() } }
        if Task.isCancelled { return Loaded(jpeg: nil, info: info) }
        var data: Data?
        if let cg = await generate(clip, info: info) { data = Self.jpeg(cg) }
        // repli ffmpeg quand AVFoundation ne sait pas décoder le format
        if data == nil, clip.kind == .video {
            data = await FFmpegTool.thumbnail(clip.path, time: (info?.duration ?? 0) * 0.1, side: Self.maxSide)
        }
        guard let data else { return Loaded(jpeg: nil, info: info) }
        try? data.write(to: file, options: .atomic)
        memory.setObject(data as NSData, forKey: k as NSString, cost: data.count)
        return Loaded(jpeg: data, info: info)
    }

    /// Image RAW (BRAW, R3D) : décodée par le SDK à l'échelle 1/8, puis réduite à la taille des vignettes.
    private func generateRaw(_ clip: Clip, info: MediaInfo?) -> CGImage? {
        guard let h = Raw.open(clip.path), h.frameCount > 0 else { return nil }
        let index = min(h.frameCount - 1, Int(Double(h.frameCount) * 0.1))
        guard let big = h.cgImage(index, scale: 3) else { return nil }
        let side = Self.maxSide, scale = Double(side) / Double(max(big.width, big.height))
        if scale >= 1 { return big }
        let w = max(1, Int(Double(big.width) * scale)), hh = max(1, Int(Double(big.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: hh, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return big }
        ctx.interpolationQuality = .high
        ctx.draw(big, in: CGRect(x: 0, y: 0, width: w, height: hh))
        return ctx.makeImage()
    }

    private func generate(_ clip: Clip, info: MediaInfo?) async -> CGImage? {
        if clip.isRaw { return generateRaw(clip, info: info) }
        let url = URL(fileURLWithPath: clip.path)
        let side = Self.maxSide
        if clip.kind == .image {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side] as CFDictionary)
        }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: side, height: side)
        gen.requestedTimeToleranceBefore = .positiveInfinity // image clé la plus proche : bien plus rapide
        gen.requestedTimeToleranceAfter = .positiveInfinity
        let t = CMTime(seconds: (info?.duration ?? 0) * 0.1, preferredTimescale: 600)
        return try? await gen.image(at: t).image
    }

    static func jpeg(_ cg: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
