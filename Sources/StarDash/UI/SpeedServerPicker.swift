import SwiftUI

/// The button by the speed gauge that says which server the test from this Mac uses, and opens the picker.
struct SpeedServerControl: View {
    @Environment(SpeedTest.self) private var test
    @Environment(Overlays.self) private var overlays
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.r(8), style: .continuous)
        let choice = Settings.shared.speedServer
        let running = test.isRunning
        Button { SpeedServerPicker.open(in: overlays) } label: {
            HStack(spacing: 7) {
                Image(systemName: choice == .cloudflare ? "cloud" : "server.rack")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Text(running ? (test.current.server ?? choice.title) : choice.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                    .opacity(running ? 0 : 1)
            }
            .foregroundStyle(.white.opacity(running ? 0.55 : 0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: 340)
            .background(.white.opacity(hovering && !running ? 0.12 : 0.05), in: shape)
            .overlay(shape.strokeBorder(.white.opacity(hovering && !running ? 0.3 : 0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(running)
        .onHover { hovering = $0 }
        .help("Server for the test from this Mac. The router test always uses its own.")
    }
}

/// Cloudflare, Auto, or one Ookla server picked from the public list.
/// The list is fetched only while this is open, and searches go to speedtest.net as typed.
struct SpeedServerPicker: View {
    @State private var query = ""
    @State private var servers: [SpeedServer] = []
    @State private var loading = true
    @State private var failure: String?

    static func open(in overlays: Overlays = .shared) {
        overlays.sheet = SheetRequest(id: "speed-servers", width: 520, content: AnyView(SpeedServerPicker()))
    }

    private var choice: SpeedServerChoice { Settings.shared.speedServer }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Theme.title("Test server"))
                .font(Theme.number(20))
                .kerning(Theme.isMono ? 1.2 : 0)
            Text("Used by the test from this Mac. The router test always uses its own server.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.top, 6)

            VStack(spacing: 2) {
                ServerRow(title: "Cloudflare", detail: "Default. Large network, close to most places.",
                          trailing: nil, selected: choice == .cloudflare) { pick(.cloudflare) }
                ServerRow(title: "Auto · nearest Ookla server", detail: "Pings the ten nearest at the start of each run and uses the quickest.",
                          trailing: nil, selected: choice == .auto) { pick(.auto) }
            }
            .padding(.top, 14)

            searchField.padding(.top, 14)

            Group {
                if loading && servers.isEmpty {
                    note(AnyView(ProgressView().controlSize(.small)))
                } else if let failure {
                    note(AnyView(Text(failure).foregroundStyle(Palette.warn)))
                } else if servers.isEmpty {
                    note(AnyView(Text("No servers match \"\(query)\".").foregroundStyle(.white.opacity(0.5))))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(servers) { server in
                                ServerRow(title: server.sponsor, detail: server.place,
                                          trailing: server.distance.map { Self.km($0) },
                                          selected: isPicked(server)) { pick(.ookla(server)) }
                            }
                        }
                    }
                    .scrollIndicators(.automatic)
                }
            }
            .frame(height: 230)
            .padding(.top, 8)

            Text("Server list from speedtest.net, nearest first. Most Ookla servers are run by local internet providers.")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.top, 10)
        }
        .padding(22)
        .task(id: query) {
            // Wait for a pause in typing before asking speedtest.net.
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(400)) }
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    private var searchField: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.r(8), style: .continuous)
        return HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            TextField("Search Ookla servers by city or provider", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
            if loading && !servers.isEmpty { ProgressView().controlSize(.mini) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.white.opacity(0.06), in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.16)))
    }

    private func note(_ content: AnyView) -> some View {
        content.font(.system(size: 12)).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let found = try await Ookla.servers(search: query.isEmpty ? nil : query)
            guard !Task.isCancelled else { return }
            servers = found
            failure = nil
        } catch {
            guard !Task.isCancelled else { return }
            servers = []
            failure = "Couldn't load the server list: \(error.localizedDescription)"
        }
    }

    private func isPicked(_ server: SpeedServer) -> Bool {
        if case .ookla(let picked) = choice { return picked.id == server.id }
        return false
    }

    private func pick(_ next: SpeedServerChoice) {
        Settings.shared.speedServer = next
    }

    static func km(_ value: Double) -> String {
        value < 1 ? "< 1 km" : value >= 1000 ? String(format: "%.1fk km", value / 1000) : String(format: "%.0f km", value)
    }
}

private struct ServerRow: View {
    var title: String
    var detail: String
    var trailing: String?
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        // Mono inverts the row under the pointer, like the app's dropdowns.
        let inverted = hovering && Theme.isMono
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(selected ? 1 : 0)
                    .frame(width: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5, weight: selected ? .semibold : .medium)).lineLimit(1)
                    Text(detail).font(.system(size: 11)).opacity(0.6).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing).font(.system(size: 11)).monospacedDigit().opacity(0.6)
                }
            }
            .foregroundStyle(inverted ? .black : .white.opacity(selected || hovering ? 1 : 0.78))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(hovering ? (Theme.isMono ? Color.white : .white.opacity(0.12)) : selected ? .white.opacity(0.06) : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.r(7), style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
