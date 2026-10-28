import AppKit
import Observation
import TailboltCore

struct Device: Identifiable, Hashable {
    let peer: TailnetPeer
    let hello: HelloInfo?

    var id: String { peer.id }
    var name: String { peer.displayName }
    /// Own device without Tailbolt: we can still reach it through Taildrop.
    var viaTaildrop: Bool { hello == nil }

    /// Owner label for other people's devices (hidden for anonymous Apple relay logins).
    var ownerName: String? {
        guard !peer.isMine, let u = peer.user else { return nil }
        if u.loginName.contains("privaterelay.appleid.com") { return nil }
        return u.displayName.isEmpty ? u.loginName : u.displayName
    }

    var symbol: String { DeviceSymbol.for(os: peer.os, name: name) }

    /// Short label for how traffic reaches this device ("Direkt (LAN)", "Relay", …), empty when idle.
    var pathLabel: String { peer.path.label }
    var pathIsSlow: Bool { peer.path == .relay }
}

enum DeviceSymbol {
    static func `for`(os: String, name: String) -> String {
        let n = name.lowercased()
        switch os.lowercased() {
        case "macos":
            if n.contains("mini") { return "macmini" }
            if n.contains("studio") { return "macstudio" }
            if n.contains("imac") { return "desktopcomputer" }
            return "laptopcomputer"
        case "ios":
            return n.contains("ipad") ? "ipad" : "iphone"
        case "windows": return "pc"
        case "linux": return "server.rack"
        case "android": return "smartphone"
        case "tvos": return "appletv"
        default: return "desktopcomputer"
        }
    }
}

enum Direction { case outgoing, incoming }

@MainActor @Observable
final class TransferItem: Identifiable {
    let id = UUID()
    let direction: Direction
    let deviceID: String?
    let peerName: String
    let peerSymbol: String
    var names: [String]
    var totalBytes: Int64 = 0
    var bytes: Int64 = 0
    var speed: Double = 0
    /// Live engine stats: LAN fast-path streams in use and bytes LZ4 saved so far.
    var lanStreams = 0
    var tailnetStreams = 0
    var bytesSaved: Int64 = 0
    var usesLAN: Bool { lanStreams > 0 }
    /// Advice worth showing next to a slow transfer (relayed path, macOS Tailscale slowdown bug).
    var hint: String?
    /// Set once a LAN fast-path stream was seen; `lanStreams` drops back to 0 when the streams close.
    var everUsedLAN = false
    /// ⌘⏎ on the incoming card: accept and show the files in the Finder once they are in place.
    @ObservationIgnored var revealWhenFinished = false
    @ObservationIgnored var startedTransferringAt: Date?
    var state: TransferState = .preparing {
        didSet {
            if state.isTerminal, let end = onEnd {
                onEnd = nil
                end()
            }
        }
    }
    var savedURLs: [URL] = []
    var awaitingDecision = false
    var dismissed = false
    var createdAt = Date()
    var finishedAt: Date?

    @ObservationIgnored var outgoing: OutgoingTransfer?
    @ObservationIgnored var incoming: IncomingTransfer?
    @ObservationIgnored var taildrop: TaildropTransfer?
    @ObservationIgnored fileprivate var lastSample: (Date, Int64)?
    /// What an outgoing transfer reads (empty for incoming) – tells the clipboard cache what is still in flight.
    @ObservationIgnored var sourceURLs: [URL] = []
    /// Runs once when the transfer reaches a terminal state, whichever path set it.
    @ObservationIgnored var onEnd: (() -> Void)?

    init(direction: Direction, deviceID: String?, peerName: String, peerSymbol: String, names: [String]) {
        self.direction = direction
        self.deviceID = deviceID
        self.peerName = peerName
        self.peerSymbol = peerSymbol
        self.names = names
    }

    var fraction: Double {
        if state == .finished { return 1 }
        return totalBytes > 0 ? min(1, Double(bytes) / Double(totalBytes)) : 0
    }

    var isActive: Bool { !state.isTerminal }

    var title: String {
        guard let first = names.first else { return "Dateien" }
        return names.count == 1 ? first : "\(first) und \(names.count - 1) weitere"
    }

