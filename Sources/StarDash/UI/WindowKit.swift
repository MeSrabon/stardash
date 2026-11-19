import SwiftUI

// Building blocks shared by the main window's pages.

/// Frosted panel.
struct Panel<Content: View>: View {
    var padding: CGFloat = 16
    /// Stretch to the tallest sibling in a row.
    var fill = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
            .background(Theme.panelFill, in: RoundedRectangle(cornerRadius: Theme.r(18), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.r(18), style: .continuous).strokeBorder(Theme.panelStroke))
    }
}

struct Kicker: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: Theme.isMono ? 10 : 10.5, weight: Theme.isMono ? .medium : .semibold))
            .kerning(Theme.isMono ? 2.2 : 1.3)
            .foregroundStyle(.white.opacity(Theme.isMono ? 0.6 : 0.5))
    }
}

struct PanelHeader: View {
    var title: String
    var trailing: String?

    init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            Kicker(title)
            Spacer()
            if let trailing {
                Text(trailing).font(.system(size: 11)).foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.bottom, 10)
    }
}

/// Label and value with a hairline above, so a stack of them reads as a table.
struct Fact: View {
    var label: String
    var value: String?
    var color: Color = .white

    init(_ label: String, _ value: String?, color: Color = .white) {
        self.label = label
        self.value = value
        self.color = color
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.white.opacity(0.5))
            Spacer(minLength: 16)
            Text(value ?? Fmt.missing)
                .foregroundStyle(value == nil ? .white.opacity(0.3) : color)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .font(.system(size: 12.5))
        .monospacedDigit()
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
    }
}

struct HeroStat: View {
    var label: String
    var value: String
    var unit: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Kicker(label)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(Theme.number(30)).monospacedDigit()
                if !unit.isEmpty {
                    Text(unit).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
    }
}

struct PaneHero: View {
    var kicker: String
    var title: String
    var subline: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Kicker(kicker)
            Text(Theme.title(title))
                .font(Theme.display(44))
                .kerning(Theme.titleKerning)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.top, 6)
            Text(subline)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .padding(.top, 2)
        }
    }
}

/// Scrolling page with the window's standard margins.
struct PaneScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(.horizontal, 28)
                .padding(.top, Theme.paneTop)
                .padding(.bottom, 28)
        }
        .scrollIndicators(.automatic)
    }
}

/// Round icon badge.
struct IconBadge: View {
    var icon: String
    var tint: Color
    var size: CGFloat = 36

    var body: some View {
        let glyph = Image(systemName: icon)
            .font(.system(size: size * 0.4, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
        if Theme.isMono {
            glyph.overlay(Rectangle().strokeBorder(.white.opacity(0.22)))
        } else {
            glyph.background(tint.opacity(0.16), in: Circle())
        }
    }
}

/// Large button that reads as a tile.
struct ActionTile: View {
    var icon: String
    var title: String
    var detail: String
    var tint: Color = Palette.accent
    /// A short result shown in place of the detail line, such as "Copied". Nothing around the tile moves.
    var status: TileStatus? = nil
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IconBadge(icon: status.map { $0.ok ? "checkmark" : "exclamationmark.triangle" } ?? icon,
                          tint: status.map { $0.ok ? Palette.good : Palette.bad } ?? tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(status?.text ?? detail).font(.system(size: 11))
                        .foregroundStyle(status.map { $0.ok ? Palette.good : Palette.bad } ?? .white.opacity(0.5))
                        .lineLimit(1)
                        .help(status?.text ?? detail)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(hovering ? 0.7 : 0.25))
                    .offset(x: hovering ? 2 : 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(hovering ? 0.09 : 0.05), in: RoundedRectangle(cornerRadius: Theme.r(16), style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.r(16), style: .continuous)
                    .strokeBorder(hovering ? tint.opacity(0.55) : .white.opacity(0.1))
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.r(16), style: .continuous))
        }
        .buttonStyle(PressScale())
        .animation(.spring(duration: 0.3, bounce: 0.25), value: hovering)
        .onHover { hovering = $0 }
    }
}

struct TileStatus: Equatable {
    var text: String
    var ok = true
}

/// Four bars for Wi-Fi signal strength in dBm.
struct SignalBars: View {
    var dBm: Double?

    private var level: Int {
        guard let dBm else { return 0 }
        return dBm >= -55 ? 4 : dBm >= -65 ? 3 : dBm >= -75 ? 2 : 1
    }

    private var color: Color {
        level >= 3 ? Palette.good : level == 2 ? Palette.warn : Palette.bad
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { bar in
                RoundedRectangle(cornerRadius: Theme.r(1))
                    .fill(bar <= level ? color : .white.opacity(0.14))
                    .frame(width: 3.5, height: 3 + CGFloat(bar) * 3)
            }
        }
    }
}

struct EmptyPane: View {
    var icon: String
    var title: String
    var detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(Theme.display(38)).foregroundStyle(.white.opacity(0.35))
            Text(title).font(Theme.number(22))
            Text(detail)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 90)
    }
}
