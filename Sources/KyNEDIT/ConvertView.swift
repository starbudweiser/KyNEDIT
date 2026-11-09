import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor @Observable
final class ConvertModel {
    var clips: [Clip] = []
    var settings: ConvertSettings = {
        if let d = UserDefaults.standard.data(forKey: "convertSettings"), let s = try? JSONDecoder().decode(ConvertSettings.self, from: d) { return s }
        return Presets.builtin[0].settings
    }() { didSet { normalize(); if let d = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(d, forKey: "convertSettings") } } }
    var presetID: String? = UserDefaults.standard.string(forKey: "convertPreset")
    var custom: [ConvertPreset] = Presets.loadCustom()
    var newName = ""
    var message = ""
    var jobIDs: [UUID] = []   // tâches lancées depuis cet onglet (suivi de la progression)

    var allCustom: [ConvertPreset] { custom }

    func apply(_ p: ConvertPreset) { settings = p.settings; presetID = p.id; UserDefaults.standard.set(p.id, forKey: "convertPreset") }

    /// Garde des réglages cohérents : conteneur permis par le codec, DNxHD en 1080p.
    private func normalize() {
        if !settings.codec.allowedWraps.contains(settings.wrap) { settings.wrap = settings.codec.allowedWraps[0] }
        if settings.codec.isHD && (settings.width != 1920 || settings.height != 1080 || !settings.pad) { settings.width = 1920; settings.height = 1080; settings.pad = true }
    }

    func savePreset() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let p = ConvertPreset(id: "custom.\(UUID().uuidString)", name: name, group: "conv.mine", settings: settings)
        custom.append(p); Presets.saveCustom(custom); presetID = p.id; newName = ""
    }
    func removeCustom(_ id: String) { custom.removeAll { $0.id == id }; Presets.saveCustom(custom) }

    func add(_ new: [Clip]) {
        let have = Set(clips.map(\.path))
        clips += new.filter { !have.contains($0.path) && $0.kind == .video }
    }

    /// Fichiers et dossiers déposés : les dossiers sont parcourus, seuls les clips vidéo sont gardés.
    func add(urls: [URL]) {
        var found: [Clip] = []
        func clip(_ u: URL) {
            let ext = u.pathExtension.lowercased()
            guard MediaScanner.kind(of: ext) == .video else { return }
            let a = try? FileManager.default.attributesOfItem(atPath: u.path)
            found.append(Clip(path: u.path, name: u.lastPathComponent, ext: ext, size: (a?[.size] as? Int64) ?? 0, mtime: (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, kind: .video))
        }
        for u in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                if let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) { for case let f as URL in e { clip(f) } }
            } else { clip(u) }
        }
        add(found.sorted { $0.path < $1.path })
    }

    func run(_ app: AppModel) {
        let list = clips, st = settings, out = app.exports.outputDir, catalog = app.catalog
        let root = commonRoot(list.map(\.path))
        Task {
            var subs: [String: [Subclip]] = [:]
            for c in list { subs[c.path] = await catalog.subclips(path: c.path) }
            let before = app.exports.jobs.count
            await app.exports.addConvert(clips: list, settings: st, outputDir: out, root: root, subclips: { subs[$0.path] ?? [] })
            let new = app.exports.jobs.dropFirst(before).map(\.id)
            let running = app.exports.jobs.contains { jobIDs.contains($0.id) && ($0.state == .waiting || $0.state == .running) }
            jobIDs = (running ? jobIDs : []) + new
            message = L("conv.queued", new.count)
        }
    }

    private func commonRoot(_ paths: [String]) -> String? {
        guard var common = paths.first.map({ ($0 as NSString).deletingLastPathComponent }) else { return nil }
        for p in paths.dropFirst() { while !p.hasPrefix(common + "/") && common != "/" { common = (common as NSString).deletingLastPathComponent } }
        return common
    }
}

struct ConvertView: View {
    let app: AppModel
    @State private var targeted = false
    @State private var open: Set<String> = ["format", "output"]

    private func binding(_ k: String) -> Binding<Bool> { Binding(get: { open.contains(k) }, set: { if $0 { open.insert(k) } else { open.remove(k) } }) }

