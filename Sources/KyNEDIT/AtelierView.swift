import SwiftUI
import AVFoundation
import AppKit

/// Un passage élagué : plage d'un clip à conserver, exportée sans réencodage.
struct TrimItem: Identifiable, Equatable {
    let id = UUID()
    var clip: Clip
    var tin: Double
    var tout: Double
    var fps: Double
    var wrap: Wrap { ["mp4", "m4v"].contains(clip.ext) ? .mp4 : clip.ext == "mxf" ? .mxf : .mov }
    var duration: Double { tout - tin }
    /// Remplaçable seulement si le conteneur reste le même et si ce clip n'a qu'un passage dans le lot (sinon le 2e passage lirait un original déjà remplacé).
    func canReplace(in items: [TrimItem]) -> Bool { ["mov", "mp4", "m4v", "mxf"].contains(clip.ext) && items.filter { $0.clip.path == clip.path }.count == 1 }
}

/// Atelier : lecteur grand format et outils rapides (élagage sans réencodage, image fixe, audio seul).
/// Touches : I / O points d'entrée et de sortie, ↩ ajoute à la liste, ⌘S exporte le clip, ⇧⌘S exporte la liste.
@MainActor @Observable
final class AtelierModel {
    let player: PlayerModel
    var clips: [Clip] = []
    var index = 0
    var items: [TrimItem] = []
    var message = ""
    var replaceOriginals = false   // volontairement non mémorisé : toujours décoché au lancement
    @ObservationIgnored weak var app: AppModel?

    init(catalog: Catalog) { player = PlayerModel(catalog: catalog) }

    var current: Clip? { clips.indices.contains(index) ? clips[index] : nil }

    func add(_ new: [Clip]) {
        let have = Set(clips.map(\.path))
        let fresh = new.filter { !have.contains($0.path) && $0.kind == .video }
        guard !fresh.isEmpty else { return }
        clips += fresh
        if player.clip == nil { Task { await open(clips.count - fresh.count) } }
    }

