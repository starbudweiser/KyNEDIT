import SwiftUI
import AppKit
import CryptoKit

/// Copie vérifiée (sauvegarde de cartes caméra) : lit la source une seule fois, écrit vers 1 à 4 destinations en parallèle,
/// calcule la somme MD5 à la lecture puis relit chaque copie pour la comparer. Écrit une liste de hachage MHL par destination.
@MainActor @Observable
final class OffloadModel {
    struct Result: Identifiable { let id = UUID(); let file: String; let ok: Bool; let note: String }
    var source: URL?
    var destinations: [URL] = []
    var verify = true
    var incremental = true
    var writeMHL = true
    var running = false
    var done = 0
    var total = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var current = ""
    var results: [Result] = []
    var finished = false
    private var cancelled = false

    func chooseSource() { if let u = pick() { source = u; destinations.removeAll { $0 == u } } }
    func addDestination() { if destinations.count < 4, let u = pick(), !destinations.contains(u), u != source { destinations.append(u) } }
    private func pick() -> URL? {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        return p.runModal() == .OK ? p.url : nil
    }
    func cancel() { cancelled = true }

    func run() {
        guard let source, !destinations.isEmpty, !running else { return }
        running = true; finished = false; cancelled = false; results = []; done = 0; bytesDone = 0; current = ""
        let dests = destinations.map { $0.appendingPathComponent(source.lastPathComponent, isDirectory: true) }
        let verify = verify, incremental = incremental, mhl = writeMHL
        Task.detached(priority: .userInitiated) { [self] in
            let files = Self.list(source)
            await MainActor.run { total = files.count; bytesTotal = files.reduce(0) { $0 + $1.size } }
            let start = Date()
            var entries: [[(String, Int64, Date, String)]] = Array(repeating: [], count: dests.count)
            for f in files {
                if await MainActor.run(body: { cancelled }) { break }
                await MainActor.run { current = f.rel }
                let r = Self.copy(f, to: dests, incremental: incremental, verify: verify) { n in Task { @MainActor in self.bytesDone += n } }
                for (i, e) in r.entries.enumerated() { if let e { entries[i].append(e) } }
                await MainActor.run { done += 1; results.append(Result(file: f.rel, ok: r.ok, note: r.note)) }
            }
            if mhl { for (i, d) in dests.enumerated() where !entries[i].isEmpty { Self.writeMHL(entries[i], at: d, start: start) } }
            await MainActor.run { running = false; finished = true; current = "" }
        }
    }

    struct Item: Sendable { let rel: String; let url: URL; let size: Int64; let mtime: Date }

