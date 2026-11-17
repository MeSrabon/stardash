import SwiftUI

/// The router and Wi-Fi page in the main window.
struct NetworkPane: View {
    @Environment(TelemetryStore.self) private var store
    @Environment(Overlays.self) private var overlays

    var body: some View {
        PaneScroll {
            let _ = Vendors.shared.loadIfNeeded()
            if let router = store.router {
                let clients = sorted(router.clients)
                // Role 2 is a mesh repeater. Role 3 is the main router itself.
                let mesh = router.clients.filter { $0.role == 2 }
                hero(router, clients)
                pingPath(router)
                LatencyCompare()
                devices(clients)
                if !mesh.isEmpty { MeshNodes(nodes: mesh) }
                HStack(alignment: .top, spacing: 14) {
                    routerPanel(router)
                    if !store.radios.isEmpty { radiosPanel }
                }
                .fixedSize(horizontal: false, vertical: true)
                if !store.interfaces.isEmpty { interfacesPanel }
            } else {
                PaneTitle("Network")
                EmptyPane(icon: "wifi.router", title: "Starlink router not found",
                          detail: "Nothing answered at \(Settings.shared.routerHost). That's normal in bypass mode or behind a third-party router. Dish telemetry still works, and you can change the router address in Settings.")
                if let dish = store.dish {
                    Panel {
                        VStack(alignment: .leading, spacing: 0) {
                            PanelHeader("Dish Ethernet")
                            Fact("Link speed", dish.ethSpeedMbps.map { "\($0) Mbps" })
                            Fact("Routers seen by dish", dish.connectedRouters.isEmpty ? nil : "\(dish.connectedRouters.count)")
                        }
                    }
                }
            }
        }
    }

