import AppKit
import Foundation

#if canImport(Sparkle)
import Sparkle
#endif

/// The updater is intentionally opt-in at bundle-build time. A public Ed25519
/// key and an HTTPS feed must both be present before Sparkle gets control; that
/// prevents a half-configured release from presenting a broken update flow.
struct SparkleConfiguration: Equatable {
    let feedURL: String
    let publicEDKey: String

    static func from(bundle: Bundle = .main) -> SparkleConfiguration? {
        guard let info = bundle.infoDictionary,
              let feedURL = info["SUFeedURL"] as? String,
              let publicEDKey = info["SUPublicEDKey"] as? String,
              // Refuse a hand-edited/broken bundle that points Sparkle at an
              // unsigned feed even when a key and URL happen to be present.
              (info["SURequireSignedFeed"] as? Bool) == true,
              isValid(feedURL: feedURL, publicEDKey: publicEDKey) else {
            return nil
        }
        return SparkleConfiguration(feedURL: feedURL, publicEDKey: publicEDKey)
    }

    /// Sparkle public keys are base64 encodings of 32-byte Ed25519 keys.
    /// Keeping this pure makes it testable without a live feed or credentials.
    static func isValid(feedURL: String, publicEDKey: String) -> Bool {
        guard let url = URL(string: feedURL), url.scheme == "https", url.host != nil else {
            return false
        }
        return publicEDKey.range(of: "^[A-Za-z0-9+/]{43}=$", options: .regularExpression) != nil
    }
}

/// Owns Sparkle's standard updater UI while retaining the old GitHub Releases
/// check for locally built bundles before the one-time signing setup is done.
@MainActor
final class UpdateManager: NSObject {
    private let configuration: SparkleConfiguration?
    private var didStart = false

    #if canImport(Sparkle)
    private var sparkleController: SPUStandardUpdaterController?
    #endif

    init(bundle: Bundle = .main) {
        configuration = SparkleConfiguration.from(bundle: bundle)
        super.init()
    }

    var usesSparkle: Bool {
        #if canImport(Sparkle)
        return sparkleController != nil
        #else
        return false
        #endif
    }

    /// Must run after applicationDidFinishLaunching; Sparkle's documented
    /// programmatic controller starts an updater for the main bundle here.
    func start() {
        guard !didStart else { return }
        didStart = true

        #if canImport(Sparkle)
        guard configuration != nil else { return }
        sparkleController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        #endif
    }

    func checkForUpdates(_ sender: Any? = nil) {
        #if canImport(Sparkle)
        if let sparkleController {
            // Sparkle supplies the standard macOS sheet, including its
            // authenticated "Install and Relaunch" action.
            sparkleController.checkForUpdates(sender)
            return
        }
        #endif
        checkGitHubReleases()
    }

    private func checkGitHubReleases() {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/brianyoungilcho/claude-dash/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            var latest: String?
            var releaseURL: String?
            if let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                latest = (object["tag_name"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                releaseURL = object["html_url"] as? String
            }
            DispatchQueue.main.async {
                let alert = NSAlert()
                if let latest {
                    let upToDate = latest.compare(current, options: .numeric) != .orderedDescending
                    alert.messageText = upToDate ? "You're up to date" : "Update available: v\(latest)"
                    alert.informativeText = upToDate
                        ? "Claude Dash v\(current) is the latest release."
                        : "You have v\(current). Download v\(latest) from GitHub, or run git pull && ./install.sh."
                    alert.addButton(withTitle: upToDate ? "OK" : "Open Releases")
                    if !upToDate { alert.addButton(withTitle: "Later") }
                    if alert.runModal() == .alertFirstButtonReturn,
                       !upToDate,
                       let releaseURL,
                       let url = URL(string: releaseURL) {
                        NSWorkspace.shared.open(url)
                    }
                } else {
                    alert.messageText = "Couldn't check for updates"
                    alert.informativeText = "GitHub wasn't reachable. Try again later."
                    alert.runModal()
                }
            }
        }.resume()
    }
}
