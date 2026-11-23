#if os(macOS)
import Carbon

/// Carbon delivers just this registered shortcut to the application's main event loop.
@MainActor
final class TalkHotKey {
    private static let signature: OSType = 0x4F545350 // OTSP
    private var sequence: UInt32 = 0
    private var key: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let changed: (Bool) -> Void

    init(changed: @escaping (Bool) -> Void) { self.changed = changed }

    func start() -> Bool {
        if key != nil { return true }
        let kinds = [kEventHotKeyPressed, kEventHotKeyReleased].map {
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32($0))
        }
        let target = GetApplicationEventTarget()
        let status = InstallEventHandler(target, { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                         EventParamType(typeEventHotKeyID), nil,
                                         MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard read == noErr else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated {
                let owner = Unmanaged<TalkHotKey>.fromOpaque(context).takeUnretainedValue()
                guard owner.key != nil, identifier.signature == TalkHotKey.signature,
                      identifier.id == owner.sequence else { return OSStatus(eventNotHandledErr) }
                owner.changed(GetEventKind(event) == UInt32(kEventHotKeyPressed))
                return noErr
            }
        }, kinds.count, kinds, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return false }
        sequence &+= 1
        let id = EventHotKeyID(signature: Self.signature, id: sequence)
        if RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey | shiftKey), id, target,
                               OptionBits(kEventHotKeyExclusive), &key) == noErr { return true }
        stop()
        return false
    }

    func stop() {
        if let key { UnregisterEventHotKey(key) }
        key = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    deinit {
        if let key { UnregisterEventHotKey(key) }
        if let handler { RemoveEventHandler(handler) }
    }
}
#endif
