import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Work queue of chunks. A chunk leaves the queue when popped and is only retired once the receiver acks it;
/// chunks on a broken connection go back into the queue. Once a LAN stream has proven itself (first ack),
/// tailnet workers only take work while plenty is left, so the slow tunnel never defines the tail.
private final class ChunkQueue {
    private var pending: [Chunk]
    private var unacked: Int
    private var lanProven = 0
    private let cond = NSCondition()

    init(_ chunks: [Chunk]) {
        pending = chunks.reversed()
        unacked = chunks.count
    }

    func pop(lan: Bool) -> Chunk? {
        cond.lock(); defer { cond.unlock() }
        if !lan && lanProven > 0 && pending.count <= lanProven * 2 { return nil }
        return pending.popLast()
    }

    func requeue(_ chunks: [Chunk]) {
        cond.lock(); pending.append(contentsOf: chunks.reversed()); cond.unlock()
    }

    func acked(lan: Bool, first: inout Bool) {
        cond.lock()
        unacked -= 1
        if lan && first { lanProven += 1; first = false }
        cond.broadcast()
        cond.unlock()
    }

    func lanWorkerLeft(proven: Bool) {
        cond.lock(); if proven { lanProven -= 1 }; cond.unlock()
    }

    var allAcked: Bool {
        cond.lock(); defer { cond.unlock() }
        return unacked <= 0
    }

    var isEmpty: Bool {
        cond.lock(); defer { cond.unlock() }
        return pending.isEmpty
    }
}

/// Chunks sent on one data connection that are still waiting for their ack.
private final class Inflight {
    private var chunks: [ChunkKey: (chunk: Chunk, sent: Int64, wire: Int64)] = [:]
    private var broken = false
    private let cond = NSCondition()

    func add(_ c: Chunk) { cond.lock(); chunks[c.key] = (c, 0, 0); cond.unlock() }

    func sent(_ key: ChunkKey, payload: Int64, wire: Int64) {
        cond.lock(); chunks[key]?.sent += payload; chunks[key]?.wire += wire; cond.unlock()
    }

    func ack(_ key: ChunkKey) -> Bool {
        cond.lock(); defer { cond.broadcast(); cond.unlock() }
        return chunks.removeValue(forKey: key) != nil
    }

    func markBroken() { cond.lock(); broken = true; cond.broadcast(); cond.unlock() }

    /// Waits until every chunk is acked. Returns false if the connection broke first.
    func drain() -> Bool {
        cond.lock(); defer { cond.unlock() }
        while !chunks.isEmpty && !broken { cond.wait() }
        return chunks.isEmpty
    }

    /// Removes everything still in flight; returns the chunks and the bytes already counted for them.
    func takeAll() -> ([Chunk], Int64, Int64) {
        cond.lock(); defer { cond.unlock() }
        let list = chunks.values.map(\.chunk)
        let sent = chunks.values.reduce(Int64(0)) { $0 + $1.sent }
        let wire = chunks.values.reduce(Int64(0)) { $0 + $1.wire }
        chunks.removeAll()
        return (list, sent, wire)
    }
}

/// Where a data connection goes: through the tailnet (always works) or straight across the LAN (fast path).
private struct Endpoint {
    let hosts: [String]      // LAN workers rotate through candidates; tailnet workers have exactly one
    let port: UInt16
    let lan: Bool
}

public final class OutgoingTransfer: TransferBase {
    public let host: String
    public let port: UInt16
    public let urls: [URL]
    /// LAN address of the peer known from `tailscale status` (its direct endpoint), if on one of our subnets.
    public var peerLANHint: String?
    /// Adaptive LZ4 on compressible chunks (still needs the receiver's "lz4" capability). Off = raw bytes only.
    public var compressionEnabled = true
    /// Message shown to the recipient on the request card (set before `start()`).
    public var note: String?
    /// What the receiver's hello said, known from `.waiting` on: whether its request card shows notes and which
    /// Tailbolt it runs ("2.0" there means the note was sent but nobody will see it).
    public private(set) var receiverShowsNotes: Bool?
    public private(set) var receiverVersion: String?

    private let myName: String
    private var sources: [String?] = []
    private let doneSignal = DispatchSemaphore(value: 0)
    private var receiverFinished = false
    private var sessionKey: SessionKey?
    private var allowCompression = false
    private var nextConnection = 0
    private var liveWorkers = 0
    private var chunkSize: Int64 = Tailbolt.maxChunkSize

