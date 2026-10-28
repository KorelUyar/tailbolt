import Foundation
import TailboltCore

// Headless Tailbolt: handy for servers, testing and as a reference for other platforms.

func usage() -> Never {
    print("""
    tailbolt-cli peers                          list tailnet devices and whether they run Tailbolt
    tailbolt-cli send <host[:port]> <paths...>  send files/folders
    tailbolt-cli bench <host[:port]> [MB]       throughput test (receiver discards the data)
    tailbolt-cli serve [--port N] [--dir PATH]  receive (auto-accepts everything)
    """)
    exit(2)
}

func hostPort(_ s: String) -> (String, UInt16) {
    if let idx = s.lastIndex(of: ":"), !s.contains("::"), let p = UInt16(s[s.index(after: idx)...]) {
        return (String(s[..<idx]), p)
    }
    return (s, Tailbolt.defaultPort)
}

let myName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

final class Printer {
    private var last = Date.distantPast
    private var lastBytes: Int64 = 0
    func show(_ t: TransferBase, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(last) > 0.5 else { return }
        let dt = now.timeIntervalSince(last)
        let speed = dt > 0 && dt < 5 ? Double(t.bytesTransferred - lastBytes) / dt : 0
        last = now; lastBytes = t.bytesTransferred
        let pct = Int(t.fractionCompleted * 100)
        let st = t.stats
        let extra = "  [lan \(st.lanStreams) / tailnet \(st.tailnetStreams), lz4 saved \(ByteFormat.string(st.bytesSavedByCompression))]"
        FileHandle.standardError.write("\r\(pct)%  \(ByteFormat.string(t.bytesTransferred)) / \(ByteFormat.string(t.totalBytes))  \(ByteFormat.speed(speed))\(extra)     ".data(using: .utf8)!)
    }
}

final class ServeDelegate: TailboltServerDelegate {
    let dir: URL
    init(dir: URL) { self.dir = dir }
    func server(_ server: TailboltServer, didReceiveOffer transfer: IncomingTransfer) {
        print("Offer from \(transfer.senderName) [\(transfer.remoteAddress)]: \(transfer.topLevelNames.joined(separator: ", ")) (\(ByteFormat.string(transfer.totalBytes)))")
        let start = Date()
        let printer = Printer()
        transfer.onStateChange = { state in
            if state.isTerminal {
                printer.show(transfer, force: true)
                let secs = Date().timeIntervalSince(start)
                print("\n→ \(state)  \(String(format: "%.2fs", secs))  avg \(ByteFormat.speed(Double(transfer.totalBytes) / max(secs, 0.001)))")
                transfer.savedURLs.forEach { print("  saved \($0.path)") }
            }
        }
        Thread.detachNewThread {
            while !transfer.state.isTerminal { printer.show(transfer); Thread.sleep(forTimeInterval: 0.25) }
        }
        transfer.accept(into: dir)
    }
    func server(_ server: TailboltServer, didSeeHello info: HelloInfo, from ip: String) {}
}

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { usage() }
args.removeFirst()

switch cmd {
case "peers":
    guard let status = Tailnet.status() else { print("Tailscale not available"); exit(1) }
    print("Me: \(status.selfName) \(status.selfIPs)")
    let group = DispatchGroup()
    let lock = NSLock()
    var rows: [String] = []
    for p in status.peers where p.online {
        group.enter()
        DispatchQueue.global().async {
            let hello = Probe.hello(host: p.address, myName: myName)
            let row = "\(hello != nil ? "●" : "○") \(p.displayName.padding(toLength: 30, withPad: " ", startingAt: 0)) \(p.address.padding(toLength: 16, withPad: " ", startingAt: 0)) \(p.os.padding(toLength: 8, withPad: " ", startingAt: 0)) \(p.path)\(p.directHost.map { " \($0)" } ?? "") \(p.isMine ? "(mine)" : p.user?.loginName ?? "")"
            lock.lock(); rows.append(row); lock.unlock()
            group.leave()
        }
    }
    group.wait()
    rows.sorted().forEach { print($0) }

case "send":
    guard args.count >= 2 else { usage() }
    let (host, port) = hostPort(args[0])
    let urls = args.dropFirst().map { URL(fileURLWithPath: $0) }
    let t = try OutgoingTransfer(host: host, port: port, urls: urls, myName: myName)
    print("Sending \(t.items.count) item(s), \(ByteFormat.string(t.totalBytes)) to \(host):\(port)")
    let done = DispatchSemaphore(value: 0)
    var started = Date()
    let printer = Printer()
    t.onStateChange = { state in
        if state == .waiting { print("Waiting for receiver…") }
        if state == .transferring { started = Date() }
        if state.isTerminal { done.signal() }
    }
    t.start()
    while done.wait(timeout: .now() + 0.25) == .timedOut {
        if t.state == .transferring { printer.show(t) }
    }
    printer.show(t, force: true)
    let secs = Date().timeIntervalSince(started)
    print("\n→ \(t.state)  \(String(format: "%.2fs", secs))  avg \(ByteFormat.speed(Double(t.totalBytes) / max(secs, 0.001)))")
    exit(t.state == .finished ? 0 : 1)

case "bench":
    guard args.count >= 1 else { usage() }
    let (host, port) = hostPort(args[0])
    let mb = args.count > 1 ? Int64(args[1]) ?? 128 : 128
    let t = OutgoingTransfer(benchHost: host, port: port, size: mb << 20, myName: myName)
    print("Bench: \(ByteFormat.string(t.totalBytes)) to \(host):\(port)")
    let done = DispatchSemaphore(value: 0)
    let printer = Printer()
    t.onStateChange = { state in if state.isTerminal { done.signal() } }
    t.start()
    while done.wait(timeout: .now() + 0.25) == .timedOut {
        if t.state == .transferring { printer.show(t) }
    }
    printer.show(t, force: true)
    let st = t.stats
    if t.state == .finished {
        print("\n→ \(ByteFormat.speed(Double(t.totalBytes) / max(t.transferSeconds, 0.001)))  in \(String(format: "%.2fs", t.transferSeconds))  (lan streams used: \(st.lanStreams > 0 ? "yes" : "no"))")
    } else {
        print("\n→ \(t.state)")
    }
    exit(t.state == .finished ? 0 : 1)

case "serve":
    var port = Tailbolt.defaultPort
    var dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    var i = 0
    while i < args.count {
        if args[i] == "--port", i + 1 < args.count { port = UInt16(args[i + 1]) ?? port; i += 2 }
        else if args[i] == "--dir", i + 1 < args.count { dir = URL(fileURLWithPath: args[i + 1]); i += 2 }
        else { usage() }
    }
    let delegate = ServeDelegate(dir: dir)
    let server = TailboltServer(port: port) { myName + " (cli)" }
    server.delegate = delegate
    try server.start()
    print("Listening on :\(port), saving to \(dir.path)")
    dispatchMain()

default:
    usage()
}
