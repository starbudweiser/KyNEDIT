import SwiftUI
import AppKit

@MainActor @Observable
final class AppModel {
    let catalog = Catalog()
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

    init() { reloadVolumes() }

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
            let total = await MediaScanner.scan(root: url, catalog: catalog, scanID: id) { n in
                Task { @MainActor in
                    self.scanned = n
                    if n - self.lastRefresh >= 5000 { self.lastRefresh = n; self.refresh() } // liste vivante pendant l'analyse
                }
            }
            scanning = false
            refresh()
            if let out = ProcessInfo.processInfo.environment["KYNEDIT_BENCH"] { // banc d'essai (essais uniquement)
                let scanT = Date().timeIntervalSince(t0)
                let t1 = Date(); let all = await catalog.list(root: url.path, query: "")
                let listT = Date().timeIntervalSince(t1)
                let t2 = Date(); let hits = await catalog.list(root: url.path, query: "door")
                let searchT = Date().timeIntervalSince(t2)
                let line = String(format: "fichiers=%d scan=%.2fs liste(%d)=%.3fs recherche(door)=%d en %.3fs\n", total, scanT, all.count, listT, hits.count, searchT)
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
