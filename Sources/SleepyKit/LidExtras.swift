import AudioToolbox
import CoreAudio
import Foundation

/// Extras opcionais para a tampa fechada sem ecrã externo, na mesma transição em
/// que o [[LidDisplay]] apaga o painel: ligar o Low Power Mode e silenciar o som.
/// Ambos desligados por omissão; `apply()` com as duas preferências a false não faz nada.
///
/// Cada extra só mexe no que sabe repor. O que fizemos fica em disco **antes** de
/// mexer (`lidLowPowerByUs`, `lidMutedByUs`…), para que um arranque depois de um
/// crash a meio de uma tampa fechada consiga repor. `restore()` olha só para
/// essas flags, nunca para as preferências: desligar a preferência não deixa nada pendurado.
///
/// Todo o trabalho (pmset, sudo, CoreAudio) corre numa fila série, nunca no main, e
/// as flags só se mexem lá dentro: `apply()` e `restore()` são executados pela ordem
/// em que foram pedidos, mesmo que a tampa abra e feche depressa. Nunca pede password
/// (com a tampa fechada ninguém a veria): sem a regra sudoers v2 o LPM fica por fazer.
enum LidExtras {
    // Preferências.
    private static let lowPowerKey = "lowPowerWhenLidClosed"
    private static let muteKey = "muteWhenLidClosed"
    // Estado que nos pertence. Internas: o [[CrashWatchdog]] lê e apaga as mesmas
    // chaves num `sh`, e tem de bater com estes nomes.
    static let lowPowerByUsKey = "lidLowPowerByUs"
    static let mutedByUsKey = "lidMutedByUs"
    static let mutedDeviceKey = "lidMutedDeviceUID"
    /// Só existe quando silenciámos pelo volume (o dispositivo não tem mute): o volume anterior.
    static let mutedVolumeKey = "lidMutedVolume"

    private static let queue = DispatchQueue(label: "sleepy.lidextras", qos: .utility)

    static var lowPowerWhenLidClosed: Bool {
        get { SleepyDefaults.store.bool(forKey: lowPowerKey) }
        set { SleepyDefaults.store.set(newValue, forKey: lowPowerKey) }
    }

    static var muteWhenLidClosed: Bool {
        get { SleepyDefaults.store.bool(forKey: muteKey) }
        set { SleepyDefaults.store.set(newValue, forKey: muteKey) }
    }

    /// Ligámos o Low Power Mode e ainda não o repusemos (sobrevive a um crash).
    static var lowPowerByUs: Bool { SleepyDefaults.store.bool(forKey: lowPowerByUsKey) }
    /// Silenciámos o som e ainda não o repusemos (sobrevive a um crash).
    static var mutedByUs: Bool { SleepyDefaults.store.bool(forKey: mutedByUsKey) }
    static var hasPending: Bool { lowPowerByUs || mutedByUs }

    // MARK: - Entrada

    /// Tampa fechada sem ecrã externo: liga o que o utilizador escolheu. Idempotente
    /// (as flags dizem o que já está feito). Só chamar na transição do `dim()`.
    static func apply() {
        let lowPower = lowPowerWhenLidClosed
        let mute = muteWhenLidClosed
        guard lowPower || mute else { return }
        queue.async {
            if lowPower { enableLowPower() }
            if mute { muteOutput() }
        }
    }

    /// Repõe o que fizemos (tampa aberta, ecrã externo, Sleepy desligado, outro
    /// modo, arranque). Sem flags não faz nada, por isso pode chamar-se sempre.
    static func restore() {
        queue.async {
            restoreLowPower()
            restoreOutput()
        }
    }

    /// Espera pelo que está em curso. Para a saída da app: sem isto um `restore()`
    /// ainda na fila perdia-se, e o Mac ficava em LPM ou sem som.
    static func flush() {
        queue.sync {}
    }

    // MARK: - Low Power Mode

