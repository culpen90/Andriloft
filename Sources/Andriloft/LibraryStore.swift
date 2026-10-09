import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AndriloftCore
import AndriloftRuntime

struct LibraryEntry: Codable, Identifiable {
    var id: UUID
    var metadata: APKMetadata
    var fileName: String
    var importedAt: Date
}

@MainActor final class LibraryStore: ObservableObject {
    @Published var entries: [LibraryEntry] = []
    @Published var selectedID: UUID?
    @Published var search = ""
    @Published var error: String?
    @Published var notice = "Ready to run supported Android apps directly on macOS."
    @Published var runningIDs: Set<UUID> = []
    @Published var importCount = 0
    private var sessions: [UUID: NativeAndroidSession] = [:]
    let directory: URL

    var filtered: [LibraryEntry] {
        entries.filter { search.isEmpty || $0.metadata.displayName.localizedCaseInsensitiveContains(search) || $0.metadata.packageName.localizedCaseInsensitiveContains(search) }
    }
    var selected: LibraryEntry? { entries.first { $0.id == selectedID } }

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Andriloft", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let index = directory.appendingPathComponent("library.json")
            if FileManager.default.fileExists(atPath: index.path) {
                entries = try JSONDecoder().decode([LibraryEntry].self, from: Data(contentsOf: index))
            }
            selectedID = entries.first?.id
        } catch { self.error = "Could not load the app library: \(error.localizedDescription)" }
    }

    func chooseAPK() {
        let panel = NSOpenPanel()
        panel.title = "Add an Android app"
        panel.message = "Choose an APK to add to your local Andriloft library."
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { panel.urls.forEach { importAPK($0) } }
    }

    func importAPK(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let package = try APKPackage(url: url)
            // Parse the executable too, so malformed DEX fails during import rather than crashing at launch.
            _ = try package.dexData.map { try DexFile(data: $0) }
            let existing = entries.first { $0.metadata.packageName == package.metadata.packageName }
            let id = existing?.id ?? UUID()
            let fileName = "\(UUID().uuidString).apk"
            let destination = directory.appendingPathComponent(fileName)
            try FileManager.default.copyItem(at: url, to: destination)
            let next = LibraryEntry(id: id, metadata: package.metadata, fileName: fileName, importedAt: Date())
            var updated = entries.filter { $0.id != id }
            updated.append(next)
            updated.sort { $0.metadata.displayName.localizedStandardCompare($1.metadata.displayName) == .orderedAscending }
            do { try save(updated) } catch { try? FileManager.default.removeItem(at: destination); throw error }
            entries = updated
            selectedID = id
            if let existing { stop(existing); try? FileManager.default.removeItem(at: fileURL(existing)) }
            importCount += 1
            notice = "Added \(package.metadata.displayName)."
        } catch { self.error = "Could not import \(url.lastPathComponent): \(error.localizedDescription)" }
    }

    func addExample() {
        let bundled = Bundle.main.url(forResource: "HelloAndroid", withExtension: "apk")
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Examples/HelloAndroid/build/HelloAndroid.apk")
        guard let url = bundled ?? (FileManager.default.fileExists(atPath: source.path) ? source : nil) else {
            error = "The example APK is missing. Run tools/build-example.sh and tools/package-app.sh to include it."
            return
        }
        importAPK(url)
    }

    func launch(_ entry: LibraryEntry) {
        if let existing = sessions[entry.id] { existing.window?.makeKeyAndOrderFront(nil); return }
        do {
            let package = try APKPackage(url: fileURL(entry))
            let session = try NativeAndroidSession(package: package)
            session.host.onMessage = { [weak self] message in self?.notice = message }
            session.host.onFailure = { [weak self] error in self?.error = "The app stopped at an unsupported operation: \(error.localizedDescription)" }
            session.onClose = { [weak self] in
                self?.sessions.removeValue(forKey: entry.id)
                self?.runningIDs.remove(entry.id)
            }
            try session.start()
            guard session.isRunning else { notice = "\(entry.metadata.displayName) finished."; return }
            sessions[entry.id] = session
            runningIDs.insert(entry.id)
            notice = "\(entry.metadata.displayName) is running with native macOS controls."
        } catch { self.error = "Could not run \(entry.metadata.displayName): \(error.localizedDescription)" }
    }

    func stop(_ entry: LibraryEntry) { sessions[entry.id]?.stop() }

    func remove(_ entry: LibraryEntry) {
        do {
            let updated = entries.filter { $0.id != entry.id }
            try save(updated)
            stop(entry)
            entries = updated
            try? FileManager.default.removeItem(at: fileURL(entry))
            selectedID = entries.first?.id
            notice = "Removed \(entry.metadata.displayName) from the library."
        } catch { self.error = "Could not save the library: \(error.localizedDescription)" }
    }

    func details(_ entry: LibraryEntry) -> String {
        do {
            let apk = try APKPackage(url: fileURL(entry))
            let files = try apk.dexData.map { try DexFile(data: $0) }
            let references = Set(files.flatMap { $0.methods.map(\.owner) }.filter { !$0.hasPrefix("Lcom/andriloft/") }).sorted()
            return "Launcher: \(entry.metadata.mainActivity ?? "None")\nDEX files: \(files.count)\nClasses: \(files.reduce(0) { $0 + $1.classes.count })\nNative libraries: \(apk.nativeLibraries.count)\n\nReferenced classes\n" + references.joined(separator: "\n")
        } catch { return error.localizedDescription }
    }

    private func fileURL(_ entry: LibraryEntry) -> URL {
        // Persisted paths must stay under our own library folder.
        directory.appendingPathComponent(URL(fileURLWithPath: entry.fileName).lastPathComponent)
    }
    private func save(_ entries: [LibraryEntry]) throws {
        try JSONEncoder().encode(entries).write(to: directory.appendingPathComponent("library.json"), options: .atomic)
    }
}
