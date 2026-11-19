import Foundation

/// The dish's own settings, the same ones the Starlink app changes.
struct DishConfig: Equatable {
    enum SnowMelt: Int, CaseIterable {
        case auto = 0, alwaysOn = 1, off = 2

        var label: String {
            switch self {
            case .auto: return "Automatic"
            case .alwaysOn: return "Always on"
            case .off: return "Off"
            }
        }
    }

    var snowMelt: SnowMelt = .auto
    /// Sleep schedule. Start is minutes past midnight UTC, the way the dish stores it.
    var sleepEnabled = false
    var sleepStartMinutes = 0
    var sleepDurationMinutes = 0
    /// Hour of the day, on the dish's local clock, when it restarts to install updates.
    var updateHour = 0
    var deferUpdates = false

    init() {}

    init(_ m: ProtoMessage) {
        snowMelt = SnowMelt(rawValue: m.int(1) ?? 0) ?? .auto
        sleepStartMinutes = m.int(4) ?? 0
        sleepDurationMinutes = m.int(5) ?? 0
        sleepEnabled = m.bool(6)
        deferUpdates = m.bool(7)
        updateHour = m.int(9) ?? 0
    }

    /// Minutes between UTC and this Mac's clock.
    private static var offset: Int { TimeZone.current.secondsFromGMT() / 60 }

    /// Sleep start as an hour on this Mac's clock.
    var sleepStartLocalHour: Int { ((sleepStartMinutes + Self.offset) % 1440 + 1440) % 1440 / 60 }

    static func utcMinutes(localHour: Int) -> Int { ((localHour * 60 - offset) % 1440 + 1440) % 1440 }
}

/// One change to send. Each setting travels with a flag saying "apply this one", so nothing else is touched.
enum DishChange {
    case snowMelt(DishConfig.SnowMelt)
    case sleep(enabled: Bool, startMinutesUTC: Int, durationMinutes: Int)
    case updateHour(Int)
    case deferUpdates(Bool)

    private static func varint(_ field: Int, _ value: Int) -> [UInt8] {
        ProtoWriter.varint(UInt64(field) << 3) + ProtoWriter.varint(UInt64(value))
    }

    var encoded: [UInt8] {
        switch self {
        case .snowMelt(let mode):
            return Self.varint(1, mode.rawValue) + Self.varint(1001, 1)
        case .sleep(let enabled, let start, let duration):
            return Self.varint(4, start) + Self.varint(4001, 1) + Self.varint(5, duration) + Self.varint(5001, 1)
                + Self.varint(6, enabled ? 1 : 0) + Self.varint(6001, 1)
        case .updateHour(let hour):
            return Self.varint(9, hour) + Self.varint(9001, 1)
        case .deferUpdates(let on):
            return Self.varint(7, on ? 1 : 0) + Self.varint(7001, 1)
        }
    }
}

extension TelemetryStore {
    func loadDishConfig() async {
        guard let response = try? await dishClient.call(2011), let config = response.message(2011)?.message(1) else {
            // An all-default config comes back as an empty message, which still counts as an answer.
            if let response = try? await dishClient.call(2011), response.has(2011) { dishConfig = DishConfig() }
            return
        }
        dishConfig = DishConfig(config)
    }

    /// Sends one change and returns nil on success, or what the dish said went wrong.
    func apply(_ change: DishChange) async -> String? {
        do {
            let response = try await dishClient.call(2010, body: ProtoWriter.field(1, body: change.encoded), timeout: 6)
            let reply = response.message(2010)
            if let problem = reply?.string(2) { return problem }
            dishConfig = DishConfig(reply?.message(1) ?? .empty)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Throws away the obstruction map. The dish rebuilds it over the following hours.
    func clearObstructionMap() async -> Bool {
        guard (try? await dishClient.call(2017)) != nil else { return false }
        mapFrames = []
        await refreshMap()
        return true
    }

    func stowDish(_ stow: Bool) async -> Bool {
        (try? await dishClient.call(2002, body: stow ? [] : [8, 1])) != nil
    }

    /// Erases the dish back to how it shipped. `DishFactoryResetRequest { app_reset = true }`, the
    /// dish's own request (it answers the generic factory_reset with Unimplemented). From Dishylink's
    /// core/dishClient.ts. Returns what happened, worded for the user.
    func factoryResetDish() async -> (ok: Bool, message: String) {
        guard dish != nil, dishError == nil else { return (false, "The dish isn't answering, so nothing was sent.") }
        do {
            _ = try await dishClient.call(2021, body: [0x08, 0x01], timeout: 8)
            return (true, "Factory reset sent. The dish is erasing itself and restarting. Set it up again in the Starlink app.")
        } catch TelemetryError.timeout {
            // The dish drops off as it resets, which can cut the reply short.
            return (true, "Factory reset sent. The dish stopped answering, which is expected while it erases itself.")
        } catch {
            return (false, "The dish refused: \(error.localizedDescription)")
        }
    }

    func rebootRouter() async -> Bool {
        (try? await routerClient.call(1001)) != nil
    }
}