    private func sorted(_ clients: [WifiClient]) -> [WifiClient] {
        clients
            .filter { !$0.isInfrastructure }
            .sorted { a, b in
                let am = isThisMac(a), bm = isThisMac(b)
                if am != bm { return am }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    private func isThisMac(_ c: WifiClient) -> Bool {
        guard let ip = c.ip else { return false }
        return store.localIPs.contains(ip)
    }

    // MARK: Hero

    private func hero(_ r: RouterStatus, _ clients: [WifiClient]) -> some View {
        let names = Array(Set(r.ssids.map(\.ssid))).sorted()
        let bands = Array(Set(r.ssids.map(\.band).filter { !$0.isEmpty })).sorted()
        var parts = [r.modelName]
        if !bands.isEmpty { parts.append(bands.joined(separator: " + ")) }
        if let uptime = r.uptime { parts.append("up \(Fmt.duration(Double(uptime)))") }
        let wireless = clients.filter(\.isWireless).count

        return HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                PaneHero(kicker: "Your network", title: names.first ?? r.modelName, subline: parts.joined(separator: " · "))
                HStack(spacing: 6) {
                    if r.bypassMode { Pill(text: "Bypass mode", color: Palette.warn) }
                    if r.noWanLink { Pill(text: "No link to dish", color: Palette.bad) }
                    ForEach(r.alerts, id: \.self) { Pill(text: $0, color: Palette.warn) }
                }
            }
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 34) {
                HeroStat(label: "Devices", value: "\(clients.count)")
                HeroStat(label: "On Wi-Fi", value: "\(wireless)")
                HeroStat(label: "Wired", value: "\(clients.count - wireless)")
            }
            .padding(.bottom, 4)
        }
    }

    // MARK: Ping path

    /// Every figure is a ping sent by the router, so a jump at one stop shows which leg is slow.
    private func pingPath(_ r: RouterStatus) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                PanelHeader("Ping from the router", trailing: "A jump at one stop shows which leg is slow")
                    .padding(.bottom, -10)
                HStack(alignment: .top, spacing: 0) {
                    stop("wifi.router", "Router", value: "start", loss: nil, tint: .white)
                    leg
                    stop("antenna.radiowaves.left.and.right", "Dish", value: Fmt.ms(r.dishLatencyMs), loss: r.dishDropRate5m, tint: Palette.accent)
                    leg
                    stop("building.2", "Starlink ground station", value: Fmt.ms(r.popLatencyMs), loss: r.popDropRate5m, tint: Palette.up)
                    leg
                    stop("globe", "Internet", value: Fmt.ms(r.pingLatencyMs), loss: nil, tint: Palette.good)
                }
            }
        }
    }

    private var leg: some View {
        Rectangle()
            .fill(LinearGradient(colors: [.white.opacity(0.08), .white.opacity(0.3), .white.opacity(0.08)], startPoint: .leading, endPoint: .trailing))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .padding(.top, 21)
    }

    private func stop(_ icon: String, _ name: String, value: String, loss: Double?, tint: Color) -> some View {
        let parts = splitUnit(value)
        return VStack(spacing: 5) {
            IconBadge(icon: icon, tint: tint, size: 42)
            Text(name).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(parts.0).font(Theme.number(parts.1.isEmpty ? 13 : 22)).monospacedDigit()
                    .foregroundStyle(parts.1.isEmpty ? .white.opacity(0.35) : .white)
                Text(parts.1).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            }
            .frame(height: 26)
            Text(loss.map { "\(Fmt.percent($0, digits: 1)) loss" } ?? " ")
                .font(.system(size: 10.5))
                .foregroundStyle((loss ?? 0) > 0.01 ? Palette.warn : .white.opacity(0.35))
        }
        .frame(width: 150)
    }

    // MARK: Devices

    private func devices(_ clients: [WifiClient]) -> some View {
        var counts: [String] = []
        for band in ["5 GHz", "5 GHz high", "2.4 GHz", "Ethernet"] {
            let n = clients.filter { $0.ifaceName == band }.count
            if n > 0 { counts.append("\(n) on \(band)") }
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Kicker("Devices")
                Spacer()
                Text((counts + ["click a device for detail"]).joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.35))
            }
            .padding(.top, 6)
            .padding(.horizontal, 2)
            if clients.isEmpty {
                Panel { Text("The router isn't reporting any devices.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45)) }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                    ForEach(clients) { client in
                        Button {
                            overlays.sheet = SheetRequest(id: client.id, content: AnyView(DeviceDetail(id: client.id, name: client.name)))
                        } label: {
                            DeviceTile(client: client, isThisMac: isThisMac(client), vendor: Vendors.shared.name(for: client.mac))
                        }
                        .buttonStyle(PressScale())
                    }
                }
            }
        }
    }

    // MARK: Panels

    private func routerPanel(_ r: RouterStatus) -> some View {
        Panel(fill: true) {
            VStack(alignment: .leading, spacing: 0) {
                PanelHeader("Router")
                Fact("Model", r.modelName)
                Fact("Firmware", r.softwareVersion)
                Fact("Public IPv4", r.publicIPv4)
                Fact("WAN address", r.wanIPv4)
                if let v6 = r.wanIPv6.first(where: { !$0.hasPrefix("fe80") }) { Fact("WAN IPv6", v6) }
            }
        }
    }

    private var radiosPanel: some View {
        Panel(fill: true) {
            VStack(alignment: .leading, spacing: 0) {
                PanelHeader("Radios")
                ForEach(store.radios) { radio in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(radio.bandName).font(.system(size: 12.5, weight: .medium))
                            Spacer()
                            Text("↓ \(Fmt.bytes(radio.rxBytes))   ↑ \(Fmt.bytes(radio.txBytes))")
                                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.white.opacity(0.45))
                        }
                        if let t = radio.temperature {
                            let color = t >= 85 ? Palette.bad : t >= 75 ? Palette.warn : Palette.good
                            HStack(spacing: 10) {
                                GeometryReader { geo in
                                    Pillow().fill(.white.opacity(0.08))
                                        .overlay(alignment: .leading) {
                                            Pillow().fill(color).frame(width: geo.size.width * CGFloat(min(1, max(0.03, t / 100))))
                                        }
                                }
                                .frame(height: 4)
                                Text(String(format: "%.0f °C", t)).font(.system(size: 11, weight: .medium)).monospacedDigit()
                                    .foregroundStyle(color)
                                    .frame(width: 44, alignment: .trailing)
                            }
                        }
                    }
                    .padding(.vertical, 9)
                    .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
                }
            }
        }
    }

    private var interfacesPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                PanelHeader("Router interfaces", trailing: "traffic since the router started")
                ForEach(store.interfaces) { iface in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(iface.up ? Palette.good : .white.opacity(0.2)).frame(width: 6, height: 6)
                        Text(iface.name).font(.system(size: 12, weight: .medium, design: .monospaced))
                            .frame(width: 96, alignment: .leading)
                        Text([iface.kind, iface.detail].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                        Spacer()
                        Text("↓ \(Fmt.bytes(iface.rxBytes))   ↑ \(Fmt.bytes(iface.txBytes))")
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(.white.opacity(0.4))
                    }
                    .padding(.vertical, 7)
                    .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
                }
            }
        }
    }
}

