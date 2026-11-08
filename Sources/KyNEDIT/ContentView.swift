import SwiftUI

enum Tab: CaseIterable { case explorer, exports, performance
    var key: String { switch self { case .explorer: "tab.explorer"; case .exports: "tab.exports"; case .performance: "tab.performance" } }
}

struct ContentView: View {
    @State private var model = AppModel()
    @State private var tab: Tab = .explorer

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Brand.text(Brand.name).font(.system(size: 13, weight: .semibold)).foregroundColor(Socle.textStrong)
                ForEach(Tab.allCases, id: \.self) { t in
                    Text(L(t.key)).font(.system(size: 12))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(tab == t ? Socle.control : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .foregroundColor(tab == t ? Socle.textStrong : Socle.muted)
                        .onTapGesture { tab = t }
                }
                Spacer()
                TextField(L("search.placeholder"), text: $model.query).textFieldStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 5).frame(maxWidth: 360)
                    .background(Socle.sunken, in: RoundedRectangle(cornerRadius: 5))
                if model.root != nil { button(L("action.open")) { model.chooseFolder() } }
            }
            .padding(.horizontal, 12).frame(height: 40).background(Socle.surface)
            Divider().overlay(Socle.border)
            HStack(spacing: 0) {
                Sidebar(model: model).frame(width: 200)
                Divider().overlay(Socle.border)
                Group {
                    if model.root == nil { EmptyState(model: model) } else { ClipList(model: model) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Socle.bg)
            }
        }
        .background(Socle.bg)
        .onAppear { // ouverture automatique d'un dossier pour les essais (KYNEDIT_OPEN=/chemin)
            if let p = ProcessInfo.processInfo.environment["KYNEDIT_OPEN"] { model.open(URL(fileURLWithPath: p)) }
        }
    }
}

func button(_ title: String, main: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(title).font(.system(size: 12, weight: .semibold)).tracking(0.5)
            .padding(.horizontal, 14).padding(.vertical, 6)
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
                Text(model.scanning ? L("scan.progress", model.scanned) : L("scan.done", model.clips.count))
                    .foregroundColor(Socle.muted)
                Spacer()
            }.padding(.horizontal, 16).padding(.vertical, 8)
            Divider().overlay(Color(hex: 0x2E2E2E))
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
    @ViewBuilder func col(_ t: String, _ w: CGFloat?) -> some View {
        Text(t.uppercased()).font(.system(size: 10.5)).tracking(0.6).foregroundColor(Socle.subtle)
            .frame(maxWidth: w == nil ? .infinity : w, alignment: .leading).frame(width: w)
    }
}
