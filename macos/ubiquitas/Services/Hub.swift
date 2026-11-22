import AppKit
import CoreGraphics
import CryptoKit
import Foundation

let configDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/ubiquitas")

/// All server-side state. Main thread only.
final class Hub: ObservableObject {
    let me = Host.current().localizedName ?? "Mac"
    @Published private(set) var screens: [Screen] = []
    @Published private(set) var clip = ""
    @Published private(set) var active: String // screen that gets the input
    @Published private(set) var source: String // machine whose own keyboard and mouse drive `active`
    @Published var status = ""
    @Published private(set) var lastReceived: URL?
    @Published private(set) var hasInputAccess = false
    @Published var shareKeyboard: Bool { didSet { sharingChanged("shareKeyboard", shareKeyboard) } }
    @Published var shareMouse: Bool { didSet { sharingChanged("shareMouse", shareMouse) } }
    let clientCommand: String

    let server: Server
    private var g = CGPoint.zero // global cursor while a client is active
    private var held = Set<UInt16>() // keys and buttons held on the active client
    private var injected = Set<UInt16>() // keys and buttons a client holds on this Mac
    private var injectPos = CGPoint.zero // this Mac's cursor while a client drives it
    private var lastClick = (code: UInt16(0), time: 0.0, count: Int64(0))
    private var incoming: [UInt32: (file: FileHandle, url: URL, left: UInt64)] = [:]
    private var relays: [UInt32: (to: String, left: UInt64)] = [:]
    private let desktop = Hub.desktopBounds()
    private let layoutURL = configDir.appendingPathComponent("layout.json")

