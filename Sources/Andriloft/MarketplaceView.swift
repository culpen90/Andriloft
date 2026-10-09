import SwiftUI
import AndriloftMarketplace

private let marketplaceAccent = Color(red: 0.43, green: 0.79, blue: 0.66)

struct MarketplaceView: View {
    @EnvironmentObject private var marketplace: MarketplaceStore
    var onAddToLibrary: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.35)
            if marketplace.isLoading {
                loading
            } else if let error = marketplace.searchError {
                unavailable(error)
            } else if marketplace.apps.isEmpty {
                emptySearch
            } else {
                catalog
            }
            footer
        }
        .onAppear { marketplace.loadIfNeeded() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Marketplace").font(.system(size: 27, weight: .bold))
                    Text("Android apps. One easy download.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search apps", text: $marketplace.query)
                        .textFieldStyle(.plain)
                        .onSubmit { marketplace.refresh() }
                    if !marketplace.query.isEmpty {
                        Button { marketplace.query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search")
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(11).frame(width: 245)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.07)))
            }
            HStack(spacing: 7) {
                Image(systemName: "shippingbox").foregroundStyle(marketplaceAccent)
                Text("Browse APKMirror and save apps straight to your Downloads folder.")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 10)
                Button { marketplace.showAccountSetup() } label: {
                    Label("Google account", systemImage: marketplace.accountState == .ready ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(marketplaceAccent)
                .help(marketplace.accountState == .ready ? "Your Google account is connected" : "Set up your Google account for downloads")
            }.font(.system(size: 12))
        }.padding(30)
    }

    private var catalog: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(marketplace.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "LATEST ON APKMIRROR" : "SEARCH RESULTS")
                        .font(.system(size: 11, weight: .bold)).tracking(1.4).foregroundStyle(.secondary)
                    Spacer()
                    Button { marketplace.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Refresh apps")
                        .accessibilityLabel("Refresh apps")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 225, maximum: 320), spacing: 18)], alignment: .leading, spacing: 18) {
                    ForEach(marketplace.apps) { app in appCard(app) }
                }
            }.padding(30)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func appCard(_ app: MarketplaceApp) -> some View {
        let state = marketplace.downloads[app.id]
        return VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .top) {
                appIcon(app)
                Spacer()
                Text("APK").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.white.opacity(0.05), in: Capsule())
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(app.name).font(.system(size: 17, weight: .semibold))
                    .lineLimit(2).frame(height: 42, alignment: .topLeading)
                Text(app.developer).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            downloadButton(app, state: state)
            if case .failed(let message) = state {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(message)
            }
        }
        .padding(20)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08)))
        .contextMenu {
            if let url = state?.fileURL {
                Button("Show in Finder") { marketplace.reveal(url) }
                Button("Add to My apps") { onAddToLibrary(url) }
                Divider()
            }
            Link("View on APKMirror", destination: app.pageURL)
        }
    }

    private func appIcon(_ app: MarketplaceApp) -> some View {
        AsyncImage(url: app.iconURL) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            ZStack {
                marketplaceAccent.opacity(0.12)
                Text(String(app.name.prefix(1)).uppercased())
                    .font(.system(size: 28, weight: .semibold)).foregroundStyle(marketplaceAccent)
            }
        }
        .frame(width: 58, height: 58)
        .background(.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityHidden(true)
    }

    private func downloadButton(_ app: MarketplaceApp, state: MarketplaceDownloadState?) -> some View {
        Button {
            if state?.isActive == true { marketplace.cancelDownload(app) }
            else { marketplace.download(app) }
        } label: {
            HStack(spacing: 8) {
                switch state {
                case .preparing:
                    ProgressView().controlSize(.small)
                    Text("Preparing…")
                    Spacer(minLength: 0)
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                case .downloading(let progress):
                    ProgressView().controlSize(.small)
                    Text("Downloading \(Int(progress * 100))%")
                    Spacer(minLength: 0)
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                case .cancelling:
                    ProgressView().controlSize(.small)
                    Text("Cancelling…")
                case .completed:
                    Image(systemName: "checkmark")
                    Text("Downloaded")
                case .failed:
                    Image(systemName: "arrow.clockwise")
                    Text("Retry download")
                case nil:
                    Image(systemName: "arrow.down")
                    Text("Download")
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity).padding(.vertical, 7)
        }
        .buttonStyle(.borderedProminent)
        .tint(state?.fileURL == nil ? marketplaceAccent : .white.opacity(0.09))
        .foregroundStyle(state?.fileURL == nil ? .black : marketplaceAccent)
        .disabled(state?.fileURL != nil || state?.isCancelling == true)
        .help(state?.isCancelling == true ? "Cancelling download" : state?.isActive == true ? "Cancel download" : state?.fileURL != nil ? "Saved to Downloads. Control-click for file actions." : "Download app")
        .accessibilityLabel(state?.isCancelling == true ? "Cancelling download of \(app.name)" : state?.isActive == true ? "Cancel download of \(app.name)" : state?.fileURL != nil ? "\(app.name) downloaded" : "Download \(app.name)")
    }

    private var loading: some View {
        VStack(spacing: 15) {
            ProgressView().controlSize(.large)
            Text("Loading apps…").font(.system(size: 14)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }

    private var emptySearch: some View {
        VStack(spacing: 14) {
            Image(systemName: "magnifyingglass").font(.system(size: 38, weight: .light)).foregroundStyle(marketplaceAccent)
            Text("No apps found").font(.system(size: 20, weight: .semibold))
            Text("Try an app name or a different search.").font(.system(size: 13)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }

    private func unavailable(_ message: String) -> some View {
        VStack(spacing: 15) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 38, weight: .light)).foregroundStyle(marketplaceAccent)
            Text("Apps couldn’t load").font(.system(size: 20, weight: .semibold))
            Text(message).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Try again") { marketplace.refresh() }
                .buttonStyle(.borderedProminent).tint(marketplaceAccent).foregroundStyle(.black)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 16) {
            Text("Downloaded apps still need support from Andriloft’s compatibility layer.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Link(destination: URL(string: "https://www.apkmirror.com")!) {
                HStack(spacing: 5) { Text("Powered by APKMirror"); Image(systemName: "arrow.up.right").font(.system(size: 9)) }
            }
            .font(.system(size: 11)).foregroundStyle(marketplaceAccent)
        }.padding(.horizontal, 24).padding(.vertical, 14).background(.black.opacity(0.12))
    }
}

struct MarketplaceAccountSetupView: View {
    @EnvironmentObject private var marketplace: MarketplaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: marketplace.accountState == .ready ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                    .font(.system(size: 35, weight: .light))
                    .foregroundStyle(marketplaceAccent)
                Spacer()
                Button { marketplace.dismissAccountSetup() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close account setup")
                .accessibilityLabel("Close account setup")
            }
            VStack(alignment: .leading, spacing: 9) {
                Text(marketplace.accountState == .ready ? "Google account connected" : "Connect your Google account")
                    .font(.system(size: 23, weight: .semibold))
                Text(marketplace.accountState == .ready ? "You’re ready to download apps with a single click." : "Complete this one-time setup to download apps using your Google account.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            connectionStatus

            if let error = marketplace.accountSetupError {
                Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Text("Google Antigravity selects the APK version in the cloud. App and version details, plus basic computer compatibility specs, are sent to Google. Computer names, serial numbers and personal files are excluded. Downloads come from APKMirror.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if marketplace.accountState != .ready {
                    Button("Cancel") { marketplace.dismissAccountSetup() }
                        .keyboardShortcut(.cancelAction)
                    if marketplace.signInWindowOpened {
                        Button("Reopen setup") { marketplace.connectGoogleAccount() }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .disabled(marketplace.isSettingUpAccount || marketplace.accountState == .checking)
                    }
                }
                Spacer()
                primaryAction
            }
        }
        .padding(28)
        .frame(width: 450)
    }

    @ViewBuilder private var connectionStatus: some View {
        if marketplace.isSettingUpAccount {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Opening Google account setup…")
            }.font(.system(size: 13)).foregroundStyle(.secondary)
        } else if marketplace.accountState == .checking {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking your connection…")
            }.font(.system(size: 13)).foregroundStyle(.secondary)
        } else if marketplace.accountState == .ready {
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(marketplaceAccent)
        } else if marketplace.signInWindowOpened {
            Text("Finish Google sign-in in the setup window, then return here and check your connection.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Setup opens Terminal and your browser. Sign in with Google there, then return to Andriloft.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var primaryAction: some View {
        if marketplace.accountState == .ready {
            Button("Done") { marketplace.dismissAccountSetup() }
                .buttonStyle(.borderedProminent).tint(marketplaceAccent).foregroundStyle(.black)
                .keyboardShortcut(.defaultAction)
        } else if marketplace.signInWindowOpened || marketplace.accountState == .unavailable {
            Button("Check connection") { marketplace.checkAccountConnection(resumePendingDownload: true) }
                .buttonStyle(.borderedProminent).tint(marketplaceAccent).foregroundStyle(.black)
                .disabled(marketplace.isSettingUpAccount || marketplace.accountState == .checking)
                .keyboardShortcut(.defaultAction)
        } else {
            Button("Connect Google account") { marketplace.connectGoogleAccount() }
                .buttonStyle(.borderedProminent).tint(marketplaceAccent).foregroundStyle(.black)
                .disabled(marketplace.isSettingUpAccount || marketplace.accountState == .checking)
                .keyboardShortcut(.defaultAction)
        }
    }
}
