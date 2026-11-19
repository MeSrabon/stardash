import SwiftUI

// Confirmations, dropdowns, switches and buttons drawn by the app itself, so they follow the theme.

/// What the main window is showing on top of its pages.
@Observable final class Overlays {
    /// The main window's overlays.
    static let shared = Overlays()
    /// The menu bar popover's, kept apart so a prompt only shows where it was asked for.
    static let popover = Overlays()
    /// Coordinate space of the whole window, which dropdowns use to say where they are.
    static let space = "window"

    var confirm: ConfirmRequest?
    var menu: MenuRequest?
    var sheet: SheetRequest?
}

/// A larger card over the window, for detail that doesn't need its own page.
struct SheetRequest {
    var id: String
    var width: CGFloat = 600
    var content: AnyView
}

struct ConfirmRequest {
    var title: String
    var message: String
    var action: String
    var destructive = true
    /// When set, the action stays off until this word is typed. For changes that can't be undone.
    var typeToConfirm: String? = nil
    var run: () -> Void
}

struct MenuRequest {
    /// Frame of the control that opened the menu, in the window's space.
    var anchor: CGRect
    var options: [(label: String, selected: Bool, pick: () -> Void)]
}

/// Sits over the whole window and draws whatever `Overlays` holds.
struct OverlayHost: View {
    var overlays: Overlays

    var body: some View {
        let confirm = overlays.confirm
        let menu = overlays.menu
        let sheet = overlays.sheet
        return ZStack {
            if let sheet { SheetLayer(request: sheet, overlays: overlays).transition(.opacity) }
            if let menu { MenuLayer(request: menu, overlays: overlays).transition(.opacity) }
            if let confirm { ConfirmLayer(request: confirm, overlays: overlays).transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.18), value: confirm != nil)
        .animation(.easeOut(duration: 0.18), value: sheet?.id)
        .animation(.easeOut(duration: 0.12), value: menu != nil)
    }
}

private func overlayCard(radius: CGFloat) -> some View {
    let shape = RoundedRectangle(cornerRadius: Theme.r(radius), style: .continuous)
    return shape
        .fill(Theme.isMono ? Color(white: 0.04) : Color(red: 0.09, green: 0.11, blue: 0.14))
        .overlay(shape.strokeBorder(.white.opacity(Theme.isMono ? 0.28 : 0.14)))
        .shadow(color: .black.opacity(0.6), radius: 24, y: 10)
}

// MARK: Sheet

private struct SheetLayer: View {
    var request: SheetRequest
    var overlays: Overlays
    @State private var shown = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .contentShape(Rectangle())
                .onTapGesture { overlays.sheet = nil }
            request.content
                .frame(maxWidth: request.width)
                .background(overlayCard(radius: 18))
                .overlay(alignment: .topTrailing) {
                    Button { overlays.sheet = nil } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 26, height: 26)
                            .background(.white.opacity(0.08), in: Pillow())
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .padding(14)
                }
                .padding(28)
                .scaleEffect(shown ? 1 : 0.97)
                .offset(y: shown ? 0 : 8)
        }
        .onAppear { withAnimation(.spring(duration: 0.28, bounce: 0.2)) { shown = true } }
    }
}

// MARK: Confirmation

private struct ConfirmLayer: View {
    var request: ConfirmRequest
    var overlays: Overlays
    @State private var shown = false
    @State private var typed = ""

    private var unlocked: Bool {
        guard let word = request.typeToConfirm else { return true }
        return typed.trimmingCharacters(in: .whitespaces) == word
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .contentShape(Rectangle())
                .onTapGesture { close() }
            VStack(alignment: .leading, spacing: 0) {
                Text(Theme.title(request.title))
                    .font(Theme.number(20))
                    .kerning(Theme.isMono ? 1.2 : 0)
                Text(request.message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                if let word = request.typeToConfirm {
                    Text("Type \(word) to continue.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.top, 14)
                    TextField(word, text: $typed)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.r(8), style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.r(8), style: .continuous).strokeBorder(.white.opacity(0.18)))
                        .padding(.top, 6)
                }
                HStack(spacing: 10) {
                    Button("Cancel") { close() }
                        .buttonStyle(CardButton(kind: .plain))
                        .keyboardShortcut(.cancelAction)
                    Button(request.action) {
                        guard unlocked else { return }
                        close()
                        request.run()
                    }
                    .buttonStyle(CardButton(kind: request.destructive ? .danger : .primary))
                    .disabled(!unlocked)
                    .opacity(unlocked ? 1 : 0.4)
                }
                .padding(.top, 22)
            }
            .padding(22)
            .frame(maxWidth: 340, alignment: .leading)
            .background(overlayCard(radius: 18))
            .padding(.horizontal, 20)
            .scaleEffect(shown ? 1 : 0.96)
            .offset(y: shown ? 0 : 8)
        }
        .onAppear { withAnimation(.spring(duration: 0.28, bounce: 0.2)) { shown = true } }
    }

    private func close() { overlays.confirm = nil }
}