    init() {
        (active, source) = (me, me)
        shareKeyboard = UserDefaults.standard.object(forKey: "shareKeyboard") as? Bool ?? true
        shareMouse = UserDefaults.standard.object(forKey: "shareMouse") as? Bool ?? true
        let (key, hex) = Hub.loadOrCreateKey()
        clientCommand = "UBIQUITAS_KEY=\(hex) ubiquitas \(ProcessInfo.processInfo.hostName)"
        server = Server(psk: key, ownName: me)

        let saved = (try? JSONDecoder().decode([Screen].self, from: Data(contentsOf: layoutURL))) ?? []
        screens = saved.map { var s = $0; s.online = false; return s }
        upsert(me, w: Int(desktop.width), h: Int(desktop.height))

        server.onHello = { [self] peer in
            upsert(peer.name, w: peer.w, h: peer.h)
            server.send(to: peer.name, Msg.control(Control(t: "clip", text: clip)))
        }
        server.onDrop = { [self] name in
            if let i = screens.firstIndex(where: { $0.name == name }) { screens[i].online = false }
            if active == name || source == name { backToLocal() }
            layoutChanged()
        }
        server.onMessage = { [self] from, msg in receive(from, msg) }
        server.onError = { [self] in status = $0 }
        server.listen()

        checkInputAccess()
        // give the cursor back however we stop, even while it's frozen
        for sig in [SIGINT, SIGTERM] { signal(sig) { _ in CGAssociateMouseAndMouseCursorPosition(1); exit(0) } }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    /// Starts reading this Mac's keyboard and mouse once macOS allows it (Accessibility permission).
    func checkInputAccess() {
        hasInputAccess = startInputTap(self)
    }

    // MARK: arrangement

    private func upsert(_ name: String, w: Int, h: Int) {
        if let i = screens.firstIndex(where: { $0.name == name }) {
            (screens[i].w, screens[i].h, screens[i].online) = (w, h, true)
        } else {
            let right = screens.map { $0.x + $0.w }.max() ?? 0
            screens.append(Screen(name: name, x: right, y: 0, w: w, h: h, online: true))
        }
        layoutChanged()
    }

    /// Moves a screen to roughly (x, y) and snaps it flush against the nearest neighbour, so the cursor can cross.
    func move(_ name: String, x: Int, y: Int) {
        guard let i = screens.firstIndex(where: { $0.name == name }) else { return }
        var s = screens[i]
        (s.x, s.y) = snap(Screen(name: name, x: x, y: y, w: s.w, h: s.h, online: s.online), to: screens.filter { $0.name != name })
        screens[i] = s
        layoutChanged()
    }

    private func layoutChanged() {
        try? JSONEncoder().encode(screens).write(to: layoutURL)
        server.broadcast(Msg.control(Control(t: "layout", screens: screens)))
    }

    // MARK: shared text and files

    func editClip(_ text: String) {
        clip = text
        server.broadcast(Msg.control(Control(t: "clip", text: text)))
    }

    func sendFile(_ url: URL, to name: String) {
        status = "Sending \(url.lastPathComponent) to \(name)…"
        DispatchQueue.global().async { [server] in
            var ok = false
            if let fh = try? FileHandle(forReadingFrom: url), let size = try? fh.seekToEnd(), (try? fh.seek(toOffset: 0)) != nil {
                let id = UInt32.random(in: .min ... .max)
                ok = server.sendAndWait(to: name, Msg.control(Control(t: "file", name: url.lastPathComponent, id: id, size: size, to: name)))
                var sent: UInt64 = 0
                while ok, sent < size, let data = try? fh.read(upToCount: 65536), !data.isEmpty {
                    ok = server.sendAndWait(to: name, Msg.chunk(id, data))
                    sent += UInt64(data.count)
                }
                ok = ok && sent == size
            }
            DispatchQueue.main.async {
                self.status = ok ? "Sent \(url.lastPathComponent) to \(name)" : "Could not send \(url.lastPathComponent) to \(name)"
            }
        }
    }

    private func receive(_ from: String, _ msg: Data) {
        switch msg.first {
        case 4:
            guard let c = try? JSONDecoder().decode(Control.self, from: msg.dropFirst()) else { return }
            switch c.t {
            case "layout":
                for s in c.screens ?? [] {
                    if let old = screens.first(where: { $0.name == s.name }), (old.x, old.y) != (s.x, s.y) { move(s.name, x: s.x, y: s.y) }
                }
            case "clip":
                clip = c.text ?? ""
                server.broadcast(msg, except: from)
            case "file":
                guard let id = c.id, let size = c.size else { return }
                if let to = c.to, to != me {
                    server.send(to: to, msg) // relay to another client
                    if size > 0 { relays[id] = (to, size) }
                } else {
                    startIncoming(id: id, name: c.name ?? "file", size: size, from: from)
                }
            case "enter": clientEnter(from, c.x ?? 0, c.y ?? 0)
            case "release": if source == from { backToLocal() } // the client took its input back itself
            default: break
            }
        case 2 where msg.count >= 5, 3 where msg.count >= 4, 6 where msg.count >= 9:
            // input from a client whose keyboard and mouse are captured
            let b = [UInt8](msg)
            let u16 = { (i: Int) in UInt16(b[i]) << 8 | UInt16(b[i + 1]) }
            let f32 = { (i: Int) in Double(Float(bitPattern: UInt32(u16(i)) << 16 | UInt32(u16(i + 2)))) }
            switch b[0] {
            case 2: clientScroll(from, Int64(Int16(bitPattern: u16(1))), Int64(Int16(bitPattern: u16(3))))
            case 3: clientKey(from, u16(1), b[3] != 0)
            default: clientMotion(from, f32(1), f32(5))
            }
        case 5 where msg.count >= 5:
            let b = Array(msg.prefix(5))
            let id = UInt32(b[1]) << 24 | UInt32(b[2]) << 16 | UInt32(b[3]) << 8 | UInt32(b[4])
            let data = msg.dropFirst(5)
            if let r = relays[id] {
                server.send(to: r.to, msg)
                relays[id] = r.left > UInt64(data.count) ? (r.to, r.left - UInt64(data.count)) : nil
            } else if let inc = incoming[id] {
                let part = data.prefix(Int(min(UInt64(data.count), inc.left)))
                do { try inc.file.write(contentsOf: part) } catch {
                    incoming[id] = nil
                    return status = "Could not save \(inc.url.lastPathComponent): \(error.localizedDescription)"
                }
                let left = inc.left - UInt64(part.count)
                incoming[id] = left > 0 ? (inc.file, inc.url, left) : nil
                if left == 0 {
                    try? inc.file.close()
                    status = "Received \(inc.url.lastPathComponent) from \(from)"
                    lastReceived = inc.url
                }
            }
        default: break
        }
    }

    private func startIncoming(id: UInt32, name: String, size: UInt64, from: String) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        guard let (file, url) = createUnique(in: downloads, name: name) else { return status = "Could not save \(name) from \(from)" }
        if size == 0 {
            lastReceived = url
            return status = "Received \(url.lastPathComponent) from \(from)"
        }
        incoming[id] = (file, url, size)
        status = "Receiving \(url.lastPathComponent) from \(from)…"
    }

