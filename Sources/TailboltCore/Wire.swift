import Foundation

public enum Tailbolt {
    public static let defaultPort: UInt16 = 48484
    public static let protocolVersion = 2
    public static let appVersion = "2.0"
    static let maxChunkSize: Int64 = 16 << 20
    static let ioBufferSize = 4 << 20
    /// Parallel TCP streams through the tailnet and (when both ends share a LAN) directly over it.
    static let tailnetStreams = 4
    static let lanStreams = 3
    static let maxStreams = 8
    /// Files at least this big are read/written uncached so multi-GB transfers don't evict everything else.
    static let noCacheThreshold: Int64 = 64 << 20
    /// Capabilities announced in hello; a sender only uses what the receiver listed.
    static var capabilities: [String] { (LZ4.available ? ["lz4"] : []) + ["lan"] }

    /// Small transfers get smaller chunks so every stream has work and the tail is short;
    /// big ones use 16 MiB (≥ 8 chunks per stream at 4 streams means ≥ 512 MiB).
    static func chunkSize(forTotal total: Int64) -> Int64 {
        let perStream = total / Int64(tailnetStreams * 8)
        return min(maxChunkSize, max(1 << 20, perStream))
    }
}

/// One entry of an offer. Paths are relative and always use "/".
public struct WireItem: Codable, Hashable {
    public var p: String        // relative path ("Folder/sub/file.txt")
    public var s: Int64         // size in bytes (0 for directories)
    public var d: Bool          // is directory
    public var m: Double?       // modification date (unix time)
    public var x: Bool?         // executable bit
    public var l: String?       // symlink destination (item is a symlink, s == 0)

    public init(p: String, s: Int64, d: Bool, m: Double? = nil, x: Bool? = nil, l: String? = nil) {
        self.p = p; self.s = s; self.d = d; self.m = m; self.x = x; self.l = l
    }
}

/// Every control message is a length-prefixed JSON object. A "chunk" message is followed by `n` raw bytes.
public struct Msg: Codable {
    public var t: String
    // hello
    public var v: Int?
    public var name: String?
    public var os: String?
    public var app: String?
    public var caps: [String]?      // "lz4", "lan"
    // offer / data
    public var id: String?
    public var items: [WireItem]?
    public var total: Int64?
    public var chunk: Int64?
    // accept / decline / error
    public var streams: Int?        // tailnet data connections the receiver wants
    public var reason: String?
    public var key: String?         // accept: base64 session key for LAN connections
    public var lan: [String]?       // accept: receiver's LAN IPv4 addresses; data: true-ish marker via `ci`
    public var ci: Int?             // data: connection index (LAN connections derive their key from it)
    public var bench: Bool?         // offer: throughput test — receiver discards the bytes, nothing is asked
    public var nonce: String?       // lan-hello / lan-ok handshake
    // chunk / ack
    public var f: Int?
    public var o: Int64?
    public var n: Int64?            // bytes that follow on the wire
    public var u: Int64?            // chunk: uncompressed length when `c` is set
    public var c: String?           // chunk: "lz4"

    public init(t: String) { self.t = t }
}

private let wireEncoder = JSONEncoder()
private let wireDecoder = JSONDecoder()

extension ByteStream {
    public func send(_ msg: Msg) throws {
        let body = try wireEncoder.encode(msg)
        var frame = Data(capacity: body.count + 4)
        var len = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }
        frame.append(body)
        try sendAll(frame)
    }

    public func receive() throws -> Msg {
        var len: UInt32 = 0
        try withUnsafeMutableBytes(of: &len) { try recvExact($0.baseAddress!, 4) }
        let count = Int(UInt32(bigEndian: len))
        guard count > 0, count < 64 << 20 else { throw SocketError("Ungültiger Frame") }
        var body = Data(count: count)
        try body.withUnsafeMutableBytes { try recvExact($0.baseAddress!, count) }
        return try wireDecoder.decode(Msg.self, from: body)
    }
}

/// `hello` with everything this build can do.
func makeHello(name: String) -> Msg {
    var hello = Msg(t: "hello")
    hello.v = Tailbolt.protocolVersion
    hello.name = name
    hello.os = Platform.name
    hello.app = Tailbolt.appVersion
    hello.caps = Tailbolt.capabilities
    return hello
}

enum Platform {
    static var name: String {
        #if os(macOS)
        return "macOS"
        #elseif os(iOS)
        return "iOS"
        #elseif os(Linux)
        return "linux"
        #elseif os(Windows)
        return "windows"
        #else
        return "unknown"
        #endif
    }
}

/// Deterministic chunk plan both sides derive from the item list.
struct ChunkKey: Hashable {
    let file: Int
    let offset: Int64
}

struct Chunk {
    let file: Int
    let offset: Int64
    let length: Int64
    var key: ChunkKey { ChunkKey(file: file, offset: offset) }
}

func planChunks(_ items: [WireItem], chunkSize: Int64) -> [Chunk] {
    var chunks: [Chunk] = []
    for (i, item) in items.enumerated() where !item.d && item.s > 0 {
        var off: Int64 = 0
        while off < item.s {
            let len = min(chunkSize, item.s - off)
            chunks.append(Chunk(file: i, offset: off, length: len))
            off += len
        }
    }
    return chunks
}

public struct HelloInfo: Hashable, Sendable {
    public let name: String
    public let os: String
    public let app: String
    public let caps: [String]

    public init(name: String, os: String, app: String, caps: [String] = []) {
        self.name = name; self.os = os; self.app = app; self.caps = caps
    }

    public var supportsLAN: Bool { caps.contains("lan") }
    public var supportsLZ4: Bool { caps.contains("lz4") }
}

public enum Probe {
    /// Returns the remote Tailbolt identity if the host runs Tailbolt on `port`.
    public static func hello(host: String, port: UInt16 = Tailbolt.defaultPort, timeout: TimeInterval = 1.5,
                             myName: String) -> HelloInfo? {
        guard let s = try? Socket.connect(host: host, port: port, timeout: timeout) else { return nil }
        defer { s.close() }
        s.setReceiveTimeout(timeout)
        guard (try? s.send(makeHello(name: myName))) != nil, let reply = try? s.receive(), reply.t == "hello" else { return nil }
        var bye = Msg(t: "bye")
        bye.reason = "probe"
        try? s.send(bye)
        return HelloInfo(name: reply.name ?? host, os: reply.os ?? "", app: reply.app ?? "", caps: reply.caps ?? [])
    }
}