    /// Builds the manifest synchronously (fast for typical folders; call off the main thread for huge trees).
    public init(host: String, port: UInt16 = Tailbolt.defaultPort, urls: [URL], myName: String) throws {
        self.host = host
        self.port = port
        self.urls = urls
        self.myName = myName
        let manifest = try SourceManifest.build(urls)
        self.sources = manifest.sources
        super.init(id: UUID().uuidString, items: manifest.items)
    }

    /// Throughput test: streams `size` bytes of random data the receiver throws away. Same code path as a
    /// real transfer (streams, LAN fast path), but incompressible and never touching disk on either end.
    public static let benchSize: Int64 = 128 << 20
    public private(set) var isBench = false
    private var benchData: UnsafeMutableRawPointer?

    public init(benchHost host: String, port: UInt16 = Tailbolt.defaultPort, size: Int64 = benchSize, myName: String) {
        self.host = host
        self.port = port
        self.urls = []
        self.myName = myName
        super.init(id: UUID().uuidString, items: [WireItem(p: "bench", s: size, d: false)])
        isBench = true
        sources = [nil]
        let n = Int(Tailbolt.maxChunkSize)
        let buf = UnsafeMutableRawPointer.allocate(byteCount: n, alignment: 16384)
        var rng = SystemRandomNumberGenerator()
        let words = buf.bindMemory(to: UInt64.self, capacity: n / 8)
        for i in 0..<(n / 8) { words[i] = rng.next() }
        benchData = buf
    }

    deinit { benchData?.deallocate() }

    /// Seconds spent in `.transferring`, for MB/s after a bench.
    public private(set) var transferSeconds: Double = 0
    private var transferStart: Date?

    public func start() {
        Thread.detachNewThread { [self] in run() }
    }

    public func cancel() {
        setState(.cancelled(nil))
    }

    private func run() {
        do {
            let control = try Socket.connect(host: host, port: port, timeout: 8)
            track(control)
            defer { untrack(control); control.close() }

            try control.send(makeHello(name: myName))
            control.setReceiveTimeout(10)
            let theirHello = try control.receive()
            guard theirHello.t == "hello" else { throw SocketError(String(localized: "Unexpected response")) }
            let caps = Set(theirHello.caps ?? [])
            receiverShowsNotes = caps.contains("note")
            receiverVersion = theirHello.app
            allowCompression = compressionEnabled && LZ4.available && caps.contains("lz4") && !isBench
            if isBench && (theirHello.v ?? 1) < 2 {
                throw SocketError(String(localized: "Tailbolt on the other device is too old for the test"))
            }

            chunkSize = Tailbolt.chunkSize(forTotal: totalBytes)
            var offer = Msg(t: "offer")
            offer.id = id
            offer.items = items
            offer.total = totalBytes
            offer.chunk = chunkSize
            if isBench { offer.bench = true }
            if !isBench { offer.note = Tailbolt.sanitizedNote(note) }
            try control.send(offer)
            setState(.waiting)

            control.setReceiveTimeout(0)   // the user on the other end may take a while
            let reply = try control.receive()
            switch reply.t {
            case "accept": break
            case "decline":
                setState(.declined(reply.reason.map(Tailbolt.localizedReason))); return
            default:
                throw SocketError(reply.reason.map(Tailbolt.localizedReason) ?? String(localized: "The recipient declined"))
            }
            if isTerminal { return }
            transferStart = Date()
            setState(.transferring)

            // The control connection now only carries the final "done" (or an error/cancel from the receiver).
            Thread.detachNewThread { [self] in watchControl(control) }

            let chunks = planChunks(items, chunkSize: chunkSize)
            if !chunks.isEmpty {
                let queue = ChunkQueue(chunks)
                var endpoints: [Endpoint] = []
                let tailnetCount = max(1, min(reply.streams ?? 1, Tailbolt.tailnetStreams, chunks.count))
                endpoints += Array(repeating: Endpoint(hosts: [host], port: port, lan: false), count: tailnetCount)

                if caps.contains("lan"), let keyString = reply.key, let key = SessionKey(base64: keyString) {
                    sessionKey = key
                    let lanHosts = lanCandidates(advertised: reply.lan ?? [])
                    if !lanHosts.isEmpty {
                        let lanCount = min(Tailbolt.lanStreams, max(1, chunks.count / 2))
                        for i in 0..<lanCount {
                            // Each LAN worker starts on a different candidate; all candidates get dialled at once.
                            let rotated = Array(lanHosts[(i % lanHosts.count)...] + lanHosts[..<(i % lanHosts.count)])
                            endpoints.append(Endpoint(hosts: rotated, port: port, lan: true))
                        }
                    }
                }

                liveWorkers = endpoints.count
                let group = DispatchGroup()
                for ep in endpoints {
                    group.enter()
                    Thread.detachNewThread { [self] in
                        runWorker(queue, endpoint: ep)
                        group.leave()
                    }
                }
                group.wait()
                if let start = transferStart { transferSeconds = Date().timeIntervalSince(start) }
                if isTerminal { return }
                guard queue.allAcked else { throw SocketError(String(localized: "Transfer incomplete")) }
            }

            setState(.finishing)
            if doneSignal.wait(timeout: .now() + 600) == .timedOut {
                throw SocketError(String(localized: "The recipient isn’t responding"))
            }
            lock.lock(); let ok = receiverFinished; lock.unlock()
            if ok { setState(.finished) }
        } catch {
            if !isTerminal { setState(.failed("\(error)")) }
        }
    }