    // MARK: input routing
    //
    // `source` is the machine whose keyboard and mouse are in use (this Mac's event tap, or a client whose
    // input is captured at a screen edge); `active` is the screen that input goes to. `g` is the cursor in
    // the global arrangement while a client screen is active.

    var isLocal: Bool { active == me }

    private func rect(_ name: String) -> CGRect? { screens.first { $0.name == name }?.rect }
    private func screen(at p: CGPoint) -> Screen? { screens.first { $0.online && $0.rect.contains(p) } }
    private func global(_ loc: CGPoint) -> CGPoint? {
        rect(me).map { CGPoint(x: $0.minX + loc.x - desktop.minX, y: $0.minY + loc.y - desktop.minY) }
    }

    /// Cursor moved on this Mac: switch to the neighbour if it's pushed against an edge that touches one.
    func localMove(_ loc: CGPoint, _ dx: Double, _ dy: Double) {
        guard var p = global(loc), let m = rect(me) else { return }
        if loc.x <= desktop.minX, dx < 0 { p.x = m.minX - 1 }
        if loc.x >= desktop.maxX - 1, dx > 0 { p.x = m.maxX }
        if loc.y <= desktop.minY, dy < 0 { p.y = m.minY - 1 }
        if loc.y >= desktop.maxY - 1, dy > 0 { p.y = m.maxY }
        if let s = screen(at: p), s.name != me { activate(s.name, at: p) }
    }

    /// Cursor moved while a client is active: move the global cursor, crossing into neighbours.
    func remoteMove(_ dx: Double, _ dy: Double) {
        guard let r = rect(active) else { return }
        g.x += dx
        g.y += dy
        if !r.contains(g) {
            if let s = screen(at: g) {
                activate(s.name, at: g)
                if isLocal { return }
            } else {
                g = CGPoint(x: min(max(g.x, r.minX), r.maxX - 1), y: min(max(g.y, r.minY), r.maxY - 1))
            }
        }
        sendPointer()
    }

    /// Hotkey: next online screen, entering clients in the middle.
    func cycle() {
        let order = screens.filter(\.online).map(\.name)
        guard order.count > 1, let i = order.firstIndex(of: active) else { return }
        switchTo(order[(i + 1) % order.count])
    }

    /// Sends input to a screen, entering a client in its middle.
    func switchTo(_ name: String) {
        activate(name, at: name == me ? nil : rect(name).map { CGPoint(x: $0.midX, y: $0.midY) })
    }

    func activate(_ name: String, at p: CGPoint?) {
        guard name != active else { return }
        releaseHeld()
        active = name
        if let p { g = p }
        if name == source && source != me {
            // back on the client the input comes from: hand it back to that client's desktop
            let r = rect(name) ?? .zero
            server.send(to: name, Msg.control(Control(t: "release", x: Int(g.x - r.minX), y: Int(g.y - r.minY))))
            backToLocal()
        } else if isLocal {
            if let p, let m = rect(me) {
                injectPos = CGPoint(x: desktop.minX + p.x - m.minX, y: desktop.minY + p.y - m.minY)
                CGWarpMouseCursorPosition(injectPos)
            } else {
                injectPos = CGEvent(source: nil)?.location ?? .zero
            }
            CGAssociateMouseAndMouseCursorPosition(1)
        } else {
            // freeze this Mac's cursor while its mouse drives a client; deltas still arrive in events
            CGAssociateMouseAndMouseCursorPosition(source == me && shareMouse ? 0 : 1)
            if shareMouse || source != me { sendPointer() }
        }
    }

