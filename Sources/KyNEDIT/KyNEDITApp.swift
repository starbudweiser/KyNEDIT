import SwiftUI
import AppKit

@main
struct KyNEDITApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 960, minHeight: 600)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L("about.menu")) { AboutWindow.show() }
            }
        }
    }
}
