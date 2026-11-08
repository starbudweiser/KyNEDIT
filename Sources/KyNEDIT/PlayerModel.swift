import SwiftUI
import AVFoundation
import CoreImage

@MainActor @Observable
final class PlayerModel {
    let player = AVPlayer()
    var clip: Clip?
    var duration = 0.0
    var time = 0.0
    var rate: Float = 0
    var fps = 25.0
    var playable = true
    var markIn: Double?
    var markOut: Double?
    var markers: [Marker] = []
    var subclips: [Subclip] = []
    var lutName: String?
    private(set) var lutURL: URL?
    /// Clip Blackmagic RAW : images décodées une à une par le SDK (AVPlayer ne lit pas ce format).
    var usesBRAW = false
    var brawImage: CGImage?
    private var braw: BRAWClipHandle?
    private var brawTask: Task<Void, Never>?
    private var playLoop: Task<Void, Never>?
    private var observer: Any?
    private let catalog: Catalog

    init(catalog: Catalog) {
        self.catalog = catalog
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = t.seconds.isFinite ? t.seconds : 0
                self.rate = self.player.rate
            }
        }
    }

    func open(_ clip: Clip, info: MediaInfo?) async {
        player.pause()
        self.clip = clip; time = 0; rate = 0; markIn = nil; markOut = nil
        fps = (info?.fps ?? 0) > 0 ? info!.fps : 25
        duration = info?.duration ?? 0
        brawTask?.cancel(); playLoop?.cancel(); braw = nil; brawImage = nil; usesBRAW = false
        if clip.rawDecodable, let handle = BRAWClipHandle(path: clip.path) {
            braw = handle; usesBRAW = true; playable = true
            fps = handle.fps > 0 ? handle.fps : 25; duration = handle.duration
            player.replaceCurrentItem(with: nil)
            markers = await catalog.markers(path: clip.path); subclips = await catalog.subclips(path: clip.path)
            showBRAWFrame(at: 0)
            return
        }
        let asset = AVURLAsset(url: URL(fileURLWithPath: clip.path))
        playable = (try? await asset.load(.isPlayable)) ?? false
        player.replaceCurrentItem(with: playable ? AVPlayerItem(asset: asset) : nil)
        if lutURL != nil { applyLUT(lutURL) }
        markers = await catalog.markers(path: clip.path)
        subclips = await catalog.subclips(path: clip.path)
    }

    func close() { player.pause(); playLoop?.cancel(); brawTask?.cancel(); braw = nil; usesBRAW = false; player.replaceCurrentItem(with: nil); clip = nil }

    // MARK: lecture
    func togglePlay() { rate != 0 ? pause() : play(1) }
    func pause() { player.pause(); rate = 0; playLoop?.cancel() }
    func play(_ r: Float) {
        guard usesBRAW else { player.rate = r; rate = r; return }
        rate = r; playLoop?.cancel()
        let wall0 = Date(), t0 = time, speed = Double(r)
        playLoop = Task { [weak self] in
            // Lecture BRAW : l'image affichée suit l'horloge ; si le décodage est plus lent, des images sont sautées.
            while let self, !Task.isCancelled, self.rate != 0 {
                let t = t0 + Date().timeIntervalSince(wall0) * speed
                if t < 0 || t > self.duration { self.pause(); self.time = max(0, min(self.duration, t)); break }
                self.time = t
                await self.decodeBRAW(at: t)
            }
        }
    }
    /// L : avance (1 → 2 → 4 ×) ; J : recule (−1 → −2 → −4 ×) ; K : pause.
    func faster() { play(rate >= 1 ? min(rate * 2, 8) : 1) }
    func reverse() { play(rate <= -1 ? max(rate * 2, -8) : -1) }
    func step(_ frames: Int) { pause(); seek(time + Double(frames) / fps) }
    private func brawIndex(_ t: Double) -> Int { max(0, min((braw?.frameCount ?? 1) - 1, Int((t * fps).rounded(.down)))) }

    /// Décode (hors du fil principal) l'image BRAW à l'instant `t` et l'affiche.
    private func decodeBRAW(at t: Double) async {
        guard let handle = braw else { return }
        let index = brawIndex(t)
        let image: CGImage? = await withCheckedContinuation { c in DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: handle.cgImage(index, scale: 2)) } }
        if let image, braw === handle { brawImage = image }
    }

    private func showBRAWFrame(at t: Double) {
        brawTask?.cancel()
        brawTask = Task { [weak self] in await self?.decodeBRAW(at: t) }
    }

    func seek(_ t: Double) {
        let c = max(0, min(t, duration > 0 ? duration : t))
        time = c
        if usesBRAW { showBRAWFrame(at: c); return }
        player.seek(to: CMTime(seconds: c, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Code temps sans les heures quand elles sont à zéro (listes étroites).
    static func shortTimecode(_ t: Double, fps: Double) -> String { let s = timecode(t, fps: fps); return s.hasPrefix("00:") ? String(s.dropFirst(3)) : s }

    var timecode: String { Self.timecode(time, fps: fps) }
    static func timecode(_ t: Double, fps: Double) -> String {
        let f = max(1, Int(fps.rounded()))
        let total = Int((t * Double(f)).rounded())
        let fr = total % f, s = (total / f) % 60, m = (total / f / 60) % 60, h = total / f / 3600
        return String(format: "%02d:%02d:%02d:%02d", h, m, s, fr)
    }

    /// Raccourcis du lecteur. Retourne true si la touche est traitée.
    func handleKey(chars: String, keyCode: UInt16, shift: Bool) -> Bool {
        guard clip != nil else { return false }
        switch keyCode {
        case 123: step(shift ? -10 : -1); return true
        case 124: step(shift ? 10 : 1); return true
        default: break
        }
        switch chars.lowercased() {
        case " ": togglePlay()
        case "k": pause()
        case "l": faster()
        case "j": reverse()
        case "i": markIn = time
        case "o": markOut = time
        case "m": addMarker()
        default: return false
        }
        return true
    }

    // MARK: marqueurs et sous-clips
    func addMarker() {
        guard let path = clip?.path else { return }
        let label = L("player.markername", markers.count + 1), t = time, catalog = catalog
        Task { let m = await catalog.addMarker(path: path, time: t, label: label); markers.append(m); markers.sort { $0.time < $1.time } }
    }
    func removeMarker(_ m: Marker) { markers.removeAll { $0.id == m.id }; let c = catalog; Task { await c.deleteMarker(id: m.id) } }

    func addSubclip() {
        guard let path = clip?.path else { return }
        let a = markIn ?? 0, b = markOut ?? duration
        guard b > a else { return }
        let name = L("player.subclipname", subclips.count + 1), catalog = catalog
        Task { let s = await catalog.addSubclip(path: path, tin: a, tout: b, name: name); subclips.append(s); subclips.sort { $0.tin < $1.tin } }
    }
    func removeSubclip(_ s: Subclip) { subclips.removeAll { $0.id == s.id }; let c = catalog; Task { await c.deleteSubclip(id: s.id) } }

    // MARK: LUT .cube
    func applyLUT(_ url: URL?) {
        lutURL = url; lutName = url?.deletingPathExtension().lastPathComponent
        guard let item = player.currentItem else { return }
        guard let url, let cube = Self.parseCube(url) else { item.videoComposition = nil; if url != nil { lutURL = nil; lutName = nil }; return }
        let size = cube.size, data = cube.data
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        item.videoComposition = AVVideoComposition(asset: item.asset, applyingCIFiltersWithHandler: { request in
            let out = request.sourceImage.clampedToExtent().applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": size, "inputCubeData": data, "inputColorSpace": space]).cropped(to: request.sourceImage.extent)
            request.finish(with: out, context: nil)
        })
    }

    /// Lit un fichier .cube 3D : (taille, données RGBA flottantes).
    nonisolated static func parseCube(_ url: URL) -> (size: Int, data: Data)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var size = 0; var floats: [Float] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("#") { continue }
            if l.hasPrefix("LUT_3D_SIZE") { size = Int(l.split(separator: " ").last ?? "") ?? 0; continue }
            let p = l.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Float($0) }
            if p.count == 3 { floats += [p[0], p[1], p[2], 1] }
        }
        guard size > 1, floats.count == size * size * size * 4 else { return nil }
        return (size, floats.withUnsafeBufferPointer { Data(buffer: $0) })
    }
}