    /// LAN addresses worth trying, best first: the endpoint Tailscale itself uses, then what the receiver
    /// advertised — but only private addresses on subnets we are on, never our own (VM bridges exist on both Macs).
    private func lanCandidates(advertised: [String]) -> [String] {
        // TAILBOLT_SELF_LAN=1 lets a single machine exercise the LAN path against itself (tests only).
        let selfTest = ProcessInfo.processInfo.environment["TAILBOLT_SELF_LAN"] == "1"
        let mine = selfTest ? [] : Set(LocalNetwork.ipv4Interfaces().map(\.address))
        var out: [String] = []
        for h in [peerLANHint].compactMap({ $0 }) + advertised {
            guard !mine.contains(h), !out.contains(h), LocalNetwork.isPrivate(h), LocalNetwork.isOnLocalSubnet(h) else { continue }
            out.append(h)
            if out.count == 4 { break }
        }
        return out
    }

    private func watchControl(_ control: Socket) {
        let msg = try? control.receive()
        if msg?.t == "done" {
            lock.lock(); receiverFinished = true; lock.unlock()
        } else if !isTerminal {
            if let msg, msg.t == "error" {
                setState(.failed(msg.reason.map(Tailbolt.localizedReason) ?? String(localized: "Error on the recipient’s side")))
            } else {
                setState(.cancelled(String(localized: "The recipient cancelled")))
            }
        }
        doneSignal.signal()
    }

    /// Opens a data connection. LAN connections complete a sealed hello/ok exchange before any payload,
    /// so bytes only ever flow to a host that proved it holds the session key.
    private func openStream(_ ep: Endpoint, attempt: Int) throws -> any ByteStream {
        let target = ep.hosts[attempt % ep.hosts.count]
        let s = try Socket.connect(host: target, port: ep.port, timeout: ep.lan ? 1.5 : 10)
        lock.lock(); let ci = nextConnection; nextConnection += 1; lock.unlock()
        var hello = Msg(t: "data")
        hello.id = id
        if ep.lan {
            guard let key = sessionKey else { throw SocketError(String(localized: "No session key")) }
            s.tuneLiveness(dead: 8)
            hello.ci = ci
            try s.send(hello)                         // plaintext envelope, everything after is sealed
            let secure = SecureStream(socket: s, key: key, transferID: id, connection: ci, role: .sender)
            var lanHello = Msg(t: "lan-hello")
            lanHello.nonce = UUID().uuidString
            try secure.send(lanHello)
            secure.setReceiveTimeout(3)
            let ok = try secure.receive()
            guard ok.t == "lan-ok", ok.nonce == lanHello.nonce else { throw SocketError(String(localized: "LAN handshake failed")) }
            secure.setReceiveTimeout(120)
            return secure
        }
        s.setReceiveTimeout(120)
        try s.send(hello)
        return s
    }

    private func runWorker(_ queue: ChunkQueue, endpoint: Endpoint) {
        var failures = 0
        let maxChunk = Int(chunkSize)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: maxChunk, alignment: 16384)
        let packed = allowCompression ? UnsafeMutableRawPointer.allocate(byteCount: LZ4.bound(maxChunk), alignment: 16384) : nil
        var proven = false
        defer {
            raw.deallocate()
            packed?.deallocate()
            if endpoint.lan { queue.lanWorkerLeft(proven: proven) }
            lock.lock(); liveWorkers -= 1; lock.unlock()
        }

