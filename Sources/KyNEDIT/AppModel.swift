import AVFoundation
import SwiftUI
import AppKit

@MainActor @Observable
final class AppModel {
    let catalog = Catalog()
    let thumbs: ThumbService
    let player: PlayerModel
    let exports = ExportQueue()
    let convert = ConvertModel()
    let offload = OffloadModel()
    var selected: Clip?
    var selection: Set<String> = []
    var selectedInfo: MediaInfo?
    var exchangeMessage: (text: String, url: URL, nle: NLE)?
    var meta: [String: ClipMeta] = [:]
    var ratingMin = 0 { didSet { refresh() } }
    var colorFilter = 0 { didSet { refresh() } }
    var heightMin = 0 { didSet { refresh(); probeMissing() } }
    var fpsFilter = 0.0 { didSet { refresh(); probeMissing() } }
    private var probeTask: Task<Void, Never>?

    /// Lit en arrière-plan les en-têtes des vidéos du dossier (quelques-unes à la fois) pour que les filtres de résolution et de cadence les voient.
    func probeMissing() {
        guard let root, heightMin > 0 || fpsFilter > 0 else { return }
        probeTask?.cancel()
        let catalog = catalog, path = root.path
        probeTask = Task {
            let todo = await catalog.unprobed(root: path)
            var done = 0
            await withTaskGroup(of: Void.self) { g in
                var it = todo.makeIterator(), running = 0
                func next() { if let c = it.next() { running += 1; g.addTask { if let i = await Prober.probe(c) { await catalog.saveInfo(i, path: c.path, mtime: c.mtime) } } } }
                for _ in 0..<6 { next() }
                while running > 0 { await g.next(); running -= 1; done += 1; if Task.isCancelled { g.cancelAll(); return }; next(); if done % 20 == 0 { refresh() } }
            }
            if !Task.isCancelled { refresh() }
        }
    }
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
                if let sel = self.selected, let d = Int(chars), (0...8).contains(d) {
                    if d <= 5 { self.setRating(sel, d == 0 ? self.metaFor(sel).rating : d) } else { self.setColor(sel, d - 5) }
                    return true
                }
                return self.player.handleKey(chars: chars, keyCode: code, shift: flags.contains(.shift))
            }
            return handled ? nil : e
        }
    }

    init() { thumbs = ThumbService(catalog: catalog); player = PlayerModel(catalog: catalog); reloadVolumes() }

    /// Clic sur une carte : simple = ce clip seul ; Cmd = ajoute ou retire ; Maj = plage depuis le clip précédemment sélectionné.
    func click(_ clip: Clip) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(clip.path) { selection.remove(clip.path); if selected?.path == clip.path { selected = clips.first { selection.contains($0.path) } ?? nil; if selected == nil { deselect() } }; return }
            selection.insert(clip.path)
        } else if flags.contains(.shift), let a = selected, let i = clips.firstIndex(where: { $0.path == a.path }), let j = clips.firstIndex(where: { $0.path == clip.path }) {
            for c in clips[min(i, j)...max(i, j)] { selection.insert(c.path) }
        } else { selection = [clip.path] }
        select(clip)
    }

    func select(_ clip: Clip) {
        selected = clip; selection.insert(clip.path); focusTick += 1
        (NSApp.mainWindow ?? NSApp.windows.first)?.makeFirstResponder(nil) // la recherche lâche le clavier : les touches vont au lecteur
        Task { let info = await thumbs.load(clip).info; selectedInfo = info; await player.open(clip, info: info) }
    }

    // MARK: métadonnées
    func metaFor(_ clip: Clip) -> ClipMeta { meta[clip.path] ?? ClipMeta() }

    private func update(_ clip: Clip, _ change: (inout ClipMeta) -> Void, tags: Bool = false) {
        var m = metaFor(clip); change(&m); meta[clip.path] = m
        let c = catalog, path = clip.path
        Task { await c.saveMeta(path: path, rating: m.rating, color: m.color, note: m.note); if tags { await c.setTags(path: path, tags: m.tags) } }
    }
    func setRating(_ clip: Clip, _ r: Int) { update(clip) { $0.rating = ($0.rating == r ? 0 : r) } }
    func setColor(_ clip: Clip, _ c: Int) { update(clip) { $0.color = ($0.color == c ? 0 : c) } }
    func setNote(_ clip: Clip, _ n: String) { update(clip) { $0.note = n } }
    func addTag(_ clip: Clip, _ t: String) {
        let tag = t.trimmingCharacters(in: .whitespaces).lowercased()
        guard !tag.isEmpty else { return }
        update(clip, { if !$0.tags.contains(tag) { $0.tags.append(tag); $0.tags.sort() } }, tags: true)
    }
    func removeTag(_ clip: Clip, _ t: String) { update(clip, { $0.tags.removeAll { $0 == t } }, tags: true) }

    /// Ajoute un clip à la file d'export : ses sous-clips s'ils existent, sinon le clip entier (lus dans la base, pas dans le lecteur).
    func addExport(_ clip: Clip) {
        let catalog = catalog, lut = exports.useLUT ? player.lutURL?.path : nil
        Task { let subs = await catalog.subclips(path: clip.path); exports.add(clip: clip, subclips: subs, lutPath: lut) }
    }

    /// Tous les clips vidéo sélectionnés, dans l'ordre de la liste.
    func addSelectionToExport() { for c in clips where selection.contains(c.path) && c.kind == .video { addExport(c) } }

    /// Envoie les clips sélectionnés (ou le clip ouvert) vers un logiciel de montage : écrit un FCPXML ou un XML Premiere dans le dossier de sortie.
    func sendToNLE(_ nle: NLE) {
        let chosen = clips.filter { selection.contains($0.path) }
        let list = chosen.isEmpty ? (selected.map { [$0] } ?? []) : chosen
        let catalog = catalog, thumbs = thumbs, meta = meta, dir = exports.outputDir
        let title = (root?.lastPathComponent ?? "kYNEDIT").replacingOccurrences(of: "/", with: "-")
        Task {
            let items = await Exchange.collect(list, catalog: catalog, thumbs: thumbs, meta: meta)
            guard !items.isEmpty else { exchangeMessage = (L("exchange.empty"), URL(fileURLWithPath: dir), nle); return }
            do {
                let url = try Exchange.write(items, for: nle, to: dir, title: title)
                exchangeMessage = (L("exchange.created", url.lastPathComponent), url, nle)
            } catch { exchangeMessage = (error.localizedDescription, URL(fileURLWithPath: dir), nle) }
        }
    }

    /// Ouvre le fichier d'échange dans le logiciel (action explicite de l'utilisateur) ; à défaut, dans le Finder.
    func openExchange() {
        guard let m = exchangeMessage else { return }
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        if let name = apps.first(where: { n in m.nle.bundleHints.contains { n.hasPrefix($0) } }) {
            let appURL = URL(fileURLWithPath: "/Applications/" + name)
            let candidate = (try? FileManager.default.contentsOfDirectory(at: appURL, includingPropertiesForKeys: nil))?.first { $0.pathExtension == "app" } ?? appURL
            NSWorkspace.shared.open([m.url], withApplicationAt: candidate.pathExtension == "app" ? candidate : appURL, configuration: NSWorkspace.OpenConfiguration())
        } else { NSWorkspace.shared.activateFileViewerSelecting([m.url]) }
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
        let metaRoot = url.path
        Task { meta = await catalog.allMeta(root: metaRoot) }
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
        let q = query, catalog = catalog, path = root.path, rMin = ratingMin, colorF = colorFilter, hMin = heightMin, fpsF = fpsFilter
        listTask = Task {
            try? await Task.sleep(for: .milliseconds(120)) // regroupe les frappes
            if Task.isCancelled { return }
            let result = await catalog.list(root: path, query: q, ratingMin: rMin, color: colorF, minHeight: hMin, fps: fpsF)
            if !Task.isCancelled { clips = result }
            if selected == nil, let name = ProcessInfo.processInfo.environment["KYNEDIT_SELECT"], let c = result.first(where: { $0.name.contains(name) }) {
                select(c) // sélection automatique pour les essais
                try? await Task.sleep(for: .seconds(1))
                if let n = Int(ProcessInfo.processInfo.environment["KYNEDIT_MULTI"] ?? "") { for c in result.filter({ $0.kind == .video }).prefix(n) { selection.insert(c.path) } } // essai : sélection multiple
                if let lut = ProcessInfo.processInfo.environment["KYNEDIT_LUT"] { player.applyLUT(URL(fileURLWithPath: lut)) }
                if let p = ProcessInfo.processInfo.environment["KYNEDIT_EXPORT"], let preset = ExportPreset(rawValue: p) { // essai d'export
                    if let d = ProcessInfo.processInfo.environment["KYNEDIT_OUT"] { exports.outputDir = d }
                    exports.preset = preset
                    if ProcessInfo.processInfo.environment["KYNEDIT_EXPORT_LUT"] != nil { exports.useLUT = true }
                    for _ in 0..<(Int(ProcessInfo.processInfo.environment["KYNEDIT_EXPORT_N"] ?? "") ?? 1) { addExport(c) }
                }
                if let pid = ProcessInfo.processInfo.environment["KYNEDIT_CONVERT"], let pr = Presets.builtin.first(where: { $0.id == pid }) { // essai de conversion
                    var st = pr.settings
                    if let lut = ProcessInfo.processInfo.environment["KYNEDIT_LUT"] { st.lutPath = lut }
                    if let f = ProcessInfo.processInfo.environment["KYNEDIT_CONVERT_FPS"], let v = Double(f) { st.fps = v }
                    if ProcessInfo.processInfo.environment["KYNEDIT_CONVERT_BURN"] != nil { st.burn = [BurnItem(field: .timecode, pos: .bl), BurnItem(field: .clipName, pos: .tl)] }
                    let out = ProcessInfo.processInfo.environment["KYNEDIT_OUT"] ?? exports.outputDir
                    let list = ProcessInfo.processInfo.environment["KYNEDIT_MULTI"] != nil ? result.filter { selection.contains($0.path) } : [c]
                    await exports.addConvert(clips: list, settings: st, outputDir: out, root: path, subclips: { _ in [] })
                }
                if let n = ProcessInfo.processInfo.environment["KYNEDIT_EXCHANGE"], let nle = NLE(rawValue: n) { // essai d'échange
                    if let d = ProcessInfo.processInfo.environment["KYNEDIT_OUT"] { exports.outputDir = d }
                    sendToNLE(nle)
                }
                if ProcessInfo.processInfo.environment["KYNEDIT_PLAY"] != nil { // essai : marqueur, entrée/sortie, sous-clip, lecture ×2
                    player.markIn = 0.5; player.markOut = 1.5; player.addSubclip(); player.seek(1); player.addMarker(); player.faster(); player.faster()
                }
            }
        }
    }

    // MARK: shotlist et images de marqueurs

    private func csv(_ f: [String]) -> String { f.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ";") }

    /// Liste de plans (CSV ouvrable dans Excel) des clips sélectionnés, ou de tous les clips affichés : métadonnées, mots-clés, marqueurs, sous-clips.
    func exportShotlist() {
        let chosen = clips.filter { selection.contains($0.path) }
        let list = (chosen.isEmpty ? clips : chosen).filter { $0.kind != .image }
        let catalog = catalog, meta = meta, thumbs = thumbs, dir = exports.outputDir
        let name = (root?.lastPathComponent ?? "kYNEDIT")
        Task {
            var lines = [csv([L("list.name"), L("info.path"), L("info.duration"), L("info.resolution"), L("unit.fps"), L("info.codec"), L("inspector.rating"), L("inspector.label"), L("inspector.tags"), L("inspector.note"), L("player.markers"), L("player.subclips")])]
            for c in list {
                let info = await thumbs.load(c).info
                let m = meta[c.path] ?? ClipMeta()
                let marks = await catalog.markers(path: c.path).map { "\(formatDuration($0.time)) \($0.label)" }.joined(separator: " | ")
                let subs = await catalog.subclips(path: c.path).map { "\($0.name) \(formatDuration($0.tin))-\(formatDuration($0.tout))" }.joined(separator: " | ")
                lines.append(csv([c.name, c.path, info.map { formatDuration($0.duration) } ?? "", info.map { "\($0.width)x\($0.height)" } ?? "", info.map { String(format: "%.3g", $0.fps) } ?? "", info?.codec ?? "",
                                  String(m.rating), m.color > 0 ? L("label.\(m.color)") : "", m.tags.joined(separator: ", "), m.note, marks, subs]))
            }
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)_shotlist.csv")
            try? ("\u{FEFF}" + lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Une image JPEG par marqueur du clip, écrite dans le dossier de sortie.
    func exportMarkerStills(_ clip: Clip) {
        let catalog = catalog, dir = URL(fileURLWithPath: exports.outputDir, isDirectory: true)
        Task.detached {
            let marks = await catalog.markers(path: clip.path)
            guard !marks.isEmpty else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: clip.path)))
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
            let base = (clip.name as NSString).deletingPathExtension
            for (i, m) in marks.enumerated() {
                guard let img = try? await gen.image(at: CMTime(seconds: m.time, preferredTimescale: 600)).image, let d = ThumbService.jpeg(img) else { continue }
                let label = m.label.isEmpty ? "" : "_" + m.label.replacingOccurrences(of: "/", with: "-")
                try? d.write(to: dir.appendingPathComponent(String(format: "%@_%02d%@.jpg", base, i + 1, label)))
            }
            await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
        }
    }

    // MARK: renommage par lot

    var showRename = false
    var renameTemplate = UserDefaults.standard.string(forKey: "renameTemplate") ?? "{name}_{n}" { didSet { UserDefaults.standard.set(renameTemplate, forKey: "renameTemplate") } }
    var renamePreview: [(old: String, new: String)] = []

    var renameTargets: [Clip] { let c = clips.filter { selection.contains($0.path) }; return c.isEmpty ? (selected.map { [$0] } ?? []) : c }

    func updateRenamePreview() {
        let targets = renameTargets, tpl = renameTemplate
        Task {
            var out: [(String, String)] = []
            for (i, c) in targets.enumerated() { out.append((c.name, await Self.renamed(c, tpl, i + 1))) }
            renamePreview = out
        }
    }

    nonisolated static func renamed(_ c: Clip, _ tpl: String, _ n: Int) async -> String {
        let meta = await SourceMeta.load(c)
        var st = ConvertSettings(); st.template = tpl.replacingOccurrences(of: "{n}", with: String(format: "%03d", n))
        let stem = Naming.name(template: st.template, clipName: (c.name as NSString).deletingPathExtension, meta: meta, settings: st).replacingOccurrences(of: st.codec.tag, with: "")
        return c.ext.isEmpty ? stem : stem + "." + (c.name as NSString).pathExtension
    }

    func applyRename() {
        let targets = renameTargets, preview = renamePreview, catalog = catalog
        guard targets.count == preview.count else { return }
        for (c, p) in zip(targets, preview) where p.new != c.name && !p.new.isEmpty {
            let old = URL(fileURLWithPath: c.path), new = old.deletingLastPathComponent().appendingPathComponent(p.new)
            guard !FileManager.default.fileExists(atPath: new.path), (try? FileManager.default.moveItem(at: old, to: new)) != nil else { continue }
            Task { await catalog.renamePath(from: c.path, to: new.path) }
        }
        showRename = false; selection = []
        if let root { Task { try? await Task.sleep(for: .milliseconds(300)); open(root) } }
    }
}
