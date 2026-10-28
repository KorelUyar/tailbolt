import Foundation

public enum TransferState: Equatable {
    case preparing
    case waiting            // offer sent / waiting for the user to decide
    case transferring
    case finishing
    case finished
    case declined(String?)
    case failed(String)
    case cancelled(String?)

    public var isTerminal: Bool {
        switch self {
        case .finished, .declined, .failed, .cancelled: return true
        default: return false
        }
    }
}

/// Shared bookkeeping for both directions: thread-safe state + byte counters.
public class TransferBase: @unchecked Sendable {
    public let id: String
    public let items: [WireItem]
    public let totalBytes: Int64

    let lock = NSLock()
    private var _state: TransferState = .preparing
    private var _bytes: Int64 = 0
    private var _wireBytes: Int64 = 0
    private var streams: [ObjectIdentifier: any ByteStream] = [:]
    private var _lanStreams = 0
    private var _tailnetStreams = 0

    /// Called on an arbitrary thread whenever `state` changes.
    public var onStateChange: ((TransferState) -> Void)?

    init(id: String, items: [WireItem]) {
        self.id = id
        self.items = items
        self.totalBytes = items.reduce(0) { $0 + ($1.d ? 0 : $1.s) }
    }

    public var state: TransferState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    /// Bytes moved so far (clamped to total).
    public var bytesTransferred: Int64 {
        lock.lock(); defer { lock.unlock() }
        return min(max(_bytes, 0), totalBytes)
    }

    public var fractionCompleted: Double {
        totalBytes == 0 ? (state == .finished ? 1 : 0) : Double(bytesTransferred) / Double(totalBytes)
    }

    /// Live view of how the bytes are moving: direct LAN streams vs. through the tailnet,
    /// and how much LZ4 saved so far (payload bytes minus bytes actually put on the wire).
    public struct Stats: Sendable {
        public let lanStreams: Int
        public let tailnetStreams: Int
        public let bytesSavedByCompression: Int64
        public var usesLAN: Bool { lanStreams > 0 }
    }

    public var stats: Stats {
        lock.lock(); defer { lock.unlock() }
        return Stats(lanStreams: _lanStreams, tailnetStreams: _tailnetStreams, bytesSavedByCompression: max(0, _bytes - _wireBytes))
    }

    /// Top-level entries (what the user dragged), e.g. ["Photos", "report.pdf"].
    public var topLevelNames: [String] {
        var seen = Set<String>(), out: [String] = []
        for item in items {
            let top = String(item.p.split(separator: "/", maxSplits: 1).first ?? "")
            if seen.insert(top).inserted { out.append(top) }
        }
        return out
    }

    /// `payload` = file bytes represented, `wire` = bytes actually sent/received for them.
    func addBytes(_ payload: Int64, wire: Int64? = nil) {
        lock.lock(); _bytes += payload; _wireBytes += wire ?? payload; lock.unlock()
    }

    func countStream(lan: Bool, delta: Int) {
        lock.lock()
        if lan { _lanStreams += delta } else { _tailnetStreams += delta }
        lock.unlock()
    }

    @discardableResult
    func setState(_ new: TransferState) -> Bool {
        lock.lock()
        if _state.isTerminal || _state == new { lock.unlock(); return false }
        _state = new
        let cb = onStateChange
        let terminal = new.isTerminal
        let toClose = terminal ? Array(streams.values) : []
        if terminal { streams.removeAll() }
        lock.unlock()
        toClose.forEach { $0.shutdown() }
        cb?(new)
        return true
    }

    var isTerminal: Bool { state.isTerminal }

    func track(_ s: any ByteStream) {
        lock.lock()
        let terminal = _state.isTerminal
        if !terminal { streams[ObjectIdentifier(s)] = s }
        lock.unlock()
        if terminal { s.shutdown() }
    }

    func untrack(_ s: any ByteStream) {
        lock.lock(); streams.removeValue(forKey: ObjectIdentifier(s)); lock.unlock()
    }
}

public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public static func speed(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }
}
