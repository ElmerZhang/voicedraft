import AppKit
import CoreAudio

import Carbon
import VoiceDraftCore

@MainActor
final class GlobalShortcuts {
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var bindings: [ShortcutBinding] = []
    private var pressed: Set<ShortcutAction> = []
    var onEvent: ((ShortcutAction, Bool) -> Void)?
    private func dispatch(_ action: ShortcutAction, down: Bool) {
        if down { guard pressed.insert(action).inserted else { return } }
        else { guard pressed.remove(action) != nil else { return } }
        onEvent?(action, down)
    }
    func uninstall() {
        pressed.removeAll()
        refs.forEach { UnregisterEventHotKey($0) }; refs.removeAll()
        if let handler { RemoveEventHandler(handler) }; handler = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }; tap = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }; source = nil
    }
    func install(_ bindings: [ShortcutBinding]) throws {
        try ShortcutBinding.validate(bindings)
        uninstall(); self.bindings = bindings
        do {
            var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                         EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            let context = Unmanaged.passUnretained(self).toOpaque()
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                let owner = Unmanaged<GlobalShortcuts>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated {
                    if Int(id.id) < owner.bindings.count { owner.dispatch(owner.bindings[Int(id.id)].action, down: GetEventKind(event) == UInt32(kEventHotKeyPressed)) }
                }
                return noErr
            }, 2, &specs, context, &handler)
            guard status == noErr else { throw FeatureError("Could not install keyboard shortcuts.") }
            for (index, binding) in bindings.enumerated() where binding.enabled && binding.keyCode != 63 {
                let masks = [shiftKey, controlKey, optionKey, cmdKey]
                var flags: UInt32 = 0
                for i in 0..<4 where binding.modifiers & (1 << i) != 0 { flags |= UInt32(masks[i]) }
                var ref: EventHotKeyRef?
                guard RegisterEventHotKey(binding.keyCode, flags, EventHotKeyID(signature: 0x56445246, id: UInt32(index)), GetApplicationEventTarget(), 0, &ref) == noErr, let ref else {
                    throw FeatureError("A shortcut is already in use by another app.")
                }
                refs.append(ref)
            }
            if bindings.contains(where: { $0.enabled && $0.keyCode == 63 }) {
                tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                    eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue), callback: { _, type, event, context in
                        guard let context else { return Unmanaged.passUnretained(event) }
                        let owner = Unmanaged<GlobalShortcuts>.fromOpaque(context).takeUnretainedValue()
                        return MainActor.assumeIsolated {
                            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                                if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                                return Unmanaged.passUnretained(event)
                            }
                            guard event.getIntegerValueField(.keyboardEventKeycode) == 63,
                                  let binding = owner.bindings.first(where: { $0.enabled && $0.keyCode == 63 }) else { return Unmanaged.passUnretained(event) }
                            owner.dispatch(binding.action, down: event.flags.contains(.maskSecondaryFn))
                            return nil
                        }
                    }, userInfo: context)
                guard let tap else { throw FeatureError("Enable Accessibility before using Fn alone.") }
                source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes); CGEvent.tapEnable(tap: tap, enable: true)
            }
        } catch { uninstall(); throw error }
    }
}

extension ShortcutBinding {
    var label: String {
        if !enabled { return F("Disabled", "未启用") }
        if keyCode == 63 { return "Fn" }
        let names: [UInt32: String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"−",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",36:"↩",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",48:"⇥",49:"Space",50:"`",51:"⌫",53:"⎋",123:"←",124:"→",125:"↓",126:"↑"]
        let flags = [(UInt32(2),"⌃"),(4,"⌥"),(1,"⇧"),(8,"⌘")].filter { modifiers & $0.0 != 0 }.map(\.1).joined()
        return flags + (names[keyCode] ?? "Key \(keyCode)")
    }
}

@MainActor
final class RecordingEffects {
    private var output: AudioDeviceID?
    private var oldMute: UInt32 = 0
    private var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private var active = false
    func begin(options: DesktopOptions) async throws {
        active = true
        if options.sounds { NSSound(named: "Tink")?.play(); try await Task.sleep(nanoseconds: 180_000_000) }
        try Task.checkCancellation()
        guard options.muteOutput else { return }
        var id: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { throw FeatureError("Could not find the system output device.") }
        size = 4
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(id, &muteAddress, &settable) == noErr, settable.boolValue,
              AudioObjectGetPropertyData(id, &muteAddress, 0, nil, &size, &oldMute) == noErr else { throw FeatureError("This output device cannot be muted. Turn off recording mute or choose another output.") }
        var value: UInt32 = 1
        guard AudioObjectSetPropertyData(id, &muteAddress, 0, nil, 4, &value) == noErr else { throw FeatureError("Could not mute system output.") }
        output = id
    }
    func end(sound: Bool) {
        if let output { AudioObjectSetPropertyData(output, &muteAddress, 0, nil, 4, &oldMute) }; output = nil
        if active && sound { NSSound(named: "Pop")?.play() }
        active = false
    }
}
