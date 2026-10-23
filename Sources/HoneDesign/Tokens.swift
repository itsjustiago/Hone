import AppKit
import SwiftUI

// Hone's visual language: a black canvas, near-black cards with hairline
// borders, and one colour per tool. Values were measured from the reference
// design (2x pixels converted to points). Every screen reads from here so the
// popover, the Kits' panels and Settings stay in step.

// MARK: - Colours

public enum VibeColor {
    /// Window/popover background.
    public static let canvas = Color(vibeHex: 0x000000)
    /// Card surface.
    public static let card = Color(vibeHex: 0x141518)
    /// Hairline around cards (and around "off" pills).
    public static let cardBorder = Color(vibeHex: 0x1C1D20)
    /// Recessed surface inside a card (pills, wells).
    public static let inset = Color(vibeHex: 0x0E0F11)
    /// A surface lifted above the card (selected pill).
    public static let raised = Color(vibeHex: 0x1A1C20)
    /// Selected/hovered control fill (top-bar capsule).
    public static let control = Color(vibeHex: 0x1D1F23)
    /// Switch track when off.
    public static let track = Color(vibeHex: 0x2A2C31)
    /// Small round corner button.
    public static let cornerFill = Color(vibeHex: 0x252628)
    public static let cornerIcon = Color(vibeHex: 0x60646C)

    /// Primary text and selected icons.
    public static let text1 = Color(vibeHex: 0xF5F6F8)
    /// Strong links, names of active items.
    public static let text2 = Color(vibeHex: 0xB2B3B5)
    /// Secondary text, idle icons.
    public static let text3 = Color(vibeHex: 0x8F939B)
    /// Tertiary text, names of inactive items.
    public static let text4 = Color(vibeHex: 0x6C7078)

    /// Status dot of something that is off.
    public static let dotOff = Color(vibeHex: 0x3D4045)

    public static let danger = Color(vibeHex: 0xE25C62)
    public static let warning = Color(vibeHex: 0xEBAE5A)
    public static let success = Color(vibeHex: 0x60C97A)

    /// Ink used on light fills (white/yellow tools).
    public static let inkOnLight = Color(vibeHex: 0x1A1B1E)
    /// The mascot's eyes.
    public static let blobEye = Color(vibeHex: 0x221B18)
}

// MARK: - Tool palette

/// The eleven tool colours. Pastel-bright so they glow on black.
public enum VibePalette {
    public static let blue = Color(vibeHex: 0x5AA2F0)
    public static let purple = Color(vibeHex: 0x8C79F7)
    public static let teal = Color(vibeHex: 0x4FC7BD)
    public static let red = Color(vibeHex: 0xE87275)
    public static let orange = Color(vibeHex: 0xEBAE5A)
    public static let pink = Color(vibeHex: 0xEF86C0)
    public static let yellow = Color(vibeHex: 0xEED65E)
    public static let lilac = Color(vibeHex: 0xC58AF2)
    public static let green = Color(vibeHex: 0x60C97A)
    /// Fills the widest hue gap of the palette (yellow to green).
    public static let lime = Color(vibeHex: 0xA6D65C)
    public static let white = Color(vibeHex: 0xF2F3F5)

    /// In display order, for previews and contact sheets.
    public static let all: [Color] = [blue, purple, teal, red, orange, pink, yellow, lilac, green, lime, white]
}

/// Single source of truth for which colour each Hone tool wears — the Hone
/// modules and the embedded Kits both read it from here.
public enum VibeToolColor {
    /// Hone itself: the white mascot.
    public static let hone = VibePalette.white
    public static let scroll = VibePalette.blue
    public static let windowPeek = VibePalette.purple
    public static let altTab = VibePalette.teal
    public static let quitOnClose = VibePalette.red
    public static let keySwap = VibePalette.orange
    public static let clippy = VibePalette.pink
    public static let screenly = VibePalette.yellow
    public static let sleepy = VibePalette.lilac
    public static let stats = VibePalette.green
    public static let soundly = VibePalette.lime
    public static let cleanKeyboard = VibePalette.white
    /// Shares Alt-Tab's teal: the palette is fully assigned and the two sit far apart in the list.
    public static let lidFold = VibePalette.teal
    /// Shares Stats' green: the palette is fully assigned, and a tweak and an app sit far apart in the list.
    public static let windowsShortcuts = VibePalette.green
    /// Shares Clippy's pink: the palette is fully assigned, and a tweak and an app sit far apart in the list.
    public static let island = VibePalette.pink
}

