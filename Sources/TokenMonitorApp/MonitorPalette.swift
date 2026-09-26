import AppKit
import SwiftUI

enum MonitorPalette {
    static let balance = adaptive(light: NSColor(srgbRed: 0.08, green: 0.43, blue: 0.30, alpha: 1), dark: NSColor(srgbRed: 0.39, green: 0.82, blue: 0.61, alpha: 1))
    static let input = adaptive(light: NSColor(srgbRed: 0.18, green: 0.38, blue: 0.70, alpha: 1), dark: NSColor(srgbRed: 0.55, green: 0.72, blue: 0.98, alpha: 1))
    static let output = adaptive(light: NSColor(srgbRed: 0.68, green: 0.35, blue: 0.16, alpha: 1), dark: NSColor(srgbRed: 0.98, green: 0.67, blue: 0.39, alpha: 1))
    static let cache = adaptive(light: NSColor(srgbRed: 0.05, green: 0.48, blue: 0.49, alpha: 1), dark: NSColor(srgbRed: 0.42, green: 0.80, blue: 0.78, alpha: 1))

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

struct MonitorMaterial: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        // Keep the popover's translucent material when the menu temporarily
        // takes focus or the pointer leaves the panel.
        view.state = .active
        view.material = material
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

enum MonitorLayout {
    static let panelWidth: CGFloat = 430
    static let panelHeight: CGFloat = 650
    static let settingsWidth: CGFloat = 490
    static let settingsHeight: CGFloat = 680
    static let panelGutter: CGFloat = 18
    static let sectionGap: CGFloat = 16
    static let iconTarget: CGFloat = 36
}
