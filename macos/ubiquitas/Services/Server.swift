import CryptoKit
import Foundation
import Network

/// An authenticated client. `name`, `w`, `h` are fixed; counters are only touched on the server queue.
final class Peer {
    let name: String, w: Int, h: Int
    let conn: NWConnection
    let tx: SymmetricKey, rx: SymmetricKey
    var txCounter: UInt64 = 0
    var rxCounter: UInt64 = 1 // frame 0 was the hello

    init(name: String, w: Int, h: Int, conn: NWConnection, tx: SymmetricKey, rx: SymmetricKey) {
        (self.name, self.w, self.h, self.conn, self.tx, self.rx) = (name, w, h, conn, tx, rx)
    }
}

/// Encrypted transport to all clients. Callbacks run on the main thread.
final class Server {
    var onHello: (Peer) -> Void = { _ in }
    var onDrop: (String) -> Void = { _ in }
    var onMessage: (String, Data) -> Void = { _, _ in }
    var onError: (String) -> Void = { _ in }

    private let psk: SymmetricKey
    private let ownName: String
    private let queue = DispatchQueue(label: "ubiquitas.net")
    private var peers: [String: Peer] = [:] // queue only

    init(psk: SymmetricKey, ownName: String) { (self.psk, self.ownName) = (psk, ownName) }

    func listen() {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        guard let listener = try? NWListener(using: NWParameters(tls: nil, tcp: tcp), on: NWEndpoint.Port(rawValue: Wire.port)!) else {
            return onError("cannot listen on port \(Wire.port)")
        }
        listener.newConnectionHandler = { [self] in accept($0) }
        listener.stateUpdateHandler = { [self] state in
            if case .failed(let e) = state { DispatchQueue.main.async { self.onError("listener failed: \(e)") } }
        }
        listener.start(queue: queue)
    }

    private func accept(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [self] state in
            switch state {
            case .failed: conn.cancel()
            case .cancelled: drop(conn)
            default: break
            }
        }
        conn.start(queue: queue)
        let saltS = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } // 32 random bytes
        conn.send(content: saltS, completion: .idempotent)
        receive(conn, 32) { [self] saltC in
            let salt = saltS + saltC
            let rx = Wire.sessionKey(psk, salt: salt, info: "ubiquitas v2 c2s")
            readFrame(conn) { [self] body in
                guard let msg = try? Wire.open(body, key: rx, counter: 0), msg.first == 4,
                      let hello = try? JSONDecoder().decode(Control.self, from: msg.dropFirst()),
                      hello.t == "hello", let name = hello.name, !name.isEmpty
                else {
                    print("rejected \(conn.endpoint): wrong key")
                    return conn.cancel()
                }
                guard name != ownName else {
                    DispatchQueue.main.async { self.onError("a client is also named \"\(name)\"; start it with UBIQUITAS_NAME=<other name>") }
                    return conn.cancel()
                }
                let peer = Peer(name: name, w: hello.w ?? 1920, h: hello.h ?? 1080, conn: conn,
                                tx: Wire.sessionKey(psk, salt: salt, info: "ubiquitas v2 s2c"), rx: rx)
                peers[name]?.conn.cancel() // same machine reconnected
                peers[name] = peer
                print("client connected: \(name) \(conn.endpoint)")
                DispatchQueue.main.async { self.onHello(peer) }
                readLoop(peer)
            }
        }
    }

    private func receive(_ conn: NWConnection, _ n: Int, _ done: @escaping (Data) -> Void) {
        conn.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, _, _ in
            guard let data, data.count == n else { return conn.cancel() }
            done(data)
        }
    }

    private func readFrame(_ conn: NWConnection, _ done: @escaping (Data) -> Void) {
        receive(conn, 4) { [self] head in
            let len = head.reduce(0) { $0 << 8 | Int($1) }
            guard len > 0, len <= Wire.maxFrame else { return conn.cancel() }
            receive(conn, len, done)
        }
    }

    private func readLoop(_ peer: Peer) {
        readFrame(peer.conn) { [self] body in
            guard let msg = try? Wire.open(body, key: peer.rx, counter: peer.rxCounter) else { return peer.conn.cancel() }
            peer.rxCounter += 1
            DispatchQueue.main.async { self.onMessage(peer.name, msg) }
            readLoop(peer)
        }
    }

    private func drop(_ conn: NWConnection) {
        guard let peer = peers.values.first(where: { $0.conn === conn }) else { return }
        peers[peer.name] = nil
        print("client disconnected: \(peer.name)")
        DispatchQueue.main.async { self.onDrop(peer.name) }
    }

    /// `done` gets false if the client is gone or the send failed.
    func send(to name: String, _ msg: Data, done: ((Bool) -> Void)? = nil) {
        queue.async { [self] in
            guard let peer = peers[name] else { done?(false); return }
            peer.conn.send(content: Wire.seal(msg, key: peer.tx, counter: peer.txCounter), completion: .contentProcessed { err in
                if err != nil { peer.conn.cancel() }
                done?(err == nil)
            })
            peer.txCounter += 1
        }
    }

    /// Blocks until the message is handed to the network. Never call on the main thread.
    func sendAndWait(to name: String, _ msg: Data) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        send(to: name, msg) { ok = $0; sem.signal() }
        sem.wait()
        return ok
    }

    func broadcast(_ msg: Data, except: String? = nil) {
        queue.async { [self] in
            for name in peers.keys where name != except { send(to: name, msg) }
        }
    }
}
