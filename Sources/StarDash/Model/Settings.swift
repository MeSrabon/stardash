import Foundation
import Observation
import ServiceManagement

enum MenuBarItem: String, CaseIterable, Identifiable, Codable {
    case latency, pingSuccess, throughput, power, obstruction, events, sparkline

    var id: String { rawValue }

    var label: String {
        switch self {
        case .latency: return "Latency"
        case .pingSuccess: return "Ping success"
        case .throughput: return "Throughput"
        case .power: return "Power draw"
        case .obstruction: return "Obstruction"
        case .events: return "Outages (last hour)"
        case .sparkline: return "Latency sparkline"
        }
    }
}

@Observable
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    var menuBarItems: [MenuBarItem] { didSet { d.set(menuBarItems.map(\.rawValue), forKey: "menuBarItems") } }
    var showStatusDot: Bool { didSet { d.set(showStatusDot, forKey: "showStatusDot") } }
    var useBytes: Bool { didSet { d.set(useBytes, forKey: "useBytes") } }
    var pollInterval: Double { didSet { d.set(pollInterval, forKey: "pollInterval") } }
    var dishHost: String { didSet { d.set(dishHost, forKey: "dishHost") } }
    var routerHost: String { didSet { d.set(routerHost, forKey: "routerHost") } }
    var avoidTunnels: Bool { didSet { d.set(avoidTunnels, forKey: "avoidTunnels") } }
    var notifyOutages: Bool { didSet { d.set(notifyOutages, forKey: "notifyOutages") } }
    var notifyAlerts: Bool { didSet { d.set(notifyAlerts, forKey: "notifyAlerts") } }
    var outageThreshold: Double { didSet { d.set(outageThreshold, forKey: "outageThreshold") } }
    var themeName: String { didSet { d.set(themeName, forKey: "theme") } }
    var openWindowAtLaunch: Bool { didSet { d.set(openWindowAtLaunch, forKey: "openWindowAtLaunch") } }
    /// Where the dish is, for working out which satellites are overhead. Kept to two decimals, about a kilometre.
    var siteLatitude: Double { didSet { d.set(siteLatitude, forKey: "siteLatitude") } }
    var siteLongitude: Double { didSet { d.set(siteLongitude, forKey: "siteLongitude") } }
    var hasSite: Bool { didSet { d.set(hasSite, forKey: "hasSite") } }

    func setSite(latitude: Double, longitude: Double) {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { return }
        siteLatitude = (latitude * 100).rounded() / 100
        siteLongitude = (longitude * 100).rounded() / 100
        hasSite = true
    }

    private init() {
        d.register(defaults: [
            "menuBarItems": [MenuBarItem.latency.rawValue, MenuBarItem.throughput.rawValue],
            "showStatusDot": true,
            "useBytes": false,
            "pollInterval": 1.0,
            "dishHost": "192.168.100.1",
            "routerHost": "192.168.1.1",
            "avoidTunnels": true,
            "notifyOutages": true,
            "notifyAlerts": true,
            "outageThreshold": 10.0,
            "openWindowAtLaunch": true,
        ])
        menuBarItems = (d.stringArray(forKey: "menuBarItems") ?? []).compactMap(MenuBarItem.init(rawValue:))
        showStatusDot = d.bool(forKey: "showStatusDot")
        useBytes = d.bool(forKey: "useBytes")
        pollInterval = max(1, d.double(forKey: "pollInterval"))
        dishHost = d.string(forKey: "dishHost") ?? "192.168.100.1"
        routerHost = d.string(forKey: "routerHost") ?? "192.168.1.1"
        avoidTunnels = d.bool(forKey: "avoidTunnels")
        notifyOutages = d.bool(forKey: "notifyOutages")
        notifyAlerts = d.bool(forKey: "notifyAlerts")
        outageThreshold = d.double(forKey: "outageThreshold")
        openWindowAtLaunch = d.bool(forKey: "openWindowAtLaunch")
        themeName = d.string(forKey: "theme") ?? "glass"
        siteLatitude = d.double(forKey: "siteLatitude")
        siteLongitude = d.double(forKey: "siteLongitude")
        hasSite = d.bool(forKey: "hasSite")
    }

    func toggle(_ item: MenuBarItem) {
        if let i = menuBarItems.firstIndex(of: item) {
            menuBarItems.remove(at: i)
        } else {
            // Keep a stable order regardless of the order things were enabled in.
            menuBarItems = MenuBarItem.allCases.filter { menuBarItems.contains($0) || $0 == item }
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("StarDash: launch at login failed: \(error.localizedDescription)")
            }
        }
    }
}
