// Captures this Mac's keyboard and mouse and routes them through the hub.
import ApplicationServices
import CoreGraphics

private let otherButtons: [Int64: UInt16] = [2: 274, 3: 275, 4: 276] // middle, back, forward
private let hotkey: Int64 = 0x28 // K, together with Control + Option
private var tapPort: CFMachPort?

/// Returns false (and shows the system permission prompt) if the app may not read input yet.
func startInputTap(_ hub: Hub) -> Bool {
    if tapPort != nil { return true }
    let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .scrollWheel,
                                .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                                .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
    tapPort = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: types.reduce(0) { $0 | (1 << $1.rawValue) },
                                callback: { _, type, event, info in
                                    handle(Unmanaged<Hub>.fromOpaque(info!).takeUnretainedValue(), type, event)
                                },
                                userInfo: Unmanaged.passUnretained(hub).toOpaque())
    guard let tapPort else {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        return false
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tapPort, 0), .commonModes)
    return true
}

private func handle(_ hub: Hub, _ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
    let pass = Unmanaged.passUnretained(event)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tapPort { CGEvent.tapEnable(tap: tapPort, enable: true) }
        return pass
    }
    if event.getIntegerValueField(.eventSourceUserData) == injectedMarker { return pass } // a client's input we replay
    if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == hotkey,
       event.flags.contains([.maskControl, .maskAlternate]) {
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { hub.cycle() }
        return nil
    }
    let local = hub.isLocal
    let mac = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

    switch type {
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
        guard hub.shareMouse else { return pass }
        let dx = Double(event.getIntegerValueField(.mouseEventDeltaX)), dy = Double(event.getIntegerValueField(.mouseEventDeltaY))
        if local {
            hub.localMove(event.location, dx, dy)
            return pass
        }
        hub.remoteMove(dx, dy)
    case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
        guard !local, hub.shareMouse else { return pass }
        let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
        switch type {
        case .leftMouseDown, .leftMouseUp: hub.forward(BTN_LEFT, down)
        case .rightMouseDown, .rightMouseUp: hub.forward(BTN_RIGHT, down)
        default: if let b = otherButtons[event.getIntegerValueField(.mouseEventButtonNumber)] { hub.forward(b, down) }
        }
    case .scrollWheel:
        guard !local, hub.shareMouse else { return pass }
        // macOS: axis 2 positive = left; evdev REL_HWHEEL positive = right
        let dy = event.getIntegerValueField(.scrollWheelEventDeltaAxis1), dx = -event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        if dx != 0 || dy != 0 { hub.scroll(dx, dy) }
    case .keyDown, .keyUp:
        guard !local, hub.shareKeyboard else { return pass }
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0, let code = evdevKey(mac) { hub.forward(code, type == .keyDown) }
    case .flagsChanged:
        guard !local, hub.shareKeyboard, let code = evdevKey(mac) else { return pass }
        if mac == 0x39 { hub.tap(code) } // macOS reports Caps Lock only as a toggle
        else if let bit = modifierBits[mac] { hub.forward(code, event.flags.rawValue & bit != 0) }
        return pass // the Mac keeps tracking modifiers, so none are stuck after switching back
    default:
        return pass
    }
    return nil
}