// MARK: - Shape & space

public enum VibeRadius {
    /// Cards.
    public static let card: CGFloat = 18
    /// Thin notice strips.
    public static let strip: CGFloat = 12
    /// Small wells/rows.
    public static let small: CGFloat = 8
}

public enum VibeSpacing {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 6
    public static let m: CGFloat = 10
    public static let l: CGFloat = 14
    public static let xl: CGFloat = 18
    /// Between stacked cards.
    public static let cardGap: CGFloat = 10
    /// Panel edge to card.
    public static let outer: CGFloat = 10
    /// Inside a card.
    public static let cardPadding: CGFloat = 14
}

public enum VibeMetrics {
    /// Width of every menu-bar panel (Hone's home and the Kits' panels).
    public static let panelWidth: CGFloat = 344
    /// Card width inside a panel.
    public static var cardWidth: CGFloat { panelWidth - 2 * VibeSpacing.outer }
    public static let pillHeight: CGFloat = 30
    /// A tweak's or app's row on the home.
    public static let rowHeight: CGFloat = 34
    public static let barTab = CGSize(width: 34, height: 24)
    public static let toggle = CGSize(width: 40, height: 24)
    public static let dot: CGFloat = 6
    public static let cornerButton: CGFloat = 16
}

public enum VibeFont {
    public static let title = Font.system(size: 15, weight: .bold)
    public static let subtitle = Font.system(size: 13)
    public static let body = Font.system(size: 12.5)
    public static let action = Font.system(size: 12.5, weight: .semibold)
    public static let actionSecondary = Font.system(size: 12.5)
    public static let pill = Font.system(size: 12, weight: .semibold)
    public static let caption = Font.system(size: 11)
    public static let barIcon = Font.system(size: 13, weight: .medium)
}

public enum VibeMotion {
    /// Hover/press feedback.
    public static let quick = Animation.easeOut(duration: 0.12)
    /// State changes (toggle, selection).
    public static let standard = Animation.easeOut(duration: 0.18)
    /// Something arriving (the hero mascot).
    public static let arrive = Animation.spring(response: 0.32, dampingFraction: 0.78)
}

// MARK: - Colour helpers

public extension Color {
    /// `0xRRGGBB` in sRGB.
    init(vibeHex hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }

    /// Relative luminance (0…1, sRGB/WCAG).
    var vibeLuminance: Double {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return 0.5 }
        func lin(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }

    /// Light enough that white on top of it is unreadable (white, yellow).
    var vibeIsLight: Bool { vibeLuminance > 0.55 }

    /// Text/glyph colour for content drawn on a fill of this colour.
    var vibeInk: Color { vibeIsLight ? VibeColor.inkOnLight : .white }

    /// Tint for native controls (switches, sliders, prominent buttons) on
    /// system backgrounds: a near-white tool colour would vanish, so those
    /// fall back to the system accent. Saturated colours pass through.
    var vibeControlTint: Color {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return self }
        return c.saturationComponent < 0.15 && c.brightnessComponent > 0.85 ? .accentColor : self
    }

    /// This colour laid over `base` at `amount` (0 = base, 1 = self), flattened
    /// to an opaque colour — e.g. a 15% tool-coloured hairline over a card.
    func vibeMix(over base: Color, amount: Double) -> Color {
        guard let a = NSColor(self).usingColorSpace(.sRGB),
              let b = NSColor(base).usingColorSpace(.sRGB) else { return self.opacity(amount) }
        let t = CGFloat(amount)
        return Color(.sRGB,
                     red: Double(b.redComponent + (a.redComponent - b.redComponent) * t),
                     green: Double(b.greenComponent + (a.greenComponent - b.greenComponent) * t),
                     blue: Double(b.blueComponent + (a.blueComponent - b.blueComponent) * t))
    }
}
