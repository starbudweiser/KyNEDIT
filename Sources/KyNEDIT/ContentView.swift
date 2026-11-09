import SwiftUI

enum Tab: CaseIterable { case explorer, atelier, convert, offload, exports, performance
    var key: String { switch self { case .explorer: "tab.explorer"; case .atelier: "tab.atelier"; case .convert: "tab.convert"; case .offload: "tab.offload"; case .exports: "tab.exports"; case .performance: "tab.performance" } }
}

struct ContentView: View {
    @State private var model = AppModel()
    private var tab: Tab { get { model.tab } nonmutating set { model.tab = newValue } }
    private let updateTimer = Timer.publish(every: 600, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Brand.text(Brand.name).font(.system(size: 13, weight: .semibold)).foregroundColor(Socle.textStrong)
                ForEach(Tab.allCases, id: \.self) { t in
                    Text(L(t.key) + (t == .exports && model.exports.pendingCount > 0 ? " (\(model.exports.pendingCount))" : "")).font(.system(size: 12))
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(tab == t ? Socle.control : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .foregroundColor(tab == t ? Socle.textStrong : Socle.muted)
                        .onTapGesture { tab = t }
                }
                Spacer()
                TextField(L("search.placeholder"), text: $model.query).textFieldStyle(.plain)
                    .padding(.horizontal, 10).frame(height: 28).frame(maxWidth: 360)
                    .background(Socle.sunken, in: RoundedRectangle(cornerRadius: 5))
                if model.root != nil { button(L("action.open")) { model.chooseFolder() } }
            }
            .padding(.horizontal, 12).frame(height: 40).background(Socle.surface)
            Divider().overlay(Socle.border)
            if tab == .performance { PerformanceView() }
            else if tab == .atelier { AtelierView(app: model) }
            else if tab == .convert { ConvertView(app: model) }
            else if tab == .offload { OffloadView(m: model.offload) }
            else if tab == .exports { ExportsView(queue: model.exports) }
            else { HStack(spacing: 0) {
                Sidebar(model: model).frame(width: 200)
                Divider().overlay(Socle.border)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Group {
                            if model.root == nil { EmptyState(model: model) } else { ClipList(model: model) }
                        }
                        if let sel = model.selected {
                            Divider().overlay(Socle.border)
                            InspectorPanel(model: model, clip: sel)
                        }
                    }
                    if model.selected != nil {
                        Divider().overlay(Socle.border)
                        PlayerPanel(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Socle.bg)
            } }
        }
        .background(Socle.bg)
        .onAppear { model.installKeyMonitor() }
        .onAppear { if let a = ProcessInfo.processInfo.environment["KYNEDIT_ATELIER"] { model.atelier.add(urls: a.split(separator: ":").map { URL(fileURLWithPath: String($0)) }); model.tab = .atelier } }
        .sheet(isPresented: $model.showRename) { RenameSheet(model: model) }
        .onAppear { // au lancement : fenêtre à taille raisonnable, centrée dans l'écran
            DispatchQueue.main.async {
                guard let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }), let v = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame else { return }
                let size = NSSize(width: min(1466, v.width * 0.95), height: min(1030, v.height * 0.95))
                w.setFrame(NSRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height), display: true)
            }
        }
        .onAppear { Updater.shared.isBusy = { [exports = model.exports] in exports.pendingCount > 0 }; Updater.shared.tick() }
        .onReceive(updateTimer) { _ in Updater.shared.tick() }
        .onAppear { // ouverture automatique d'un dossier pour les essais (KYNEDIT_OPEN=/chemin)
            if let p = ProcessInfo.processInfo.environment["KYNEDIT_OPEN"] { model.open(URL(fileURLWithPath: p)) }
        }
    }
}

func button(_ title: String, main: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(title).font(.system(size: 12, weight: .semibold)).tracking(0.5).lineLimit(1).fixedSize()
            .padding(.horizontal, 14).frame(height: 28)
            .background(main ? Socle.action : Socle.control, in: RoundedRectangle(cornerRadius: 5))
            .foregroundColor(main ? Socle.onAction : Socle.text)
    }.buttonStyle(.plain)
}

struct EmptyState: View {
    let model: AppModel
    var body: some View {
        VStack(spacing: 14) {
            Text(L("empty.title")).font(.system(size: 15)).foregroundColor(Socle.textStrong)
            Brand.text(L("app.tagline")).foregroundColor(Socle.muted)
            button(L("action.open"), main: true) { model.chooseFolder() }
            Text(L("empty.note")).font(.system(size: 11)).foregroundColor(Socle.subtle)
        }
    }
}

struct Sidebar: View {
    let model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("sidebar.volumes").uppercased()).font(.system(size: 10.5)).tracking(0.8)
                    .foregroundColor(Socle.subtle).padding(.bottom, 6)
                ForEach(model.volumes, id: \.self) { v in
                    let name = (try? v.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? v.lastPathComponent
                    Text(name).font(.system(size: 12)).lineLimit(1)
                        .foregroundColor(model.root == v ? Socle.textStrong : Socle.text)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4).padding(.horizontal, 8)
                        .background(model.root == v ? Color(hex: 0x303030) : .clear, in: RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle()).onTapGesture { model.open(v) }
                }
            }.padding(12)
        }
        .background(Socle.surface)
    }
}