    var statusText: String {
        switch state {
        case .preparing: return "Wird vorbereitet…"
        case .waiting: return direction == .outgoing ? "Warten auf Annahme…" : "Möchte senden"
        case .transferring:
            if taildrop != nil { return "Via Taildrop…" }
            var s = "\(ByteFormat.string(bytes)) von \(ByteFormat.string(totalBytes))"
            if speed > 0 {
                s += " · \(ByteFormat.speed(speed))"
                let remaining = Double(totalBytes - bytes) / speed
                if remaining > 1 { s += " · " + Self.eta(remaining) }
            }
            return s
        case .finishing: return "Wird abgeschlossen…"
        case .finished:
            return direction == .outgoing ? "Gesendet · \(ByteFormat.string(totalBytes))" : "Empfangen · \(ByteFormat.string(totalBytes))"
        case .declined(let r): return r.map { "Abgelehnt: \($0)" } ?? "Abgelehnt"
        case .failed(let r): return "Fehler: \(r)"
        case .cancelled(let r): return r ?? "Abgebrochen"
        }
    }

    /// Seconds spent moving bytes (the engine's own clock for outgoing transfers); nil before the first byte.
    var durationSeconds: Double? {
        if let o = outgoing, o.transferSeconds > 0 { return o.transferSeconds }
        guard let start = startedTransferringAt else { return nil }
        return (finishedAt ?? Date()).timeIntervalSince(start)
    }

    /// Mean throughput over the whole transfer – "4,2 GB in 8,1 s · 520 MB/s" on finished rows and the bench result.
    var averageSpeed: Double? {
        guard let d = durationSeconds, d > 0.05, bytes > 0 else { return nil }
        return Double(bytes) / d
    }

    /// "noch 48 s", "noch 1:12 min", "noch 1:02 h" – whole seconds, in the style of the finished rows (`DurationFormat.seconds`).
    /// Every surface (shelf bubble, popover row, incoming card) shows the ETA through this.
    static func eta(_ seconds: Double) -> String {
        "noch " + DurationFormat.seconds(max(1, seconds.rounded()))
    }

    func cancel() {
        outgoing?.cancel()
        incoming?.cancel()
        taildrop?.cancel()
        if !state.isTerminal { state = .cancelled(nil) }
    }
}

/// What went out last and where to – the popover's "Zuletzt" row and "Erneut senden".
struct LastPayload: Equatable {
    let urls: [URL]
    let deviceID: String
    let deviceName: String
    let at: Date

    /// Clipboard exports are deleted once sent, so only what still exists can be sent again.
    var existingURLs: [URL] { urls.filter { FileManager.default.fileExists(atPath: $0.path) } }
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var status: TailnetStatus?
    private(set) var tailscaleMissing = false
    private(set) var devices: [Device] = []
    private(set) var hasRefreshed = false
    /// A discovery round is running (the popover shows "Suche…" meanwhile).
    private(set) var isRefreshing = false
    var transfers: [TransferItem] = []
    private(set) var serverError: String?
    private(set) var lastPayload: LastPayload? = AppModel.loadLastPayload()

    @ObservationIgnored private var seen: [String: (hello: HelloInfo, at: Date)] = [:]
    @ObservationIgnored private var refreshing = false
    /// `TAILBOLT_DEMO=1`: a fixed example tailnet replaces discovery (for public screenshots).
    @ObservationIgnored private(set) var demoMode = false
    @ObservationIgnored private var server: TailboltServer?
    @ObservationIgnored private var tick: Timer?
    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private let serverDelegate = ServerBridge()
    /// Number of visible UI surfaces that want fresh discovery data.
    @ObservationIgnored var visibleSurfaces = 0 {
        didSet { if visibleSurfaces > oldValue { refresh(); nudgeIdlePeers() } }
    }

    @ObservationIgnored private var lastNudge = Date.distantPast

    /// Tailscale only knows the path to a peer once traffic flows. Pinging idle peers when a surface opens
    /// upgrades DERP-only paths to direct before the user even picks a device.
    private func nudgeIdlePeers() {
        guard Date().timeIntervalSince(lastNudge) > 20, let status else { return }
        lastNudge = Date()
        let idle = devices.filter { $0.peer.path == .unknown || $0.peer.path == .relay }.prefix(6).map(\.peer.address)
        guard !idle.isEmpty else { return }
        _ = status
        DispatchQueue.global(qos: .utility).async {
            DispatchQueue.concurrentPerform(iterations: idle.count) { i in Tailnet.nudge(idle[i]) }
        }
    }

