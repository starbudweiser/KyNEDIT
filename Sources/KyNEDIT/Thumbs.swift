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
    private let limiter = AsyncLimiter(max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
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

    func load(_ clip: Clip) async -> Loaded {
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
        guard let cg = await generate(clip, info: info), let data = Self.jpeg(cg) else { return Loaded(jpeg: nil, info: info) }
        try? data.write(to: file, options: .atomic)
        memory.setObject(data as NSData, forKey: k as NSString, cost: data.count)
        return Loaded(jpeg: data, info: info)
    }

    private func generate(_ clip: Clip, info: MediaInfo?) async -> CGImage? {
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
