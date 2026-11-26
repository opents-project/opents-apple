#if os(macOS)
import Carbon
import CoreGraphics
import Foundation

/// Carbon delivers just this registered shortcut to the application's main event loop.
@MainActor
final class TalkHotKey {
    private static let signature: OSType = 0x4F545350 // OTSP
    private static var sequence: UInt32 = 0
    private var registrationID: UInt32 = 0
    private var key: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var spaceReleaseCheck: Timer?
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
                      identifier.id == owner.registrationID else { return OSStatus(eventNotHandledErr) }
                if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                    owner.changed(false)
                } else if owner.spaceReleaseCheck == nil {
                    owner.changed(true)
                }
                return noErr
            }
        }, kinds.count, kinds, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return false }
        Self.sequence &+= 1
        registrationID = Self.sequence
        let id = EventHotKeyID(signature: Self.signature, id: registrationID)
        if RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey | shiftKey), id, target,
                               OptionBits(kEventHotKeyExclusive), &key) == noErr {
            waitForHeldSpaceRelease()
            return true
        }
        stop()
        return false
    }

    func stop() {
        spaceReleaseCheck?.invalidate()
        spaceReleaseCheck = nil
        if let key { UnregisterEventHotKey(key) }
        key = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    deinit {
        spaceReleaseCheck?.invalidate()
        if let key { UnregisterEventHotKey(key) }
        if let handler { RemoveEventHandler(handler) }
    }

    private func waitForHeldSpaceRelease() {
        guard Self.spaceIsDown else { return }
        let check = Timer(timeInterval: 0.02, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard !Self.spaceIsDown else { return }
                timer.invalidate()
                self?.spaceReleaseCheck = nil
            }
        }
        spaceReleaseCheck = check
        RunLoop.main.add(check, forMode: .common)
    }

    private static var spaceIsDown: Bool {
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Space))
    }
}
#endif
