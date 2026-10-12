import CoreGraphics
import Foundation
import ObjectiveC

/// Apaga o painel interno e a retroiluminação do teclado com a tampa fechada.
///
/// Com o `disablesleep` ativo e a tampa fechada sem ecrã externo, o macOS deixa
/// o painel interno aceso dentro da tampa (calor, bateria). Não há API pública
/// para o brilho do painel nem do teclado: usamos os frameworks privados
/// DisplayServices e CoreBrightness, sempre com `dlsym`/`responds(to:)` antes.
/// Se faltar alguma coisa, não faz nada (e diz uma vez no log) — nunca crasha.
///
/// "Amostra de confiança" = o último brilho lido com a tampa ABERTA e sem nós a
/// escurecer. Fica em disco com a flag `dimmedByUs`, para que um arranque
/// depois de um crash a meio de uma tampa fechada consiga repor o brilho.
enum LidDisplay {
    private static let trustedPanelKey = "trustedPanelBrightness"
    private static let trustedKeyboardKey = "trustedKeyboardBrightness"
    private static let dimmedKey = "dimmedByUs"
    /// O powerd às vezes reaplica um valor antigo ao abrir a tampa.
    private static let reapplyDelay: TimeInterval = 2

    /// Incrementa a cada dim/restore: uma reposição atrasada só corre se nada
    /// mudou entretanto.
    private static var generation = 0
    /// Até aqui não se amostra: o valor ainda pode ser o do powerd, não o do utilizador.
    private static var restoringUntil: Date?

    /// Escurecemos e ainda não repusemos (sobrevive a um crash).
    static var dimmedByUs: Bool { SleepyDefaults.store.bool(forKey: dimmedKey) }

    static var trustedPanel: Float? { (SleepyDefaults.store.object(forKey: trustedPanelKey) as? NSNumber)?.floatValue }
    static var trustedKeyboard: Float? { (SleepyDefaults.store.object(forKey: trustedKeyboardKey) as? NSNumber)?.floatValue }

    // MARK: - Amostra

    /// Guarda o brilho atual como amostra de confiança. Chamar só com a tampa
    /// aberta. Escreve em disco só quando muda.
    static func sampleTrusted() {
        guard !dimmedByUs else { return }
        if let until = restoringUntil, Date() < until { return }
        let store = SleepyDefaults.store
        // Painel a 0 de tampa aberta é quase sempre um valor de passagem; repor
        // um 0 seria pior do que repor o anterior.
        if let id = builtInDisplayID(), let panel = panelBrightness(id), panel > 0.01, panel != trustedPanel {
            store.set(panel, forKey: trustedPanelKey)
        }
        if let keyboard = keyboardBrightness(), keyboard != trustedKeyboard {
            store.set(keyboard, forKey: trustedKeyboardKey)
        }
    }

    // MARK: - Escurecer / repor

    /// Painel e teclado a 0 e ecrã a dormir. Só põe a 0 o que sabe repor.
    static func dim() {
        generation += 1
        restoringUntil = nil
        SleepyDefaults.store.set(true, forKey: dimmedKey)
        if trustedPanel != nil, let id = builtInDisplayID() {
            setPanelBrightness(0, id)
        }
        if trustedKeyboard != nil {
            setKeyboardBrightness(0)
        }
        SleepController.runPmsetInBackground(["displaysleepnow"])
    }

    /// Repõe painel e teclado com a amostra, e outra vez `reapplyDelay` depois.
    /// Amostra desconhecida ⇒ não mexe. A flag só cai se o painel foi reposto
    /// (com um ecrã externo e a tampa fechada o interno pode estar offline —
    /// tenta-se outra vez na próxima mudança).
    static func restore() {
        generation += 1
        let current = generation
        restoringUntil = Date().addingTimeInterval(reapplyDelay + 0.5)
        guard apply() else { return }
        SleepyDefaults.store.set(false, forKey: dimmedKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + reapplyDelay) {
            guard generation == current else { return }
            _ = apply()
        }
    }

    /// `true` se o painel ficou reposto (ou não havia nada a repor).
    private static func apply() -> Bool {
        if let keyboard = trustedKeyboard { setKeyboardBrightness(keyboard) }
        guard displayServices != nil, let panel = trustedPanel else { return true }
        guard let id = builtInDisplayID() else { return false }
        return setPanelBrightness(panel, id)
    }