        while !isTerminal {
            // A LAN worker that can't get anywhere just leaves — the tailnet workers finish the job.
            if endpoint.lan && queue.isEmpty { return }
            // Everything acked (typically by the LAN streams): nothing left for this worker to do or to fail at.
            if queue.allAcked { return }
            let inflight = Inflight()
            var stream: (any ByteStream)?
            var counted = false
            var firstAck = true
            do {
                let s = try openStream(endpoint, attempt: failures)
                stream = s
                track(s)
                countStream(lan: endpoint.lan, delta: 1)
                counted = true
                let isLAN = endpoint.lan

                Thread.detachNewThread {
                    while let msg = try? s.receive(), msg.t == "ack", let f = msg.f, let o = msg.o {
                        if inflight.ack(ChunkKey(file: f, offset: o)) {
                            queue.acked(lan: isLAN, first: &firstAck)
                            if isLAN { proven = true }
                        }
                    }
                    inflight.markBroken()
                }

                var fileIndex = -1
                var fd: Int32 = -1
                var compressible = false
                defer { if fd >= 0 { close(fd) } }

                while let chunk = queue.pop(lan: endpoint.lan) {
                    inflight.add(chunk)
                    if chunk.file != fileIndex && !isBench {
                        if fd >= 0 { close(fd) }
                        guard let path = sources[chunk.file] else { throw SourceError(String(localized: "Source missing")) }
                        fd = open(path, O_RDONLY)
                        guard fd >= 0 else {
                            let name = (path as NSString).lastPathComponent
                            throw SourceError(String(localized: "Can’t read \(name)"))
                        }
                        fcntl(fd, F_RDAHEAD, 1)
                        if items[chunk.file].s >= Tailbolt.noCacheThreshold { fcntl(fd, F_NOCACHE, 1) }
                        fileIndex = chunk.file
                        compressible = allowCompression && !LZ4.likelyIncompressible(path: path)
                    }

                    // Read the whole chunk; a short read means the file shrank underneath us.
                    var got = 0
                    let want = Int(chunk.length)
                    if let benchData {
                        raw.copyMemory(from: benchData, byteCount: want)
                        got = want
                    }
                    while got < want {
                        let n = pread(fd, raw + got, want - got, chunk.offset + Int64(got))
                        guard n > 0 else { throw SourceError(String(localized: "A file changed while it was being sent")) }
                        got += n
                    }

                    var header = Msg(t: "chunk")
                    header.f = chunk.file
                    header.o = chunk.offset
                    var payload: UnsafeRawPointer = UnsafeRawPointer(raw)
                    var wireLength = want
                    if compressible, let packed, want >= 1 << 20 {
                        let c = LZ4.compress(raw, want, into: packed, capacity: LZ4.bound(maxChunk))
                        if c > 0 {
                            header.c = "lz4"
                            header.u = chunk.length
                            payload = UnsafeRawPointer(packed)
                            wireLength = c
                        }
                    }
                    header.n = Int64(wireLength)
                    try s.send(header)
                    try s.sendAll(payload, wireLength)
                    addBytes(chunk.length, wire: Int64(wireLength))
                    inflight.sent(chunk.key, payload: chunk.length, wire: Int64(wireLength))
                    if isTerminal { return }
                }
                guard inflight.drain() else { throw SocketError(String(localized: "Connection interrupted")) }
                try? s.send(Msg(t: "bye"))
                untrack(s)
                s.close()
                // Tailnet workers may have been held back by LAN pre-emption; if work remains, keep going.
                if !endpoint.lan && !queue.isEmpty && !queue.allAcked {
                    Thread.sleep(forTimeInterval: 0.5)
                    continue
                }
                return
            } catch {
                if let stream { untrack(stream); stream.close() }
                if counted { countStream(lan: endpoint.lan, delta: -1) }
                let (lost, sentBytes, wireBytes) = inflight.takeAll()
                queue.requeue(lost)
                addBytes(-sentBytes, wire: -wireBytes)
                if isTerminal { return }
                Debug.log("tx worker \(endpoint.lan ? "lan" : "tailnet") attempt \(failures + 1): \(error)")
                if error is SourceError {
                    setState(.failed("\(error)")); return
                }
                // The other streams may have finished the job while this one was failing – that is a success.
                if queue.allAcked { return }
                failures += 1
                if endpoint.lan {
                    // Fast path is optional: try each candidate once, then leave quietly.
                    if failures >= max(2, endpoint.hosts.count) { return }
                    Thread.sleep(forTimeInterval: 0.3)
                    continue
                }
                // ~22 s of retries (0.5, 1, 1.5, 2, 2.5, then 3 s apart): a Tailscale path change or a short
                // outage must not kill a transfer whose control connection is still fine.
                if failures > 10 {
                    lock.lock(); let others = liveWorkers - 1; lock.unlock()
                    if others <= 0 && !queue.allAcked {
                        let detail = "\(error)"
                        setState(.failed(String(localized: "Connection lost: \(detail)")))
                    }
                    return
                }
                Thread.sleep(forTimeInterval: min(0.5 * Double(failures), 3))
            }
        }
    }
}

private struct SourceError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
