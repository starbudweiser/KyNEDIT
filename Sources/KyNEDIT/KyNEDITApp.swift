import SwiftUI
import AppKit

@main
struct KyNEDITApp: App {
    init() { HeadlessConvert.startIfRequested(); Snapshot.startIfRequested() }
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1100, minHeight: 640)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1466, height: 1030)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L("about.menu")) { AboutWindow.show() }
                Button(L("legal.menu")) { LegalWindow.show() }
            }
        }
        Settings { SettingsView() }
    }
}
