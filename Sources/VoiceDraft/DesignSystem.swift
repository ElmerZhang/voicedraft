import SwiftUI
import AppKit

/// Shared visual language for every VoiceDraft surface (main window, settings overlay, sheets, onboarding, HUD).
/// Views use these tokens and components instead of hard-coded colors, radii and font sizes.
/// Colors adapt to the system appearance; the light values match the original reference design.
enum VD {
    enum Palette {
        /// Primary text.
        static let ink = adaptive(light: NSColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1), dark: NSColor(red: 0.94, green: 0.94, blue: 0.96, alpha: 1))
        /// Window content background.
        static let canvas = adaptive(light: .white, dark: NSColor(red: 0.118, green: 0.118, blue: 0.125, alpha: 1))
        /// Sidebar, settings rail and shaded boxes.
        static let surface = adaptive(light: NSColor(red: 0.967, green: 0.967, blue: 0.970, alpha: 1), dark: NSColor(red: 0.165, green: 0.165, blue: 0.175, alpha: 1))
        /// Cards and chips that sit on canvas or surface.
        static let elevated = adaptive(light: .white, dark: NSColor(red: 0.205, green: 0.205, blue: 0.215, alpha: 1))
        /// Text editor and search field backgrounds.
        static let field = adaptive(light: NSColor(red: 0.975, green: 0.975, blue: 0.978, alpha: 1), dark: NSColor(white: 1, alpha: 0.06))
        /// Hairline borders.
        static let line = adaptive(light: NSColor(white: 0, alpha: 0.065), dark: NSColor(white: 1, alpha: 0.09))
        /// Selected navigation and filter backgrounds.
        static let selection = adaptive(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.10))
        /// Brand accent.
        static let accent = adaptive(light: NSColor(red: 0.15, green: 0.34, blue: 0.96, alpha: 1), dark: NSColor(red: 0.42, green: 0.57, blue: 1.0, alpha: 1))
        static let accentSoft = adaptive(light: NSColor(red: 0.15, green: 0.34, blue: 0.96, alpha: 0.12), dark: NSColor(red: 0.42, green: 0.57, blue: 1.0, alpha: 0.22))
        /// Recording state.
        static let recording = adaptive(light: NSColor(red: 0.84, green: 0.25, blue: 0.22, alpha: 1), dark: NSColor(red: 0.95, green: 0.38, blue: 0.34, alpha: 1))
        static let success = Color(nsColor: .systemGreen)
        static let warning = Color(nsColor: .systemOrange)
        static let danger = Color(nsColor: .systemRed)
        /// Icons and text drawn on `accent` or `recording` fills.
        static let onAccent = Color.white
        /// Dimming layer behind in-window modals such as the settings overlay.
        static let scrim = adaptive(light: NSColor(white: 0, alpha: 0.36), dark: NSColor(white: 0, alpha: 0.55))
        /// Drop shadow of floating panels.
        static let shadow = adaptive(light: NSColor(white: 0, alpha: 0.18), dark: NSColor(white: 0, alpha: 0.5))
        /// Decorative wash behind the Home shortcut card (gradient start and end).
        static let washStart = adaptive(light: NSColor(red: 0.94, green: 0.97, blue: 0.98, alpha: 1), dark: NSColor(red: 0.14, green: 0.16, blue: 0.20, alpha: 1))
        static let washEnd = adaptive(light: NSColor(red: 0.96, green: 0.95, blue: 0.99, alpha: 1), dark: NSColor(red: 0.17, green: 0.15, blue: 0.21, alpha: 1))
        /// Floating HUD panel fill (always dark).
        static let hudPanel = Color(red: 0.085, green: 0.085, blue: 0.09)

        static func adaptive(light: NSColor, dark: NSColor) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            })
        }
    }

    enum Radius {
        static let control: CGFloat = 8
        static let chip: CGFloat = 12
        static let card: CGFloat = 16
        static let panel: CGFloat = 22
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Font {
        static let hero = SwiftUI.Font.system(size: 40, weight: .bold)
        static let pageTitle = SwiftUI.Font.system(size: 30, weight: .bold)
        static let sheetTitle = SwiftUI.Font.system(size: 20, weight: .semibold)
        static let sectionTitle = SwiftUI.Font.system(size: 19, weight: .semibold)
        static let cardTitle = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 14)
        static let detail = SwiftUI.Font.system(size: 12)
        static let footnote = SwiftUI.Font.system(size: 11)
        static let mono = SwiftUI.Font.system(size: 12, design: .monospaced)
        static let statValue = SwiftUI.Font.system(size: 22, weight: .bold)
        /// Brand word mark in the sidebar.
        static let brand = SwiftUI.Font.system(size: 23, weight: .bold, design: .rounded)
        /// Sidebar navigation rows.
        static let navigation = SwiftUI.Font.system(size: 16, weight: .medium)
    }
}