/// The wide buttons at the bottom of a confirmation.
private struct CardButton: ButtonStyle {
    enum Kind { case plain, primary, danger }
    var kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        Face(kind: kind, label: configuration.label, pressed: configuration.isPressed)
    }

    private struct Face<Label: View>: View {
        var kind: Kind
        var label: Label
        var pressed: Bool
        @State private var hovering = false

        var body: some View {
            let fill: Color = switch kind {
            case .plain: .white.opacity(hovering ? 0.12 : 0.05)
            case .primary: .white.opacity(hovering ? 1 : 0.92)
            case .danger: Palette.bad.opacity(hovering ? 1 : 0.88)
            }
            label
                .font(.system(size: Theme.isMono ? 11 : 13, weight: .semibold))
                .kerning(Theme.isMono ? 1.6 : 0)
                .textCase(Theme.isMono ? .uppercase : nil)
                .foregroundStyle(kind == .primary ? .black : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(fill, in: RoundedRectangle(cornerRadius: Theme.r(10), style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.r(10), style: .continuous)
                    .strokeBorder(.white.opacity(kind == .plain ? 0.22 : 0)))
                .contentShape(Rectangle())
                .scaleEffect(pressed ? 0.97 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

// MARK: Dropdown

private struct MenuLayer: View {
    var request: MenuRequest
    var overlays: Overlays
    private let rowHeight: CGFloat = 30

    var body: some View {
        GeometryReader { geo in
            let width = max(request.anchor.width, 180)
            let height = CGFloat(request.options.count) * rowHeight + 10
            // Opens under the control, or above it when there's no room below.
            let below = request.anchor.maxY + 6 + height <= geo.size.height - 8
            let y = below ? request.anchor.maxY + 6 : request.anchor.minY - 6 - height
            // Lines up with the control's left edge on the left half of the window, its right edge otherwise.
            let leading = request.anchor.midX < geo.size.width / 2
            let x = min(max(8, leading ? request.anchor.minX : request.anchor.maxX - width), geo.size.width - width - 8)

            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { close() }
            VStack(spacing: 0) {
                ForEach(Array(request.options.enumerated()), id: \.offset) { _, option in
                    MenuRow(label: option.label, selected: option.selected, height: rowHeight) {
                        option.pick()
                        close()
                    }
                }
            }
            .padding(5)
            .frame(width: width)
            .background(overlayCard(radius: 12))
            .offset(x: x, y: y)
            Button("") { close() }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
        }
    }

    private func close() { overlays.menu = nil }
}

private struct MenuRow: View {
    var label: String
    var selected: Bool
    var height: CGFloat
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        // Mono inverts the row under the pointer; Glass tints it.
        let inverted = hovering && Theme.isMono
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(selected ? 1 : 0)
                Text(label).font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(inverted ? .black : .white.opacity(selected || hovering ? 1 : 0.7))
            .padding(.horizontal, 9)
            .frame(height: height)
            .background(hovering ? (Theme.isMono ? Color.white : .white.opacity(0.12)) : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.r(7), style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A dropdown that opens the app's own menu.
struct DropPicker<Value: Hashable>: View {
    var options: [(value: Value, label: String)]
    @Binding var selection: Value
    @Environment(Overlays.self) private var overlays
    @State private var frame = CGRect.zero
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.r(8), style: .continuous)
        Button {
            let binding = $selection
            let current = selection
            overlays.menu = MenuRequest(anchor: frame, options: options.map { option in
                (option.label, option.value == current, { binding.wrappedValue = option.value })
            })
        } label: {
            HStack(spacing: 8) {
                Text(options.first { $0.value == selection }?.label ?? "")
                    .font(.system(size: 12.5))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.white.opacity(hovering ? 0.13 : 0.07), in: shape)
            .overlay(shape.strokeBorder(.white.opacity(hovering ? 0.3 : 0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .background(GeometryReader { geo in
            Color.clear.onChange(of: geo.frame(in: .named(Overlays.space)), initial: true) { _, value in frame = value }
        })
    }
}

// MARK: Switch and buttons

/// On/off switch: a white bar in Mono, a blue capsule in Glass.
struct ThemedSwitch: ToggleStyle {
    /// Push the label and the switch to opposite edges.
    var spread = false

    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        let mono = Theme.isMono
        return HStack(spacing: 10) {
            configuration.label
            if spread { Spacer(minLength: 0) }
            Button {
                withAnimation(.spring(duration: 0.25, bounce: 0.25)) { configuration.isOn.toggle() }
            } label: {
                Pillow()
                    .fill(on ? (mono ? Color.white : Theme.control) : .white.opacity(mono ? 0 : 0.14))
                    .overlay(Pillow().strokeBorder(.white.opacity(on ? 0 : mono ? 0.4 : 0.1)))
                    .frame(width: 34, height: 20)
                    .overlay(alignment: on ? .trailing : .leading) {
                        Pillow()
                            .fill(on ? (mono ? Color.black : .white) : .white.opacity(mono ? 0.7 : 0.9))
                            .frame(width: 14, height: 14)
                            .padding(3)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// Small outlined button for rows and footers.
struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Face(label: configuration.label, pressed: configuration.isPressed)
    }

    private struct Face<Label: View>: View {
        var label: Label
        var pressed: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Theme.r(8), style: .continuous)
            label
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(enabled ? 0.95 : 0.35))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(.white.opacity(hovering && enabled ? 0.13 : 0.07), in: shape)
                .overlay(shape.strokeBorder(.white.opacity(hovering && enabled ? 0.3 : 0.1)))
                .contentShape(Rectangle())
                .scaleEffect(pressed ? 0.96 : 1)
                .onHover { hovering = $0 }
        }
    }
}
