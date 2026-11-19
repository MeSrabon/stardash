import AppKit
import Foundation
import Observation
import WebKit

/// The optional Starlink account. Everything else in StarDash works without it.
@MainActor
@Observable
final class Account {
    static let shared = Account()

    enum Status: Equatable {
        case signedOut
        case signedIn
        /// A session is stored but Starlink stopped accepting it.
        case expired
    }

    private(set) var status: Status
    private(set) var profile: CloudProfile?
    var problem: String?

    private(set) var billing: BillingUsage?
    private(set) var billingError: String?
    private(set) var billingLoading = false
    @ObservationIgnored private var billingAt = Date.distantPast

    private(set) var router: RouterCloudSettings?
    private(set) var routerError: String?
    private(set) var routerLoading = false

    @ObservationIgnored let cloud = StarlinkCloud()
    @ObservationIgnored private var signInWindow: SignInWindow?
    @ObservationIgnored private var profileLoaded = false

    var signedIn: Bool { status == .signedIn }
    var signingIn: Bool { signInWindow != nil }

    /// What to call the account: a name, an email or the account number.
    var title: String {
        profile?.name ?? profile?.email ?? profile?.accountNumber ?? "Starlink account"
    }

    private init() {
        // Only the keychain is read here. Nothing is sent until a page asks for account data.
        status = Keychain.read() != nil ? .signedIn : .signedOut
    }

    // MARK: Session

    func signIn() {
        if let signInWindow {
            signInWindow.show()
            return
        }
        problem = nil
        let window = SignInWindow { [weak self] cookie in
            guard let self else { return false }
            return await self.adopt(cookie)
        } onClose: { [weak self] in
            self?.signInWindow = nil
        }
        signInWindow = window
        window.show()
    }

    /// Takes a session from the sign-in window. True once Starlink accepts it.
    private func adopt(_ cookie: String) async -> Bool {
        do {
            let profile = try await cloud.connect(cookie)
            self.profile = profile
            profileLoaded = true
            status = .signedIn
            problem = nil
            billing = nil
            router = nil
            return true
        } catch CloudError.signedOut {
            problem = "Starlink didn't accept that sign-in. Try again."
            return false
        } catch {
            problem = error.localizedDescription
            return false
        }
    }

    /// Deletes the keychain item and anything the sign-in page stored.
    func signOut() {
        Keychain.delete()
        Task { await cloud.forget() }
        status = .signedOut
        profile = nil
        profileLoaded = false
        billing = nil
        billingError = nil
        router = nil
        routerError = nil
        problem = nil
        signInWindow?.close()
        SignInWindow.clearWebData()
    }

    private func noteFailure(_ error: Error) -> String {
        if case CloudError.signedOut = error, status != .signedOut { status = .expired }
        return error.localizedDescription
    }

    // MARK: Reads

    func loadProfile(force: Bool = false) async {
        guard status != .signedOut, force || !profileLoaded else { return }
        profileLoaded = true
        do {
            profile = try await cloud.profile()
            status = .signedIn
            problem = nil
        } catch {
            profileLoaded = false
            problem = noteFailure(error)
        }
    }

    func loadBilling(force: Bool = false) async {
        guard signedIn, !billingLoading else { return }
        guard force || billing == nil || Date().timeIntervalSince(billingAt) > 600 else { return }
        billingLoading = true
        defer { billingLoading = false }
        do {
            billing = try await cloud.billing()
            billingAt = Date()
            billingError = nil
        } catch {
            billingError = noteFailure(error)
        }
    }

    func loadRouter() async {
        guard signedIn, !routerLoading else { return }
        routerLoading = true
        defer { routerLoading = false }
        do {
            router = try await cloud.routerSettings()
            routerError = nil
        } catch {
            routerError = noteFailure(error)
        }
    }

    // MARK: Writes. Each returns nil on success, or what went wrong.

    func setWifi(renames: [String: String], password: String) async -> String? {
        await write { try await self.cloud.setWifi(renames: renames, password: password) }
    }

    func setNameservers(_ servers: [String]) async -> String? {
        await write { try await self.cloud.setNameservers(servers) }
    }

    func setPaused(clientID: UInt64, paused: Bool, protect: Set<String>) async -> String? {
        await write(reload: false) { try await self.cloud.setPaused(clientID: clientID, paused: paused, protect: protect) }
    }

    func factoryResetRouter() async -> String? {
        await write(reload: false) { try await self.cloud.factoryResetRouter() }
    }

    private func write(reload: Bool = true, _ work: () async throws -> Void) async -> String? {
        guard signedIn else { return "Sign in to your Starlink account first." }
        do {
            try await work()
            if reload {
                // The router takes a moment to apply a change before it reports it.
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    await self.loadRouter()
                }
            }
            return nil
        } catch {
            return noteFailure(error)
        }
    }
}

// MARK: Sign-in window

/// A plain window with the starlink.com sign-in page. Captcha and two-step codes happen in the page.
/// The page's storage lives in memory only, so nothing it keeps outlasts the window.
@MainActor
final class SignInWindow: NSObject, NSWindowDelegate, WKHTTPCookieStoreObserver, WKNavigationDelegate {
    private static let start = URL(string: "https://www.starlink.com/account")!

    private let window: NSWindow
    private let web: WKWebView
    private let adopt: (String) async -> Bool
    private let onClose: () -> Void
    private var adopting = false
    private var done = false

    init(adopt: @escaping (String) async -> Bool, onClose: @escaping () -> Void) {
        self.adopt = adopt
        self.onClose = onClose
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 980, height: 760), configuration: config)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Sign in to Starlink"
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.delegate = self
        window.center()
        web.navigationDelegate = self
        config.websiteDataStore.httpCookieStore.add(self)
        web.load(URLRequest(url: Self.start))
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        web.configuration.websiteDataStore.httpCookieStore.remove(self)
        web.stopLoading()
        onClose()
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in self.tryAdopt() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        tryAdopt()
    }

    /// The durable `Starlink.Com.Sso` cookie appears the moment sign-in completes. The short-lived
    /// token can land a beat later, so the jar is read again on each try.
    private func tryAdopt() {
        guard !done, !adopting else { return }
        adopting = true
        Task {
            defer { adopting = false }
            for attempt in 0..<4 {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(700)) }
                guard !done, let cookie = await sessionCookie() else { continue }
                if await adopt(cookie) {
                    done = true
                    window.close()
                    return
                }
            }
        }
    }

    private func sessionCookie() async -> String? {
        let all = await web.configuration.websiteDataStore.httpCookieStore.allCookies()
        let starlink = all.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return domain == "starlink.com" || domain.hasSuffix(".starlink.com")
        }
        guard starlink.contains(where: { $0.name == "Starlink.Com.Sso" }) else { return nil }
        // One value per name. The more specific domain goes last so it wins.
        var jar: [(String, String)] = []
        for cookie in starlink.sorted(by: { $0.domain.count < $1.domain.count }) {
            jar.removeAll { $0.0 == cookie.name }
            jar.append((cookie.name, cookie.value))
        }
        return jar.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }

    /// Removes anything starlink.com left in the app's shared web storage. The sign-in window
    /// keeps its own in memory, but this covers older builds and any other web view.
    static func clearWebData() {
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let starlink = records.filter { $0.displayName.contains("starlink") }
            guard !starlink.isEmpty else { return }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: starlink) {}
        }
    }
}