struct DeviceTile: View {
    var client: WifiClient
    var isThisMac: Bool
    var vendor: String?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(icon: isThisMac ? "laptopcomputer" : client.isWireless ? "wifi" : "cable.connector",
                      tint: isThisMac ? Palette.accent : .white.opacity(0.75), size: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(client.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if isThisMac { Pill(text: "This Mac", color: Palette.accent) }
                    if client.blocked { Pill(text: "Blocked", color: Palette.bad) }
                }
                Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 4) {
                if client.isWireless {
                    HStack(spacing: 6) {
                        if let signal = client.signal {
                            Text(String(format: "%.0f dBm", signal)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                        }
                        SignalBars(dBm: client.signal)
                    }
                } else {
                    Text("Wired").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
                Text(usage).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.35))
            }
            .monospacedDigit()
        }
        .padding(12)
        .background(.white.opacity(hovering ? 0.085 : 0.05), in: RoundedRectangle(cornerRadius: Theme.r(16), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.r(16), style: .continuous)
                .strokeBorder(isThisMac ? Palette.accent.opacity(0.45) : .white.opacity(hovering ? 0.2 : 0.08))
        )
        .animation(.easeOut(duration: 0.18), value: hovering)
        .onHover { hovering = $0 }
        .help(tooltip)
    }

    private var detail: String {
        var parts = [client.ip ?? "No IP", client.ifaceName]
        if let vendor, vendor != "Private address" { parts.insert(vendor, at: 0) }
        if let t = client.associatedSeconds, t > 0 { parts.append("for \(Fmt.duration(Double(t)))") }
        return parts.joined(separator: " · ")
    }

    /// The router counts from its own side, so what it transmitted is what the device downloaded.
    private var usage: String {
        if client.isWireless, client.rxBytes + client.txBytes > 0 {
            return "↓ \(Fmt.bytes(client.txBytes))  ↑ \(Fmt.bytes(client.rxBytes))"
        }
        if let down = client.downloadMB, let up = client.uploadMB, down + up > 0 {
            return "↓ \(Fmt.megabytes(down))  ↑ \(Fmt.megabytes(up))"
        }
        return " "
    }

    private var tooltip: String {
        var lines = ["MAC \(client.mac ?? "unknown")"]
        if let snr = client.snr, client.isWireless { lines.append(String(format: "SNR %.0f dB", snr)) }
        if let w = client.channelWidth, w > 0 { lines.append("Channel width \(w) MHz") }
        if client.isWireless, let rx = client.rxRateMbps, let tx = client.txRateMbps {
            lines.append(String(format: "Link rate %.0f Mbps from device, %.0f Mbps to device", rx, tx))
        }
        return lines.joined(separator: "\n")
    }
}