    // MARK: - Painel (DisplayServices)

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let displayServices: (get: GetBrightness, set: SetBrightness)? = {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness") else {
            NSLog("Sleepy: DisplayServices indisponível — o brilho do painel não é mexido")
            return nil
        }
        return (unsafeBitCast(get, to: GetBrightness.self), unsafeBitCast(set, to: SetBrightness.self))
    }()

    /// Sempre o ecrã interno, nunca o `CGMainDisplayID()` (que pode ser o externo).
    static func builtInDisplayID() -> CGDirectDisplayID? {
        LidMonitor.onlineDisplays().first { CGDisplayIsBuiltin($0) != 0 }
    }

    private static func panelBrightness(_ id: CGDirectDisplayID) -> Float? {
        guard let ds = displayServices else { return nil }
        var value: Float = 0
        return ds.get(id, &value) == 0 ? value : nil
    }

    @discardableResult
    private static func setPanelBrightness(_ value: Float, _ id: CGDirectDisplayID) -> Bool {
        guard let ds = displayServices else { return false }
        let result = ds.set(id, value)
        if result != 0 { NSLog("Sleepy: falha a mudar o brilho do painel (\(result))") }
        return result == 0
    }

    // MARK: - Teclado (CoreBrightness)

    private typealias KeyboardGet = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias KeyboardSet = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
    /// `(UInt64) -> Bool`: isKeyboardBuiltIn:, isBacklightDimmedOnKeyboard:…
    private typealias KeyboardBool = @convention(c) (AnyObject, Selector, UInt64) -> Bool
    private typealias KeyboardIDs = @convention(c) (AnyObject, Selector) -> Unmanaged<NSArray>?

    private struct Keyboard {
        let client: NSObject
        let ids: [UInt64]
        let get: KeyboardGet
        let set: KeyboardSet
        let getSelector: Selector
        let setSelector: Selector
        /// Retroiluminação apagada pelo sistema (inatividade, luz ambiente):
        /// o valor lido aí não é o do utilizador.
        let isOffBySystem: (UInt64) -> Bool
    }

    /// Criado uma vez: o cliente e os IDs do teclado interno não mudam.
    private static let keyboard: Keyboard? = {
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        let idsSel = NSSelectorFromString("copyKeyboardBacklightIDs")
        let getSel = NSSelectorFromString("brightnessForKeyboard:")
        let setSel = NSSelectorFromString("setBrightness:forKeyboard:")
        let builtInSel = NSSelectorFromString("isKeyboardBuiltIn:")
        guard let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else {
            NSLog("Sleepy: KeyboardBrightnessClient indisponível — o teclado não é mexido")
            return nil
        }
        let client = cls.init()
        guard client.responds(to: idsSel), client.responds(to: getSel), client.responds(to: setSel),
              let idsIMP = client.method(for: idsSel),
              let getIMP = client.method(for: getSel),
              let setIMP = client.method(for: setSel) else {
            NSLog("Sleepy: KeyboardBrightnessClient sem os seletores esperados — o teclado não é mexido")
            return nil
        }
        // "copy…" devolve +1; ler sem consumir no máximo deixa fugir um array
        // pequeno uma vez, enquanto consumir a mais crashava.
        let copyIDs = unsafeBitCast(idsIMP, to: KeyboardIDs.self)
        var ids = (copyIDs(client, idsSel)?.takeUnretainedValue() as? [NSNumber] ?? []).map(\.uint64Value)
        // Só o teclado interno fica debaixo da tampa.
        if client.responds(to: builtInSel), let builtInIMP = client.method(for: builtInSel) {
            let isBuiltIn = unsafeBitCast(builtInIMP, to: KeyboardBool.self)
            ids = ids.filter { isBuiltIn(client, builtInSel, $0) }
        }
        guard !ids.isEmpty else {
            NSLog("Sleepy: sem teclado interno com retroiluminação — o teclado não é mexido")
            return nil
        }
        let offChecks: [(KeyboardBool, Selector)] = ["isBacklightDimmedOnKeyboard:", "isBacklightSuppressedOnKeyboard:"]
            .map(NSSelectorFromString)
            .compactMap { sel in
                guard client.responds(to: sel), let imp = client.method(for: sel) else { return nil }
                return (unsafeBitCast(imp, to: KeyboardBool.self), sel)
            }
        return Keyboard(client: client, ids: ids,
                        get: unsafeBitCast(getIMP, to: KeyboardGet.self),
                        set: unsafeBitCast(setIMP, to: KeyboardSet.self),
                        getSelector: getSel, setSelector: setSel,
                        isOffBySystem: { id in offChecks.contains { $0.0(client, $0.1, id) } })
    }()

    private static func keyboardBrightness() -> Float? {
        guard let kb = keyboard, let id = kb.ids.first, !kb.isOffBySystem(id) else { return nil }
        return kb.get(kb.client, kb.getSelector, id)
    }

    private static func setKeyboardBrightness(_ value: Float) {
        guard let kb = keyboard else { return }
        for id in kb.ids where !kb.set(kb.client, kb.setSelector, value, id) {
            NSLog("Sleepy: falha a mudar o brilho do teclado \(id)")
        }
    }
}