    func add(urls: [URL]) {
        var found: [Clip] = []
        for u in urls {
            let ext = u.pathExtension.lowercased()
            guard MediaScanner.kind(of: ext) == .video else { continue }
            let a = try? FileManager.default.attributesOfItem(atPath: u.path)
            found.append(Clip(path: u.path, name: u.lastPathComponent, ext: ext, size: (a?[.size] as? Int64) ?? 0, mtime: (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, kind: .video))
        }
        add(found)
    }

    func open(_ i: Int) async {
        guard clips.indices.contains(i) else { return }
        index = i
        let c = clips[i]
        let info = await app?.thumbs.load(c).info
        await player.open(c, info: info)
    }
    func go(_ delta: Int) { let i = index + delta; if clips.indices.contains(i) { Task { await open(i) } } }

    func remove(_ clip: Clip) {
        guard let i = clips.firstIndex(of: clip) else { return }
        clips.remove(at: i); items.removeAll { $0.clip == clip }
        if clips.isEmpty { player.close(); index = 0 } else { Task { await open(min(index, clips.count - 1)) } }
    }

    private func currentItem() -> TrimItem? {
        guard let c = current, player.clip == c, player.duration > 0 else { return nil }
        let a = player.markIn ?? 0, b = player.markOut ?? player.duration
        guard b - a > 0.01 else { message = L("atelier.badrange"); return nil }
        return TrimItem(clip: c, tin: a, tout: b, fps: player.fps)
    }

    /// Ajoute le passage courant à la liste d'export, puis passe au clip suivant.
    func addCurrent() {
        guard let it = currentItem() else { return }
        items.append(it); message = L("atelier.added", it.clip.name)
        if index >= clips.count - 1 { player.markIn = nil; player.markOut = nil } else { go(1) }
    }

    /// Exporte le clip courant tout de suite (⌘S).
    func exportNow() {
        guard let it = currentItem(), let app, confirmReplace([it]) else { return }
        message = L("atelier.sent", 1)
        let rep = replaceOriginals
        Task { await app.exports.addTrims([it], outputDir: app.exports.outputDir, replace: rep) }
        go(1)
    }

    /// Envoie toute la liste à l'export (⇧⌘S).
    func exportAll() {
        guard !items.isEmpty, let app, confirmReplace(items) else { return }
        let list = items; items = []
        message = L("atelier.sent", list.count)
        let rep = replaceOriginals
        Task { await app.exports.addTrims(list, outputDir: app.exports.outputDir, replace: rep) }
    }

    /// Étape de confirmation avant de remplacer des originaux : vrai si l'export peut continuer.
    private func confirmReplace(_ list: [TrimItem]) -> Bool {
        guard replaceOriginals else { return true }
        let n = list.filter { $0.canReplace(in: list) }.count
        guard n > 0 else { return true }
        let a = NSAlert()
        a.alertStyle = .critical
        a.messageText = L("atelier.replace.title")
        a.informativeText = L("atelier.replace.body", n)
        a.addButton(withTitle: L("atelier.replace.ok"))
        a.addButton(withTitle: L("rename.cancel").capitalized)
        return a.runModal() == .alertFirstButtonReturn
    }

    /// Image fixe à la position de lecture, dans le dossier de sortie.
    func stillFrame() {
        guard let c = current, let app, !c.isRaw else { return }
        let t = player.time, dir = URL(fileURLWithPath: app.exports.outputDir, isDirectory: true)
        let name = (c.name as NSString).deletingPathExtension + "_" + PlayerModel.timecode(t, fps: player.fps).replacingOccurrences(of: ":", with: "-") + ".jpg"
        Task.detached {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: c.path)))
            gen.appliesPreferredTrackTransform = true; gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
            guard let img = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image, let d = ThumbService.jpeg(img) else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? d.write(to: dir.appendingPathComponent(name))
            await MainActor.run { self.message = L("atelier.stillSaved", name) }
        }
    }

    /// Piste audio du passage courant, copiée telle quelle (sans réencodage).
    func extractAudio() {
        guard let it = currentItem() ?? current.map({ TrimItem(clip: $0, tin: 0, tout: player.duration, fps: player.fps) }), let app, let ff = FFmpegTool.ffmpeg, !it.clip.isRaw else { return }
        let dir = URL(fileURLWithPath: app.exports.outputDir, isDirectory: true)
        let out = dir.appendingPathComponent((it.clip.name as NSString).deletingPathExtension + "_audio.mov")
        Task.detached {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let p = Process(); p.executableURL = ff
            p.arguments = ["-hide_banner", "-y", "-loglevel", "error", "-nostdin", "-ss", String(format: "%.6f", it.tin), "-i", it.clip.path, "-t", String(format: "%.6f", it.duration), "-vn", "-c:a", "copy", out.path]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            await MainActor.run { self.message = p.terminationStatus == 0 ? L("atelier.audio", out.lastPathComponent) : L("atelier.audiofail") }
        }
    }

    /// Touches de l'atelier ; retourne vrai si la touche est traitée.
    func handleKey(chars: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        if flags.contains(.command) {
            if chars.lowercased() == "s" { if flags.contains(.shift) { exportAll() } else { exportNow() }; return true }
            return false
        }
        switch keyCode {
        case 36, 76: addCurrent(); return true
        case 126: go(-1); return true
        case 125: go(1); return true
        default: return player.handleKey(chars: chars, keyCode: keyCode, shift: flags.contains(.shift))
        }
    }
}

