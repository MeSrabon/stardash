import CoreLocation
import Foundation
import Observation

/// Keeps the list of Starlink satellites over the dish current while someone is looking at the sky.
@MainActor
@Observable
final class SkyWatch {
    static let shared = SkyWatch()

    var satellites: [VisibleSatellite] = []
    /// Where each satellite will be half a minute from now, for drawing which way it's heading.
    var ahead: [Int: SkyPosition] = [:]
    var catalogCount = 0
    var fetchedAt: Date?
    var error: String?
    /// Every satellite's place over the Earth, for the dashboard globe. Empty until the orbits load.
    var shell: [SIMD3<Float>] = []
    @ObservationIgnored private var shellWatchers = 0

    /// The globe asks for the whole constellation only while it's on screen.
    func watchShell(_ on: Bool) { shellWatchers = max(0, shellWatchers + (on ? 1 : -1)) }

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var watchers = 0

    /// Starlink doesn't serve from satellites lower than this.
    nonisolated static let serviceElevation = 25.0

    func start(site: @escaping @MainActor () -> GeoPoint?, floor: @escaping @MainActor () -> Double) {
        watchers += 1
        guard loop == nil else { return }
        loop = Task { [weak self] in
            var tick = 0
            var loaded = false
            while !Task.isCancelled {
                let wantsShell = (self?.shellWatchers ?? 0) > 0
                // Nothing is downloaded until something on screen needs it.
                if site() != nil || wantsShell, !loaded || tick % 600 == 0 {
                    loaded = true
                    await SatelliteCatalog.shared.refreshIfNeeded()
                    let count = await SatelliteCatalog.shared.count
                    let fetched = await SatelliteCatalog.shared.fetchedAt
                    let problem = await SatelliteCatalog.shared.lastError
                    self?.catalogCount = count
                    self?.fetchedAt = fetched
                    self?.error = problem
                }
                tick += 1
                if wantsShell, tick % 2 == 1 {
                    let all = await SatelliteCatalog.shared.shell(at: Date())
                    if !all.isEmpty { self?.shell = all }
                }
                if let point = site() {
                    let now = Date()
                    let minimum = floor()
                    let current = await SatelliteCatalog.shared.visible(from: point, at: now, minElevation: minimum)
                    let later = await SatelliteCatalog.shared.visible(from: point, at: now.addingTimeInterval(30), minElevation: minimum - 5)
                    guard let self, !Task.isCancelled else { return }
                    self.satellites = current
                    self.ahead = Dictionary(later.map { ($0.id, SkyPosition(azimuth: $0.azimuth, elevation: $0.elevation, rangeKm: $0.rangeKm)) },
                                            uniquingKeysWith: { a, _ in a })
                } else if self?.satellites.isEmpty == false {
                    self?.satellites = []
                    self?.ahead = [:]
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        loop?.cancel()
        loop = nil
    }

    /// The dish doesn't say which satellite it's using. This picks the one it most plausibly is:
    /// in service range, in clear sky, and closest to where the dish faces.
    func bestPlaced(alignment: Alignment?, map: ObstructionMap?) -> VisibleSatellite? {
        let candidates = satellites.filter { sat in
            guard sat.elevation >= Self.serviceElevation else { return false }
            if let v = map?.sample(azimuth: sat.azimuth, elevation: sat.elevation), v >= 0, v < 0.5 { return false }
            return true
        }
        guard let az = alignment?.azimuth, let el = alignment?.elevation else { return candidates.first }
        return candidates.min { Self.separation(az, el, $0.azimuth, $0.elevation) < Self.separation(az, el, $1.azimuth, $1.elevation) }
    }

    /// Angle between two directions in the sky, in degrees.
    static func separation(_ az1: Double, _ el1: Double, _ az2: Double, _ el2: Double) -> Double {
        let r = Double.pi / 180
        let c = sin(el1 * r) * sin(el2 * r) + cos(el1 * r) * cos(el2 * r) * cos((az1 - az2) * r)
        return acos(min(1, max(-1, c))) / r
    }
}

extension TelemetryStore {
    /// Where the dish is: its own fix when it shares one, otherwise what was set in Settings.
    var site: GeoPoint? {
        if let dishLocation { return dishLocation }
        let s = Settings.shared
        return s.hasSite ? GeoPoint(latitude: s.siteLatitude, longitude: s.siteLongitude) : nil
    }

    /// Most dishes refuse this unless location sharing is switched on in the Starlink app.
    func refreshLocation() async {
        guard let response = try? await dishClient.call(1017),
              let lla = response.message(1017)?.message(1),
              let lat = lla.float(1), let lon = lla.float(2), lat != 0 || lon != 0 else { return }
        dishLocation = GeoPoint(latitude: lat, longitude: lon, altitudeKm: (lla.float(3) ?? 0) / 1000)
    }
}

/// Asks macOS where this Mac is, once. The Mac sits near the dish, which is close enough for a sky chart.
@MainActor
final class MacLocation: NSObject, CLLocationManagerDelegate {
    static let shared = MacLocation()
    private let manager = CLLocationManager()
    private var done: ((Result<CLLocationCoordinate2D, Error>) -> Void)?

    struct Refused: LocalizedError {
        var errorDescription: String? { "Location access is off for StarDash. Allow it in System Settings, Privacy & Security, Location Services." }
    }

    func find(_ completion: @escaping (Result<CLLocationCoordinate2D, Error>) -> Void) {
        done = completion
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        switch manager.authorizationStatus {
        case .denied, .restricted: finish(.failure(Refused()))
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: manager.requestLocation()
        }
    }

    private func finish(_ result: Result<CLLocationCoordinate2D, Error>) {
        done?(result)
        done = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard self.done != nil else { return }
            switch status {
            case .denied, .restricted: self.finish(.failure(Refused()))
            case .notDetermined: break
            default: self.manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        Task { @MainActor in self.finish(.success(coordinate)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(.failure(error)) }
    }
}