    /// Os valores do `pmset -g custom`, por fonte: `true` = LPM ligado, `false` =
    /// desligado, `nil` = não se sabe (ou é outro modo, como o High Power).
    ///
    /// O macOS 26 mostra `powermode` (0 automático, 1 baixo consumo, 2 alto
    /// desempenho); versões anteriores mostram `lowpowermode` (0/1). Aceitam-se ambos.
    static func parseLowPowerMode(custom: String) -> (ac: Bool?, battery: Bool?) {
        enum Section { case ac, battery, other }
        struct Reading {
            var lowPowerMode: Bool?
            var powerMode: Bool?
            /// `powermode` com outro valor (High Power): nem o LPM nem o 0 valem.
            var otherMode = false
            var value: Bool? { otherMode ? nil : lowPowerMode ?? powerMode }
        }
        var section = Section.other
        var readings: [Section: Reading] = [:]
        for line in custom.split(whereSeparator: \.isNewline) {
            // Cabeçalho: sem indentação e acabado em ":".
            if let first = line.first, !first.isWhitespace {
                switch line.trimmingCharacters(in: .whitespaces) {
                case "Battery Power:": section = .battery
                case "AC Power:": section = .ac
                default: section = .other
                }
                continue
            }
            guard section != .other else { continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2 else { continue }
            var reading = readings[section] ?? Reading()
            switch (fields[0], fields[1]) {
            case ("lowpowermode", "0"): reading.lowPowerMode = false
            case ("lowpowermode", "1"): reading.lowPowerMode = true
            case ("powermode", "0"): reading.powerMode = false
            case ("powermode", "1"): reading.powerMode = true
            case ("powermode", _): reading.otherMode = true
            default: continue
            }
            readings[section] = reading
        }
        return (readings[.ac]?.value, readings[.battery]?.value)
    }

    /// Só se atua com o LPM desligado nas duas fontes. Quem o usa só numa delas
    /// (ou tem outro modo) não é mexido: repor com `-a 0` apagava essa escolha.
    static func shouldEnableLowPower(_ state: (ac: Bool?, battery: Bool?)) -> Bool {
        state.ac == false && state.battery == false
    }

    private static func enableLowPower() {
        guard !lowPowerByUs else { return }
        guard let custom = run("/usr/bin/pmset", ["-g", "custom"]) else {
            NSLog("Sleepy: Low Power Mode — não deu para ler o pmset, não mexo")
            return
        }
        let state = parseLowPowerMode(custom: custom)
        guard shouldEnableLowPower(state) else {
            NSLog("Sleepy: Low Power Mode já ligado, por fonte ou desconhecido (ac=\(describe(state.ac)), bateria=\(describe(state.battery))) — não mexo")
            return
        }
        // Antes de ligar: um crash entre os dois passos ainda sabe que tem de repor.
        SleepyDefaults.store.set(true, forKey: lowPowerByUsKey)
        guard PrivilegedAccess.setLowPowerMode(true) else {
            SleepyDefaults.store.set(false, forKey: lowPowerByUsKey)
            NSLog("Sleepy: Low Power Mode — sem acesso sem password para o ligar (regra sudoers antiga?)")
            return
        }
        let after = run("/usr/bin/pmset", ["-g", "custom"]).map(parseLowPowerMode(custom:))
        NSLog("Sleepy: tampa fechada — Low Power Mode ligado (leitura: ac=\(describe(after?.ac)), bateria=\(describe(after?.battery)))")
    }

    private static func restoreLowPower() {
        guard lowPowerByUs else { return }
        guard PrivilegedAccess.setLowPowerMode(false) else {
            // A flag fica: tenta-se outra vez na próxima mudança ou no arranque.
            NSLog("Sleepy: não deu para repor o Low Power Mode (sem acesso sem password)")
            return
        }
        SleepyDefaults.store.set(false, forKey: lowPowerByUsKey)
        NSLog("Sleepy: Low Power Mode reposto")
    }

    private static func describe(_ value: Bool?) -> String {
        value.map { $0 ? "ligado" : "desligado" } ?? "?"
    }

    /// stdout de um comando sem privilégios. `nil` se falhar a correr ou sair com erro.
    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Som

    /// Silencia o dispositivo de saída por omissão **no momento em que a tampa
    /// fecha** (mute próprio, ou volume a 0 se não tiver mute) e guarda o UID dele
    /// com o volume de antes. A reposição atua nesse mesmo UID, não no dispositivo
    /// por omissão de agora; se a saída mudar entretanto (auscultadores, AirPods),
    /// o novo dispositivo não é silenciado e a reposição devolve o som ao antigo. Se
    /// o dispositivo desapareceu (desligado), não há o que repor e a flag cai.
    private static func muteOutput() {
        guard !mutedByUs else { return }
        guard let device = Audio.defaultOutputDevice(), let uid = Audio.uid(of: device) else {
            NSLog("Sleepy: som — sem dispositivo de saída, não mexo")
            return
        }
        let store = SleepyDefaults.store
        if Audio.canSet(device, Audio.mute) {
            guard let muted = Audio.get(device, Audio.mute) else { return }
            guard muted == 0 else {
                NSLog("Sleepy: som — já estava silenciado, não mexo")
                return
            }
            store.set(uid, forKey: mutedDeviceKey)
            store.removeObject(forKey: mutedVolumeKey)
            store.set(true, forKey: mutedByUsKey)
            guard Audio.set(device, Audio.mute, 1) else {
                clearMuteState()
                return
            }
            NSLog("Sleepy: tampa fechada — som silenciado (mute)")
        } else if let selector = Audio.volumeSelector(device), let volume = Audio.get(device, selector) {
            guard volume > 0 else {
                NSLog("Sleepy: som — volume já a 0, não mexo")
                return
            }
            store.set(uid, forKey: mutedDeviceKey)
            store.set(volume, forKey: mutedVolumeKey)
            store.set(true, forKey: mutedByUsKey)
            guard Audio.set(device, selector, 0) else {
                clearMuteState()
                return
            }
            NSLog("Sleepy: tampa fechada — som silenciado (volume \(volume) → 0)")
        } else {
            NSLog("Sleepy: som — o dispositivo de saída não tem mute nem volume geral, não mexo")
        }
    }

    private static func restoreOutput() {
        guard mutedByUs else { return }
        let store = SleepyDefaults.store
        guard let uid = store.string(forKey: mutedDeviceKey), let device = Audio.device(forUID: uid) else {
            // O dispositivo foi-se (desligado, ou reiniciou noutro estado): não há o que repor.
            NSLog("Sleepy: som — o dispositivo silenciado já não existe, flag limpa")
            clearMuteState()
            return
        }
        let restored: Bool
        if let volume = (store.object(forKey: mutedVolumeKey) as? NSNumber)?.floatValue {
            restored = Audio.volumeSelector(device).map { Audio.set(device, $0, volume) } ?? false
        } else {
            restored = Audio.set(device, Audio.mute, 0)
        }
        // A flag fica se falhar: tenta-se outra vez na próxima mudança ou no arranque.
        guard restored else {
            NSLog("Sleepy: não deu para repor o som")
            return
        }
        clearMuteState()
        NSLog("Sleepy: som reposto")
    }

    private static func clearMuteState() {
        let store = SleepyDefaults.store
        store.set(false, forKey: mutedByUsKey)
        store.removeObject(forKey: mutedDeviceKey)
        store.removeObject(forKey: mutedVolumeKey)
    }

    // MARK: - CoreAudio

    /// Propriedades do dispositivo de saída, sempre no elemento principal.
    private enum Audio {
        static let mute = AudioObjectPropertySelector(kAudioDevicePropertyMute)
        /// Volume geral "virtual" (o que as teclas de volume mexem). 'vmvc'.
        static let virtualMainVolume = AudioObjectPropertySelector(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        static let volumeScalar = AudioObjectPropertySelector(kAudioDevicePropertyVolumeScalar)

        static func outputAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(mSelector: selector,
                                       mScope: kAudioDevicePropertyScopeOutput,
                                       mElement: kAudioObjectPropertyElementMain)
        }

        static func defaultOutputDevice() -> AudioDeviceID? {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var device = AudioDeviceID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
            return status == noErr && device != AudioDeviceID(kAudioObjectUnknown) ? device : nil
        }

        static func uid(of device: AudioDeviceID) -> String? {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var uid: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
            return status == noErr ? uid?.takeRetainedValue() as String? : nil
        }

        /// O dispositivo com este UID, se ainda existir.
        static func device(forUID uid: String) -> AudioDeviceID? {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var qualifier = uid as CFString
            var device = AudioDeviceID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = withUnsafeMutablePointer(to: &qualifier) { pointer in
                AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                           UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
            }
            return status == noErr && device != AudioDeviceID(kAudioObjectUnknown) ? device : nil
        }

        static func canSet(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> Bool {
            var address = outputAddress(selector)
            guard AudioObjectHasProperty(device, &address) else { return false }
            var settable: DarwinBoolean = false
            return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
        }

        /// O primeiro volume geral que se pode mexer, ou `nil` (só tem volumes por canal).
        static func volumeSelector(_ device: AudioDeviceID) -> AudioObjectPropertySelector? {
            [virtualMainVolume, volumeScalar].first { canSet(device, $0) }
        }

        /// Mute é um UInt32 (0/1); volume um Float32. Os dois cabem em Float para quem chama.
        static func get(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> Float? {
            var address = outputAddress(selector)
            var size: UInt32
            if selector == mute {
                var value: UInt32 = 0
                size = UInt32(MemoryLayout<UInt32>.size)
                guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
                return Float(value)
            }
            var value: Float32 = 0
            size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
            return value
        }

        static func set(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ newValue: Float) -> Bool {
            var address = outputAddress(selector)
            let status: OSStatus
            if selector == mute {
                var value: UInt32 = newValue > 0 ? 1 : 0
                status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
            } else {
                var value = Float32(newValue)
                status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
            }
            if status != noErr { NSLog("Sleepy: som — falha a mudar a propriedade \(selector) (\(status))") }
            return status == noErr
        }
    }
}
