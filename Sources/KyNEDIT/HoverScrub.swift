import SwiftUI
import AVFoundation

/// Défilement au survol : la position horizontale du pointeur sur la vignette choisit l'image affichée.
/// Images extraites à la demande (image clé la plus proche, petite taille), mises en cache par tranche de 1/40 de la durée.
@MainActor @Observable
final class HoverScrub {
    private(set) var image: CGImage?
    private(set) var fraction: Double = 0
    private final class Gen: @unchecked Sendable { let g: AVAssetImageGenerator; init(_ g: AVAssetImageGenerator) { self.g = g } }
    private var generator: Gen?
    private var cache: [Int: CGImage] = [:]
    private var task: Task<Void, Never>?
    private let steps = 40

    func move(clip: Clip, duration: Double, fraction f: Double) {
        guard duration > 0, !clip.isRaw, clip.kind == .video else { return }
        fraction = min(max(f, 0), 1)
        let bucket = min(steps - 1, Int(fraction * Double(steps)))
        if let c = cache[bucket] { image = c; return }
        if generator == nil {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: clip.path)))
            g.appliesPreferredTrackTransform = true
            g.maximumSize = CGSize(width: 480, height: 480)
            g.requestedTimeToleranceBefore = .positiveInfinity
            g.requestedTimeToleranceAfter = .positiveInfinity
            generator = Gen(g)
        }
        guard let gen = generator else { return }
        task?.cancel()
        task = Task {
            let t = CMTime(seconds: duration * (Double(bucket) + 0.5) / Double(steps), preferredTimescale: 600)
            if let img = try? await gen.g.image(at: t).image, !Task.isCancelled { cache[bucket] = img; image = img }
        }
    }

    func end() { task?.cancel(); generator?.g.cancelAllCGImageGeneration(); image = nil }
}
