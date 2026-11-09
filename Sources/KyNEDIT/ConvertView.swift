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
            message = L("conv.queued", app.exports.jobs.count - before)
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

    private var m: ConvertModel { app.convert }

    var body: some View {
        @Bindable var m = app.convert
        HStack(spacing: 0) {
            presetColumn(m).frame(width: 250)
            Divider().overlay(Socle.border)
            sourceColumn(m)
            Divider().overlay(Socle.border)
            settingsColumn($m.settings, m).frame(width: 340)
        }.background(Socle.bg)
    }

    // MARK: préréglages

    private func presetColumn(_ m: ConvertModel) -> some View {
        let groups = ["group.edit", "group.proxy", "group.avid", "group.delivery", "group.dailies", "group.camera"]
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                header(L("conv.presets"))
                if !m.custom.isEmpty {
                    sub(L("conv.mine"))
                    ForEach(m.custom) { p in presetRow(p, m, deletable: true) }
                }
                ForEach(groups, id: \.self) { g in
                    sub(L(g))
                    ForEach(Presets.builtin.filter { $0.group == g }) { p in presetRow(p, m, deletable: false) }
                }
            }.padding(12)
        }.background(Socle.surface)
    }

    private func presetRow(_ p: ConvertPreset, _ m: ConvertModel, deletable: Bool) -> some View {
        HStack {
            Text(p.name).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
            Spacer()
            if deletable { Text("✕").font(.system(size: 11)).foregroundColor(Socle.subtle).onTapGesture { m.removeCustom(p.id) }.help(L("conv.delete")) }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(m.presetID == p.id ? Socle.control : .clear, in: RoundedRectangle(cornerRadius: 4))
        .foregroundColor(m.presetID == p.id ? Socle.textStrong : Socle.text)
        .contentShape(Rectangle()).onTapGesture { m.apply(p) }
    }

    // MARK: sources

    private func sourceColumn(_ m: ConvertModel) -> some View {
        VStack(spacing: 0) {
            HStack {
                header(L("conv.sources") + (m.clips.isEmpty ? "" : " · \(m.clips.count)"))
                Spacer()
                if !m.clips.isEmpty { Text(L("conv.clear")).font(.system(size: 11)).foregroundColor(Socle.accentText).onTapGesture { m.clips = [] } }
            }.padding(.horizontal, 16).padding(.top, 12)
            if m.clips.isEmpty {
                VStack(spacing: 12) {
                    Text(L("conv.drop")).font(.system(size: 12)).foregroundColor(Socle.muted).multilineTextAlignment(.center)
                    if !app.selection.isEmpty { button(L("conv.add.selection", app.selection.count)) { m.add(app.clips.filter { app.selection.contains($0.path) }) } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(m.clips) { c in
                            HStack {
                                Text(c.name).font(.system(size: 12)).foregroundColor(Socle.text).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text((c.path as NSString).deletingLastPathComponent.split(separator: "/").last.map(String.init) ?? "").font(.system(size: 11)).foregroundColor(Socle.subtle).lineLimit(1)
                                Text("✕").font(.system(size: 11)).foregroundColor(Socle.subtle).onTapGesture { m.clips.removeAll { $0.path == c.path } }
                            }.padding(.horizontal, 16).padding(.vertical, 5)
                            Divider().overlay(Socle.border)
                        }
                    }
                }
                HStack {
                    if !app.selection.isEmpty { button(L("conv.add.selection", app.selection.count)) { m.add(app.clips.filter { app.selection.contains($0.path) }) } }
                    Spacer()
                    if !m.message.isEmpty { Text(m.message).font(.system(size: 11)).foregroundColor(Socle.muted) }
                    button(L("conv.run", m.clips.count), main: true) { m.run(app) }
                }.padding(12).background(Socle.surface)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(targeted ? Socle.sunken : Socle.bg)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for p in providers { _ = p.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in app.convert.add(urls: [url]) } } } }
            return true
        }
    }

    // MARK: réglages

    private func settingsColumn(_ s: Binding<ConvertSettings>, _ m: ConvertModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(L("conv.format"))
                row(L("conv.codec")) { menu(VCodec.allCases, s.codec, label: { $0.label }) }
                row(L("conv.wrap")) { menu(s.wrappedValue.codec.allowedWraps, s.wrap, label: { $0.label }) }
                row(L("conv.size")) { menu(Self.sizes, sizeBinding(s), label: { $0.name == "" ? L("conv.size.source") : $0.name }) }
                if s.wrappedValue.width > 0 { check(L("conv.pad"), s.pad) }
                row(L("conv.fps")) { menu(Self.rates, s.fps, label: { $0 == 0 ? L("conv.fps.source") : fpsLabel($0) }) }
                if s.wrappedValue.codec.isHD { note(L("conv.dnxhd.note")) }
                if s.wrappedValue.passthroughVideo { note(L("conv.hint.fast")) }

                header(L("conv.color"))
                row(L("conv.color.in")) { menu(CamLog.allCases, s.colorIn, label: { $0.label }) }
                row(L("conv.lut")) {
                    HStack(spacing: 8) {
                        Text(s.wrappedValue.lutPath.map { ($0 as NSString).lastPathComponent } ?? L("conv.lut.none")).font(.system(size: 12)).foregroundColor(Socle.muted).lineLimit(1).truncationMode(.middle)
                        Text(L("conv.lut.choose")).font(.system(size: 11)).foregroundColor(Socle.accentText).onTapGesture { chooseFile(["cube"]) { s.wrappedValue.lutPath = $0 } }
                        if s.wrappedValue.lutPath != nil { Text("✕").font(.system(size: 11)).foregroundColor(Socle.subtle).onTapGesture { s.wrappedValue.lutPath = nil } }
                    }
                }

                header(L("conv.audio"))
                row(L("conv.audio")) { menu(AudioMode.allCases, s.audio, label: { L("conv.audio." + $0.rawValue) }) }
                if s.wrappedValue.audio != .none { row("") { menu(AudioChannels.allCases, s.channels, label: { L("conv.ch." + $0.rawValue) }) } }
                if m.clips.contains(where: \.isRaw) { note(L("conv.raw.note")) }

                header(L("conv.burn"))
                ForEach(Array(s.wrappedValue.burn.enumerated()), id: \.offset) { i, _ in
                    HStack(spacing: 6) {
                        menu(BurnField.allCases, s.burn[i].field, label: { L("field." + $0.rawValue) })
                        menu(Pos.allCases, s.burn[i].pos, label: { L("pos." + $0.rawValue) })
                        Text("✕").font(.system(size: 11)).foregroundColor(Socle.subtle).onTapGesture { s.wrappedValue.burn.remove(at: i) }
                    }
                }
                Text(L("conv.burn.add")).font(.system(size: 11)).foregroundColor(Socle.accentText).onTapGesture { s.wrappedValue.burn.append(BurnItem(field: .timecode, pos: .bl)) }
                if s.wrappedValue.burn.contains(where: { $0.field == .custom }) {
                    TextField(L("conv.text"), text: s.customText).textFieldStyle(.plain).padding(6).background(Socle.sunken, in: RoundedRectangle(cornerRadius: 4)).font(.system(size: 12))
                }
                if !s.wrappedValue.burn.isEmpty { row(L("conv.fontsize")) { stepper(s.fontPercent, 1...10, 0.5) } }
                row(L("conv.logo")) {
                    HStack(spacing: 8) {
                        Text(s.wrappedValue.logoPath.map { ($0 as NSString).lastPathComponent } ?? L("conv.lut.none")).font(.system(size: 12)).foregroundColor(Socle.muted).lineLimit(1).truncationMode(.middle)
                        Text(L("conv.lut.choose")).font(.system(size: 11)).foregroundColor(Socle.accentText).onTapGesture { chooseFile(["png", "jpg", "jpeg", "tif", "tiff"]) { s.wrappedValue.logoPath = $0 } }
                        if s.wrappedValue.logoPath != nil { Text("✕").font(.system(size: 11)).foregroundColor(Socle.subtle).onTapGesture { s.wrappedValue.logoPath = nil } }
                    }
                }
                if s.wrappedValue.logoPath != nil {
                    row("") { menu(Pos.allCases, s.logoPos, label: { L("pos." + $0.rawValue) }) }
                    row(L("conv.logo.size")) { stepper(s.logoPercent, 2...60, 1) }
                    row(L("conv.logo.opacity")) { stepper(Binding(get: { s.wrappedValue.logoOpacity * 100 }, set: { s.wrappedValue.logoOpacity = $0 / 100 }), 10...100, 10) }
                }

                header(L("conv.output"))
                row(L("conv.template")) {
                    TextField("", text: s.template).textFieldStyle(.plain).padding(6).background(Socle.sunken, in: RoundedRectangle(cornerRadius: 4)).font(.system(size: 12))
                }
                note(L("conv.template.hint"))
                row(L("conv.folder")) {
                    HStack {
                        Text(URL(fileURLWithPath: app.exports.outputDir).lastPathComponent).font(.system(size: 12)).foregroundColor(Socle.muted).lineLimit(1).truncationMode(.middle)
                        Text(L("export.choose")).font(.system(size: 11)).foregroundColor(Socle.accentText).onTapGesture { app.exports.chooseFolder() }
                    }
                }
                check(L("conv.recreate"), s.recreateFolders)
                check(L("conv.ale"), s.ale)
                check(L("conv.assemble"), s.assemble)

                VStack(alignment: .leading, spacing: 8) {
                    TextField(L("conv.preset.name"), text: Binding(get: { m.newName }, set: { m.newName = $0 })).textFieldStyle(.plain).padding(6)
                        .background(Socle.sunken, in: RoundedRectangle(cornerRadius: 4)).font(.system(size: 12))
                    button(L("conv.save")) { m.savePreset() }
                }.padding(.top, 6)
            }.padding(16)
        }.background(Socle.surface)
    }

    // MARK: éléments

    struct Size: Hashable { let name: String; let w: Int; let h: Int }
    static let sizes: [Size] = [Size(name: "", w: 0, h: 0), Size(name: "UHD 3840×2160", w: 3840, h: 2160), Size(name: "2K 2048×1080", w: 2048, h: 1080), Size(name: "1080p 1920×1080", w: 1920, h: 1080), Size(name: "720p 1280×720", w: 1280, h: 720), Size(name: "540p 960×540", w: 960, h: 540), Size(name: "480p 854×480", w: 854, h: 480), Size(name: "1080×1080", w: 1080, h: 1080), Size(name: "1080×1920", w: 1080, h: 1920)]
    static let rates: [Double] = [0, 23.976, 24, 25, 29.97, 30, 50, 59.94, 60]
    private func fpsLabel(_ f: Double) -> String { f.rounded() == f ? String(format: "%.0f i/s", f) : String(format: "%.3f i/s", f).replacingOccurrences(of: ".970 ", with: ".97 ").replacingOccurrences(of: ".940 ", with: ".94 ") }

    private func sizeBinding(_ s: Binding<ConvertSettings>) -> Binding<Size> {
        Binding(get: { Self.sizes.first { $0.w == s.wrappedValue.width && $0.h == s.wrappedValue.height } ?? Self.sizes[0] },
                set: { s.wrappedValue.width = $0.w; s.wrappedValue.height = $0.h; if $0.w == 0 { s.wrappedValue.pad = false } })
    }

    private func header(_ t: String) -> some View { Text(t).font(.system(size: 12, weight: .semibold)).foregroundColor(Socle.textStrong).padding(.top, 2) }
    private func sub(_ t: String) -> some View { Text(t).font(.system(size: 11, weight: .semibold)).foregroundColor(Socle.subtle).padding(.top, 10).padding(.horizontal, 8) }
    private func note(_ t: String) -> some View { Text(t).font(.system(size: 11)).foregroundColor(Socle.subtle).fixedSize(horizontal: false, vertical: true) }
    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .center) {
            Text(label).font(.system(size: 12)).foregroundColor(Socle.muted).frame(width: 90, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func check(_ t: String, _ b: Binding<Bool>) -> some View {
        HStack(spacing: 6) { Text(b.wrappedValue ? "☑" : "☐").foregroundColor(Socle.accentText); Text(t).font(.system(size: 12)).foregroundColor(Socle.text).fixedSize(horizontal: false, vertical: true) }
            .contentShape(Rectangle()).onTapGesture { b.wrappedValue.toggle() }
    }
    private func menu<T: Hashable>(_ items: [T], _ sel: Binding<T>, label: @escaping (T) -> String) -> some View {
        Menu { ForEach(items, id: \.self) { i in Button(label(i)) { sel.wrappedValue = i } } } label: {
            HStack(spacing: 6) { Text(label(sel.wrappedValue)).lineLimit(1); Spacer(minLength: 4); Text("⌄").foregroundColor(Socle.subtle) }
                .font(.system(size: 12)).foregroundColor(Socle.text)
                .padding(.horizontal, 8).padding(.vertical, 4).frame(minWidth: 150, alignment: .leading).background(Socle.control, in: RoundedRectangle(cornerRadius: 4))
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
    private func stepper(_ v: Binding<Double>, _ r: ClosedRange<Double>, _ step: Double) -> some View {
        HStack(spacing: 8) {
            Text("−").frame(width: 20).background(Socle.control, in: RoundedRectangle(cornerRadius: 4)).onTapGesture { v.wrappedValue = max(r.lowerBound, v.wrappedValue - step) }
            Text(String(format: step < 1 ? "%.1f" : "%.0f", v.wrappedValue)).font(.system(size: 12).monospacedDigit()).frame(width: 36)
            Text("+").frame(width: 20).background(Socle.control, in: RoundedRectangle(cornerRadius: 4)).onTapGesture { v.wrappedValue = min(r.upperBound, v.wrappedValue + step) }
        }.font(.system(size: 12)).foregroundColor(Socle.text)
    }
    private func chooseFile(_ exts: [String], _ done: @escaping (String) -> Void) {
        let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false; p.allowedContentTypes = exts.compactMap { UTType(filenameExtension: $0) }
        if p.runModal() == .OK, let u = p.url { done(u.path) }
    }
}

/// Essai d'affichage sans fenêtre (KYNEDIT_SNAPSHOT=<fichier.png>, KYNEDIT_TAB=convert|exports|performance) : écrit une image de l'onglet.
enum Snapshot {
    @MainActor static func startIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["KYNEDIT_SNAPSHOT"] else { return }
        Task { @MainActor in
            let app = AppModel()
            if let n = env["KYNEDIT_ADD"] { app.convert.add(urls: [URL(fileURLWithPath: n)]) }
            let view = AnyView(ConvertView(app: app).frame(width: 1466, height: 980).background(Socle.bg).environment(\.colorScheme, .dark))
            let host = NSHostingView(rootView: view)
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1466, height: 980), styleMask: [.borderless], backing: .buffered, defer: false)
            win.contentView = host; host.frame = NSRect(x: 0, y: 0, width: 1466, height: 980)
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(600))
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: out)) }
            }
            exit(0)
        }
    }
}
