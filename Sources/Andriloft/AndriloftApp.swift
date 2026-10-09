import SwiftUI
import AppKit
import AndriloftUpdates

@main struct AndriloftApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var updater = AppUpdater()
    @StateObject private var marketplace = MarketplaceStore()
    var body: some Scene {
        WindowGroup("Andriloft") {
            LibraryView()
                .environmentObject(library)
                .environmentObject(updater)
                .environmentObject(marketplace)
                .frame(minWidth: 850, minHeight: 580)
                .sheet(isPresented: $marketplace.isAccountSetupPresented, onDismiss: marketplace.accountSetupDidDismiss) {
                    MarketplaceAccountSetupView().environmentObject(marketplace)
                }
                .onOpenURL { library.importAPK($0) }
                .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1060, height: 720)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                Button("Google Account…") { marketplace.showAccountSetup() }
            }
            CommandGroup(after: .newItem) {
                Button("Add Android App…") { library.chooseAPK() }.keyboardShortcut("o")
                Button("Add Example App") { library.addExample() }
            }
        }
    }
}