    nonisolated static func list(_ root: URL) -> [Item] {
        var out: [Item] = []
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]), v.isRegularFile == true else { continue }
            out.append(Item(rel: String(u.path.dropFirst(root.path.count + 1)), url: u, size: Int64(v.fileSize ?? 0), mtime: v.contentModificationDate ?? Date()))
        }
        return out.sorted { $0.rel < $1.rel }
    }

    /// Copie un fichier vers toutes les destinations (source lue une fois), puis vérifie chaque copie.
    nonisolated static func copy(_ f: Item, to dests: [URL], incremental: Bool, verify: Bool, progress: @escaping @Sendable (Int64) -> Void) -> (ok: Bool, note: String, entries: [(String, Int64, Date, String)?]) {
        let fm = FileManager.default
        var targets: [(Int, URL)] = []
        var entries: [(String, Int64, Date, String)?] = Array(repeating: nil, count: dests.count)
        var skipped = 0
        for (i, d) in dests.enumerated() {
            let t = d.appendingPathComponent(f.rel)
            try? fm.createDirectory(at: t.deletingLastPathComponent(), withIntermediateDirectories: true)
            if incremental, let a = try? fm.attributesOfItem(atPath: t.path), (a[.size] as? Int64) == f.size, let m = a[.modificationDate] as? Date, abs(m.timeIntervalSince(f.mtime)) < 1 {
                skipped += 1; progress(f.size); continue
            }
            targets.append((i, t))
        }
        if targets.isEmpty { return (true, L("off.r.skipped"), entries) }
        guard let input = try? FileHandle(forReadingFrom: f.url) else { return (false, L("off.r.readFail"), entries) }
        defer { try? input.close() }
        var outs: [(Int, URL, FileHandle)] = []
        for (i, t) in targets {
            fm.createFile(atPath: t.path + ".part", contents: nil)
            guard let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: t.path + ".part")) else { return (false, L("off.r.writeFail"), entries) }
            outs.append((i, t, h))
        }
        var md5 = Insecure.MD5()
        let chunk = 8 << 20
        var failed = false
        while true {
            guard let data = try? input.read(upToCount: chunk), !data.isEmpty else { break }
            md5.update(data: data)
            let g = DispatchGroup()
            nonisolated(unsafe) var werr = false
            for o in outs { g.enter(); DispatchQueue.global(qos: .userInitiated).async { do { try o.2.write(contentsOf: data) } catch { werr = true }; g.leave() } }
            g.wait()
            if werr { failed = true; break }
            progress(Int64(data.count))
        }
        let hash = md5.finalize().map { String(format: "%02x", $0) }.joined()
        var problems: [String] = []
        for o in outs {
            try? o.2.close()
            if failed { try? fm.removeItem(atPath: o.1.path + ".part"); problems.append(L("off.r.write")); continue }
            try? fm.removeItem(at: o.1)
            do { try fm.moveItem(atPath: o.1.path + ".part", toPath: o.1.path) } catch { problems.append(L("off.r.rename")); continue }
            try? fm.setAttributes([.modificationDate: f.mtime], ofItemAtPath: o.1.path)
        }
        if verify && !failed {   // relecture de chaque copie en parallèle
            let g = DispatchGroup(); let lock = NSLock()
            for o in outs {
                g.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let ok = Self.md5(of: o.1) == hash
                    lock.lock(); if !ok { problems.append(L("off.r.mismatch")) }; lock.unlock()
                    g.leave()
                }
            }
            g.wait()
        }
        if problems.isEmpty { for o in outs { entries[o.0] = (f.rel, f.size, f.mtime, hash) } }
        return (problems.isEmpty, problems.isEmpty ? (verify ? L("off.r.verified") : L("off.r.copied")) : problems.joined(separator: ", "), entries)
    }

    nonisolated static func md5(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var md5 = Insecure.MD5()
        while let d = try? h.read(upToCount: 8 << 20), !d.isEmpty { md5.update(data: d) }
        return md5.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func writeMHL(_ rows: [(String, Int64, Date, String)], at dir: URL, start: Date) {
        let iso = ISO8601DateFormatter()
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        var x = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<hashlist version=\"1.0\">\n <creatorinfo>\n  <name>\(esc(NSFullUserName()))</name>\n  <username>\(esc(NSUserName()))</username>\n  <hostname>\(esc(ProcessInfo.processInfo.hostName))</hostname>\n  <tool>kYNEDIT</tool>\n  <startdate>\(iso.string(from: start))</startdate>\n  <finishdate>\(iso.string(from: Date()))</finishdate>\n </creatorinfo>\n"
        for r in rows { x += " <hash>\n  <file>\(esc(r.0))</file>\n  <size>\(r.1)</size>\n  <lastmodificationdate>\(iso.string(from: r.2))</lastmodificationdate>\n  <md5>\(r.3)</md5>\n  <hashdate>\(iso.string(from: Date()))</hashdate>\n </hash>\n" }
        x += "</hashlist>\n"
        let name = "\(dir.lastPathComponent)_\(Int(start.timeIntervalSince1970)).mhl"
        try? x.write(to: dir.deletingLastPathComponent().appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}

struct OffloadView: View {
    @Bindable var m: OffloadModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SCard(title: L("off.source")) {
                    HStack(spacing: 12) {
                        Text(m.source?.path ?? "—").font(.system(size: 12)).foregroundColor(Socle.text).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        SLink(title: L("export.choose")) { m.chooseSource() }
                    }.frame(minHeight: UI.rowHeight)
                }
                SCard(title: L("off.dest")) {
                    ForEach(m.destinations, id: \.self) { d in
                        HStack(spacing: 12) {
                            Text(d.path).font(.system(size: 12)).foregroundColor(Socle.text).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            SLink(title: "✕") { m.destinations.removeAll { $0 == d } }
                        }.frame(minHeight: UI.rowHeight)
                    }
                    if m.destinations.count < 4 { SLink(title: L("off.add")) { m.addDestination() } }
                }
                SCard(title: L("off.options")) {
                    SCheck(title: L("off.verify"), isOn: $m.verify)
                    SCheck(title: L("off.incremental"), isOn: $m.incremental)
                    SCheck(title: L("off.mhl"), isOn: $m.writeMHL)
                }
                HStack(spacing: 14) {
                    if m.running { button(L("off.cancel")) { m.cancel() } } else { button(L("off.run"), main: true) { m.run() } }
                    if m.total > 0 {
                        ProgressView(value: m.bytesTotal > 0 ? Double(m.bytesDone) / Double(m.bytesTotal) : 0).tint(Socle.action).frame(maxWidth: 320)
                        Text(L("off.progress", m.done, m.total)).font(.system(size: 12)).foregroundColor(Socle.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.frame(minHeight: 32)
                if !m.current.isEmpty { Text(m.current).font(.system(size: 11)).foregroundColor(Socle.subtle).lineLimit(1).truncationMode(.middle) }
                if m.finished {
                    let bad = m.results.filter { !$0.ok }
                    Text(bad.isEmpty ? L("off.done") : L("off.errors", bad.count)).font(.system(size: 12, weight: .semibold)).foregroundColor(bad.isEmpty ? Color(hex: 0x4ADE80) : Color(hex: 0xF87171))
                    ForEach(bad) { r in Text("\(r.file) : \(r.note)").font(.system(size: 11)).foregroundColor(Color(hex: 0xF87171)).lineLimit(2) }
                }
            }.padding(28).frame(maxWidth: 800, alignment: .leading).frame(maxWidth: .infinity)
        }.background(Socle.bg)
    }
}
