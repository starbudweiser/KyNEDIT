import AppKit
import SwiftUI

/// Contrat de licence utilisateur final et mentions tierces (textes dans Contents/Resources/Legal, copiés par build.sh).
@MainActor
enum LegalWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: LegalView()))
            w.styleMask = [.titled, .closable, .resizable]
            w.title = L("legal.menu")
            w.setContentSize(NSSize(width: 640, height: 560))
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Texte d'un fichier légal dans la langue courante, sinon en anglais ; nil si le fichier est absent.
    static func text(_ base: String, localized: Bool = true) -> String? {
        guard let dir = Bundle.main.resourcePath.map({ $0 + "/Legal/" }) else { return nil }
        let names = localized ? ["\(base)-\(Lang.current).txt", "\(base)-en.txt"] : ["\(base).txt"]
        for n in names {
            if let s = try? String(contentsOfFile: dir + n, encoding: .utf8) { return s }
        }
        return nil
    }
}

private struct LegalView: View {
    private enum Tab: Hashable { case eula, notices, blackmagic }
    @State private var tab: Tab = .eula
    private let blackmagic = LegalWindow.text("ThirdParty-BlackmagicRAW", localized: false)

    var body: some View {
        VStack(spacing: 10) {
            Picker("", selection: $tab) {
                Text(L("legal.tab.eula")).tag(Tab.eula)
                Text(L("legal.tab.notices")).tag(Tab.notices)
                if blackmagic != nil { Text("Blackmagic RAW").tag(Tab.blackmagic) }
            }
            .pickerStyle(.segmented).labelsHidden()
            ScrollView {
                Text(content).font(.system(size: 12)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
        }
        .padding(16).frame(minWidth: 520, minHeight: 360)
    }

    private var content: String {
        let missing = L("legal.missing")
        switch tab {
        case .eula: return LegalWindow.text("EULA") ?? missing
        case .notices: return LegalWindow.text("NOTICES") ?? missing
        case .blackmagic: return blackmagic ?? missing
        }
    }
}
