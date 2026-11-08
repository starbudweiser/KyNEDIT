import SwiftUI

enum Tab: CaseIterable { case explorer, exports, performance
    var key: String { switch self { case .explorer: "tab.explorer"; case .exports: "tab.exports"; case .performance: "tab.performance" } }
}

struct ContentView: View {
    @State private var tab: Tab = .explorer
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Brand.text(Brand.name)
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(Socle.textStrong)
                ForEach(Tab.allCases, id: \.self) { t in
                    Text(L(t.key)).font(.system(size: 12))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(tab == t ? Socle.control : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .foregroundColor(tab == t ? Socle.textStrong : Socle.muted)
                        .onTapGesture { tab = t }
                }
                Spacer()
                TextField(L("search.placeholder"), text: $query).textFieldStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 5).frame(maxWidth: 360)
                    .background(Socle.sunken, in: RoundedRectangle(cornerRadius: 5))
            }
            .padding(.horizontal, 12).frame(height: 40).background(Socle.surface)
            Divider().overlay(Socle.border)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(["sidebar.volumes", "sidebar.favorites", "sidebar.tags"], id: \.self) { k in
                        Text(L(k).uppercased()).font(.system(size: 10.5)).tracking(0.8).foregroundColor(Socle.subtle)
                    }
                    Spacer()
                }
                .padding(12).frame(width: 200, alignment: .topLeading).background(Socle.surface)
                Divider().overlay(Socle.border)
                VStack(spacing: 14) {
                    Text(L("empty.title")).font(.system(size: 15)).foregroundColor(Socle.textStrong)
                    Brand.text(L("app.tagline")).foregroundColor(Socle.muted)
                    Text(L("action.open")).font(.system(size: 12, weight: .semibold)).tracking(0.5)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Socle.action, in: RoundedRectangle(cornerRadius: 5)).foregroundColor(Socle.onAction)
                    Text(L("empty.note")).font(.system(size: 11)).foregroundColor(Socle.subtle)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Socle.bg)
            }
        }
        .background(Socle.bg)
    }
}