    var body: some View {
        @Bindable var m = app.convert
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sourcePane(m)
                Divider().overlay(Socle.border)
                settingsPane($m.settings, m).frame(width: 360)
            }
            Divider().overlay(Socle.border)
            bottomBar(m)
        }.background(Socle.bg)
    }

    // MARK: sources (tableau, comme la liste de clips d'EditReady)

    private func sourcePane(_ m: ConvertModel) -> some View {
        VStack(spacing: 0) {
            if m.clips.isEmpty {
                VStack(spacing: 14) {
                    Text(L("conv.drop")).font(.system(size: 12)).foregroundColor(Socle.muted).multilineTextAlignment(.center).frame(maxWidth: 320)
                    if !app.selection.isEmpty { button(L("conv.add.selection", app.selection.count)) { m.add(app.clips.filter { app.selection.contains($0.path) }) } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 12) {
                    col(L("list.name"), nil).padding(.leading, 56 + 12)
                    col(L("info.duration"), 70); col(L("info.resolution"), 90); col(L("info.codec"), 110)
                    Spacer().frame(width: 20)
                }.padding(.horizontal, UI.gutter).frame(height: 30)
                Divider().overlay(Socle.border)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(m.clips) { c in
                            SourceRow(clip: c, service: app.thumbs) { m.clips.removeAll { $0.path == c.path } }
                            Divider().overlay(Socle.border)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(targeted ? Socle.sunken : Socle.bg)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(targeted ? Socle.accentText : .clear, lineWidth: 1).padding(6))
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for p in providers { _ = p.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in app.convert.add(urls: [url]) } } } }
            return true
        }
    }

    private func col(_ t: String, _ w: CGFloat?) -> some View {
        Text(t.uppercased()).font(.system(size: 10.5)).tracking(0.6).foregroundColor(Socle.subtle).lineLimit(1)
            .frame(maxWidth: w == nil ? .infinity : w, alignment: .leading).frame(width: w)
    }

    // MARK: barre du bas : résumé des réglages à gauche, action à droite

    private func bottomBar(_ m: ConvertModel) -> some View {
        let s = m.settings
        let size = s.width > 0 ? "\(s.width)×\(s.height)" : L("conv.size.source")
        let rate = s.fps > 0 ? fpsText(s.fps) : L("conv.fps.source")
        return HStack(spacing: 12) {
            Text("\(s.codec.label) · \(s.wrap.label) · \(size) · \(rate)").font(.system(size: 12)).foregroundColor(Socle.muted).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 12)
            progressSummary(m)
            if !m.clips.isEmpty { SLink(title: L("conv.clear")) { m.clips = [] } }
            if !app.selection.isEmpty { button(L("conv.add.selection", app.selection.count)) { m.add(app.clips.filter { app.selection.contains($0.path) }) } }
            button(L("conv.run", m.clips.count), main: true) { if !m.clips.isEmpty { m.run(app) } }
        }.padding(.horizontal, UI.gutter).frame(height: 52).background(Socle.surface)
    }

    /// Progression des conversions lancées d'ici : barre, pourcentage, nombre terminé ; lien vers les fichiers à la fin.
    @ViewBuilder private func progressSummary(_ m: ConvertModel) -> some View {
        let jobs = app.exports.jobs.filter { m.jobIDs.contains($0.id) }
        if jobs.isEmpty {
            if !m.message.isEmpty { Text(m.message).font(.system(size: 12)).foregroundColor(Socle.muted).lineLimit(1) }
        } else {
            let running = jobs.contains { $0.state == .waiting || $0.state == .running }
            let done = jobs.filter { $0.state == .done }.count, failed = jobs.filter { $0.state == .failed }.count
            let p = jobs.reduce(0.0) { $0 + ($1.state == .done ? 1 : $1.state == .running ? $1.progress : 0) } / Double(jobs.count)
            HStack(spacing: 10) {
                Text(running ? L("atelier.progress") : failed > 0 ? L("atelier.failed", failed) : L("atelier.finished")).font(.system(size: 12))
                    .foregroundColor(running ? Socle.muted : failed > 0 ? Color(hex: 0xF87171) : Color(hex: 0x4ADE80)).lineLimit(1)
                ProgressView(value: p).tint(running ? Socle.action : Color(hex: 0x4ADE80)).frame(width: 140)
                Text("\(done)/\(jobs.count) · \(Int((p * 100).rounded())) %").font(.system(size: 12).monospacedDigit()).foregroundColor(Socle.muted).lineLimit(1)
                if !running, done > 0 { SLink(title: L("atelier.reveal")) { NSWorkspace.shared.activateFileViewerSelecting(jobs.compactMap(\.outputPath).map { URL(fileURLWithPath: $0) }) } }
            }
        }
    }

    // MARK: réglages (sections repliables)

    private func settingsPane(_ s: Binding<ConvertSettings>, _ m: ConvertModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                presetBlock(s, m)
                SSection(title: L("conv.format"), open: binding("format")) {
                    SRow(label: L("conv.codec")) { SDropdown(items: VCodec.allCases, selection: s.codec, label: { $0.label }) }
                    SRow(label: L("conv.wrap")) { SDropdown(items: s.wrappedValue.codec.allowedWraps, selection: s.wrap, label: { $0.label }) }
                    if s.wrappedValue.codec != .rewrap {
                        SRow(label: L("conv.size")) { SDropdown(items: Self.sizes, selection: sizeBinding(s), label: { $0.name == "" ? L("conv.size.source") : $0.name }) }
                        if s.wrappedValue.width > 0 { SCheck(title: L("conv.pad"), isOn: s.pad) }
                        SRow(label: L("conv.fps")) { SDropdown(items: Self.rates, selection: s.fps, label: { $0 == 0 ? L("conv.fps.source") : fpsText($0) }) }
                    }
                    if s.wrappedValue.codec.isHD { note(L("conv.dnxhd.note")) }
                    if s.wrappedValue.passthroughVideo && s.wrappedValue.codec != .rewrap { note(L("conv.hint.fast")) }
                }
                if s.wrappedValue.codec != .rewrap {
                    SSection(title: L("conv.color"), open: binding("color")) {
                        SRow(label: L("conv.color.in")) { SDropdown(items: CamLog.allCases, selection: s.colorIn, label: { $0.label }) }
                        SRow(label: L("conv.lut")) { fileChooser(s.lutPath, ["cube"]) }
                    }
                }
                SSection(title: L("conv.audio"), open: binding("audio")) {
                    SRow(label: L("conv.audio")) { SDropdown(items: AudioMode.allCases, selection: s.audio, label: { L("conv.audio." + $0.rawValue) }) }
                    if s.wrappedValue.audio != .none && s.wrappedValue.codec != .rewrap {
                        SRow(label: L("conv.channels")) { SDropdown(items: AudioChannels.allCases, selection: s.channels, label: { L("conv.ch." + $0.rawValue) }) }
                    }
                }
                if s.wrappedValue.codec != .rewrap {
                    SSection(title: L("conv.burn"), open: binding("burn")) {
                        ForEach(Array(s.wrappedValue.burn.enumerated()), id: \.offset) { i, _ in
                            HStack(spacing: 8) {
                                SDropdown(items: BurnField.allCases, selection: s.burn[i].field, label: { L("field." + $0.rawValue) })
                                SDropdown(items: Pos.allCases, selection: s.burn[i].pos, label: { L("pos." + $0.rawValue) })
                                SLink(title: "✕") { s.wrappedValue.burn.remove(at: i) }.frame(width: 16)
                            }
                        }
                        SLink(title: L("conv.burn.add")) { s.wrappedValue.burn.append(BurnItem(field: .timecode, pos: .bl)) }
                        if s.wrappedValue.burn.contains(where: { $0.field == .custom }) { SField(placeholder: L("conv.text"), text: s.customText) }
                        if !s.wrappedValue.burn.isEmpty { SRow(label: L("conv.fontsize")) { SStepper(value: s.fontPercent, range: 1...10, step: 0.5) } }
                        SRow(label: L("conv.logo")) { fileChooser(s.logoPath, ["png", "jpg", "jpeg", "tif", "tiff"]) }
                        if s.wrappedValue.logoPath != nil {
                            SRow(label: L("conv.logo.pos")) { SDropdown(items: Pos.allCases, selection: s.logoPos, label: { L("pos." + $0.rawValue) }) }
                            SRow(label: L("conv.logo.size")) { SStepper(value: s.logoPercent, range: 2...60, step: 1) }
                            SRow(label: L("conv.logo.opacity")) { SStepper(value: Binding(get: { s.wrappedValue.logoOpacity * 100 }, set: { s.wrappedValue.logoOpacity = $0 / 100 }), range: 10...100, step: 10) }
                        }
                    }
                }
                SSection(title: L("conv.output"), open: binding("output")) {
                    SRow(label: L("conv.template")) { SField(placeholder: "", text: s.template) }
                    note(L("conv.template.hint"))
                    SRow(label: L("conv.folder")) {
                        HStack(spacing: 10) {
                            Text(URL(fileURLWithPath: app.exports.outputDir).lastPathComponent).font(.system(size: 12)).foregroundColor(Socle.muted).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            SLink(title: L("export.choose")) { app.exports.chooseFolder() }
                        }
                    }
                    SCheck(title: L("conv.recreate"), isOn: s.recreateFolders)
                    SCheck(title: L("conv.ale"), isOn: s.ale)
                    SCheck(title: L("conv.assemble"), isOn: s.assemble)
                    if m.clips.contains(where: \.isRaw) { note(L("conv.raw.note")) }
                }
            }.padding(UI.gutter)
        }.background(Socle.surface)
    }

    private func presetBlock(_ s: Binding<ConvertSettings>, _ m: ConvertModel) -> some View {
        let all = Presets.builtin + m.custom
        let current = all.first { $0.id == m.presetID && $0.settings == s.wrappedValue } ?? all.first { $0.settings == s.wrappedValue }
        return VStack(alignment: .leading, spacing: 8) {
            Text(L("conv.presets").uppercased()).font(.system(size: 10.5)).tracking(0.8).foregroundColor(Socle.subtle)
            Menu {
                if !m.custom.isEmpty { Section(L("conv.mine")) { ForEach(m.custom) { p in Button(p.name) { m.apply(p) } } } }
                ForEach(["group.edit", "group.proxy", "group.avid", "group.delivery", "group.dailies", "group.camera"], id: \.self) { g in
                    Section(L(g)) { ForEach(Presets.builtin.filter { $0.group == g }) { p in Button(p.name) { m.apply(p) } } }
                }
            } label: { SDropdownLabel(text: current?.name ?? L("conv.custom")) }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            HStack(spacing: 8) {
                SField(placeholder: L("conv.preset.name"), text: Binding(get: { m.newName }, set: { m.newName = $0 }))
                button(L("conv.save")) { m.savePreset() }
                if let id = m.presetID, m.custom.contains(where: { $0.id == id }) { SLink(title: "✕") { m.removeCustom(id) }.help(L("conv.delete")) }
            }.frame(height: 28)
        }
    }

    // MARK: éléments

    struct Size: Hashable { let name: String; let w: Int; let h: Int }
    static let sizes: [Size] = [Size(name: "", w: 0, h: 0), Size(name: "UHD 3840×2160", w: 3840, h: 2160), Size(name: "2K 2048×1080", w: 2048, h: 1080), Size(name: "1080p 1920×1080", w: 1920, h: 1080), Size(name: "720p 1280×720", w: 1280, h: 720), Size(name: "540p 960×540", w: 960, h: 540), Size(name: "480p 854×480", w: 854, h: 480), Size(name: "1080×1080", w: 1080, h: 1080), Size(name: "1080×1920", w: 1080, h: 1920)]
    static let rates: [Double] = [0, 23.976, 24, 25, 29.97, 30, 50, 59.94, 60]

    private func sizeBinding(_ s: Binding<ConvertSettings>) -> Binding<Size> {
        Binding(get: { Self.sizes.first { $0.w == s.wrappedValue.width && $0.h == s.wrappedValue.height } ?? Self.sizes[0] },
                set: { s.wrappedValue.width = $0.w; s.wrappedValue.height = $0.h; if $0.w == 0 { s.wrappedValue.pad = false } })
    }

    private func note(_ t: String) -> some View { Text(t).font(.system(size: 11)).foregroundColor(Socle.subtle).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading) }

    private func fileChooser(_ path: Binding<String?>, _ exts: [String]) -> some View {
        HStack(spacing: 10) {
            Text(path.wrappedValue.map { ($0 as NSString).lastPathComponent } ?? L("conv.lut.none")).font(.system(size: 12)).foregroundColor(Socle.muted).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            SLink(title: L("conv.lut.choose")) { chooseFile(exts) { path.wrappedValue = $0 } }
            if path.wrappedValue != nil { SLink(title: "✕") { path.wrappedValue = nil } }
        }
    }

    private func chooseFile(_ exts: [String], _ done: @escaping (String) -> Void) {
        let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false; p.allowedContentTypes = exts.compactMap { UTType(filenameExtension: $0) }
        if p.runModal() == .OK, let u = p.url { done(u.path) }
    }
}

