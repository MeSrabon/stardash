import SwiftUI

/// Router settings that only change through the Starlink account: Wi-Fi, DNS and factory reset.
/// The router refuses these over the local network, so they go the way the Starlink app sends them.
struct RouterCloudPanel: View {
    @Environment(Overlays.self) private var overlays
    @State private var note: String?
    @State private var noteIsError = false

    var body: some View {
        let account = Account.shared
        let settings = account.router
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                PanelHeader("Router settings", trailing: settings != nil ? "Changes go through your Starlink account"
                    : account.routerLoading ? "Reading from your Starlink account…" : nil)
                if settings == nil, let error = account.routerError {
                    row("Couldn't read the router's settings", error, color: Palette.bad) {
                        Button("Try again") { Task { await account.loadRouter() } }
                    }
                }
                if let settings {
                    row("Wi-Fi", wifiSummary(settings)) {
                        Button("Change…") { editWifi(settings) }
                            .disabled(!settings.networks.contains(where: \.secured))
                    }
                    if settings.customDNSAllowed {
                        row("DNS servers", settings.nameservers.isEmpty ? "Starlink's own" : settings.nameservers.joined(separator: ", ")) {
                            Button("Change…") { editDNS(settings) }
                        }
                    } else {
                        row("DNS servers", "This router doesn't allow custom DNS.") { EmptyView() }
                    }
                    ForEach(settings.mesh) { node in
                        row(node.name, ["Mesh node", node.hardware].compactMap { $0 }.joined(separator: " · ")) {
                            Pill(text: node.trusted ? "Trusted" : node.auth, color: node.trusted ? Palette.good : Palette.warn)
                        }
                    }
                    if !settings.mesh.isEmpty {
                        Text("Mesh trust is shown as the router reports it. Change it in the Starlink app.")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.35))
                            .padding(.vertical, 8)
                    }
                }
                row("Factory reset", "Erases every router setting, the Wi-Fi name and password included.") {
                    Button { confirmReset() } label: { Text("Factory reset…").foregroundStyle(Palette.bad) }
                }
                if let note {
                    Text(note)
                        .font(.system(size: 11.5)).foregroundStyle(noteIsError ? Palette.bad : .white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }
            }
        }
        .buttonStyle(QuietButton())
        .task { await account.loadRouter() }
    }

    private func wifiSummary(_ settings: RouterCloudSettings) -> String {
        guard !settings.networks.isEmpty else { return "The router didn't list any networks." }
        return settings.networks.map { network in
            var text = network.ssid
            if !network.bands.isEmpty { text += " on \(network.bands.joined(separator: " and "))" }
            if network.guest { text += " (guest)" }
            if !network.secured { text += " (no password)" }
            return text
        }.joined(separator: ", ")
    }

    private func row(_ title: String, _ detail: String, color: Color = .white.opacity(0.45),
                     @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(detail).font(.system(size: 11)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
    }

    private func report(_ problem: String?, _ done: String) {
        note = problem ?? done
        noteIsError = problem != nil
    }

    private func editWifi(_ settings: RouterCloudSettings) {
        overlays.sheet = SheetRequest(id: "wifi-editor", width: 520, content: AnyView(
            WifiEditor(networks: settings.networks.filter(\.secured)) { problem in
                report(problem, "Wi-Fi change sent. Devices need to join again with the new details.")
            }
        ))
    }

    private func editDNS(_ settings: RouterCloudSettings) {
        overlays.sheet = SheetRequest(id: "dns-editor", width: 460, content: AnyView(
            DNSEditor(current: settings.nameservers) { problem, cleared in
                report(problem, cleared ? "The router is back on Starlink's DNS servers." : "DNS servers saved.")
            }
        ))
    }

    private func confirmReset() {
        overlays.confirm = ConfirmRequest(
            title: "Factory reset the router?",
            message: "This erases all router settings: the Wi-Fi name and password, DNS, mesh pairing and device names. The network goes down for every device, this Mac included. Afterwards the router has to be set up again with the Starlink app, as if it were new. This can't be undone.",
            action: "Factory reset",
            typeToConfirm: "RESET"
        ) {
            Task {
                let problem = await Account.shared.factoryResetRouter()
                report(problem, "Factory reset sent. The router is erasing itself and restarting. Set it up again in the Starlink app.")
            }
        }
    }
}

// MARK: Editors

/// Text input that matches the app's fields.
struct FormField: View {
    var label: String
    var placeholder: String = ""
    @Binding var text: String
    var secure = false
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !label.isEmpty { Kicker(label) }
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: monospaced ? .monospaced : .default))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.r(8), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.r(8), style: .continuous).strokeBorder(.white.opacity(0.14)))
        }
    }
}

