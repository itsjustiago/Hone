import AppKit
import SwiftUI
import HoneDesign

/// Offscreen PNG renders of the popover from fake data, for checking UI work
/// without opening windows or capturing the screen. Run with
/// `HONE_RENDER_PREVIEWS=<folder> .build/debug/Hone` (see `HoneMain`).
@MainActor
enum PreviewRenderer {
    static func renderAll(to folder: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("render: \(error)\n".utf8))
            return false
        }

        let mixed = Fixture.tools(off: ["windowPeek", "quitOnClose", "sleepy"])
        var pages: [(String, AnyView)] = [
            ("home", popover(mixed)),
            ("home-alerts", popover(
                Fixture.tools(off: ["windowPeek", "sleepy"],
                              alerts: ["clippy": .paused, "screenly": .missingPermission("Gravação de Ecrã")]),
                notices: [.update(version: "1.6.0"), .accessibility])),
            // Sleepy on but not blocking sleep: switch on, mascot asleep.
            ("home-sleepy-idle", popover(Fixture.tools(off: ["windowPeek", "quitOnClose"], idle: ["sleepy"]))),
            ("home-off", popover(Fixture.tools(off: Set(Fixture.all.map(\.id))))),
            ("blobs", AnyView(blobSheet)),
            ("blobs-gaze", AnyView(gazeSheet)),
        ]
        // Other surfaces add their pages in their own files.
        pages += kitPages + settingsPages

        var ok = true
        for (name, view) in pages {
            let url = folder.appendingPathComponent("\(name).png")
            if write(view, to: url) {
                print("render: \(url.path)")
            } else {
                FileHandle.standardError.write(Data("render: failed \(name)\n".utf8))
                ok = false
            }
        }
        return ok
    }

    private static func popover(_ tools: [HomeTool], notices: [HomeNotice] = []) -> AnyView {
        let tabs = [HomeTab.home] + tools.filter(\.canOpenPanel)
            .map { HomeTab(id: $0.id, systemImage: $0.iconSystemName, title: $0.title) }
        return AnyView(
            PopoverShell(tabs: tabs, selectedTab: nil) {
                HomeView(tools: tools, notices: notices)
            }
        )
    }

    /// Every tool colour in each mood, hero size and pill size.
    private static var blobSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(VibePalette.all.enumerated()), id: \.offset) { _, color in
                HStack(spacing: 22) {
                    ForEach(Blob.Mood.allCases, id: \.self) { mood in
                        Blob(color: color, mood: mood, height: 50, glow: mood == .awake)
                            .frame(width: 80, height: 60)
                    }
                    ForEach(Blob.Mood.allCases, id: \.self) { mood in
                        Blob(color: color, mood: mood, height: 19)
                            .frame(width: 32, height: 24)
                    }
                }
            }
        }
        .padding(20)
        .background(VibeColor.card)
        .environment(\.colorScheme, .dark)
    }

    /// The eyes turned toward a pointer in each direction (the pointer is the
    /// small white dot), at hero size and pill size, awake and alert.
    private static var gazeSheet: some View {
        let targets: [(String, CGPoint)] = [
            ("cima-esq", CGPoint(x: -30, y: -20)), ("cima", CGPoint(x: 52, y: -30)),
            ("dir", CGPoint(x: 150, y: 30)), ("baixo", CGPoint(x: 52, y: 120)),
            ("perto", CGPoint(x: 70, y: 30)),
        ]
        func cell(_ mood: Blob.Mood, height: CGFloat, target: CGPoint) -> some View {
            let size = CGSize(width: height * 1.3, height: height)
            return Color.clear
                .frame(width: 190, height: 150)
                .overlay(alignment: .topLeading) {
                    Blob(color: VibeToolColor.scroll, mood: mood, height: height)
                        .frame(width: size.width, height: size.height)
                        .offset(x: 52 - size.width / 2, y: 30 - size.height / 2)
                }
                .overlay(alignment: .topLeading) {
                    Circle().fill(.white).frame(width: 5, height: 5)
                        .offset(x: target.x - 2.5, y: target.y - 2.5)
                }
                .blobsLookAt(target)
        }
        return VStack(alignment: .leading, spacing: 4) {
            ForEach([(Blob.Mood.awake, 50.0), (.alert, 50.0), (.awake, 19.0)], id: \.1) { mood, height in
                HStack(spacing: 4) {
                    ForEach(targets, id: \.0) { _, target in
                        cell(mood, height: height, target: target)
                    }
                }
            }
        }
        .padding(10)
        .background(VibeColor.card)
        .environment(\.colorScheme, .dark)
    }

    private static func write(_ view: AnyView, to url: URL) -> Bool {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else { return false }
        return (try? png.write(to: url)) != nil
    }
}

