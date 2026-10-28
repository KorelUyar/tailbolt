import Foundation
#if canImport(Darwin)
import Darwin
#endif

public protocol TailboltServerDelegate: AnyObject {
    /// A peer wants to send something. Call `accept(into:)` or `decline(_:)` on the transfer (any thread).
    func server(_ server: TailboltServer, didReceiveOffer transfer: IncomingTransfer)
    /// A peer said hello (probe or offer) — handy for instant discovery.
    func server(_ server: TailboltServer, didSeeHello info: HelloInfo, from ip: String)
}

public final class TailboltServer {
    public let port: UInt16
    public weak var delegate: TailboltServerDelegate?
    public var myName: () -> String
    /// Hand out session keys so senders on the same LAN can bypass the tunnel (encrypted end-to-end anyway).
    public var lanFastPathEnabled = true
    /// Advertise "lz4" so senders may compress chunks; off = senders stream raw bytes to us.
    public var compressionEnabled = true

    private var listener: Listener?
    private let lock = NSLock()
    private var transfers: [String: IncomingTransfer] = [:]

    public init(port: UInt16 = Tailbolt.defaultPort, myName: @escaping () -> String) {
        self.port = port
        self.myName = myName
    }

    public func start() throws {
        let l = try Listener(port: port)
        listener = l
        Thread.detachNewThread { [weak self] in
            while let s = try? l.accept() {
                Thread.detachNewThread { self?.handle(s) }
            }
        }
    }

    public func stop() {
        listener?.close()
        listener = nil
    }

    private func handle(_ s: Socket) {
        let fromTailnet = TailnetAddress.isAllowed(s.remoteAddress)
        s.setReceiveTimeout(30)
        guard let first = try? s.receive() else { Debug.log("rx \(s.remoteAddress): no first frame"); s.close(); return }
        switch first.t {
        case "hello" where fromTailnet:
            var reply = makeHello(name: myName())
            reply.caps = Tailbolt.capabilities.filter { ($0 != "lan" || lanFastPathEnabled) && ($0 != "lz4" || compressionEnabled) }
            guard (try? s.send(reply)) != nil else { s.close(); return }
            delegate?.server(self, didSeeHello: HelloInfo(name: first.name ?? s.remoteAddress, os: first.os ?? "",
                                                          app: first.app ?? "", caps: first.caps ?? []),
                             from: s.remoteAddress)
            guard let next = try? s.receive(), next.t == "offer" else { s.close(); return }
            handleOffer(next, hello: first, control: s)
        case "data":
            lock.lock(); let t = first.id.flatMap { transfers[$0] }; lock.unlock()
            guard let t else { Debug.log("rx data \(s.remoteAddress): unknown transfer \(first.id ?? "-")"); s.close(); return }
            if let ci = first.ci {
                // LAN fast path: any source address may knock, but nothing is allocated and the index is only
                // kept once the sealed hello authenticates (3 s budget), and at most a few may be pending.
                guard lanFastPathEnabled, let key = t.sessionKey, t.beginConnection(ci) else {
                    Debug.log("rx lan \(s.remoteAddress) ci \(ci): rejected (lan \(lanFastPathEnabled), key \(t.sessionKey != nil))"); s.close(); return
                }
                let secure = SecureStream(socket: s, key: key, transferID: t.id, connection: ci, role: .receiver)
                secure.setReceiveTimeout(3)
                guard let hello = try? secure.receive(), hello.t == "lan-hello" else {
                    Debug.log("rx lan \(s.remoteAddress) ci \(ci): handshake failed"); t.endConnection(ci, authenticated: false); s.close(); return
                }
                var ok = Msg(t: "lan-ok")
                ok.nonce = hello.nonce
                guard (try? secure.send(ok)) != nil else { t.endConnection(ci, authenticated: false); s.close(); return }
                t.endConnection(ci, authenticated: true)
                s.tuneLiveness(dead: 8)
                t.handleData(secure, lan: true)
            } else {
                guard fromTailnet, t.remoteAddress == s.remoteAddress else {
                    Debug.log("rx data \(s.remoteAddress): address mismatch (control \(t.remoteAddress), tailnet \(fromTailnet))"); s.close(); return
                }
                t.handleData(s, lan: false)
            }
        default:
            s.close()
        }
    }

