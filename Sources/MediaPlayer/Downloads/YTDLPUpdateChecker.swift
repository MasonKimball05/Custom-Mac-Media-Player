import AppKit
import SwiftUI

/// Watches for a newer yt-dlp. Sites change often enough that an old yt-dlp stops being
/// able to download from them, and yt-dlp ships fixes within days, so being a few versions
/// behind is the most common reason a download fails.
///
/// The app can't install the update itself: its sandbox can read Homebrew's folder but not
/// write to it. So this compares the installed version with the one Homebrew currently
/// offers (not yt-dlp's GitHub releases, which Homebrew can lag by hours, and `brew
/// upgrade` can only install what Homebrew has) and says how to update when it's behind.
@MainActor
final class YTDLPUpdateChecker: ObservableObject {
    static let updateCommand = "brew upgrade yt-dlp"

    @Published private(set) var installedVersion: String?
    @Published private(set) var latestVersion: String?

    /// How stale the latest-version check may get. Homebrew's listing is a small static
    /// file, but there's no reason to fetch it more than about daily.
    private let checkInterval: TimeInterval = 24 * 60 * 60
    private let formulaURL = URL(string: "https://formulae.brew.sh/api/formula/yt-dlp.json")!
    private var periodicTask: Task<Void, Never>?

    var isOutdated: Bool {
        guard let installedVersion, let latestVersion else { return false }
        return Self.isVersion(latestVersion, newerThan: installedVersion)
    }

    init() {
        latestVersion = UserDefaults.standard.string(forKey: AppSettingsKeys.ytdlpLatestVersion)
        // Checked again every few hours while the app stays open, which can be days.
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
            }
        }
    }

    /// Re-reads the installed version every time (it's quick, and it's how an update the
    /// user just ran in Terminal gets noticed), and Homebrew's latest version when the last
    /// check is more than a day old.
    func refresh() async {
        installedVersion = await YTDLP.installedVersion()
        guard installedVersion != nil else { return }

        let lastCheck = UserDefaults.standard.object(forKey: AppSettingsKeys.ytdlpLastUpdateCheck) as? Date
        if let lastCheck, Date().timeIntervalSince(lastCheck) < checkInterval, latestVersion != nil { return }
        guard let latest = await fetchLatestVersion() else { return }
        latestVersion = latest
        UserDefaults.standard.set(latest, forKey: AppSettingsKeys.ytdlpLatestVersion)
        UserDefaults.standard.set(Date(), forKey: AppSettingsKeys.ytdlpLastUpdateCheck)
    }

    private func fetchLatestVersion() async -> String? {
        guard let (data, response) = try? await URLSession.shared.data(from: formulaURL),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let versions = json["versions"] as? [String: Any] else { return nil }
        return versions["stable"] as? String
    }

    func copyUpdateCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.updateCommand, forType: .string)
    }

    func openTerminal() {
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    /// Homebrew's "2026.9.21" written the way yt-dlp writes its own version, "2026.09.21".
    static func displayVersion(_ version: String) -> String {
        let parts = (version.split(separator: "_").first ?? "").split(separator: ".")
        return parts.enumerated().map { index, part in
            index > 0 && part.count == 1 ? "0" + part : String(part)
        }.joined(separator: ".")
    }

    /// Compares dotted versions numerically: Homebrew writes "2026.8.19" where yt-dlp itself
    /// says "2026.08.19". A Homebrew revision suffix ("_1") is ignored.
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.split(separator: "_").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let (a, b) = (parts(candidate), parts(current))
        for index in 0..<max(a.count, b.count) {
            let (x, y) = (index < a.count ? a[index] : 0, index < b.count ? b[index] : 0)
            if x != y { return x > y }
        }
        return false
    }
}

/// Shown in the download sheet and the downloads list while yt-dlp is behind Homebrew's
/// version, with the command that updates it. Nothing is shown when it's current.
struct YTDLPUpdateNotice: View {
    @ObservedObject var updates: YTDLPUpdateChecker

    @State private var copied = false

    var body: some View {
        if updates.isOutdated, let installed = updates.installedVersion, let latest = updates.latestVersion {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("yt-dlp \(YTDLPUpdateChecker.displayVersion(latest)) is available (you have \(installed)). Sites change often, and older versions stop working with them. Update to keep downloads working.")
                } icon: {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text(YTDLPUpdateChecker.updateCommand)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    Button(copied ? "Copied" : "Copy") {
                        updates.copyUpdateCommand()
                        copied = true
                    }
                    Button("Open Terminal") { updates.openTerminal() }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
