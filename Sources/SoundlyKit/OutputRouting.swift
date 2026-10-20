import CoreAudio

/// A device an app's processes play to (`kAudioProcessPropertyDevices`, output
/// scope), as far as the routing rule needs to know it.
struct ProcessOutputDevice: Equatable {
    var id: AudioDeviceID
    var name: String
    /// `nil` for a plain device. For an aggregate (a multi-output device, or the
    /// one voice processing builds around a headset), its sub-devices that have
    /// output streams.
    var outputSubdevices: [AudioDeviceID]?
}

/// Where an app's tap should play.
enum OutputRoute: Equatable {
    /// No device open (paused, between calls) or none readable: a live tap stays
    /// where it is, a new one goes to the default output.
    case undetermined
    /// More than one candidate: the system's default output.
    case ambiguous
    case device(AudioDeviceID)
    /// The app plays to a device the aggregate can't hold (an aggregate with
    /// several outputs: a multi-output device). Device name, for the reason.
    case unusable(name: String)
}

/// The tap mutes the app on every device, so its copy has to go where the app
/// was heard: a USB headset on a call stays on the headset even when the system
/// output is the speakers. Pure, so the rule is tested without Core Audio.
enum OutputRouting {
    /// `devices`: one entry per device the app's processes use; `nil` for one
    /// that couldn't be read (another process's private aggregate, say), which is
    /// left out. One clear answer → that device; several → the default.
    static func route(_ devices: [ProcessOutputDevice?]) -> OutputRoute {
        var outcomes: [OutputRoute] = []
        for device in devices.compactMap({ $0 }) {
            let outcome: OutputRoute
            if let outputs = device.outputSubdevices {
                // An aggregate around one output (voice processing) is that output;
                // several outputs can't be followed by one tap.
                outcome = outputs.count == 1 ? .device(outputs[0]) : .unusable(name: device.name)
            } else {
                outcome = .device(device.id)
            }
            if !outcomes.contains(outcome) { outcomes.append(outcome) }
        }
        switch outcomes.count {
        case 0: return .undetermined
        case 1: return outcomes[0]
        default: return .ambiguous
        }
    }
}

/// What the mixer gets back for an app: the route, resolved to a device.
enum OutputChoice: Equatable {
    case undetermined
    case ambiguous
    case device(OutputDevice)
    case unusable(name: String)
}

extension ProcessOutputDevice {
    /// `nil` when Core Audio won't describe the device to this process.
    static func read(_ id: AudioDeviceID) -> ProcessOutputDevice? {
        guard let device = OutputDevice.read(id) else { return nil }
        let classID = (try? AudioObject.read(id, kAudioObjectPropertyClass, as: AudioClassID.self, initial: 0)) ?? 0
        guard classID == kAudioAggregateDeviceClassID || device.transport == kAudioDeviceTransportTypeAggregate else {
            return ProcessOutputDevice(id: id, name: device.name, outputSubdevices: nil)
        }
        let subdevices = (try? AudioObject.readArray(id, kAudioAggregateDevicePropertyActiveSubDeviceList,
                                                     of: AudioObjectID.self, initial: 0)) ?? []
        let outputs = subdevices.filter { AudioObject.streamCount($0, scope: kAudioObjectPropertyScopeOutput) > 0 }
        return ProcessOutputDevice(id: id, name: device.name, outputSubdevices: outputs)
    }
}
