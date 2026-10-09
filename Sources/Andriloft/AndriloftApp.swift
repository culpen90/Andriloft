import SwiftUI
import AppKit

@main struct AndriloftApp: App {
    @StateObject private var library = LibraryStore()
    var body: some Scene {
        WindowGroup("Andriloft") {
            LibraryView()
                .environmentObject(library)
                .frame(minWidth: 850, minHeight: 580)
                .onOpenURL { library.importAPK($0) }
                .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1060, height: 720)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Android App…") { library.chooseAPK() }.keyboardShortcut("o")
                Button("Add Example App") { library.addExample() }
            }
        }
    }
}