/// Title, explanation and the Cancel and Save buttons every editor sheet shares.
struct EditorFrame<Content: View>: View {
    var title: String
    var detail: String
    var problem: String?
    var save: String
    var canSave: Bool
    var onSave: () -> Void
    @ViewBuilder var content: Content
    @Environment(Overlays.self) private var overlays

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Theme.title(title)).font(Theme.number(20)).kerning(Theme.isMono ? 1.2 : 0)
                Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.trailing, 30)
            content
            HStack(spacing: 10) {
                if let problem {
                    Text(problem).font(.system(size: 11.5)).foregroundStyle(Palette.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Cancel") { overlays.sheet = nil }
                Button(save) { onSave() }.disabled(!canSave)
            }
            .buttonStyle(QuietButton())
        }
        .padding(22)
    }
}

struct WifiEditor: View {
    var networks: [RouterCloudSettings.Network]
    var onResult: (String?) -> Void
    @Environment(Overlays.self) private var overlays
    @State private var names: [String: String] = [:]
    @State private var password = ""
    @State private var again = ""
    @State private var reveal = false

    private var renames: [String: String] {
        var out: [String: String] = [:]
        for network in networks {
            let new = (names[network.ssid] ?? network.ssid).trimmingCharacters(in: .whitespaces)
            if new != network.ssid { out[network.ssid] = new }
        }
        return out
    }

    private var problem: String? {
        for network in networks {
            if let problem = WifiRules.nameProblem(names[network.ssid] ?? network.ssid) { return problem }
        }
        if password.isEmpty { return nil }
        if let problem = WifiRules.passwordProblem(password) { return problem }
        if !reveal, again != password { return "The two passwords don't match." }
        return nil
    }

    var body: some View {
        EditorFrame(title: "Wi-Fi name and password",
                    detail: "The router never shows its current password, so enter one even if it stays the same. 8 to 63 characters.",
                    problem: problem, save: "Save…",
                    canSave: problem == nil && !password.isEmpty && (reveal || again == password)) {
            confirm()
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(networks) { network in
                    FormField(label: networks.count > 1 ? "Name for \(network.ssid)\(network.guest ? " (guest)" : "")" : "Network name",
                              placeholder: network.ssid,
                              text: Binding(get: { names[network.ssid] ?? network.ssid }, set: { names[network.ssid] = $0 }))
                }
                FormField(label: "Password", text: $password, secure: !reveal, monospaced: reveal)
                if !reveal { FormField(label: "Password again", text: $again, secure: true) }
                Toggle("Show password", isOn: $reveal)
                    .toggleStyle(ThemedSwitch())
                    .font(.system(size: 12))
            }
        }
    }

    private func confirm() {
        var lines: [String] = []
        for (old, new) in renames.sorted(by: { $0.key < $1.key }) { lines.append("\"\(old)\" becomes \"\(new)\".") }
        lines.append("Every device on Wi-Fi drops off, this Mac too if it uses Wi-Fi, and has to join again with the \(renames.isEmpty ? "new password" : "new name and password"). Devices that aren't updated stay offline.")
        if networks.count > 1 { lines.append("The password applies to every network on this router except guest networks, which keep their own.") }
        let renames = renames
        let password = password
        overlays.confirm = ConfirmRequest(
            title: renames.isEmpty ? "Change the Wi-Fi password?" : "Change the Wi-Fi?",
            message: lines.joined(separator: " "),
            action: "Change Wi-Fi"
        ) {
            overlays.sheet = nil
            Task { onResult(await Account.shared.setWifi(renames: renames, password: password)) }
        }
    }
}

struct DNSEditor: View {
    var current: [String]
    var onResult: (String?, Bool) -> Void
    @Environment(Overlays.self) private var overlays
    @State private var fields: [String]

    init(current: [String], onResult: @escaping (String?, Bool) -> Void) {
        self.current = current
        self.onResult = onResult
        _fields = State(initialValue: (current + Array(repeating: "", count: DNSList.maxServers)).prefix(DNSList.maxServers).map { $0 })
    }

    private var entered: [String] { fields.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    private var problem: String? {
        if let bad = entered.first(where: { DNSList.address($0) == nil }) { return "\(bad) isn't an IP address." }
        return nil
    }

    var body: some View {
        EditorFrame(title: "DNS servers",
                    detail: "Up to four addresses, the first one used first. Leave them all empty to go back to Starlink's own.",
                    problem: problem, save: "Save…", canSave: problem == nil && DNSList.normalized(entered) != current) {
            confirm()
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<DNSList.maxServers, id: \.self) { i in
                    FormField(label: i == 0 ? "Main" : "Backup \(i)", placeholder: i == 0 ? "1.1.1.1" : "", text: $fields[i], monospaced: true)
                }
            }
        }
    }

    private func confirm() {
        guard let servers = DNSList.normalized(entered) else { return }
        overlays.confirm = ConfirmRequest(
            title: servers.isEmpty ? "Go back to Starlink's DNS?" : "Change DNS servers?",
            message: servers.isEmpty
                ? "The router sends lookups to Starlink's own servers again. Devices pick this up as they renew their connection."
                : "The router will send every lookup to \(servers.joined(separator: ", ")). Devices pick this up as they renew their connection. A wrong address stops websites from loading.",
            action: "Save DNS",
            destructive: false
        ) {
            overlays.sheet = nil
            Task { onResult(await Account.shared.setNameservers(servers), servers.isEmpty) }
        }
    }
}
