#if os(macOS)
import Foundation

@main
enum MacAudioDevicesCheck {
    static func main() throws {
        if CommandLine.arguments.count == 3 {
            let store = UserDefaults(suiteName: CommandLine.arguments[2])!
            var routes = MacDeviceSelection(store: store)
            switch CommandLine.arguments[1] {
            case "save":
                let mic = MacAudioDevice(id: 11, uid: "usb-mic", name: "USB mic")
                routes.inventory = DeviceInventory(devices: [.input: [mic]])
                routes.choose(.input, uid: mic.uid)
                precondition(store.synchronize())
            case "restore":
                precondition(routes.preferred == [.input: "usb-mic"] && routes.actual.isEmpty)
                store.removePersistentDomain(forName: CommandLine.arguments[2])
            default: preconditionFailure("Unexpected test mode")
            }
            return
        }
        let suite = "org.opents-project.tests.devices.\(UUID())"
        for mode in ["save", "restore"] {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = [mode, suite + ".restart"]
            try child.run()
            child.waitUntilExit()
            precondition(child.terminationStatus == 0, "Cross-process preference test: \(mode)")
        }
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        let mic = MacAudioDevice(id: 11, uid: "usb-mic", name: "USB mic")
        let phones = MacAudioDevice(id: 12, uid: "headphones", name: "Headphones")
        let speaker = MacAudioDevice(id: 13, uid: "speaker", name: "Speaker")
        let initial = DeviceInventory(devices: [.input: [mic], .output: [speaker, phones]],
                                      defaults: [.input: mic.id, .output: speaker.id])
        var routes = MacDeviceSelection(store: store)
        routes.inventory = initial
        precondition(routes.bindings(microphone: true).isEmpty)
        routes.choose(.input, uid: phones.uid)
        precondition(routes.preferred.isEmpty)
        routes.choose(.input, uid: mic.uid)
        routes.choose(.output, uid: phones.uid)
        let selected = [DeviceSide.input: mic.id, .output: phones.id]
        precondition(routes.bindings(microphone: true) == selected)
        precondition(routes.bindings(microphone: false) == [.output: phones.id])
        routes = MacDeviceSelection(store: UserDefaults(suiteName: suite)!)
        routes.inventory = initial
        precondition(routes.bindings(microphone: true) == selected && routes.actual.isEmpty)

        var unplugged = initial
        unplugged.devices[.output] = [speaker]
        precondition(routes.updateInventory(unplugged, microphone: true, outputActive: true))
        precondition(routes.bindings(microphone: true) == [.input: mic.id])
        routes.actual = [.input: mic, .output: speaker]
        precondition(routes.preferred[.output] == phones.uid && routes.savedNames[.output] == phones.name)
        precondition(routes.actual[.output] == speaker)
        // Core Audio object IDs can change between attachments.
        let reattached = MacAudioDevice(id: 121, uid: phones.uid, name: "USB Headphones")
        var plugged = initial
        plugged.devices[.output] = [speaker, reattached]
        precondition(routes.updateInventory(plugged, microphone: true, outputActive: true))
        precondition(routes.bindings(microphone: true)[.output] == reattached.id)
        routes.actual[.output] = reattached
        var newDefault = plugged
        newDefault.defaults[.output] = reattached.id
        precondition(!routes.updateInventory(newDefault, microphone: true, outputActive: true))
        precondition(routes.updateInventory(nil, microphone: true, outputActive: true))
        precondition(routes.bindings(microphone: true).isEmpty && routes.preferred[.output] == phones.uid)
        precondition(routes.updateInventory(initial, microphone: false, outputActive: true))

        enum StartError: Error { case unavailable }
        var attempts: [[DeviceSide: UInt32]] = []
        try MacDeviceSelection.start(bindings: selected) { binding in
            attempts.append(binding)
            if binding[.output] != nil { throw DeviceBindingFailure(side: .output) }
        }
        precondition(attempts == [selected, [.input: mic.id]])
        attempts = []
        try MacDeviceSelection.start(bindings: [.input: mic.id]) { binding in
            attempts.append(binding)
            // Simulate a shared audio unit that redirected the output as well.
            let observedOutput = binding.isEmpty ? speaker.id : phones.id
            try MacDeviceSelection.verify(.output, actual: observedOutput, bindings: binding, defaults: initial.defaults)
        }
        precondition(attempts == [[.input: mic.id], [:]])
        attempts = []
        try MacDeviceSelection.start(bindings: selected) { binding in
            attempts.append(binding)
            try MacDeviceSelection.verify(.output, actual: speaker.id, bindings: binding, defaults: initial.defaults)
        }
        precondition(attempts == [selected, [.input: mic.id]])
        attempts = []
        do {
            try MacDeviceSelection.start(bindings: selected) { binding in
                attempts.append(binding)
                throw StartError.unavailable
            }
            preconditionFailure("Expected graph failure on the default route")
        } catch StartError.unavailable {}
        precondition(attempts == [selected, [:]])
        precondition(routes.preferred[.output] == phones.uid)
        routes.choose(.output, uid: nil)
        precondition(routes.bindings(microphone: true) == [.input: mic.id])
        precondition(routes.updateInventory(newDefault, microphone: false, outputActive: true))
        precondition(!routes.updateInventory(newDefault, microphone: false, outputActive: true))
        let restored = MacDeviceSelection(store: store)
        precondition(restored.preferred == [.input: mic.uid])
        print("Passed device selection, defaults, UID restoration, unplug, discovery and start failures")
    }
}
#endif
