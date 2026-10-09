import SwiftUI
import UniformTypeIdentifiers

private let accent = Color(red: 0.43, green: 0.79, blue: 0.66)

struct LibraryView: View {
    @EnvironmentObject var library: LibraryStore
    @State private var showRuntime = false
    @State private var diagnostics: String?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().opacity(0.35)
                if showRuntime { runtimeInfo }
                else if library.entries.isEmpty { emptyLibrary }
                else { appLibrary }
                Spacer(minLength: 0)
                statusBar
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .preferredColorScheme(.dark)
        .alert("Andriloft", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("OK") { library.error = nil }
        } message: { Text(library.error ?? "") }
        .sheet(isPresented: Binding(get: { diagnostics != nil }, set: { if !$0 { diagnostics = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("APK details").font(.title2.bold())
                ScrollView { Text(diagnostics ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                Button("Done") { diagnostics = nil }.keyboardShortcut(.defaultAction)
            }.padding(24).frame(width: 620, height: 480)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in library.importAPK(url) } }
                }
            }
            return !providers.isEmpty
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 27)).foregroundStyle(accent)
                Text("Andriloft").font(.system(size: 21, weight: .bold))
            }.padding(.top, 12)
            VStack(spacing: 8) {
                navigationItem("My apps", symbol: "square.grid.2x2", active: !showRuntime) { showRuntime = false }
                navigationItem("Compatibility", symbol: "cpu", active: showRuntime) { showRuntime = true }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Label("Native compatibility", systemImage: "circle.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(accent)
                Text("Android APIs.\nA macOS home.").font(.system(size: 19, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                Text("Experimental · v0.1").font(.caption).foregroundStyle(.secondary)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        }.padding(22).frame(width: 218).background(Color(red: 0.065, green: 0.083, blue: 0.091))
    }
    private func navigationItem(_ title: String, symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Image(systemName: symbol).frame(width: 20); Text(title); Spacer() }
                .font(.system(size: 14, weight: .medium)).padding(12)
                .foregroundStyle(active ? accent : .white.opacity(0.65))
                .background(active ? accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text(showRuntime ? "Compatibility layer" : "Your Android apps").font(.system(size: 27, weight: .bold))
                Text(showRuntime ? "What runs in this first build" : "A familiar app, a native window.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { library.chooseAPK() } label: { Label("Add APK", systemImage: "plus").padding(.horizontal, 7).padding(.vertical, 5) }
                .buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
        }.padding(30)
    }
    private var emptyLibrary: some View {
        VStack(spacing: 18) {
            Image(systemName: "app.badge").font(.system(size: 54, weight: .light)).foregroundStyle(accent).padding(.bottom, 6)
            Text("Give an Android app a new home").font(.system(size: 22, weight: .semibold))
            Text("Drop an APK here, or start with the included example.\nSupported Android views become real Mac controls.")
                .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
            HStack(spacing: 12) {
                Button("Try the example") { library.addExample() }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                Button("Choose APK…") { library.chooseAPK() }.buttonStyle(.bordered)
            }.padding(.top, 8)
            Text("Early support for Java apps using basic Android views.").font(.caption).foregroundStyle(.secondary).padding(.top, 10)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }
    private var appLibrary: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("LIBRARY · \(library.entries.count)").font(.system(size: 11, weight: .bold)).tracking(1.5).foregroundStyle(.secondary)
                Spacer()
                HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Find an app", text: $library.search).textFieldStyle(.plain) }
                    .padding(9).frame(width: 215).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 18)], spacing: 18) {
                    ForEach(library.filtered) { entry in appCard(entry) }
                }
            }
        }.padding(30)
    }
    private func appCard(_ entry: LibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(accent.opacity(0.12)).frame(width: 58, height: 58)
                    Text(String(entry.metadata.displayName.prefix(1)).uppercased()).font(.system(size: 29, weight: .semibold)).foregroundStyle(accent)
                }
                Spacer()
                if library.runningIDs.contains(entry.id) { Label("Running", systemImage: "circle.fill").font(.system(size: 10, weight: .medium)).foregroundStyle(accent) }
                Menu {
                    Button("APK details") { diagnostics = library.details(entry) }
                    if library.runningIDs.contains(entry.id) { Button("Stop app") { library.stop(entry) } }
                    Button("Remove from library", role: .destructive) { library.remove(entry) }
                } label: { Image(systemName: "ellipsis").frame(width: 20) }.menuStyle(.borderlessButton).frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.metadata.displayName).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Text(entry.metadata.packageName).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            Divider().opacity(0.4)
            HStack {
                Text("v\(entry.metadata.versionName)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { library.launch(entry) } label: { Label(library.runningIDs.contains(entry.id) ? "Open" : "Run app", systemImage: "play.fill") }
                    .buttonStyle(.bordered).tint(accent)
                    .disabled(entry.metadata.mainActivity == nil)
            }
        }.padding(20).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08), lineWidth: 1))
    }
    private var runtimeInfo: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) { Image(systemName: "arrow.triangle.branch").foregroundStyle(accent); Text("APK → DEX interpreter → Android API bridge → AppKit").font(.system(size: 14, weight: .medium)) }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading).background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                Text("Runs directly on macOS").font(.title2.bold())
                Text("Andriloft executes a supported subset of Android bytecode in its own interpreter. Activity startup, view calls, and app callbacks cross into native macOS APIs. Your APKs stay in your local library.").foregroundStyle(.secondary).lineSpacing(4)
                capability("Supported in v0.1", text: "Basic Java activities · LinearLayout · TextView · Button · EditText · click listeners · string resources · SharedPreferences · toast messages", symbol: "checkmark.circle", color: accent)
                capability("Still to implement", text: "AndroidX and Compose · XML layouts · JNI and Linux libraries · Google Play services · WebView · network, media and device services", symbol: "wrench.and.screwdriver", color: .orange)
                Text("Most existing Android apps depend on APIs beyond this first version. Andriloft reports the exact unsupported call when execution reaches it.").font(.callout).foregroundStyle(.secondary).lineSpacing(4)
                Button("Add the test APK") { library.addExample(); showRuntime = false }.buttonStyle(.bordered)
            }.padding(30)
        }
    }
    private func capability(_ title: String, text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 8) { Text(title).font(.headline); Text(text).font(.callout).foregroundStyle(.secondary).lineSpacing(5) }
        }
    }
    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(accent).frame(width: 5, height: 5)
            Text(library.notice).lineLimit(1)
            Spacer()
            Text("DEX / AppKit").font(.system(size: 10, design: .monospaced))
        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 14).background(.black.opacity(0.12))
    }
}
