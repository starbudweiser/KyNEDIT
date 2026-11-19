import AppKit
import SwiftUI

/// Fenêtre « À propos » (structure du modèle Socle : icône, nom, version, texte, auteurs, licence).
@MainActor
enum AboutWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let info = Bundle.main.infoDictionary ?? [:]
            let version = info["CFBundleShortVersionString"] as? String ?? "?"
            let build = info["CFBundleVersion"] as? String ?? "?"
            let view = VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
                Brand.text(Brand.name).font(.system(size: 17, weight: .bold))
                Text(L("about.version", version, build)).foregroundColor(.secondary)
                Brand.text(L("about.tagline"))
                Text(L("about.authors")).bold()
                Text(L("about.collection"))
                Text(L("about.license"))
                Brand.text(L("about.disclaimer")).foregroundColor(.secondary)
                Brand.text(L("about.credit")).foregroundColor(.secondary)
            }
            .font(.system(size: 12)).multilineTextAlignment(.center)
            .frame(width: 300).padding(28)
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.styleMask = [.titled, .closable]
            w.title = L("about.menu")
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
