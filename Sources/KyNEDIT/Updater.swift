// kYNEDIT — mise à jour depuis les releases GitHub : recherche quotidienne, téléchargement, vérification de la signature, remplacement.
import Foundation
import AppKit
import SwiftUI

@MainActor @Observable
final class Updater {
    static let shared = Updater()

    enum State: Equatable {
        case idle, checking, upToDate
        case available(version: String)
        case downloading
        case failed(String)
    }

    static let repo = "starbudweiser/kynedit"
    static let teamID = "35KLMK53PN"                   // seule signature acceptée pour une mise à jour
    private let interval: TimeInterval = 24 * 3600

    private(set) var state: State = .idle
    /// Renseigné par l'interface : vrai tant qu'un export tourne (jamais d'installation à ce moment-là).
    var isBusy: () -> Bool = { false }
    private var assetURL: URL?
    private var checking = false

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static var autoUpdate: Bool {
        get { UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoUpdate") }
    }

    /// Appelé régulièrement : une recherche par jour, et installation automatique dès qu'aucun export ne tourne.
    func tick() {
        let last = UserDefaults.standard.object(forKey: "updateLastCheck") as? Date ?? .distantPast
        if (state == .idle || state == .upToDate), Date().timeIntervalSince(last) > interval, Self.autoUpdate {
            Task { await check() }
        }
        if Self.autoUpdate, !isBusy(), case .available = state { Task { await install() } }
    }

    func check() async {
        guard !checking, state != .downloading else { return }
        checking = true; state = .checking
        defer { checking = false }
        do {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 20
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { throw UpdateError.noRelease }
            UserDefaults.standard.set(Date(), forKey: "updateLastCheck")
            let assets = json["assets"] as? [[String: Any]] ?? []
            let zip = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
            guard VersionCompare.isNewer(tag, than: currentVersion) else { state = .upToDate; return }
            guard let s = zip?["browser_download_url"] as? String, let url = URL(string: s) else { throw UpdateError.noRelease }
            assetURL = url
            state = .available(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Télécharge la nouvelle version, vérifie sa signature, puis remplace l'appli et la relance.
    func install() async {
        guard case .available(let version) = state, let url = assetURL else { return }
        guard !isBusy() else { return }                              // jamais pendant un traitement
        state = .downloading
        do {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("kYNEDIT-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let (tmp, resp) = try await URLSession.shared.download(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.download }
            let zip = work.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: tmp, to: zip)
            let out = work.appendingPathComponent("out")
            try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
            let app = out.appendingPathComponent("kYNEDIT.app")
            try await Self.verify(app, current: currentVersion)
            guard !isBusy() else { state = .available(version: version); return }   // un export a démarré entre-temps
            try Self.swapAndRelaunch(new: app, work: work)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    enum UpdateError: LocalizedError {
        case noRelease, download, badSignature, badVersion
        var errorDescription: String? {
            switch self {
            case .noRelease: return L("upd.err.none")
            case .download: return L("upd.err.download")
            case .badSignature: return L("upd.err.signature")
            case .badVersion: return L("upd.err.version")
            }
        }
    }

    /// La nouvelle appli doit être valide, signée par la même équipe et plus récente.
    private static func verify(_ app: URL, current: String) async throws {
        try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        let info = try await run("/usr/bin/codesign", ["-dv", "--verbose=2", app.path])
        guard info.contains("TeamIdentifier=\(teamID)") else { throw UpdateError.badSignature }
        guard let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              plist["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              let v = plist["CFBundleShortVersionString"] as? String,
              VersionCompare.isNewer(v, than: current) else { throw UpdateError.badVersion }
    }

    /// Un petit script détaché attend la fin de l'appli, remplace le paquet puis relance la nouvelle version.
    private static func swapAndRelaunch(new: URL, work: URL) throws {
        let target = Bundle.main.bundlePath
        let script = work.appendingPathComponent("swap.sh")
        let body = """
        #!/bin/sh
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
        rm -rf "\(target)" && /usr/bin/ditto "\(new.path)" "\(target)" && /usr/bin/open -g "\(target)"
        rm -rf "\(work.path)"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
    }

    @discardableResult
    private static func run(_ exe: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process(), pipe = Pipe()
                p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
                p.standardOutput = pipe; p.standardError = pipe
                do { try p.run() } catch { cont.resume(throwing: error); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self)
                if p.terminationStatus == 0 { cont.resume(returning: text) }
                else { cont.resume(throwing: exe.hasSuffix("codesign") ? UpdateError.badSignature : UpdateError.download) }
            }
        }
    }
}

enum VersionCompare {
    /// Vrai si `a` est strictement plus récent que `b` (comparaison numérique, « v » initial ignoré).
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}

/// Réglages (⌘,) : mises à jour.
struct SettingsView: View {
    @State private var updater = Updater.shared
    @State private var auto = Updater.autoUpdate

    private var status: String {
        switch updater.state {
        case .idle: L("upd.version", updater.currentVersion)
        case .checking: L("upd.checking")
        case .upToDate: L("upd.uptodate", updater.currentVersion)
        case .available(let v): L("upd.available", v)
        case .downloading: L("upd.downloading")
        case .failed(let e): L("upd.failed", e)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("upd.title")).font(.system(size: 13, weight: .semibold)).foregroundColor(Socle.textStrong)
            Toggle(L("upd.auto"), isOn: $auto).toggleStyle(.checkbox).font(.system(size: 12)).foregroundColor(Socle.text)
                .onChange(of: auto) { _, v in Updater.autoUpdate = v }
            HStack(spacing: 8) {
                button(L("upd.check")) { Task { await updater.check() } }
                    .disabled(updater.state == .checking || updater.state == .downloading)
                if case .available(let v) = updater.state {
                    button(L("upd.install", v), main: true) { Task { await updater.install() } }.disabled(updater.isBusy())
                }
            }
            Text(status).font(.system(size: 11)).foregroundColor(Socle.subtle)
            if case .available = updater.state, updater.isBusy() { Text(L("upd.busy")).font(.system(size: 11)).foregroundColor(Socle.subtle) }
        }
        .padding(20).frame(width: 460, alignment: .leading).background(Socle.bg).preferredColorScheme(.dark)
    }
}
