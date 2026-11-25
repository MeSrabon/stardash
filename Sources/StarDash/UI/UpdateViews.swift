import SwiftUI

/// Settings › Updates: the version, the daily check, and the update itself when there is one.
struct UpdatesPanel: View {
    @Bindable private var updater = AppUpdater.shared

    var body: some View {
        Panel(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                GroupTitle("Updates")
                SettingRow(icon: "arrow.triangle.2.circlepath", tint: Palette.accent,
                           title: "StarDash \(updater.version)", detail: status, detailColor: statusColor) {
                    Button(updater.phase == .checking ? "Checking…" : "Check now") { updater.check() }
                        .disabled(!updater.isAvailable || updater.phase == .checking || updater.hasUpdate)
                }
                SettingRow(icon: "calendar", tint: Palette.good, title: "Check every day",
                           detail: "Asks GitHub for a newer version. Nothing about this Mac is sent") {
                    Toggle("", isOn: $updater.checksAutomatically).labelsHidden()
                        .disabled(!updater.isAvailable)
                }
                if updater.hasUpdate, let offer = updater.offer {
                    offerView(offer)
                }
            }
        }
    }

    private var status: String {
        if !updater.isAvailable && !updater.hasUpdate { return "Updates work in the installed app" }
        switch updater.phase {
        case .checking: return "Checking for a newer version…"
        case .upToDate: return "Up to date"
        case .failed(let message): return "Couldn't check: \(message)"
        case .available, .downloading, .extracting, .installing:
            return "Version \(updater.offer?.version ?? "") is available"
        case .idle:
            guard let date = updater.lastChecked else { return "Not checked yet" }
            return "Checked \(date.formatted(.relative(presentation: .named)))"
        }
    }

    private var statusColor: Color {
        switch updater.phase {
        case .failed: return Palette.warn
        case .available, .downloading, .extracting, .installing: return .white.opacity(0.8)
        default: return .white.opacity(0.45)
        }
    }

    private func offerView(_ offer: (version: String, notes: String?)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let notes = offer.notes, !notes.isEmpty {
                ReleaseNotes(text: notes)
                    .frame(maxHeight: 180)
            }
            HStack(spacing: 8) {
                UpdateProgress(phase: updater.phase)
                Spacer()
                if updater.phase == .available {
                    Button("Later") { updater.later() }
                    Button("Install and relaunch") { updater.install() }
                }
            }
        }
        .padding(16)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
    }
}

/// The changelog section from the appcast, rendered from its Markdown.
private struct ReleaseNotes: View {
    var text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: true).enumerated()), id: \.offset) { _, raw in
                    line(String(raw))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder
    private func line(_ raw: String) -> some View {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("### ") {
            Kicker(String(trimmed.dropFirst(4))).padding(.top, 4)
        } else if trimmed.hasPrefix("- ") {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("•").foregroundStyle(.white.opacity(0.4))
                Text(markdown(String(trimmed.dropFirst(2))))
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.75))
        } else if !trimmed.hasPrefix(">") {
            Text(markdown(trimmed))
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.leading, raw.hasPrefix("  ") ? 14 : 0)
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }
}

private struct UpdateProgress: View {
    var phase: AppUpdater.Phase

    var body: some View {
        switch phase {
        case .downloading(let fraction):
            HStack(spacing: 8) {
                if let fraction {
                    ProgressView(value: fraction).frame(width: 120)
                    Text("Downloading \(Int(fraction * 100))%")
                } else {
                    ProgressView().controlSize(.small)
                    Text("Downloading…")
                }
            }
            .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6)).monospacedDigit()
        case .extracting:
            label("Preparing the update…")
        case .installing:
            label("Installing. StarDash will reopen in a moment.")
        default:
            EmptyView()
        }
    }

    private func label(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
        }
    }
}

/// The popover's one-line notice when a new version is waiting.
struct PopoverUpdateRow: View {
    var updater = AppUpdater.shared
    var openSettings: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 1) {
                Text("StarDash \(updater.offer?.version ?? "") is out")
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5)).monospacedDigit()
            }
            .lineLimit(1)
            .contentShape(Rectangle())
            .onTapGesture { openSettings() }
            .help("See what's new in Settings")
            Spacer(minLength: 6)
            if updater.phase == .available {
                Button("Update") { updater.install() }
                    .buttonStyle(QuietButton())
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.r(10), style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.r(10), style: .continuous).strokeBorder(.white.opacity(0.25)))
    }

    private var detail: String {
        switch updater.phase {
        case .downloading(let fraction): return fraction.map { "Downloading \(Int($0 * 100))%" } ?? "Downloading…"
        case .extracting: return "Preparing…"
        case .installing: return "Installing, back in a moment"
        default: return "Click for what's new"
        }
    }
}
