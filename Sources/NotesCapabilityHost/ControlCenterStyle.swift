import SwiftUI

enum ControlCenterType {
    static let title = Font.system(size: 22, weight: .semibold)
    static let brand = Font.system(size: 15, weight: .semibold)
    static let section = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    static let detail = Font.system(size: 12)
    static let control = Font.system(size: 13, weight: .medium)
}

enum ControlCenterPalette {
    static let canvas = adaptive(light: 0.975, dark: 0.095)
    static let sidebar = adaptive(light: 0.93, dark: 0.10)
    static let raised = adaptive(light: 0.95, dark: 0.145)
    static let separator = Color(nsColor: .separatorColor).opacity(0.55)
    static let selected = Color.primary.opacity(0.09)

    private static func adaptive(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let luminance = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(calibratedWhite: luminance, alpha: 1)
        })
    }
}

struct ControlCenterChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct ControlCenterNavigationStyle: ButtonStyle {
    let selected: Bool
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(selected || configuration.isPressed ? ControlCenterPalette.selected
                        : hovered ? ControlCenterPalette.selected.opacity(0.6) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10))
            .onHover { hovered = $0 }
    }
}

struct ControlCenterButtonStyle: ButtonStyle {
    var prominent = false
    var iconOnly = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ControlCenterType.control)
            .foregroundStyle(prominent ? Color(nsColor: .textBackgroundColor)
                            : configuration.role == .destructive ? Color(nsColor: .systemRed) : Color.primary)
            .padding(.horizontal, iconOnly ? 0 : 13)
            .frame(width: iconOnly ? 30 : nil, height: 30)
            .background(prominent ? Color(nsColor: .labelColor) : ControlCenterPalette.selected, in: Capsule())
            .contentShape(Capsule())
            .opacity(!enabled ? 0.45 : configuration.isPressed ? 0.75 : 1)
    }
}
