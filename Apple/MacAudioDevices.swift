#if os(macOS)
import AVFAudio
import CoreAudio
import Foundation

enum DeviceSide: String, CaseIterable { case input, output }

struct MacAudioDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

struct DeviceInventory: Equatable {
    var devices: [DeviceSide: [MacAudioDevice]] = [:]
    var defaults: [DeviceSide: AudioDeviceID] = [:]
}

struct DeviceBindingFailure: Error {
    let side: DeviceSide
}

struct MacDeviceSelection {
    private let store: UserDefaults
    private(set) var preferred: [DeviceSide: String] = [:]
    private(set) var savedNames: [DeviceSide: String] = [:]
    var inventory: DeviceInventory?
    var actual: [DeviceSide: MacAudioDevice] = [:]

    init(store: UserDefaults = .standard) {
        self.store = store
        for side in DeviceSide.allCases {
            let entry = store.dictionary(forKey: Self.key(side))
            preferred[side] = entry?["uid"] as? String
            savedNames[side] = entry?["name"] as? String
        }
    }

    private static func key(_ side: DeviceSide) -> String { "audioDevice.\(side.rawValue)" }

    mutating func choose(_ side: DeviceSide, uid: String?) {
        let key = Self.key(side)
        if let uid {
            guard let device = inventory?.devices[side]?.first(where: { $0.uid == uid }) else { return }
            store.set(["uid": uid, "name": device.name], forKey: key)
            savedNames[side] = device.name
        } else {
            store.removeObject(forKey: key)
            savedNames[side] = nil
        }
        preferred[side] = uid
    }

    func bindings(microphone: Bool) -> [DeviceSide: AudioDeviceID] {
        var ids: [DeviceSide: AudioDeviceID] = [:]
        for side in DeviceSide.allCases where side == .output || microphone {
            ids[side] = inventory?.devices[side]?.first { $0.uid == preferred[side] }?.id
        }
        return ids
    }

    mutating func updateInventory(_ latest: DeviceInventory?, microphone: Bool, outputActive: Bool) -> Bool {
        let previous = inventory
        guard latest != previous else { return false }
        let oldBindings = bindings(microphone: microphone)
        inventory = latest
        let updated = bindings(microphone: microphone)
        if oldBindings != updated || !outputActive { return true }
        return DeviceSide.allCases.contains { side in
            (side == .output || microphone) && previous?.defaults[side] != latest?.defaults[side] &&
            (updated[side] == nil || actual[side]?.id != updated[side])
        }
    }

    // Some duplex units can change the other side as a side effect of binding.
    // Reject that explicit binding if it displaces a known system default.
    static func verify(_ side: DeviceSide, actual: AudioDeviceID, bindings: [DeviceSide: AudioDeviceID],
                       defaults: [DeviceSide: AudioDeviceID]) throws {
        if let wanted = bindings[side] {
            if actual != wanted { throw DeviceBindingFailure(side: side) }
        } else if let system = defaults[side], system != kAudioObjectUnknown, actual != system,
                  let other = bindings.keys.first {
            throw DeviceBindingFailure(side: other)
        }
    }

    /// Every attempt starts with a fresh engine on system defaults. A failed
    /// bind removes only that side. A graph start error retries both defaults.
    static func start(bindings: [DeviceSide: AudioDeviceID],
                      attempt: ([DeviceSide: AudioDeviceID]) throws -> Void) throws {
        var remaining = bindings
        while true {
            do { try attempt(remaining); return }
            catch let failure as DeviceBindingFailure where remaining[failure.side] != nil {
                remaining[failure.side] = nil
            } catch {
                guard !remaining.isEmpty else { throw error }
                remaining.removeAll()
            }
        }
    }
}

enum MacAudioHardware {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func device(_ id: AudioDeviceID) -> MacAudioDevice? {
        guard id != kAudioObjectUnknown, let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return MacAudioDevice(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid)
    }

    static func inventory() -> DeviceInventory? {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
        if !ids.isEmpty {
            let status = ids.withUnsafeMutableBytes { bytes in
                AudioObjectGetPropertyData(system, &property, 0, nil, &size, bytes.baseAddress!)
            }
            guard status == noErr else { return nil }
        }
        var result = DeviceInventory()
        for side in DeviceSide.allCases {
            var defaultProperty = address(side == .input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
            var current = AudioDeviceID(kAudioObjectUnknown)
            var bytes = UInt32(MemoryLayout.size(ofValue: current))
            if AudioObjectGetPropertyData(system, &defaultProperty, 0, nil, &bytes, &current) == noErr {
                result.defaults[side] = current
            }
            var streams = address(kAudioDevicePropertyStreams, side == .input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput)
            result.devices[side] = ids.compactMap { id in
                var length: UInt32 = 0
                guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &length) == noErr, length > 0 else { return nil }
                return device(id)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return result
    }

    static func bind(_ ids: [DeviceSide: AudioDeviceID], to engine: AVAudioEngine) throws {
        for side in DeviceSide.allCases {
            guard let id = ids[side] else { continue }
            let unit = side == .input ? engine.inputNode.auAudioUnit : engine.outputNode.auAudioUnit
            do { try unit.setDeviceID(id) }
            catch { throw DeviceBindingFailure(side: side) }
        }
    }

    static func readback(_ engine: AVAudioEngine, microphone: Bool,
                         expected: [DeviceSide: AudioDeviceID], defaults: [DeviceSide: AudioDeviceID]) throws -> [DeviceSide: MacAudioDevice] {
        var active: [DeviceSide: MacAudioDevice] = [:]
        for side in DeviceSide.allCases where side == .output || microphone {
            let id = side == .input ? engine.inputNode.auAudioUnit.deviceID : engine.outputNode.auAudioUnit.deviceID
            try MacDeviceSelection.verify(side, actual: id, bindings: expected, defaults: defaults)
            active[side] = device(id)
        }
        return active
    }
}

/// Observe the device list as well as default changes while connected. The
/// property callbacks carry no device snapshot; read it on the main actor.
final class MacDeviceMonitor {
    private let system = AudioObjectID(kAudioObjectSystemObject)
    private let callback: AudioObjectPropertyListenerBlock
    private var installed: [AudioObjectPropertyAddress] = []

    init(change: @escaping @MainActor () -> Void) {
        callback = { _, _ in Task { @MainActor in change() } }
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            var property = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListenerBlock(system, &property, .main, callback) == noErr { installed.append(property) }
        }
    }

    deinit {
        for var property in installed { AudioObjectRemovePropertyListenerBlock(system, &property, .main, callback) }
    }
}
#endif
