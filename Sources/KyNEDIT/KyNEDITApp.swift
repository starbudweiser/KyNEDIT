import SwiftUI
import AppKit

@main
struct KyNEDITApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1100, minHeight: 640)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L("about.menu")) { AboutWindow.show() }
            }
        }
    }
}
