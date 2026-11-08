import SwiftUI
import AppKit

@MainActor @Observable
final class AppModel {
    let catalog = Catalog()
    let thumbs: ThumbService
    let player: PlayerModel
    var selected: Clip?
    var focusTick = 0 // change à chaque sélection : le panneau lecteur reprend alors le clavier (sinon la recherche le garde)
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

    /// Raccourcis clavier du lecteur : actifs quand un clip est ouvert et qu'aucun champ de texte n'a le clavier.
    func installKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let chars = e.charactersIgnoringModifiers ?? "", code = e.keyCode, flags = e.modifierFlags
            let handled: Bool = MainActor.assumeIsolated {
                guard let self, self.selected != nil, !flags.contains(.command) else { return false }
                if (NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first)?.firstResponder is NSText { return false }
                return self.player.handleKey(chars: chars, keyCode: code, shift: flags.contains(.shift))
            }
            return handled ? nil : e
        }
    }

    init() { thumbs = ThumbService(catalog: catalog); player = PlayerModel(catalog: catalog); reloadVolumes() }

    func select(_ clip: Clip) {
        selected = clip; focusTick += 1
        (NSApp.mainWindow ?? NSApp.windows.first)?.makeFirstResponder(nil) // la recherche lâche le clavier : les touches vont au lecteur
        Task { let info = await thumbs.load(clip).info; await player.open(clip, info: info) }
    }

    func deselect() { selected = nil; player.close() }

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
            if selected == nil, let name = ProcessInfo.processInfo.environment["KYNEDIT_SELECT"], let c = result.first(where: { $0.name.contains(name) }) {
                select(c) // sélection automatique pour les essais
                try? await Task.sleep(for: .seconds(1))
                if let lut = ProcessInfo.processInfo.environment["KYNEDIT_LUT"] { player.applyLUT(URL(fileURLWithPath: lut)) }
                if ProcessInfo.processInfo.environment["KYNEDIT_PLAY"] != nil { // essai : marqueur, entrée/sortie, sous-clip, lecture ×2
                    player.markIn = 0.5; player.markOut = 1.5; player.addSubclip(); player.seek(1); player.addMarker(); player.faster(); player.faster()
                }
            }
        }
    }
}
