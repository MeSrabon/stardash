import Charts
import SwiftUI

// MARK: Settings

/// The optional Starlink account, in Settings.
struct StarlinkAccountPanel: View {
    @Environment(Overlays.self) private var overlays
    @Environment(AppActions.self) private var actions

    var body: some View {
        let account = Account.shared
        Panel(padding: 0) {
            VStack(spacing: 0) {
                GroupTitle("Starlink account")
                switch account.status {
                case .signedOut:
                    SettingRow(icon: "person.crop.circle", tint: Palette.accent, title: "Not signed in",
                               detail: "Optional. Adds billing usage, router settings and network rules.") {
                        Button(account.signingIn ? "Signing in…" : "Sign in…") { account.signIn() }
                    }
                case .signedIn:
                    SettingRow(icon: "person.crop.circle.badge.checkmark", tint: Palette.good, title: account.title,
                               detail: account.profile?.accountNumber.map { "Account \($0)" } ?? "Signed in",
                               detailColor: Palette.good) {
                        Button("Sign out…") { confirmSignOut() }
                    }
                    // Signing in only pays off on other pages, so say where.
                    unlocked("chart.bar.xaxis", "Billing usage", "Data used this billing cycle and earlier ones, as Starlink counts it", .usage)
                    unlocked("wifi.router", "Router settings", "Change the Wi-Fi name and password, and the DNS servers", .network)
                    unlocked("hand.raised", "Network rules", "Data limits, online hours and timers that pause devices for you", .network)
                case .expired:
                    SettingRow(icon: "person.crop.circle.badge.exclamationmark", tint: Palette.warn, title: "Session ended",
                               detail: "Starlink stopped accepting the saved sign-in.", detailColor: Palette.warn) {
                        HStack(spacing: 8) {
                            Button("Sign out") { account.signOut() }
                            Button("Sign in again…") { account.signIn() }
                        }
                    }
                }
                if let problem = account.problem {
                    Text(problem)
                        .font(.system(size: 11)).foregroundStyle(Palette.bad)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.top, 4)
                }
                Text("The session is kept in your keychain. StarDash only contacts starlink.com for these features, with the same requests the Starlink website makes.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .task { await account.loadProfile() }
    }

    private func unlocked(_ icon: String, _ title: String, _ detail: String, _ pane: Pane) -> some View {
        SettingRow(icon: icon, tint: Palette.accent, title: title, detail: detail) {
            Button("Open") { actions.showPane(pane) }
        }
    }

    private func confirmSignOut() {
        overlays.confirm = ConfirmRequest(
            title: "Sign out of Starlink?",
            message: "StarDash forgets the session and clears what the sign-in page stored. Your rules stay saved, but they can't pause or resume devices until you sign in again.",
            action: "Sign out"
        ) { Account.shared.signOut() }
    }
}

/// Shown on pages with account features while signed out.
struct AccountPrompt: View {
    @Environment(AppActions.self) private var actions
    var text: String

    var body: some View {
        Panel {
            HStack(spacing: 12) {
                IconBadge(icon: "person.crop.circle", tint: .white.opacity(0.8), size: 34)
                Text(text)
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Sign in…") { Account.shared.signIn() }
                Button("Settings") { actions.showPane(.settings) }
            }
            .buttonStyle(QuietButton())
        }
    }
}

// MARK: Usage

/// Starlink's own count of data against the plan, the figure the bill uses.
struct BillingUsageView: View {
    @State private var selected: Int?

    var body: some View {
        let account = Account.shared
        Group {
            if let usage = account.billing, let cycle = cycle(usage) {
                content(usage, cycle)
            } else {
                Panel {
                    VStack(spacing: 10) {
                        if account.billingLoading || (account.billing == nil && account.billingError == nil) {
                            Text("Reading usage from your Starlink account…")
                        } else if let error = account.billingError {
                            Text(error).foregroundStyle(Palette.bad)
                            Button("Try again") { Task { await account.loadBilling(force: true) } }
                                .buttonStyle(QuietButton())
                        } else {
                            Text("Starlink hasn't reported a billing cycle for this service yet.")
                        }
                    }
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, minHeight: 190)
                }
            }
        }
        .task { await account.loadBilling() }
    }

    private func cycle(_ usage: BillingUsage) -> BillingCycle? {
        guard let last = usage.cycles.last else { return nil }
        return usage.cycles.first { $0.id == selected } ?? last
    }

    private static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private static func day(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.abbreviated).day())
    }

    private static func month(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.abbreviated))
    }

    private static func gb(_ value: Double) -> String {
        value >= 1000 ? String(format: "%.2f TB", value / 1000) : value >= 100 ? String(format: "%.0f GB", value) : String(format: "%.1f GB", value)
    }

    @ViewBuilder
    private func content(_ usage: BillingUsage, _ cycle: BillingCycle) -> some View {
        let latest = cycle.id == usage.cycles.last?.id
        let limit = usage.unlimited ? nil : usage.limitGB.flatMap { $0 > 0 ? $0 : nil }
        let daysLeft = max(0, Int(ceil(cycle.end.timeIntervalSinceNow / 86_400)))
        let used = splitUnit(Self.gb(cycle.totalGB))

        HStack(alignment: .bottom) {
            HStack(alignment: .top, spacing: 34) {
                HeroStat(label: latest ? "Used this cycle" : "Used", value: used.0, unit: used.1)
                if let limit {
                    let parts = splitUnit(Self.gb(limit))
                    HeroStat(label: "Plan allowance", value: parts.0, unit: parts.1)
                    let left = splitUnit(Self.gb(max(0, limit - cycle.totalGB)))
                    HeroStat(label: "Left", value: left.0, unit: left.1)
                } else {
                    HeroStat(label: "Plan allowance", value: usage.limitGB == nil ? Fmt.missing : "Unlimited")
                }
                if latest { HeroStat(label: "Days left", value: "\(daysLeft)") }
            }
            Spacer(minLength: 0)
            if usage.cycles.count > 1 {
                ChipPicker(options: usage.cycles.suffix(6).map { ($0.id, Self.month($0.start)) },
                           selection: Binding(get: { cycle.id }, set: { selected = $0 }), pad: 10)
                    .padding(.bottom, 4)
            }
        }

        Panel {
            VStack(alignment: .leading, spacing: 12) {
                PanelHeader("Billing cycle", trailing: "\(Self.day(cycle.start)) to \(Self.day(cycle.end)), from your Starlink account")
                    .padding(.bottom, -6)
                if let limit {
                    let share = min(1, cycle.totalGB / limit)
                    VStack(alignment: .leading, spacing: 6) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.white.opacity(0.08))
                                Rectangle().fill(share >= 0.9 ? Palette.warn : Palette.accent)
                                    .frame(width: max(2, geo.size.width * share))
                            }
                        }
                        .frame(height: 6)
                        Text(String(format: "%.0f%% of %@%@", share * 100, Self.gb(limit), usage.bucketName.map { " \($0.lowercased())" } ?? ""))
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    }
                }
                let days = cycle.daily.enumerated().compactMap { index, value -> (Date, Double)? in
                    Self.utc.date(byAdding: .day, value: index, to: cycle.start).map { ($0, value) }
                }
                if days.isEmpty {
                    Text("No daily figures for this cycle.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, minHeight: 190)
                } else {
                    Chart(days, id: \.0) { day in
                        BarMark(x: .value("Day", day.0, unit: .day), y: .value("GB", day.1))
                            .foregroundStyle(Palette.down)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine().foregroundStyle(.white.opacity(0.06))
                            AxisValueLabel { if let v = value.as(Double.self) { Text(String(format: "%g GB", v)).font(.system(size: 9.5)) } }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 8)) { _ in
                            AxisValueLabel(format: Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.abbreviated).day())
                                .font(.system(size: 9.5))
                        }
                    }
                    .frame(height: 190)
                }
                Text("Starlink's own count, the one your plan uses. It runs a few hours behind and covers every device, not just the ones StarDash sees.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.35))
            }
        }
    }
}