struct AtelierView: View {
    let app: AppModel
    @State private var targeted = false
    private var m: AtelierModel { app.atelier }
    private var p: PlayerModel { app.atelier.player }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                viewer
                Divider().overlay(Socle.border)
                tools
            }
            Divider().overlay(Socle.border)
            side.frame(width: 320)
        }
        .background(Socle.bg)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for pr in providers { _ = pr.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in app.atelier.add(urls: [url]) } } } }
            return true
        }
    }

    // MARK: viewer

    private var viewer: some View {
        ZStack {
            Color.black
            if m.current == nil {
                Text(L("atelier.empty")).font(.system(size: 12)).foregroundColor(Socle.muted).multilineTextAlignment(.center).frame(maxWidth: 360)
            } else if p.usesBRAW {
                if let img = p.brawImage { Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit) }
            } else if p.playable { VideoSurface(player: p.player) }
            else { Text(L(m.current?.isRaw == true ? "player.raw" : "player.unsupported")).font(.system(size: 12)).foregroundColor(Socle.subtle) }
        }
        .overlay(alignment: .topLeading) {
            if let c = m.current {
                Text("\(m.index + 1)/\(m.clips.count)  \(c.name)").font(.system(size: 12)).foregroundColor(.white).lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 10).frame(height: 26).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4)).padding(12)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if m.current != nil {
                Text(p.timecode).font(.system(size: 20, weight: .semibold).monospacedDigit()).foregroundColor(.white)
                    .padding(.horizontal, 12).frame(height: 34).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4)).padding(12)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(targeted ? Socle.accentText : .clear, lineWidth: 2))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: outils (bas)

    private var tools: some View {
        let a = p.markIn ?? 0, b = p.markOut ?? p.duration
        return VStack(spacing: 12) {
            TrimTimeline(model: p, done: m.items.filter { $0.clip == m.current })
            HStack(spacing: 0) {
                readout(L("atelier.in"), p.markIn.map { PlayerModel.timecode($0, fps: p.fps) } ?? "—", active: p.markIn != nil)
                readout(L("atelier.out"), p.markOut.map { PlayerModel.timecode($0, fps: p.fps) } ?? "—", active: p.markOut != nil)
                readout(L("atelier.duration"), p.duration > 0 ? PlayerModel.timecode(max(0, b - a), fps: p.fps) : "—", active: true)
                Spacer(minLength: 8)
                if !m.message.isEmpty { Text(m.message).font(.system(size: 12)).foregroundColor(Socle.muted).lineLimit(1).truncationMode(.middle) }
            }
            HStack(spacing: 8) {
                tool("◀", key: "↑", help: L("atelier.prev")) { m.go(-1) }
                tool(p.rate == 0 ? "▶" : "❚❚", key: L("atelier.space"), help: L("atelier.play")) { p.togglePlay() }
                tool("▶", key: "↓", help: L("atelier.next")) { m.go(1) }
                Divider().frame(height: 20).overlay(Socle.border)
                tool(L("atelier.in"), key: "I") { p.markIn = p.time }
                tool(L("atelier.out"), key: "O") { p.markOut = p.time }
                tool(L("atelier.reset"), key: nil) { p.markIn = nil; p.markOut = nil }
                Divider().frame(height: 20).overlay(Socle.border)
                tool(L("atelier.still"), key: nil) { m.stillFrame() }
                tool(L("atelier.audioonly"), key: nil) { m.extractAudio() }
                Spacer(minLength: 8)
                tool(L("atelier.add"), key: "↩") { m.addCurrent() }
                tool(L("atelier.export"), key: "⌘S", main: true) { m.exportNow() }
            }
        }.padding(UI.gutter).background(Socle.surface)
    }

    private func readout(_ label: String, _ value: String, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 10)).tracking(0.8).foregroundColor(Socle.subtle).lineLimit(1)
            Text(value).font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundColor(active ? Socle.textStrong : Socle.subtle).lineLimit(1)
        }.frame(width: 130, alignment: .leading)
    }

    private func tool(_ title: String, key: String?, main: Bool = false, help: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 12, weight: .semibold)).tracking(title.count > 2 ? 0.5 : 0).lineLimit(1).fixedSize()
                if let key {
                    HStack(spacing: 2) {
                        if key.hasPrefix("⇧") { Image(systemName: "shift").font(.system(size: 9, weight: .bold)) }
                        Text(key.hasPrefix("⇧") ? String(key.dropFirst()) : key).font(.system(size: 10, weight: .semibold))
                    }.padding(.horizontal, 5).frame(height: 16)
                    .background((main ? Color.black : Color.white).opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                }
            }
            .padding(.horizontal, 12).frame(height: 32)
            .background(main ? Socle.action : Socle.control, in: RoundedRectangle(cornerRadius: 5))
            .foregroundColor(main ? Socle.onAction : Socle.text)
        }.buttonStyle(.plain).help(help ?? "")
    }

    // MARK: panneau de droite : clips et liste d'export

    private var side: some View {
        VStack(spacing: 0) {
            HStack { Text(L("atelier.clips").uppercased()).font(.system(size: 10.5)).tracking(0.8).foregroundColor(Socle.subtle); Spacer()
                if !app.selection.isEmpty { SLink(title: L("atelier.addsel", app.selection.count)) { m.add(app.clips.filter { app.selection.contains($0.path) }) } }
            }.padding(.horizontal, UI.gutter).frame(height: 36)
            Divider().overlay(Socle.border)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(m.clips.enumerated()), id: \.element.id) { i, c in
                        MiniClipRow(clip: c, service: app.thumbs, selected: i == m.index, trims: m.items.filter { $0.clip == c }.count) { Task { await m.open(i) } } remove: { m.remove(c) }
                        Divider().overlay(Socle.border)
                    }
                }
            }.frame(maxHeight: .infinity)
            Divider().overlay(Socle.border)
            HStack { Text((L("atelier.list") + (m.items.isEmpty ? "" : " · \(m.items.count)")).uppercased()).font(.system(size: 10.5)).tracking(0.8).foregroundColor(Socle.subtle); Spacer()
                if !m.items.isEmpty { SLink(title: L("conv.clear")) { m.items = [] } }
            }.padding(.horizontal, UI.gutter).frame(height: 36)
            Divider().overlay(Socle.border)
            if m.items.isEmpty {
                Text(L("atelier.listempty")).font(.system(size: 12)).foregroundColor(Socle.subtle).multilineTextAlignment(.center).padding(UI.gutter).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(m.items) { it in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(it.clip.name).font(.system(size: 12)).foregroundColor(Socle.text).lineLimit(1).truncationMode(.middle)
                                Text("\(PlayerModel.shortTimecode(it.tin, fps: it.fps)) → \(PlayerModel.shortTimecode(it.tout, fps: it.fps))  ·  \(PlayerModel.shortTimecode(it.duration, fps: it.fps))").font(.system(size: 11).monospacedDigit()).foregroundColor(Socle.subtle).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            SLink(title: "✕") { m.items.removeAll { $0.id == it.id } }
                        }.padding(.horizontal, UI.gutter).frame(height: 44)
                        Divider().overlay(Socle.border)
                    }
                }
            }.frame(maxHeight: .infinity)
            Divider().overlay(Socle.border)
            VStack(alignment: .leading, spacing: 4) {
                SCheck(title: L("atelier.replace"), isOn: Binding(get: { m.replaceOriginals }, set: { m.replaceOriginals = $0 }))
                if m.replaceOriginals { Text(L("atelier.replace.note")).font(.system(size: 11)).foregroundColor(Color(hex: 0xF87171)).fixedSize(horizontal: false, vertical: true) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, UI.gutter).padding(.top, 10)
            VStack(alignment: .leading, spacing: 10) {
                Text(L("atelier.lossless")).font(.system(size: 11)).foregroundColor(Socle.subtle).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                tool(L("atelier.exportall", m.items.count), key: "⇧⌘S", main: !m.items.isEmpty) { m.exportAll() }.frame(maxWidth: .infinity, alignment: .trailing)
            }.padding(UI.gutter)
        }.background(Socle.surface)
    }
}