// MARK: - Containers

/// Rounded card. `.plain` is a white/elevated card with a hairline; `.shaded` is a filled surface box without a stroke.
struct VDSurface<Content: View>: View {
    enum Style { case plain, shaded }
    var style: Style = .plain
    var padding: CGFloat = 20
    var spacing: CGFloat = VD.Space.l
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(style == .shaded ? VD.Palette.surface : VD.Palette.elevated, in: RoundedRectangle(cornerRadius: VD.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: VD.Radius.card, style: .continuous).strokeBorder(style == .shaded ? Color.clear : VD.Palette.line))
    }
}

/// Page title with optional subtitle and trailing accessory, used by every main page.
struct VDPageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.subtitle = subtitle; self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: VD.Space.l) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(VD.Font.pageTitle).tracking(-0.8).lineLimit(2).minimumScaleFactor(0.85)
                if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(3) }
            }
            Spacer(minLength: VD.Space.l)
            trailing
        }
    }
}

extension VDPageHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) { self.init(title, subtitle: subtitle) { EmptyView() } }
}

/// Section label inside settings and long pages: icon + title over a hairline.
struct VDSectionHeader: View {
    let icon: String
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: VD.Space.m) {
            Label(title, systemImage: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
            Divider()
        }
    }
}

/// Setting row: title and optional detail on the left, control on the right.
struct VDSettingRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: VD.Space.xl) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(VD.Font.body.weight(.medium))
                if let detail { Text(detail).font(VD.Font.detail).foregroundStyle(.secondary).lineSpacing(2).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: VD.Space.l)
            control.controlSize(.large)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Small components

/// Keyboard key caps, e.g. ["⌃", "⌥", "Space"].
struct VDKeyCaps: View {
    let keys: [String]
    var size: CGFloat = 15

    init(keys: [String], size: CGFloat = 15) { self.keys = keys; self.size = size }

    /// Splits a `ShortcutBinding.label` such as "⌃⌥Space" or "Fn" into individual caps.
    init(label: String, size: CGFloat = 15) {
        var caps: [String] = []
        var rest = Substring(label)
        while let first = rest.first, "⌃⌥⇧⌘".contains(first) { caps.append(String(first)); rest = rest.dropFirst() }
        if !rest.isEmpty { caps.append(String(rest)) }
        self.init(keys: caps.isEmpty ? [label] : caps, size: size)
    }
    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key).font(.system(size: size, weight: .semibold)).frame(minWidth: size * 1.5)
                    .padding(.horizontal, 7).padding(.vertical, 7)
                    .background(VD.Palette.elevated, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(VD.Palette.line))
                    .shadow(color: .black.opacity(0.06), radius: 0, y: 1)
            }
        }.fixedSize()
    }
}

/// Capsule segmented filter with a selected pill.
struct VDFilterPills: View {
    let labels: [String]
    @Binding var selection: Int
    var body: some View {
        HStack(spacing: 2) {
            ForEach(labels.indices, id: \.self) { index in
                Button { selection = index } label: {
                    Text(labels[index]).font(.system(size: 13, weight: selection == index ? .medium : .regular))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(selection == index ? VD.Palette.elevated : .clear, in: Capsule())
                        .contentShape(Capsule())
                }.buttonStyle(.plain).accessibilityAddTraits(selection == index ? [.isSelected] : [])
            }
        }.padding(4).background(VD.Palette.surface, in: Capsule())
    }
}

/// Small status badge such as "Active".
struct VDBadge: View {
    let text: String
    var tint: Color = VD.Palette.accent
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

/// Icon-only button with a 28pt hit target, tooltip and accessibility label.
struct VDIconButton: View {
    let systemName: String
    let label: String
    var size: CGFloat = 13
    var tint: Color? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: size, weight: .medium))
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? Color.secondary)
        .help(label).accessibilityLabel(label)
    }
}