/// Ligne du tableau des sources : vignette, nom, durée, résolution, codec.
struct SourceRow: View {
    let clip: Clip
    let service: ThumbService
    let remove: () -> Void
    @State private var loaded: Loaded?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let d = loaded?.jpeg, let img = NSImage(data: d) { Image(nsImage: img).resizable().scaledToFill() } else { Color(hex: 0x2A2A2A) }
            }.frame(width: 56, height: 32).clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.name).font(.system(size: 12)).foregroundColor(Socle.text).lineLimit(1).truncationMode(.middle)
                Text((clip.path as NSString).deletingLastPathComponent).font(.system(size: 10.5)).foregroundColor(Socle.subtle).lineLimit(1).truncationMode(.head)
            }.frame(maxWidth: .infinity, alignment: .leading)
            cell(loaded?.info.map { formatDuration($0.duration) } ?? "", 70)
            cell(loaded?.info.flatMap { $0.width > 0 ? "\($0.width)×\($0.height)" : nil } ?? "", 90)
            cell(loaded?.info?.codec ?? "", 110)
            SLink(title: "✕", action: remove).frame(width: 20)
        }
        .padding(.horizontal, UI.gutter).frame(height: 44)
        .task(id: clip.path) { loaded = await service.load(clip) }
    }

    private func cell(_ t: String, _ w: CGFloat) -> some View {
        Text(t).font(.system(size: 12).monospacedDigit()).foregroundColor(Socle.muted).lineLimit(1).truncationMode(.tail).frame(width: w, alignment: .leading)
    }
}

