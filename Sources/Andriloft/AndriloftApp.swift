import SwiftUI
import AppKit
import AndriloftUpdates

@main struct AndriloftApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var updater = AppUpdater()
    var body: some Scene {
        WindowGroup("Andriloft") {
            LibraryView()
                .environmentObject(library)
                .environmentObject(updater)
                .frame(minWidth: 850, minHeight: 580)
                .onOpenURL { library.importAPK($0) }
                .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1060, height: 720)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(after: .newItem) {
                Button("Add Android App…") { library.chooseAPK() }.keyboardShortcut("o")
                Button("Add Example App") { library.addExample() }
            }
        }
    }
}