    /// This Mac's own keyboard and mouse control this Mac again.
    private func backToLocal() {
        releaseHeld()
        (source, active) = (me, me)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Lets go of every key and button still held on the active screen, so nothing stays stuck.
    private func releaseHeld() {
        if isLocal {
            let keys = injected
            keys.forEach { inject($0, down: false) }
        } else {
            held.forEach { server.send(to: active, Msg.key($0, false)) }
            held = []
        }
    }

    // MARK: input from a client (its screen-edge capture)

    /// A client's keyboard and mouse were captured at one of its edges; (x, y) is the cursor on its screen.
    private func clientEnter(_ from: String, _ x: Int, _ y: Int) {
        let refuse = { self.server.send(to: from, Msg.control(Control(t: "release", x: x, y: y))) }
        guard let r = rect(from), source == me ? isLocal : true else { return refuse() } // this Mac's mouse is busy elsewhere
        var p = CGPoint(x: r.minX + CGFloat(x), y: r.minY + CGFloat(y))
        if x <= 0 { p.x = r.minX - 1 } else if x >= Int(r.width) - 1 { p.x = r.maxX } // just across the edge
        if y <= 0 { p.y = r.minY - 1 } else if y >= Int(r.height) - 1 { p.y = r.maxY }
        guard let s = screen(at: p), s.name != from else { return refuse() }
        if source != me, source != from { // another client was in control: give its input back first
            server.send(to: source, Msg.control(Control(t: "release")))
            backToLocal()
        }
        releaseHeld()
        (source, active) = (from, from)
        activate(s.name, at: p)
    }

    private func clientMotion(_ from: String, _ dx: Double, _ dy: Double) {
        guard from == source else { return }
        guard isLocal else { return remoteMove(dx, dy) }
        var loc = CGPoint(x: injectPos.x + dx, y: injectPos.y + dy)
        if !desktop.contains(loc) {
            if let p = global(loc), let s = screen(at: p), s.name != me { return activate(s.name, at: p) }
            loc = CGPoint(x: min(max(loc.x, desktop.minX), desktop.maxX - 1), y: min(max(loc.y, desktop.minY), desktop.maxY - 1))
        }
        injectPos = loc
        let type: CGEventType = injected.contains(BTN_LEFT) ? .leftMouseDragged
            : injected.contains(BTN_RIGHT) ? .rightMouseDragged
            : injected.contains(where: { $0 > BTN_RIGHT && $0 <= BTN_EXTRA }) ? .otherMouseDragged : .mouseMoved
        post(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: loc, mouseButton: .left))
    }

    private func clientKey(_ from: String, _ code: UInt16, _ down: Bool) {
        guard from == source else { return }
        if isLocal { inject(code, down: down) } else { forward(code, down) }
    }