/// Essai d'affichage sans fenêtre (KYNEDIT_SNAPSHOT=<fichier.png>, KYNEDIT_TAB=convert|exports|performance) : écrit une image de l'onglet.
enum Snapshot {
    @MainActor static func startIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["KYNEDIT_SNAPSHOT"] else { return }
        Task { @MainActor in
            let tab = env["KYNEDIT_TAB"] ?? "convert"
            let app = AppModel()
            if let n = env["KYNEDIT_ADD"] { app.convert.add(urls: n.split(separator: ":").map { URL(fileURLWithPath: String($0)) }) }
            let size = CGSize(width: Double(env["KYNEDIT_W"] ?? "") ?? 1466, height: Double(env["KYNEDIT_H"] ?? "") ?? 980)
            let content: AnyView
            switch tab {
            case "offload": content = AnyView(OffloadView(m: app.offload))
            case "exports": content = AnyView(ExportsView(queue: app.exports))
            case "performance": content = AnyView(PerformanceView())
            case "explorer": content = AnyView(ContentView())
            default: content = AnyView(ConvertView(app: app))
            }
            let view = AnyView(content.frame(width: size.width, height: size.height).background(Socle.bg).environment(\.colorScheme, .dark))
            let host = NSHostingView(rootView: view)
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
            win.contentView = host; host.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(Int(env["KYNEDIT_WAIT"] ?? "") ?? 600))
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: out)) }
            }
            exit(0)
        }
    }
}