/// The eleven tools as fake values (mirrors the modules' metadata).
enum Fixture {
    struct Spec {
        let id, title, shortTitle, category, tagline, icon: String
        let tint: Color
        var momentary = false
        var actionLabel = ""
        var panel = false
    }

    static let all: [Spec] = [
        Spec(id: "scroll", title: "Scroll", shortTitle: "Scroll", category: "Rato",
             tagline: "Inverte a roda do rato sem mexer no trackpad e torna o scroll suave.",
             icon: "computermouse.fill", tint: VibeToolColor.scroll),
        Spec(id: "windowPeek", title: "Window Peek", shortTitle: "Window Peek", category: "Dock",
             tagline: "Passa o rato num ícone do Dock para ver e trocar de janela.",
             icon: "macwindow.on.rectangle", tint: VibeToolColor.windowPeek),
        Spec(id: "altTab", title: "Alt-Tab Visual", shortTitle: "Alt-Tab", category: "Janelas",
             tagline: "Mantém ⌥ e carrega em Tab para ver e trocar entre todas as janelas.",
             icon: "rectangle.stack.fill", tint: VibeToolColor.altTab),
        Spec(id: "quitOnClose", title: "Fechar = Sair", shortTitle: "Fechar = Sair", category: "Apps",
             tagline: "Fecha a última janela de uma app e ela sai sozinha.",
             icon: "xmark.app.fill", tint: VibeToolColor.quitOnClose),
        Spec(id: "keySwap", title: "Comando ⇄ Controlo", shortTitle: "⌘ ⇄ ⌃", category: "Teclado",
             tagline: "Troca ⌘ com ⌃ para copiares e colares como no Windows.",
             icon: "command.square.fill", tint: VibeToolColor.keySwap),
        Spec(id: "lidFold", title: "Dobra da tampa", shortTitle: "Tampa", category: "Ecrã",
             tagline: "O ecrã dobra-se quando fechas ou abres a tampa.",
             icon: "laptopcomputer", tint: VibeToolColor.lidFold),
        Spec(id: "clippy", title: "Clippy", shortTitle: "Clippy", category: "Clipboard",
             tagline: "Um atalho mostra o que copiaste, texto e imagens.",
             icon: "doc.on.clipboard", tint: VibeToolColor.clippy, panel: true),
        Spec(id: "screenly", title: "Screenly", shortTitle: "Screenly", category: "Capturas",
             tagline: "Capturas de região, janela ou ecrã inteiro, com anotação e conta-gotas.",
             icon: "camera.viewfinder", tint: VibeToolColor.screenly, panel: true),
        Spec(id: "sleepy", title: "Sleepy", shortTitle: "Sleepy", category: "Energia",
             tagline: "Mantém o ecrã aceso e o Mac acordado, mesmo de tampa fechada.",
             icon: "moon.zzz", tint: VibeToolColor.sleepy, panel: true),
        Spec(id: "stats", title: "Stats", shortTitle: "Stats", category: "Sistema",
             tagline: "CPU, memória, GPU e ventoinhas em direto na barra de menus.",
             icon: "cpu", tint: VibeToolColor.stats, panel: true),
        Spec(id: "cleanKeyboard", title: "Limpar Teclado", shortTitle: "Limpar Teclado", category: "Teclado",
             tagline: "Bloqueia o teclado uns segundos para o limpares à vontade.",
             icon: "keyboard.fill", tint: VibeToolColor.cleanKeyboard, momentary: true, actionLabel: "Limpar"),
    ]

    static func tools(off: Set<String>, alerts: [String: HomeTool.Alert] = [:],
                      idle: Set<String> = []) -> [HomeTool] {
        all.map { s in
            HomeTool(id: s.id, title: s.title, shortTitle: s.shortTitle, category: s.category,
                     tagline: s.tagline, iconSystemName: s.icon, tint: s.tint, isAvailable: true,
                     isMomentary: s.momentary, actionLabel: s.actionLabel,
                     isEnabled: !s.momentary && !off.contains(s.id), hasPanel: s.panel,
                     alert: alerts[s.id], isIdle: idle.contains(s.id))
        }
    }
}