    private func handleOffer(_ offer: Msg, hello: Msg, control: Socket) {
        guard let id = offer.id, let items = offer.items, IncomingTransfer.validate(items) == nil else {
            var err = Msg(t: "decline")
            err.reason = "Ungültiges Angebot"
            try? control.send(err)
            control.close()
            return
        }
        let bench = offer.bench == true
        if bench {
            // A throughput test never touches disk and never asks; keep it small enough to be harmless.
            guard items.count == 1, !items[0].d, items[0].l == nil, items[0].s <= 512 << 20 else {
                var err = Msg(t: "decline"); err.reason = "Ungültiger Test"
                try? control.send(err); control.close(); return
            }
        }
        let t = IncomingTransfer(id: id, items: items, chunkSize: offer.chunk ?? Tailbolt.maxChunkSize,
                                 senderName: hello.name ?? control.remoteAddress, remoteAddress: control.remoteAddress,
                                 control: control, lanFastPath: lanFastPathEnabled && (hello.caps ?? []).contains("lan"),
                                 bench: bench)
        lock.lock(); transfers[id] = t; lock.unlock()
        defer { lock.lock(); transfers.removeValue(forKey: id); lock.unlock() }
        if bench {
            t.accept(into: URL(fileURLWithPath: "/dev/null"))
        } else {
            delegate?.server(self, didReceiveOffer: t)
        }
        t.runControl()
    }
}

public final class IncomingTransfer: TransferBase {
    public let senderName: String
    public let remoteAddress: String
    public let receivedAt = Date()
    public let isBench: Bool
    public private(set) var savedURLs: [URL] = []

    private let control: Socket
    private let chunkSize: Int64
    private let lanFastPath: Bool
    private let decision = DispatchSemaphore(value: 0)
    private let completion = DispatchSemaphore(value: 0)
    private var destination: URL?
    private var declineReason: String?
    private var staging: URL?
    private var completedChunks = Set<ChunkKey>()
    private var completedBytes: Int64 = 0
    private var usedConnections = Set<Int>()
    private let fileBytes: Int64
    private(set) var sessionKey: SessionKey?

    init(id: String, items: [WireItem], chunkSize: Int64, senderName: String, remoteAddress: String, control: Socket,
         lanFastPath: Bool, bench: Bool = false) {
        self.senderName = senderName
        self.remoteAddress = remoteAddress
        self.control = control
        self.chunkSize = max(1 << 20, min(chunkSize, 256 << 20))
        self.lanFastPath = lanFastPath
        self.isBench = bench
        self.fileBytes = items.reduce(0) { $0 + (($1.d || $1.l != nil) ? 0 : $1.s) }
        super.init(id: id, items: items)
        track(control)
    }

    public func accept(into directory: URL) {
        lock.lock(); destination = directory; lock.unlock()
        decision.signal()
    }

    public func decline(_ reason: String? = nil) {
        lock.lock(); declineReason = reason ?? "Abgelehnt"; lock.unlock()
        decision.signal()
    }

    public func cancel() {
        setState(.cancelled(nil))
        decision.signal()
        completion.signal()
    }

    /// Each LAN connection index may be used once (its key is derived from it). An index is held
    /// tentatively while the handshake runs and released again if it fails, so a stranger on the LAN can't
    /// burn the real sender's indices; a handful of unauthenticated knocks may be pending at a time.
    private var pendingConnections = 0

    func beginConnection(_ ci: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard ci >= 0, ci < 10_000, pendingConnections < 8, usedConnections.insert(ci).inserted else { return false }
        pendingConnections += 1
        return true
    }

    func endConnection(_ ci: Int, authenticated: Bool) {
        lock.lock()
        pendingConnections -= 1
        if !authenticated { usedConnections.remove(ci) }
        lock.unlock()
    }

