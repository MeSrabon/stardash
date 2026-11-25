import AppKit
import Observation
import Sparkle

/// Updates through Sparkle, with StarDash drawing the UI itself (a popover row and a Settings panel).
/// Sparkle does the feed check, download, EdDSA signature check and the swap and relaunch.
/// The feed is `appcast.xml` on the latest GitHub release; see `SUFeedURL` in scripts/bundle.sh.
@MainActor
@Observable
final class AppUpdater: NSObject {
    static let shared = AppUpdater()

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading(Double?)
        case extracting
        case installing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// The version on offer, and its notes from the appcast.
    private(set) var offer: (version: String, notes: String?)?
    private(set) var lastChecked: Date?

    var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    /// Only a real app bundle has a feed and a key. `swift run` and demo mode skip updates.
    var isAvailable: Bool { controller != nil }

    /// Mirrors Sparkle's own setting, which it keeps in user defaults.
    var checksAutomatically = true {
        didSet { controller?.automaticallyChecksForUpdates = checksAutomatically }
    }

    var hasUpdate: Bool {
        switch phase {
        case .available, .downloading, .extracting, .installing: return true
        default: return false
        }
    }

    @ObservationIgnored private var controller: SPUUpdater?
    @ObservationIgnored private var reply: ((SPUUserUpdateChoice) -> Void)?
    @ObservationIgnored private var cancelCheck: (() -> Void)?
    @ObservationIgnored private var expected: UInt64 = 0
    @ObservationIgnored private var received: UInt64 = 0
    @ObservationIgnored private var autoInstall = false

    func start() {
        guard controller == nil, !Demo.on, Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: nil)
        do {
            try updater.start()
            controller = updater
            lastChecked = updater.lastUpdateCheckDate
            checksAutomatically = updater.automaticallyChecksForUpdates
            // Test hook: check now and install whatever is found, without clicks.
            if CommandLine.arguments.contains("--update-test") {
                autoInstall = true
                check()
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func check() {
        guard let controller, controller.canCheckForUpdates else { return }
        controller.checkForUpdates()
    }

    func install() {
        guard let reply else { return }
        self.reply = nil
        reply(.install)
    }

    /// Hides the offer until the next check. Sparkle asks again later.
    func later() {
        let reply = self.reply
        self.reply = nil
        offer = nil
        phase = .idle
        reply?(.dismiss)
    }

    /// For screenshots: pretend an update is waiting.
    func showDemoOffer() {
        offer = ("0.5.0", "Pick the speed test server, and update from inside the app.")
        phase = .available
    }

    private func finishCheck() {
        cancelCheck = nil
        lastChecked = controller?.lastUpdateCheckDate ?? Date()
    }
}

extension AppUpdater: SPUUserDriver {
    nonisolated func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Daily checks are on by default and can be turned off in Settings. Nothing about the Mac is sent.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    nonisolated func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        MainActor.assumeIsolated {
            cancelCheck = cancellation
            phase = .checking
        }
    }

    nonisolated func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let version = appcastItem.displayVersionString
        let notes = appcastItem.itemDescription
        MainActor.assumeIsolated {
            finishCheck()
            self.reply = reply
            offer = (version, notes)
            phase = .available
            if autoInstall { install() }
        }
    }

    nonisolated func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    nonisolated func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    nonisolated func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        MainActor.assumeIsolated {
            finishCheck()
            phase = .upToDate
        }
        acknowledgement()
    }

    nonisolated func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            finishCheck()
            reply = nil
            phase = .failed(message)
        }
        acknowledgement()
    }

    nonisolated func showDownloadInitiated(cancellation: @escaping () -> Void) {
        MainActor.assumeIsolated {
            expected = 0
            received = 0
            phase = .downloading(nil)
        }
    }

    nonisolated func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        MainActor.assumeIsolated { expected = expectedContentLength }
    }

    nonisolated func showDownloadDidReceiveData(ofLength length: UInt64) {
        MainActor.assumeIsolated {
            received += length
            phase = .downloading(expected > 0 ? min(1, Double(received) / Double(expected)) : nil)
        }
    }

    nonisolated func showDownloadDidStartExtractingUpdate() {
        MainActor.assumeIsolated { phase = .extracting }
    }

    nonisolated func showExtractionReceivedProgress(_ progress: Double) {
        MainActor.assumeIsolated { phase = .extracting }
    }

    nonisolated func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // The person already chose Install, so go straight on.
        MainActor.assumeIsolated { phase = .installing }
        reply(.install)
    }

    nonisolated func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        MainActor.assumeIsolated { phase = .installing }
    }

    nonisolated func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        MainActor.assumeIsolated { phase = .idle }
        acknowledgement()
    }

    nonisolated func showUpdateInFocus() {}

    nonisolated func dismissUpdateInstallation() {
        MainActor.assumeIsolated {
            reply = nil
            cancelCheck = nil
            switch phase {
            case .upToDate, .failed: break
            default:
                offer = nil
                phase = .idle
            }
        }
    }
}
