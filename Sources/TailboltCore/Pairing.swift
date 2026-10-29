import Foundation

/// Mutual auto-accept ("pairing"): one side asks, the other confirms on a card, and from then on transfers between
/// the two arrive without asking – in both directions. Each side only ever changes its own list, so a peer can
/// never make us trust it without the user clicking "Allow" here.
///
/// Wire: hello → `pair` → (user decides) → `pair-ok` | `decline`. `unpair` (after hello) tells the other side that
/// we turned it off; it only ever removes trust, so it needs no confirmation.
public enum Pairing {
    public enum Outcome: Equatable {
        case accepted
        case declined(String?)
        case failed(String)
    }

    /// How long the other side has to decide; the card times out a little earlier.
    public static let decisionTimeout: TimeInterval = 130

    /// Asks `host` to pair. Blocks until the user there decides (or the request times out) – call off the main thread.
    public static func request(host: String, port: UInt16 = Tailbolt.defaultPort, myName: String) -> Outcome {
        do {
            let s = try Socket.connect(host: host, port: port, timeout: 8)
            defer { s.close() }
            try s.send(makeHello(name: myName))
            s.setReceiveTimeout(10)
            let hello = try s.receive()
            guard hello.t == "hello" else { return .failed(String(localized: "Unexpected response")) }
            guard (hello.caps ?? []).contains("pair") else {
                return .failed(String(localized: "Tailbolt on the other device is too old – it needs version 2.3 or newer"))
            }
            try s.send(Msg(t: "pair"))
            s.setReceiveTimeout(decisionTimeout)
            let reply = try s.receive()
            switch reply.t {
            case "pair-ok": return .accepted
            case "decline": return .declined(reply.reason.map(Tailbolt.localizedReason))
            default: return .failed(reply.reason.map(Tailbolt.localizedReason) ?? String(localized: "Unexpected response"))
            }
        } catch {
            return .failed("\(error)")
        }
    }

    /// Best effort: lets `host` know we no longer auto-accept from it, so it can drop us too.
    public static func revoke(host: String, port: UInt16 = Tailbolt.defaultPort, myName: String) {
        guard let s = try? Socket.connect(host: host, port: port, timeout: 4) else { return }
        defer { s.close() }
        s.setReceiveTimeout(4)
        guard (try? s.send(makeHello(name: myName))) != nil, let hello = try? s.receive(), hello.t == "hello",
              (hello.caps ?? []).contains("pair") else { return }
        try? s.send(Msg(t: "unpair"))
    }
}

/// A peer's pairing request waiting for the user here. `accept()` / `decline()` from any thread.
public final class PairRequest: @unchecked Sendable {
    public let senderName: String
    public let remoteAddress: String
    public let receivedAt = Date()
    /// Called once (on the connection's thread) with the result – true = paired – after the user decided, the
    /// sender gave up, or the request timed out. May be set from any thread while the request waits.
    /// Set after the request already ended, it runs right away with that result.
    public var onFinish: ((Bool) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return finish }
        set {
            lock.lock(); finish = newValue; let done = result; lock.unlock()
            if let done, let newValue { newValue(done) }
        }
    }
    private var finish: ((Bool) -> Void)?
    private var result: Bool?

    private let control: Socket
    private let decision = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var accepted = false
    private var reason: String?

    init(senderName: String, remoteAddress: String, control: Socket) {
        self.senderName = senderName
        self.remoteAddress = remoteAddress
        self.control = control
    }

    public func accept() {
        lock.lock(); accepted = true; lock.unlock()
        decision.signal()
    }

    public func decline(_ reason: String? = nil) {
        lock.lock(); self.reason = reason ?? "Declined"; lock.unlock()
        decision.signal()
    }

    /// Runs on the connection's thread until there is an answer; the sender hanging up counts as a no.
    func run() {
        let started = Date()
        var gaveUp = false
        while decision.wait(timeout: .now() + 0.5) == .timedOut {
            if control.peerHasClosed() { gaveUp = true; break }
            if Date().timeIntervalSince(started) > Pairing.decisionTimeout - 10 {
                lock.lock(); reason = "No response"; lock.unlock()
                break
            }
        }
        lock.lock(); let ok = accepted && !gaveUp; let why = reason; lock.unlock()
        if ok {
            try? control.send(Msg(t: "pair-ok"))
        } else if !gaveUp {
            var m = Msg(t: "decline"); m.reason = why ?? "Declined"   // English on the wire
            try? control.send(m)
        }
        control.close()
        lock.lock(); result = ok; let callback = finish; lock.unlock()
        callback?(ok)
    }
}