    /// Rejects absolute paths, traversal and anything nested below a symlink entry.
    static func validate(_ items: [WireItem]) -> String? {
        var links = Set<String>()
        for item in items {
            let parts = item.p.split(separator: "/", omittingEmptySubsequences: false)
            if item.p.isEmpty || item.p.hasPrefix("/") || item.p.contains("\0") || item.s < 0 { return item.p }
            if parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) { return item.p }
            if item.l != nil {
                if item.s != 0 || item.d { return item.p }
                links.insert(item.p)
            }
        }
        for item in items {
            var prefix = ""
            for part in item.p.split(separator: "/").dropLast() {
                prefix += prefix.isEmpty ? String(part) : "/" + part
                if links.contains(prefix) { return item.p }
            }
        }
        return nil
    }

    // MARK: control connection

    func runControl() {
        let started = Date()
        while decision.wait(timeout: .now() + 0.5) == .timedOut {
            if control.peerHasClosed() {
                setState(.cancelled("Absender hat abgebrochen")); return
            }
            if Date().timeIntervalSince(started) > 300 {
                lock.lock(); declineReason = "Keine Antwort"; lock.unlock()
                break
            }
        }
        if isTerminal { control.close(); return }

        lock.lock(); let reason = declineReason; let dest = destination; lock.unlock()
        guard let dest, reason == nil else {
            var m = Msg(t: "decline"); m.reason = reason
            try? control.send(m)
            setState(.declined(reason))
            control.close()
            return
        }

        do {
            if !isBench { try prepare(in: dest) }
        } catch {
            var m = Msg(t: "decline"); m.reason = "\(error)"
            try? control.send(m)
            setState(.failed("\(error)"))
            cleanup()
            control.close()
            return
        }

        let chunkCount = planChunks(items, chunkSize: chunkSize).count
        var accept = Msg(t: "accept")
        accept.streams = max(1, min(Tailbolt.tailnetStreams, chunkCount))
        if lanFastPath && chunkCount > 0 {
            let key = SessionKey.random()
            lock.lock(); sessionKey = key; lock.unlock()
            accept.key = key.base64
            accept.lan = LocalNetwork.advertisableAddresses()
        }
        setState(.transferring)
        do { try control.send(accept) } catch {
            setState(.failed("\(error)")); cleanup(); return
        }

        if chunkCount > 0 {
            while completion.wait(timeout: .now() + 0.5) == .timedOut {
                if control.peerHasClosed() {
                    setState(.cancelled("Absender hat abgebrochen")); break
                }
            }
        }
        if isTerminal {
            cleanup(); control.close(); return
        }

        setState(.finishing)
        do {
            savedURLs = isBench ? [] : try finalize(into: dest)
            try? control.send(Msg(t: "done"))
            setState(.finished)
        } catch {
            var m = Msg(t: "error"); m.reason = "\(error)"
            try? control.send(m)
            setState(.failed("\(error)"))
            cleanup()
        }
        control.close()
    }

    private func prepare(in dest: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        if let free = try? dest.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < fileBytes + (64 << 20) {
            throw SocketError("Nicht genug Speicherplatz (\(ByteFormat.string(fileBytes)) benötigt)")
        }
        let stage = dest.appendingPathComponent(".tailbolt-\(id)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        lock.lock(); staging = stage; lock.unlock()

        for item in items {
            let url = stage.appendingPathComponent(item.p)
            if item.d {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            } else if item.l == nil {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
                guard fd >= 0 else { throw SocketError("Kann \(item.p) nicht anlegen") }
                defer { close(fd) }
                if item.s > 0 {
                    #if canImport(Darwin)
                    // Ask APFS for contiguous space up front; parallel writers then never fight over extents.
                    var store = fstore_t(fst_flags: UInt32(F_ALLOCATECONTIG | F_ALLOCATEALL), fst_posmode: F_PEOFPOSMODE,
                                         fst_offset: 0, fst_length: off_t(item.s), fst_bytesalloc: 0)
                    if fcntl(fd, F_PREALLOCATE, &store) != 0 {
                        store.fst_flags = UInt32(F_ALLOCATEALL)
                        _ = fcntl(fd, F_PREALLOCATE, &store)
                    }
                    #endif
                    if ftruncate(fd, off_t(item.s)) != 0 { throw SocketError("Kann \(item.p) nicht anlegen") }
                }
            }
        }
    }

    private func finalize(into dest: URL) throws -> [URL] {
        let fm = FileManager.default
        guard let stage = staging else { return [] }
        // Symlinks last, so nothing can ever be written through one.
        for item in items {
            let url = stage.appendingPathComponent(item.p)
            if let target = item.l {
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.createSymbolicLink(atPath: url.path, withDestinationPath: target)
                continue
            }
            var attrs: [FileAttributeKey: Any] = [:]
            if let m = item.m { attrs[.modificationDate] = Date(timeIntervalSince1970: m) }
            if item.x == true { attrs[.posixPermissions] = 0o755 }
            if !attrs.isEmpty { try? fm.setAttributes(attrs, ofItemAtPath: url.path) }
        }
        // Directory mtimes after their contents are in place.
        for item in items.reversed() where item.d {
            if let m = item.m {
                try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: m)],
                                      ofItemAtPath: stage.appendingPathComponent(item.p).path)
            }
        }
        var out: [URL] = []
        for name in topLevelNames {
            var target = dest.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path) || (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil {
                target = dest.appendingPathComponent(uniqueName(name) { fm.fileExists(atPath: dest.appendingPathComponent($0).path) })
            }
            try fm.moveItem(at: stage.appendingPathComponent(name), to: target)
            out.append(target)
        }
        try? fm.removeItem(at: stage)
        return out
    }

    private func cleanup() {
        lock.lock(); let stage = staging; staging = nil; lock.unlock()
        if let stage { try? FileManager.default.removeItem(at: stage) }
    }

    // MARK: data connections

    func handleData(_ s: any ByteStream, lan: Bool) {
        guard state == .transferring else { Debug.log("rx data: state \(state), closing"); s.close(); return }
        track(s)
        countStream(lan: lan, delta: 1)
        defer { countStream(lan: lan, delta: -1); untrack(s); s.close() }
        s.setReceiveTimeout(120)
        lock.lock(); let stage = staging; lock.unlock()
        guard let stage = isBench ? URL(fileURLWithPath: "/dev/null") : stage else { return }

        let maxChunk = Int(chunkSize)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: maxChunk, alignment: 16384)
        var packed: UnsafeMutableRawPointer?
        defer { raw.deallocate(); packed?.deallocate() }
        var fileIndex = -1
        var fd: Int32 = -1
        defer { if fd >= 0 { close(fd) } }

        while !isTerminal {
            guard let msg = try? s.receive() else { Debug.log("rx data: receive failed"); return }
            if msg.t == "bye" { return }
            guard msg.t == "chunk", let f = msg.f, let o = msg.o, let n = msg.n,
                  items.indices.contains(f), !items[f].d, items[f].l == nil,
                  o >= 0, n > 0 else { return }
            let compressed = msg.c == "lz4"
            let length = compressed ? (msg.u ?? -1) : n
            guard length > 0, length <= chunkSize, o + length <= items[f].s,
                  !compressed || (LZ4.available && n <= Int64(LZ4.bound(maxChunk))) else { return }
            let key = ChunkKey(file: f, offset: o)
            lock.lock(); let duplicate = completedChunks.contains(key); lock.unlock()

            if f != fileIndex && !duplicate && !isBench {
                if fd >= 0 { close(fd) }
                fd = open(stage.appendingPathComponent(items[f].p).path, O_WRONLY)
                guard fd >= 0 else { setState(.failed("Schreibfehler bei \(items[f].p)")); return }
                if items[f].s >= Tailbolt.noCacheThreshold { fcntl(fd, F_NOCACHE, 1) }
                fileIndex = f
            }

            do {
                if compressed {
                    if packed == nil { packed = UnsafeMutableRawPointer.allocate(byteCount: LZ4.bound(maxChunk), alignment: 16384) }
                    try s.recvExact(packed!, Int(n))
                    if !duplicate {
                        guard LZ4.decompress(packed!, Int(n), into: raw, expected: Int(length)) else {
                            setState(.failed("Daten beschädigt (LZ4)")); return
                        }
                        guard isBench || write(fd, raw, Int(length), at: o) else { return }
                        addBytes(length, wire: n)
                    }
                } else {
                    var off = o
                    let end = o + n
                    while off < end {
                        // Whole 4 MiB blocks → one aligned pwrite each (uncached writes want that).
                        let want = Int(min(Int64(Tailbolt.ioBufferSize), end - off))
                        try s.recvExact(raw, want)
                        if !duplicate {
                            guard isBench || write(fd, raw, want, at: off) else { return }
                            addBytes(Int64(want))
                        }
                        off += Int64(want)
                    }
                }
            } catch { return }

            if !duplicate { complete(key, length) }
            var ack = Msg(t: "ack")
            ack.f = f
            ack.o = o
            guard (try? s.send(ack)) != nil else { return }
        }
    }

    /// pwrite loop; flips the transfer to failed on I/O errors.
    private func write(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ count: Int, at offset: Int64) -> Bool {
        var written = 0
        while written < count {
            let w = pwrite(fd, buf + written, count - written, offset + Int64(written))
            if w < 0 {
                if errno == EINTR { continue }
                setState(.failed("Schreibfehler: \(String(cString: strerror(errno)))"))
                return false
            }
            written += w
        }
        return true
    }

    private func complete(_ key: ChunkKey, _ n: Int64) {
        lock.lock()
        let isNew = completedChunks.insert(key).inserted
        if isNew { completedBytes += n }
        let done = completedBytes >= fileBytes
        lock.unlock()
        if done { completion.signal() }
    }
}
