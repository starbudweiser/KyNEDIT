import SwiftUI
import AppKit

@MainActor @Observable
final class AppModel {
    let catalog = Catalog()
    let thumbs: ThumbService
    var gridMode = true
    var root: URL?
    var clips: [Clip] = []
    var query = "" { didSet { refresh() } }
    var scanning = false
    var scanned = 0
    var volumes: [URL] = []
    private var lastRefresh = 0
    private var scanTask: Task<Void, Never>?
    private var listTask: Task<Void, Never>?
    private var scanCounter = Int(Date().timeIntervalSince1970)

    init() { thumbs = ThumbService(catalog: catalog); reloadVolumes() }

    func reloadVolumes() {
        volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey],
                                                        options: [.skipHiddenVolumes]) ?? []
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        scanTask?.cancel()
        root = url; clips = []; scanned = 0; lastRefresh = 0; scanning = true
        scanCounter += 1
        let id = scanCounter, catalog = catalog
        refresh() // affiche tout de suite ce que le catalogue connaît déjà
        scanTask = Task {
            let t0 = Date()
            let stats = await MediaScanner.scan(root: url, catalog: catalog, scanID: id) { n in
                Task { @MainActor in
                    self.scanned = n
                    if n - self.lastRefresh >= 5000 { self.lastRefresh = n; self.refresh() } // liste vivante pendant l'analyse
                }
            }
            scanning = false
            refresh()
            if let out = ProcessInfo.processInfo.environment["KYNEDIT_THUMBS"] { // banc d'essai des vignettes (essais uniquement)
                let sample = Array(await catalog.list(root: url.path, query: "").filter { $0.kind == .video }.prefix(200))
                var lines = "clips vidéo testés : \(sample.count)\n"
                for pass in ["à froid (sonde + vignette)", "en-têtes en base, vignettes sur disque"] {
                    if pass.hasPrefix("en-têtes") { thumbs.clearMemory() }
                    let t = Date(); var ok = 0
                    await withTaskGroup(of: Bool.self) { g in
                        for c in sample { g.addTask { [thumbs] in await thumbs.load(c).jpeg != nil } }
                        for await r in g where r { ok += 1 }
                    }
                    let dt = Date().timeIntervalSince(t)
                    lines += String(format: "%@ : %d vignettes en %.2fs (%.1f ms/clip, %.0f clips/s)\n", pass, ok, dt, dt * 1000 / Double(max(sample.count, 1)), Double(sample.count) / dt)
                }
                var hist: [String: Int] = [:]; var shown = 0
                for c in sample {
                    let l = await thumbs.load(c)
                    if l.jpeg == nil {
                        let why = await thumbs.debugError(c, duration: l.info?.duration ?? 0)
                        hist["\(c.ext) | \(l.info?.codec ?? "?") | \(why)", default: 0] += 1
                        if shown < 3 { lines += "échec : \(c.name) (\(c.size / 1_000_000) Mo)\n"; shown += 1 }
                    }
                }
                for (k, v) in hist { lines += "\(v) × \(k)\n" }
                try? lines.write(toFile: out, atomically: true, encoding: .utf8)
            }
            if let out = ProcessInfo.processInfo.environment["KYNEDIT_BENCH"] { // banc d'essai (essais uniquement)
                let scanT = Date().timeIntervalSince(t0)
                let t1 = Date(); let all = await catalog.list(root: url.path, query: "")
                let listT = Date().timeIntervalSince(t1)
                let t2 = Date(); let hits = await catalog.list(root: url.path, query: "door")
                let searchT = Date().timeIntervalSince(t2)
                let walked = 0; let walkT = 0.0
                let line = String(format: "parcours seul (cache chaud)=%d en %.2fs | ", walked, walkT) + String(format: "fichiers=%d scan=%.2fs (index final %.2fs) liste(%d)=%.3fs recherche(door)=%d en %.3fs\n", stats.total, scanT, stats.finishSeconds, all.count, listT, hits.count, searchT)
                try? line.write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
    }

    func refresh() {
        guard let root else { return }
        listTask?.cancel()
        let q = query, catalog = catalog, path = root.path
        listTask = Task {
            try? await Task.sleep(for: .milliseconds(120)) // regroupe les frappes
            if Task.isCancelled { return }
            let result = await catalog.list(root: path, query: q)
            if !Task.isCancelled { clips = result }
        }
    }
}
