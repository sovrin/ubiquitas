// Wire format shared with the Rust client. Spec: README.md at the repository root.
import CoreGraphics
import CryptoKit
import Foundation

enum Wire {
    static let port: UInt16 = 24242
    static let maxFrame = 1 << 20

    static func sessionKey(_ psk: SymmetricKey, salt: Data, info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: psk, salt: salt, info: Data(info.utf8), outputByteCount: 32)
    }

    static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        try! ChaChaPoly.Nonce(data: Data(count: 4) + be(counter))
    }

    /// One frame: u32 length, then ciphertext || tag.
    static func seal(_ msg: Data, key: SymmetricKey, counter: UInt64) -> Data {
        let box = try! ChaChaPoly.seal(msg, using: key, nonce: nonce(counter))
        let body = box.ciphertext + box.tag
        return be(UInt32(body.count)) + body
    }

    static func open(_ body: Data, key: SymmetricKey, counter: UInt64) throws -> Data {
        let n = nonce(counter).withUnsafeBytes { Data($0) }
        return try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: n + body), using: key)
    }
}

/// One machine in the shared arrangement. Coordinates are in a global space, y pointing down.
struct Screen: Codable, Equatable, Identifiable {
    var name: String
    var x, y, w, h: Int
    var online: Bool
    var id: String { name }
    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

/// JSON control message; `t` says which fields are used.
/// hello{name,w,h} · layout{screens} · clip{text} · file{id,name,size,to} · enter{x,y} · release{x,y}
struct Control: Codable {
    var t: String
    var name: String? = nil
    var w: Int? = nil
    var h: Int? = nil
    var screens: [Screen]? = nil
    var text: String? = nil
    var id: UInt32? = nil
    var size: UInt64? = nil
    var to: String? = nil
    var x: Int? = nil
    var y: Int? = nil
}

/// Message payloads, first byte is the type. Key and button codes are Linux evdev codes.
enum Msg {
    static func pointer(_ x: UInt16, _ y: UInt16) -> Data { Data([1]) + be(x) + be(y) }
    static func scroll(_ dx: Int64, _ dy: Int64) -> Data { Data([2]) + i16(dx) + i16(dy) }
    static func key(_ code: UInt16, _ down: Bool) -> Data { Data([3]) + be(code) + Data([down ? 1 : 0]) }
    static func control(_ c: Control) -> Data { Data([4]) + (try! JSONEncoder().encode(c)) }
    static func chunk(_ id: UInt32, _ bytes: Data) -> Data { Data([5]) + be(id) + bytes }
    private static func i16(_ v: Int64) -> Data { be(UInt16(bitPattern: Int16(clamping: v))) }
}

func be<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("ubiquitas: \(msg)\n".utf8))
    exit(1)
}

/// Creates a new file for an incoming transfer without ever overwriting or leaving `dir`.
func createUnique(in dir: URL, name: String) -> (FileHandle, URL)? {
    let base = (name as NSString).lastPathComponent
    let safe = base.isEmpty || base == "." || base == ".." || base.contains("/") || base.contains("\0") ? "file" : base
    let stem = (safe as NSString).deletingPathExtension, ext = (safe as NSString).pathExtension
    for i in 0 ..< 1000 {
        let url = dir.appendingPathComponent(i == 0 ? safe : "\(stem) (\(i))" + (ext.isEmpty ? "" : ".\(ext)"))
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        if fd >= 0 { return (FileHandle(fileDescriptor: fd, closeOnDealloc: true), url) }
        if errno != EEXIST { return nil }
    }
    return nil
}