    var myName: String {
        status?.selfName ?? Host.current().localizedName ?? "Mac"
    }

    var activeTransfers: [TransferItem] { transfers.filter(\.isActive) }

    func start() {
        // The name is read on the accept thread, hence the cached copy.
        let server = TailboltServer { [weak self] in self?.cachedName ?? "Mac" }
        serverDelegate.model = self
        server.delegate = serverDelegate
        server.lanFastPathEnabled = Settings.shared.lanTurboEnabled
        server.compressionEnabled = Settings.shared.lz4Enabled
        do {
            try server.start()
        } catch {
            serverError = "\(error)"
        }
        self.server = server

        tick = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick() }
        }
        refresh()
    }

    @ObservationIgnored private nonisolated(unsafe) var cachedName = Host.current().localizedName ?? "Mac"

    // MARK: discovery

    func refresh() {
        guard !refreshing, !demoMode else { return }
        refreshing = true
        isRefreshing = true
        lastRefresh = Date()
        let name = myName
        DispatchQueue.global(qos: .userInitiated).async {
            let (status, found) = Self.discover(myName: name)
            DispatchQueue.main.async { self.apply(status, found) }
        }
    }

    /// Asks Tailscale for the peer list, then says hello to every online peer in parallel.
    private nonisolated static func discover(myName: String) -> (TailnetStatus?, [String: HelloInfo]) {
        guard let status = Tailnet.status() else { return (nil, [:]) }
        let candidates = status.peers.filter { $0.online && $0.os.lowercased() != "tvos" }
        let lock = NSLock()
        var found: [String: HelloInfo] = [:]
        DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
            let peer = candidates[i]
            if let h = Probe.hello(host: peer.address, timeout: 1.2, myName: myName) {
                lock.lock(); found[peer.id] = h; lock.unlock()
            }
        }
        return (status, found)
    }

    /// Explains slow transfers: a relayed path, or macOS Tailscale's known throughput collapse
    /// (direct LAN path yet < 150 Mbit/s and no LAN-turbo streams — restarting Tailscale fixes it).
    private func updateHints(_ now: Date) {
        for item in transfers where item.direction == .outgoing && item.state == .transferring {
            if item.startedTransferringAt == nil { item.startedTransferringAt = now }
            guard item.taildrop == nil, let id = item.deviceID,
                  let device = devices.first(where: { $0.id == id }) else { continue }
            let elapsed = now.timeIntervalSince(item.startedTransferringAt ?? now)
            var hint: String?
            if device.peer.path == .relay && !item.usesLAN {
                hint = "Läuft über einen Relay-Server (UDP blockiert?) – deutlich langsamer als direkt."
            } else if elapsed > 6, item.speed > 0, item.speed < 18_000_000, !item.usesLAN,
                      device.peer.path == .lan || device.peer.path == .direct {
                hint = "Tailscale ist gerade ungewöhnlich langsam (macOS-Bug) – Tailscale beenden und neu starten hilft."
            }
            if item.hint != hint { item.hint = hint }
        }
    }

    private func apply(_ status: TailnetStatus?, _ found: [String: HelloInfo]) {
        refreshing = false
        isRefreshing = false
        hasRefreshed = true
        tailscaleMissing = Tailnet.cliPath == nil
        self.status = status
        if let status { cachedName = status.selfName }
        let now = Date()
        for (id, h) in found { seen[id] = (h, now) }
        // Keep a device for a little while after a missed probe so the UI doesn't flicker.
        seen = seen.filter { now.timeIntervalSince($0.value.at) < 75 }
        rebuildDevices()
    }

    private func rebuildDevices() {
        guard let status else { devices = []; return }
        let recent = Settings.shared.recentDeviceIDs
        var list: [Device] = []
        for peer in status.peers where peer.online {
            if let h = seen[peer.id]?.hello {
                list.append(Device(peer: peer, hello: h))
            } else if peer.isMine && peer.taildropAvailable {
                list.append(Device(peer: peer, hello: nil))
            }
        }
        func rank(_ d: Device) -> (Int, Int, String) {
            let r = recent.firstIndex(of: d.id) ?? 1000
            return (d.viaTaildrop ? 1 : 0, r, d.name.lowercased())
        }
        devices = list.sorted { rank($0) < rank($1) }
    }

    /// Replaces the real tailnet with example devices so screenshots never show real names or addresses.
    func useDemoTailnet() {
        demoMode = true
        let lanHost: String = {
            guard let a = LocalNetwork.ipv4Interfaces().first?.address else { return "192.168.1.23" }
            return a.split(separator: ".").dropLast().joined(separator: ".") + ".23"
        }()
        let peers: [TailnetPeer] = [
            .make(id: "demo-noah", hostName: "Noahs MacBook Pro", dnsName: "noahs-macbook-pro.example.ts.net",
                  ips: ["100.101.1.1"], os: "macOS",
                  user: .make(id: 11, loginName: "noah@example.com", displayName: "Noah Meier"),
                  curAddr: "\(lanHost):41641", active: true),
            .make(id: "demo-lena", hostName: "Lena – Mac Studio", dnsName: "lena-mac-studio.example.ts.net",
                  ips: ["100.101.1.2"], os: "macOS",
                  user: .make(id: 12, loginName: "lena@example.com", displayName: "Lena Keller"),
                  curAddr: "203.0.113.7:41641"),
            .make(id: "demo-server", hostName: "home-server", dnsName: "home-server.example.ts.net",
                  ips: ["100.101.1.3"], os: "linux", isMine: true, relay: "fra", active: true),
            .make(id: "demo-iphone", hostName: "Mein iPhone", dnsName: "mein-iphone.example.ts.net",
                  ips: ["100.101.1.4"], os: "iOS", isMine: true, taildropAvailable: true),
        ]
        status = .make(selfName: "Saras MacBook Air",
                       selfUser: .make(id: 10, loginName: "sara@example.com", displayName: "Sara Meier"),
                       selfIPs: ["100.101.1.9"], peers: peers, tailnetName: "example.ts.net")
        cachedName = "Saras MacBook Air"
        hasRefreshed = true
        tailscaleMissing = false
        let now = Date()
        seen = [:]
        for p in peers where !p.taildropAvailable {
            seen[p.id] = (HelloInfo(name: p.hostName, os: p.os, app: Tailbolt.appVersion), now)
        }
        rebuildDevices()
    }

    func debugSeen(_ peer: TailnetPeer) {
        seen[peer.id] = (HelloInfo(name: peer.displayName, os: peer.os, app: ""), Date())
        rebuildDevices()
    }

    fileprivate func sawHello(from ip: String) {
        guard let peer = status?.peers.first(where: { $0.ips.contains(ip) }) else {
            if Date().timeIntervalSince(lastRefresh) > 3 { refresh() }
            return
        }
        if seen[peer.id] == nil {
            seen[peer.id] = (HelloInfo(name: peer.displayName, os: peer.os, app: ""), Date())
            rebuildDevices()
        } else {
            seen[peer.id]?.at = Date()
        }
    }

    private func onTick() {
        let now = Date()
        for item in transfers where item.isActive {
            if item.state == .transferring && item.startedTransferringAt == nil { item.startedTransferringAt = now }
            let core: TransferBase? = item.outgoing ?? item.incoming
            guard let core else { continue }
            item.bytes = core.bytesTransferred
            let st = core.stats
            if st.lanStreams > 0 && !item.everUsedLAN { item.everUsedLAN = true }
            if st.lanStreams != item.lanStreams { item.lanStreams = st.lanStreams }
            if st.tailnetStreams != item.tailnetStreams { item.tailnetStreams = st.tailnetStreams }
            if st.bytesSavedByCompression != item.bytesSaved { item.bytesSaved = st.bytesSavedByCompression }
            if item.state == .transferring {
                if let (t, b) = item.lastSample {
                    let dt = now.timeIntervalSince(t)
                    if dt >= 0.5 {
                        let inst = Double(item.bytes - b) / dt
                        item.speed = item.speed == 0 ? inst : item.speed * 0.6 + inst * 0.4
                        item.lastSample = (now, item.bytes)
                    }
                } else {
                    item.lastSample = (now, item.bytes)
                }
            }
        }
        updateHints(now)
        syncServerSettings()
        let interval: TimeInterval = visibleSurfaces > 0 ? 6 : 30
        if now.timeIntervalSince(lastRefresh) > interval { refresh() }
    }

    /// Einstellungen → Senden (LAN-Turbo, LZ4) also govern what we offer senders; kept in step on every tick.
    private func syncServerSettings() {
        guard let server else { return }
        let settings = Settings.shared
        if server.lanFastPathEnabled != settings.lanTurboEnabled { server.lanFastPathEnabled = settings.lanTurboEnabled }
        if server.compressionEnabled != settings.lz4Enabled { server.compressionEnabled = settings.lz4Enabled }
    }

    // MARK: last payload

    private static let lastPayloadKey = "lastPayload"

    private static func loadLastPayload() -> LastPayload? {
        guard let raw = UserDefaults.standard.dictionary(forKey: lastPayloadKey),
              let paths = raw["paths"] as? [String], let id = raw["deviceID"] as? String,
              let name = raw["deviceName"] as? String, let at = raw["at"] as? Double, !paths.isEmpty else { return nil }
        return LastPayload(urls: paths.map { URL(fileURLWithPath: $0) }, deviceID: id, deviceName: name, at: Date(timeIntervalSince1970: at))
    }

    private func rememberPayload(_ urls: [URL], to device: Device, persist: Bool = true) {
        guard !urls.isEmpty else { return }
        lastPayload = LastPayload(urls: urls, deviceID: device.id, deviceName: device.name, at: Date())
        guard persist else { return }
        UserDefaults.standard.set(["paths": urls.map(\.path), "deviceID": device.id, "deviceName": device.name,
                                   "at": Date().timeIntervalSince1970], forKey: Self.lastPayloadKey)
    }

    /// Dev aid (`--snapshot`): a "Zuletzt" row without touching the user's defaults.
    func debugSetLastPayload(_ urls: [URL], to device: Device) {
        rememberPayload(urls, to: device, persist: false)
    }

    /// "Erneut senden": the last payload to the same device again. Falls back to the shelf (with the files loaded)
    /// when that device is not online right now.
    @discardableResult
    func resendLast() -> TransferItem? {
        guard let last = lastPayload else { return nil }
        let urls = last.existingURLs
        guard !urls.isEmpty else {
            ToastController.shared.flash("Die Dateien von damals gibt es nicht mehr", symbol: "doc.questionmark", tone: .error, duration: 3)
            return nil
        }
        if let device = devices.first(where: { $0.id == last.deviceID }) { return send(urls, to: device) }
        ShelfController.shared.show(at: nil, files: urls, keyboard: true)
        ToastController.shared.flash("\(last.deviceName) ist nicht online", symbol: "wifi.slash", tone: .error, duration: 3)
        return nil
    }

    // MARK: always accept

    /// Offers from this peer skip the card: on the "Immer annehmen" list, or a favorite while that setting is on.
    func isAlwaysAccepted(peerID: String?) -> Bool {
        guard let peerID else { return false }
        let settings = Settings.shared
        if settings.alwaysAccepts(peerID) { return true }
        return settings.autoAcceptFavorites && settings.favoriteSlot(of: peerID) != nil
    }

    // MARK: sending

    /// Zero-UI path (hotkeys): sends to a device by id and lets the HUD toast report progress.
    /// nil when that device is not online right now.
    @discardableResult
    func sendDirect(_ urls: [URL], to deviceID: String) -> TransferItem? {
        guard let device = devices.first(where: { $0.id == deviceID }) else { return nil }
        let item = send(urls, to: device)
        ToastController.shared.track(item)
        return item
    }

    @discardableResult
    func send(_ urls: [URL], to device: Device) -> TransferItem {
        Settings.shared.noteUsed(device.id, name: device.name)
        rememberPayload(urls, to: device)
        let item = TransferItem(direction: .outgoing, deviceID: device.id, peerName: device.name,
                                peerSymbol: device.symbol, names: urls.map(\.lastPathComponent))
        item.sourceURLs = urls
        item.onEnd = { ClipboardPackager.release(urls) }
        transfers.insert(item, at: 0)
        trimHistory()

        if device.viaTaildrop {
            if urls.contains(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }) {
                item.state = .failed("Ordner gehen via Taildrop nicht – Tailbolt auf dem Gerät installieren")
                return item
            }
            item.totalBytes = urls.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
            let td = TaildropTransfer(target: device.peer.address, urls: urls)
            item.taildrop = td
            item.state = .transferring
            td.onFinish = { error in
                DispatchQueue.main.async {
                    guard !item.state.isTerminal else { return }
                    item.state = error.map { .failed($0) } ?? .finished
                    item.finishedAt = Date()
                }
            }
            td.start()
            return item
        }

        let host = device.peer.address
        let name = myName
        let lanHint = Settings.shared.lanTurboEnabled && device.peer.path == .lan ? device.peer.directHost : nil
        let compress = Settings.shared.lz4Enabled
        Task.detached(priority: .userInitiated) {
            do {
                let t = try OutgoingTransfer(host: host, urls: urls, myName: name)
                t.peerLANHint = lanHint
                t.compressionEnabled = compress
                await MainActor.run {
                    guard !item.state.isTerminal else { return }
                    item.outgoing = t
                    item.totalBytes = t.totalBytes
                    t.onStateChange = { s in
                        DispatchQueue.main.async {
                            item.state = s
                            if s == .transferring { item.lastSample = nil }
                            if s.isTerminal {
                                item.bytes = t.bytesTransferred
                                item.finishedAt = Date()
                            }
                            // Sound + haptic once per transfer, whichever surface (or none) shows it.
                            if s == .finished { Feedback.transferFinished(item) }
                        }
                    }
                    t.start()
                }
            } catch {
                await MainActor.run { item.state = .failed(error.localizedDescription) }
            }
        }
        return item
    }

    private func trimHistory() {
        let finished = transfers.filter { !$0.isActive }
        if finished.count > 30 {
            let drop = Set(finished.suffix(finished.count - 30).map(\.id))
            transfers.removeAll { drop.contains($0.id) }
        }
    }

    // MARK: receiving

    fileprivate func received(_ t: IncomingTransfer) {
        let peer = status?.peers.first { $0.ips.contains(t.remoteAddress) }
        let isLocal = t.remoteAddress == "127.0.0.1" || t.remoteAddress == "::1" || status?.selfIPs.contains(t.remoteAddress) == true
        let name = peer?.displayName ?? t.senderName
        let item = TransferItem(direction: .incoming, deviceID: peer?.id, peerName: name,
                                peerSymbol: DeviceSymbol.for(os: peer?.os ?? "macOS", name: name),
                                names: t.topLevelNames)
        item.incoming = t
        item.totalBytes = t.totalBytes
        item.state = .waiting
        transfers.insert(item, at: 0)
        trimHistory()

        t.onStateChange = { s in
            DispatchQueue.main.async {
                item.state = s
                if s != .waiting { item.awaitingDecision = false }
                if s == .transferring { item.lastSample = nil }
                if s.isTerminal {
                    item.finishedAt = Date()
                    item.bytes = t.bytesTransferred
                    item.savedURLs = t.savedURLs
                    if s == .finished { Self.announce(t.savedURLs) }
                    if s == .finished, item.revealWhenFinished, !t.savedURLs.isEmpty {
                        NSWorkspace.shared.activateFileViewerSelecting(t.savedURLs)
                    }
                }
            }
        }

        let trusted = isAlwaysAccepted(peerID: peer?.id)
        if (Settings.shared.autoAcceptOwnDevices && (peer?.isMine == true || isLocal)) || trusted {
            accept(item)
        } else {
            item.awaitingDecision = true
            Sounds.incoming()
        }
        IncomingPanelController.shared.update()
    }

    func accept(_ item: TransferItem) {
        item.awaitingDecision = false
        item.incoming?.accept(into: Settings.shared.downloadDirectory)
    }

    func decline(_ item: TransferItem) {
        item.awaitingDecision = false
        item.incoming?.decline()
    }

    /// Bounces the Downloads stack in the Dock like Safari does.
    private static func announce(_ urls: [URL]) {
        for url in urls {
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: url.path)
        }
    }
}

/// Server callbacks arrive on background threads; hop to the main actor here.
private final class ServerBridge: TailboltServerDelegate {
    weak var model: AppModel?

    func server(_ server: TailboltServer, didReceiveOffer transfer: IncomingTransfer) {
        DispatchQueue.main.async { [weak model] in model?.received(transfer) }
    }

    func server(_ server: TailboltServer, didSeeHello info: HelloInfo, from ip: String) {
        DispatchQueue.main.async { [weak model] in model?.sawHello(from: ip) }
    }
}