    private func clientScroll(_ from: String, _ dx: Int64, _ dy: Int64) {
        guard from == source else { return }
        if isLocal {
            // macOS: wheel 1 positive = up, wheel 2 positive = left
            post(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                         wheel1: Int32(clamping: dy), wheel2: Int32(clamping: -dx), wheel3: 0))
        } else {
            scroll(dx, dy)
        }
    }

    /// Replays a client's key or mouse button on this Mac.
    private func inject(_ code: UInt16, down: Bool) {
        if down { injected.insert(code) } else { injected.remove(code) }
        if (BTN_LEFT ... BTN_EXTRA).contains(code) {
            let n = Int64(code - BTN_LEFT) // 0 left, 1 right, 2 middle, 3 back, 4 forward (= macOS button numbers)
            let type: CGEventType = n == 0 ? (down ? .leftMouseDown : .leftMouseUp)
                : n == 1 ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .otherMouseDown : .otherMouseUp)
            if down { // macOS apps need the click count to see double clicks
                let now = ProcessInfo.processInfo.systemUptime
                let again = code == lastClick.code && now - lastClick.time < NSEvent.doubleClickInterval
                lastClick = (code, now, again ? lastClick.count + 1 : 1)
            }
            let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: injectPos,
                            mouseButton: CGMouseButton(rawValue: UInt32(min(n, 2)))!)
            e?.setIntegerValueField(.mouseEventButtonNumber, value: n)
            e?.setIntegerValueField(.mouseEventClickState, value: lastClick.count)
            return post(e)
        }
        guard let mac = macKey(code) else { return }
        let e = CGEvent(keyboardEventSource: nil, virtualKey: mac, keyDown: down)
        if modifierBits[mac] != nil { e?.type = .flagsChanged } // macOS sees modifiers as flag changes
        post(e)
    }

    private func post(_ e: CGEvent?) {
        guard let e else { return }
        var flags = CGEventFlags()
        for code in injected {
            if let m = macKey(code), let bit = modifierBits[m], let mask = modifierMasks[m] {
                flags.insert(CGEventFlags(rawValue: bit))
                flags.insert(mask)
            }
        }
        e.flags = flags
        e.setIntegerValueField(.eventSourceUserData, value: injectedMarker)
        e.post(tap: .cghidEventTap)
    }

    private func sendPointer() {
        guard let r = rect(active) else { return }
        let nx = (g.x - r.minX) / max(r.width - 1, 1), ny = (g.y - r.minY) / max(r.height - 1, 1)
        server.send(to: active, Msg.pointer(UInt16(clamping: Int(nx * 65535)), UInt16(clamping: Int(ny * 65535))))
    }

    func forward(_ code: UInt16, _ down: Bool) {
        if down { held.insert(code) } else { held.remove(code) }
        server.send(to: active, Msg.key(code, down))
    }

    func tap(_ code: UInt16) {
        server.send(to: active, Msg.key(code, true))
        server.send(to: active, Msg.key(code, false))
    }

    func scroll(_ dx: Int64, _ dy: Int64) { server.send(to: active, Msg.scroll(dx, dy)) }

    private func sharingChanged(_ key: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
        guard source == me else { return } // these settings are about this Mac's own keyboard and mouse
        if !shareKeyboard && !shareMouse { activate(me, at: nil) }
        else if !isLocal { CGAssociateMouseAndMouseCursorPosition(shareMouse ? 0 : 1) }
    }

    // MARK: setup helpers

    private static func desktopBounds() -> CGRect {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).map(CGDisplayBounds).reduce(CGRect.null) { $0.union($1) }
    }

    private static func loadOrCreateKey() -> (SymmetricKey, String) {
        let url = configDir.appendingPathComponent("key")
        if FileManager.default.fileExists(atPath: url.path) {
            guard let hex = try? String(contentsOf: url, encoding: .utf8), let bytes = hexBytes(hex), bytes.count == 32 else {
                die("\(url.path) is not a 64-character hex key; delete it to generate a new one")
            }
            return (SymmetricKey(data: bytes), hex.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let key = SymmetricKey(size: .bits256)
        let hex = key.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(hex.utf8), attributes: [.posixPermissions: 0o600]) else {
            die("cannot write \(url.path)")
        }
        return (key, hex)
    }
}

func hexBytes(_ s: String) -> [UInt8]? {
    let c = Array(s.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    guard c.count % 2 == 0 else { return nil }
    let bytes = stride(from: 0, to: c.count, by: 2).compactMap { UInt8(String(decoding: c[$0 ..< $0 + 2], as: UTF8.self), radix: 16) }
    return bytes.count * 2 == c.count ? bytes : nil
}

/// Position that puts `r` flush against the side of a neighbour closest to where it was dropped,
/// overlapping it by at least one pixel along that side.
func snap(_ r: Screen, to others: [Screen]) -> (Int, Int) {
    var best = (r.x, r.y), bestD = Int.max
    for o in others {
        let cx = min(max(r.x, o.x - r.w + 1), o.x + o.w - 1)
        let cy = min(max(r.y, o.y - r.h + 1), o.y + o.h - 1)
        for c in [(o.x - r.w, cy), (o.x + o.w, cy), (cx, o.y - r.h), (cx, o.y + o.h)] {
            let d = abs(c.0 - r.x) + abs(c.1 - r.y)
            if d < bestD { (best, bestD) = (c, d) }
        }
    }
    return best
}