struct ClipList: View {
    let model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.root?.lastPathComponent ?? "").font(.system(size: 12, weight: .semibold)).foregroundColor(Socle.textStrong)
                Text(model.scanning ? L(model.scanned == 1 ? "scan.progress.one" : "scan.progress", model.scanned) : L(model.clips.count == 1 ? "scan.done.one" : "scan.done", model.clips.count))
                    .foregroundColor(Socle.muted)
                Spacer()
                filters
                HStack(spacing: 2) {
                    ForEach([true, false], id: \.self) { g in
                        Text(L(g ? "view.grid" : "view.list")).font(.system(size: 12))
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(model.gridMode == g ? Color(hex: 0x404040) : Socle.control, in: RoundedRectangle(cornerRadius: 4))
                            .foregroundColor(model.gridMode == g ? Socle.textStrong : Socle.text)
                            .onTapGesture { model.gridMode = g }
                    }
                }
            }.padding(.horizontal, 16).padding(.vertical, 8)
            Divider().overlay(Color(hex: 0x2E2E2E))
            if model.gridMode {
                if model.clips.isEmpty && !model.scanning {
                    Text(L("empty.folder")).foregroundColor(Socle.subtle).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else { ClipGrid(model: model) }
            } else {
            HStack(spacing: 0) {
                col(L("list.name"), nil); col(L("list.type"), 90); col(L("list.size"), 90); col(L("list.date"), 130)
            }.padding(.horizontal, 16).padding(.vertical, 5)
            Divider().overlay(Color(hex: 0x2E2E2E))
            if model.clips.isEmpty && !model.scanning {
                Text(L("empty.folder")).foregroundColor(Socle.subtle).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.clips) { c in
                    HStack(spacing: 0) {
                        Text(c.name).lineLimit(1).foregroundColor(Socle.textStrong).frame(maxWidth: .infinity, alignment: .leading)
                        Text(L("kind.\(c.kind == .video ? "video" : c.kind == .audio ? "audio" : "image")") + " · " + c.ext.uppercased())
                            .foregroundColor(Socle.muted).frame(width: 90, alignment: .leading)
                        Text(ByteCountFormatter.string(fromByteCount: c.size, countStyle: .file))
                            .foregroundColor(Socle.muted).frame(width: 90, alignment: .leading)
                        Text(Date(timeIntervalSince1970: c.mtime).formatted(date: .abbreviated, time: .shortened))
                            .foregroundColor(Socle.muted).frame(width: 130, alignment: .leading)
                    }
                    .font(.system(size: 12)).listRowInsets(EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 7))
                    .listRowSeparator(.hidden).listRowBackground(Color.clear)
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
            }
            }
        }
    }
    private func filterLabel(_ t: String, active: Bool) -> some View {
        HStack(spacing: 4) { Text(t).lineLimit(1); Text("⌄").foregroundColor(Socle.subtle) }
            .font(.system(size: 11)).foregroundColor(active ? Socle.accentText : Socle.muted).padding(.horizontal, 8).frame(height: 24).background(Socle.control, in: RoundedRectangle(cornerRadius: 4))
    }
    private var filters: some View {
        HStack(spacing: 10) {
            Menu {
                Button(L("filter.res.all")) { model.heightMin = 0 }
                ForEach([(720, "HD 720+"), (1080, "Full HD 1080+"), (1440, "2K 1440+"), (2160, "UHD 2160+"), (4320, "8K 4320+")], id: \.0) { h in Button(h.1) { model.heightMin = h.0 } }
            } label: { filterLabel(model.heightMin == 0 ? L("filter.res") : "≥ \(model.heightMin)p", active: model.heightMin > 0) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Menu {
                Button(L("filter.fps.all")) { model.fpsFilter = 0 }
                ForEach([23.976, 24, 25, 29.97, 30, 50, 59.94, 60], id: \.self) { f in Button(fpsText(f)) { model.fpsFilter = f } }
            } label: { filterLabel(model.fpsFilter == 0 ? L("filter.fps") : fpsText(model.fpsFilter), active: model.fpsFilter > 0) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            StarRating(value: model.ratingMin, size: 13) { model.ratingMin = model.ratingMin == $0 ? 0 : $0 }
            ForEach(1...3, id: \.self) { c in
                Circle().fill(labelColors[c]).frame(width: 10, height: 10)
                    .overlay(Circle().stroke(model.colorFilter == c ? Color.white : .clear, lineWidth: 1.5).padding(-3))
                    .contentShape(Rectangle().inset(by: -4)).onTapGesture { model.colorFilter = model.colorFilter == c ? 0 : c }
            }
        }.padding(.trailing, 8)
    }

    @ViewBuilder func col(_ t: String, _ w: CGFloat?) -> some View {
        Text(t.uppercased()).font(.system(size: 10.5)).tracking(0.6).foregroundColor(Socle.subtle)
            .frame(maxWidth: w == nil ? .infinity : w, alignment: .leading).frame(width: w)
    }
}


struct RenameSheet: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("rename.title")).font(.system(size: 13, weight: .semibold)).foregroundColor(Socle.textStrong)
            TextField("", text: $model.renameTemplate).textFieldStyle(.plain).padding(6).background(Socle.sunken, in: RoundedRectangle(cornerRadius: 4)).font(.system(size: 12))
                .onChange(of: model.renameTemplate) { _, _ in model.updateRenamePreview() }
            Text(L("rename.hint")).font(.system(size: 11)).foregroundColor(Socle.subtle)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(model.renamePreview.enumerated()), id: \.offset) { _, p in
                        HStack(spacing: 8) { Text(p.old).foregroundColor(Socle.muted); Text("→").foregroundColor(Socle.subtle); Text(p.new).foregroundColor(Socle.text) }.font(.system(size: 11)).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 200).padding(8).background(Socle.sunken, in: RoundedRectangle(cornerRadius: 4))
            HStack { Spacer(); button(L("rename.cancel")) { model.showRename = false }; button(L("rename.apply"), main: true) { model.applyRename() } }
        }.padding(20).frame(width: 560).background(Socle.surface).preferredColorScheme(.dark)
        .onAppear { model.updateRenamePreview() }
    }
}
