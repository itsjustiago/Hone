import AppKit

/// Cor do símbolo na barra de menus com o Sleepy ligado. `none` deixa a imagem
/// como template (segue a cor da barra), como antes desta opção existir.
enum IconAccent: String, CaseIterable, Identifiable {
    case none, orange, yellow, green, blue, purple, pink, red

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Nenhuma"
        case .orange: return "Laranja"
        case .yellow: return "Amarelo"
        case .green: return "Verde"
        case .blue: return "Azul"
        case .purple: return "Roxo"
        case .pink: return "Rosa"
        case .red: return "Vermelho"
        }
    }

    /// Cores de sistema: adaptam-se sozinhas ao claro/escuro da barra.
    var color: NSColor? {
        switch self {
        case .none: return nil
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .red: return .systemRed
        }
    }

    /// A bolinha ao lado do nome no picker das Definições; «Nenhuma» é um anel.
    /// Cor resolvida dentro do drawing handler, para seguir a aparência do menu.
    var swatch: NSImage {
        let color = color
        return NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            if let color {
                color.setFill()
                NSBezierPath(ovalIn: rect).fill()
            } else {
                NSColor.secondaryLabelColor.setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
            }
            return true
        }
    }
}

/// As duas preferências do ícone, na mesma suite das restantes do Sleepy.
enum MenuBarIconSettings {
    private static let accentKey = "menuBarAccent"
    private static let countdownKey = "menuBarCountdown"

    /// Laranja por omissão: o ícone destaca-se quando o Mac está a ser mantido acordado.
    static var accent: IconAccent {
        get { IconAccent(rawValue: SleepyDefaults.store.string(forKey: accentKey) ?? "") ?? .orange }
        set { SleepyDefaults.store.set(newValue.rawValue, forKey: accentKey) }
    }

    /// Desligada por omissão: a contagem alarga o ícone na barra.
    static var showsCountdown: Bool {
        get { SleepyDefaults.store.bool(forKey: countdownKey) }
        set { SleepyDefaults.store.set(newValue, forKey: countdownKey) }
    }
}

/// O desenho do ícone da barra e as decisões puras por trás dele.
enum MenuBarIcon {
    /// Espaço entre a caixa do símbolo e a contagem.
    static let countdownGap: CGFloat = 3
    static let countdownFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    /// A cor do símbolo: só com o Sleepy ligado e uma cor escolhida. `nil` = template.
    static func accentColor(_ accent: IconAccent, isActive: Bool) -> NSColor? {
        isActive ? accent.color : nil
    }

    /// O que falta para o prazo, curto: "45m" ou "2h05". Minutos arredondados para
    /// cima, para nunca mostrar «0m» com o Sleepy ainda ligado. `nil` sem prazo
    /// ou com o prazo já passado.
    static func countdownText(until deadline: Date?, now: Date) -> String? {
        guard let deadline else { return nil }
        let remaining = deadline.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        let minutes = Int((remaining / 60).rounded(.up))
        guard minutes >= 60 else { return "\(minutes)m" }
        return "\(minutes / 60)h" + String(format: "%02d", minutes % 60)
    }

    /// O timer da contagem só corre com algo para contar e alguém a ver o ícone:
    /// a tool a correr, o Sleepy ligado, a opção da contagem ligada, o ícone próprio
    /// visível e um prazo. Qualquer condição falsa sozinha desliga-o.
    static func countdownTimerWanted(isRunning: Bool, isActive: Bool, showsCountdown: Bool,
                                     showsOwnIcon: Bool, hasDeadline: Bool) -> Bool {
        isRunning && isActive && showsCountdown && showsOwnIcon && hasDeadline
    }

    /// O símbolo centrado na caixa fixa `box` (à esquerda, sempre no mesmo sítio) e,
    /// se houver contagem, o texto à direita. Com `accent` a imagem deixa de ser
    /// template e símbolo e texto levam essa cor; sem ele, template, como sempre.
    static func image(symbol: NSImage, box: NSSize, accent: NSColor?, countdown: String?) -> NSImage {
        let font = countdownFont
        var width = box.width
        if let countdown {
            width += countdownGap + (countdown as NSString).size(withAttributes: [.font: font]).width
        }
        let image = NSImage(size: NSSize(width: width.rounded(.up), height: box.height), flipped: false) { rect in
            let size = symbol.size
            // Half points: pixel-aligned on Retina.
            let x = ((box.width - size.width) / 2 * 2).rounded() / 2
            let y = ((box.height - size.height) / 2 * 2).rounded() / 2
            (accent.map { tinted(symbol, $0) } ?? symbol).draw(in: NSRect(x: x, y: y, width: size.width, height: size.height))
            if let countdown {
                // Colours are resolved inside the drawing handler, so they follow the
                // appearance of the menu bar. Template: only the alpha counts.
                let text = NSAttributedString(string: countdown,
                                              attributes: [.font: font, .foregroundColor: accent ?? NSColor.black])
                // Centred on the digits (cap height), not on the taller line box.
                let baseline = ((rect.height - font.capHeight) / 2 * 2).rounded() / 2
                text.draw(at: NSPoint(x: box.width + countdownGap, y: baseline + font.descender))
            }
            return true
        }
        image.isTemplate = accent == nil
        return image
    }

    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