struct MiniClipRow: View {
    let clip: Clip
    let service: ThumbService
    let selected: Bool
    let trims: Int
    let open: () -> Void
    let remove: () -> Void
    @State private var loaded: Loaded?

    var body: some View {
        HStack(spacing: 10) {
            Group { if let d = loaded?.jpeg, let img = NSImage(data: d) { Image(nsImage: img).resizable().scaledToFill() } else { Color(hex: 0x2A2A2A) } }
                .frame(width: 56, height: 32).clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.name).font(.system(size: 12)).foregroundColor(selected ? Socle.textStrong : Socle.text).lineLimit(1).truncationMode(.middle)
                Text(loaded?.info.map { formatDuration($0.duration) } ?? "").font(.system(size: 11).monospacedDigit()).foregroundColor(Socle.subtle)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if trims > 0 { Text("✓ \(trims)").font(.system(size: 11)).foregroundColor(Color(hex: 0x4ADE80)) }
            SLink(title: "✕", action: remove)
        }
        .padding(.horizontal, UI.gutter).frame(height: 48)
        .background(selected ? Socle.control : .clear).contentShape(Rectangle()).onTapGesture(perform: open)
        .task(id: clip.path) { loaded = await service.load(clip) }
    }
}

/// Ligne de temps de l'atelier : plage conservée en surbrillance, poignées d'entrée et de sortie déplaçables, tête de lecture.
struct TrimTimeline: View {
    let model: PlayerModel
    let done: [TrimItem]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, d = max(model.duration, 0.001)
            let a = model.markIn ?? 0, b = model.markOut ?? d
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Socle.sunken)
                ForEach(done) { it in Rectangle().fill(Color(hex: 0x4ADE80).opacity(0.25)).frame(width: max(2, w * it.duration / d)).offset(x: w * it.tin / d) }
                Rectangle().fill(Color(hex: 0x38BDF8).opacity(0.35)).frame(width: max(2, w * (b - a) / d)).offset(x: w * a / d)
                handle(at: w * a / d, color: Color(hex: 0x38BDF8)).gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    model.markIn = min(max(0, Double(g.location.x / max(w, 1)) * d), b - 0.04) })
                handle(at: w * b / d, color: Color(hex: 0x38BDF8)).gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    model.markOut = max(min(d, Double(g.location.x / max(w, 1)) * d), a + 0.04) })
                Rectangle().fill(.white).frame(width: 2).offset(x: w * min(model.time, d) / d).allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in model.seek(Double(g.location.x / max(w, 1)) * d) })
        }.frame(height: 44)
    }

    private func handle(at x: CGFloat, color: Color) -> some View {
        Rectangle().fill(color).frame(width: 6).frame(maxHeight: .infinity).offset(x: x - 3).contentShape(Rectangle().inset(by: -4))
    }
}