/// Centered empty state for lists and grids.
struct VDEmptyState: View {
    let icon: String
    let title: String
    var detail: String? = nil
    var verticalPadding: CGFloat = 56
    var body: some View {
        VStack(spacing: VD.Space.m) {
            Image(systemName: icon).font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
            if let detail { Text(detail).font(VD.Font.detail).foregroundStyle(.tertiary).multilineTextAlignment(.center) }
        }.frame(maxWidth: .infinity).padding(.vertical, verticalPadding)
    }
}

/// Switch-style toggle whose title is used for accessibility only; pair it with a `VDSettingRow` title.
struct VDSwitch: View {
    let title: String
    @Binding var isOn: Bool
    init(_ title: String, isOn: Binding<Bool>) { self.title = title; self._isOn = isOn }
    var body: some View { Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch) }
}

/// Setting row whose control is a switch labelled by the row title.
struct VDSwitchRow: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        VDSettingRow(title: title, detail: detail) { VDSwitch(title, isOn: $isOn) }
    }
}

/// Search field with a leading magnifying glass.
struct VDSearchField: View {
    let title: String
    @Binding var text: String
    var width: CGFloat = 200
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            SingleLineField(title, text: $text).frame(width: width)
        }
    }
}

/// Visible field label above a text input.
struct VDLabeledField<Content: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(VD.Font.body.weight(.medium))
            if let detail { Text(detail).font(VD.Font.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            content
        }
    }
}

/// Borderless "more" menu for page-level secondary actions.
/// Uses the button menu style with a plain button so the whole 28pt square opens the menu;
/// `.borderlessButton` wraps the label in an AppKit pop-up that ignores the frame (about 26×15pt hit area).
struct VDOverflowMenu<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    var body: some View {
        Menu { content } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 17))
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(.secondary)
        .help(label).accessibilityLabel(label)
    }
}

/// Inline notice bar for success, info, warning and error feedback.
struct VDInlineNotice: View {
    enum Kind { case info, success, warning, error }
    let kind: Kind
    let text: String
    var dismissLabel: String = "Dismiss"
    var onDismiss: (() -> Void)? = nil

    private var tint: Color {
        switch kind {
        case .info: return VD.Palette.accent
        case .success: return VD.Palette.success
        case .warning: return VD.Palette.warning
        case .error: return VD.Palette.danger
        }
    }
    private var icon: String {
        switch kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "exclamationmark.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: VD.Space.m) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.system(size: 13)).foregroundStyle(VD.Palette.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onDismiss { VDIconButton(systemName: "xmark", label: dismissLabel, size: 11, action: onDismiss) }
        }
        .padding(.horizontal, VD.Space.l).padding(.vertical, VD.Space.m)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: VD.Radius.chip, style: .continuous))
    }
}

// MARK: - Styles

/// Page-level call to action: ink pill (`prominent`) or surface pill.
/// The whole capsule is the hit area, and a disabled pill is dimmed (custom styles do not dim on their own).
struct VDPillButtonStyle: ButtonStyle {
    var prominent = true
    func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration, prominent: prominent)
    }

    private struct Pill: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 18).padding(.vertical, 10)
                .foregroundStyle(prominent ? VD.Palette.canvas : VD.Palette.ink)
                .background(prominent ? VD.Palette.ink : VD.Palette.surface, in: Capsule())
                .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.75 : 1)
                .contentShape(Capsule())
        }
    }
}

extension ButtonStyle where Self == VDPillButtonStyle {
    static var vdPill: VDPillButtonStyle { VDPillButtonStyle() }
    static var vdPillSecondary: VDPillButtonStyle { VDPillButtonStyle(prominent: false) }
}

extension View {
    /// Styles a `TextEditor` as a visible input box with a field background and hairline.
    func vdEditorBox(minHeight: CGFloat? = nil, maxHeight: CGFloat? = nil) -> some View {
        self.scrollContentBackground(.hidden)
            .padding(VD.Space.s)
            .frame(minHeight: minHeight, maxHeight: maxHeight)
            .background(VD.Palette.field, in: RoundedRectangle(cornerRadius: VD.Radius.chip, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: VD.Radius.chip, style: .continuous).strokeBorder(VD.Palette.line))
    }

    /// Standard sheet chrome: padding, width, background and accent tint (sheets do not always inherit the window tint).
    func vdSheet(width: CGFloat) -> some View {
        self.padding(VD.Space.xl).frame(width: width).background(VD.Palette.canvas).tint(VD.Palette.accent)
    }
}
