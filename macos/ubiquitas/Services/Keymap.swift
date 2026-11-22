import Carbon

/// macOS virtual keycode (kVK_*) → Linux evdev KEY_* code. Physical positions; the client applies its own layout.
private let macToEvdev: [UInt16: UInt16] = [
    0x00: 30, 0x01: 31, 0x02: 32, 0x03: 33, 0x04: 35, 0x05: 34, 0x06: 44, 0x07: 45, // A S D F H G Z X
    0x08: 46, 0x09: 47, 0x0A: 86, 0x0B: 48, 0x0C: 16, 0x0D: 17, 0x0E: 18, 0x0F: 19, // C V §/<> B Q W E R
    0x10: 21, 0x11: 20, 0x12: 2, 0x13: 3, 0x14: 4, 0x15: 5, 0x16: 7, 0x17: 6, // Y T 1 2 3 4 6 5
    0x18: 13, 0x19: 10, 0x1A: 8, 0x1B: 12, 0x1C: 9, 0x1D: 11, 0x1E: 27, 0x1F: 24, // = 9 7 - 8 0 ] O
    0x20: 22, 0x21: 26, 0x22: 23, 0x23: 25, 0x24: 28, 0x25: 38, 0x26: 36, 0x27: 40, // U [ I P Return L J '
    0x28: 37, 0x29: 39, 0x2A: 43, 0x2B: 51, 0x2C: 53, 0x2D: 49, 0x2E: 50, 0x2F: 52, // K ; \ , / N M .
    0x30: 15, 0x31: 57, 0x32: 41, 0x33: 14, 0x35: 1, // Tab Space ` Backspace Esc
    0x36: 126, 0x37: 125, 0x38: 42, 0x39: 58, 0x3A: 56, 0x3B: 29, 0x3C: 54, 0x3D: 100, 0x3E: 97, // RCmd Cmd Shift Caps Opt Ctrl RShift ROpt RCtrl
    0x40: 187, 0x41: 83, 0x43: 55, 0x45: 78, 0x47: 69, 0x48: 115, 0x49: 114, 0x4A: 113, // F17 KP. KP* KP+ Clear VolUp VolDown Mute
    0x4B: 98, 0x4C: 96, 0x4E: 74, 0x4F: 188, 0x50: 189, 0x51: 117, // KP/ KPEnter KP- F18 F19 KP=
    0x52: 82, 0x53: 79, 0x54: 80, 0x55: 81, 0x56: 75, 0x57: 76, 0x58: 77, 0x59: 71, 0x5B: 72, 0x5C: 73, // KP0-9
    0x5A: 190, 0x5D: 124, 0x5E: 89, 0x5F: 95, // F20 JIS-Yen JIS-Ro JIS-KP,
    0x60: 63, 0x61: 64, 0x62: 65, 0x63: 61, 0x64: 66, 0x65: 67, 0x67: 87, 0x69: 183, // F5 F6 F7 F3 F8 F9 F11 F13
    0x6A: 186, 0x6B: 184, 0x6D: 68, 0x6F: 88, 0x71: 185, 0x72: 110, 0x73: 102, 0x74: 104, // F16 F14 F10 F12 F15 Help/Insert Home PgUp
    0x75: 111, 0x76: 62, 0x77: 107, 0x78: 60, 0x79: 109, 0x7A: 59, // FwdDelete F4 End F2 PgDown F1
    0x7B: 105, 0x7C: 106, 0x7D: 108, 0x7E: 103, // ← → ↓ ↑
]

/// Device-specific modifier bits (NX_DEVICE*KEYMASK) per modifier keycode, so left and right keys are tracked separately.
let modifierBits: [UInt16: UInt64] = [
    0x3B: 0x1, 0x38: 0x2, 0x3C: 0x4, 0x37: 0x8, 0x36: 0x10, 0x3A: 0x20, 0x3D: 0x40, 0x3E: 0x2000,
]

/// Generic modifier flag per modifier keycode, set on injected events.
let modifierMasks: [UInt16: CGEventFlags] = [
    0x3B: .maskControl, 0x3E: .maskControl, 0x38: .maskShift, 0x3C: .maskShift,
    0x3A: .maskAlternate, 0x3D: .maskAlternate, 0x37: .maskCommand, 0x36: .maskCommand,
]

let BTN_LEFT: UInt16 = 272, BTN_RIGHT: UInt16 = 273, BTN_EXTRA: UInt16 = 276
/// Marks events we post ourselves, so the event tap lets them through untouched.
let injectedMarker: Int64 = 0x7562_6971 // "ubiq"

private let isISO = KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO
private let evdevToMac = Dictionary(macToEvdev.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })

func evdevKey(_ mac: UInt16) -> UInt16? {
    // macOS swaps these two codes on ISO keyboards (key left of 1 vs. key next to left Shift)
    if isISO && mac == 0x0A { return 41 }
    if isISO && mac == 0x32 { return 86 }
    return macToEvdev[mac]
}

func macKey(_ evdev: UInt16) -> UInt16? {
    if isISO && evdev == 41 { return 0x0A }
    if isISO && evdev == 86 { return 0x32 }
    return evdevToMac[evdev]
}
