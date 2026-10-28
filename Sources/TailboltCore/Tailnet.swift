import Foundation

public struct TailnetUser: Hashable, Sendable {
    public let id: Int64
    public let loginName: String
    public let displayName: String
    public let profilePicURL: URL?
}

public struct TailnetPeer: Identifiable, Hashable, Sendable {
    public let id: String
    public let hostName: String
    public let dnsName: String
    public let ips: [String]
    public let os: String
    public let online: Bool
    public let user: TailnetUser?
    public let isMine: Bool          // same Tailscale user as this machine
    public let taildropAvailable: Bool
    /// Endpoint of the current direct WireGuard path ("192.168.3.77:41641"), empty when relayed or idle.
    public let curAddr: String
    public let relay: String         // home DERP region ("fra") — always set, does NOT mean relayed
    public let peerRelay: String     // non-empty when traffic goes through a tailnet peer relay
    public let active: Bool          // packets exchanged with this peer within the last ~2 min

    public enum Path: Sendable, Equatable {
        case lan, direct, peerRelay, relay, unknown

        public var label: String {
            switch self {
            case .lan: return "Direkt (LAN)"
            case .direct: return "Direkt"
            case .peerRelay: return "Peer-Relay"
            case .relay: return "Relay"
            case .unknown: return ""
            }
        }
    }

    /// How traffic currently reaches this peer (per `tailscale status`): peer relay beats everything,
    /// a direct endpoint on one of our subnets is `.lan`, a direct endpoint elsewhere `.direct`,
    /// recent traffic without a direct endpoint means DERP, and an idle peer is simply unknown.
    public var path: Path {
        if !peerRelay.isEmpty { return .peerRelay }
        if let host = directHost { return LocalNetwork.isOnLocalSubnet(host) ? .lan : .direct }
        if active && !relay.isEmpty { return .relay }
        return .unknown
    }

    /// IP of the direct endpoint, if any (for same-LAN peers this is their LAN address).
    public var directHost: String? {
        guard !curAddr.isEmpty else { return nil }
        if curAddr.hasPrefix("[") {                       // [v6]:port
            return curAddr.dropFirst().split(separator: "]").first.map(String.init)
        }
        return curAddr.split(separator: ":").first.map(String.init)
    }

    /// iOS reports "localhost" as host name; the MagicDNS label is nicer there.
    public var displayName: String {
        let label = dnsName.split(separator: ".").first.map(String.init) ?? hostName
        if hostName.isEmpty || hostName == "localhost" { return label }
        return hostName
    }

    public var address: String { ips.first(where: { $0.contains(".") }) ?? ips.first ?? dnsName }
}

public struct TailnetStatus: Sendable {
    public let selfName: String
    public let selfUser: TailnetUser?
    public let selfIPs: [String]
    public let peers: [TailnetPeer]
    public let running: Bool
    public let tailnetName: String?
}

/// Local (non-Tailscale) interface addresses, used to spot peers on the same LAN.
public enum LocalNetwork {
    public struct Interface: Sendable {
        public let name: String
        public let address: String
        public let netmask: String
    }

    /// IPv4 interfaces that are up, not loopback and not the Tailscale utun.
    public static func ipv4Interfaces() -> [Interface] {
        var out: [Interface] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cur {
            cur = ifa.pointee.ifa_next
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  ifa.pointee.ifa_flags & UInt32(IFF_UP) != 0, ifa.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  ifa.pointee.ifa_flags & UInt32(IFF_POINTOPOINT) == 0 else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard let mask = ifa.pointee.ifa_netmask else { continue }
            let addr = ipv4String(sa), netmask = ipv4String(mask)
            guard !addr.isEmpty, TailnetAddress.isAllowed(addr) == false else { continue }
            out.append(Interface(name: name, address: addr, netmask: netmask))
        }
        return out
    }

    /// Addresses worth telling a peer about: private ranges on real Ethernet/Wi-Fi/Thunderbolt interfaces only —
    /// no VM bridges (bridge100, vmnet), no AP/diagnostic interfaces, no link-local, never a public IP.
    public static func advertisableAddresses() -> [String] {
        ipv4Interfaces().filter { i in
            let n = i.name
            let realNIC = n.hasPrefix("en") || n == "bridge0"
            return realNIC && isPrivate(i.address)
        }.prefix(4).map(\.address)
    }

    public static func isPrivate(_ ip: String) -> Bool {
        guard let v = ipv4Value(ip) else { return false }
        if v >> 24 == 10 { return true }                       // 10/8
        if v >> 20 == 0xAC1 { return true }                    // 172.16/12
        if v >> 16 == 0xC0A8 { return true }                   // 192.168/16
        return false
    }

    private static func ipv4String(_ sa: UnsafeMutablePointer<sockaddr>) -> String {
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
            var a = sin.pointee.sin_addr
            guard inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count)) != nil else { return "" }
            return String(cString: buf)
        }
    }

    public static func isOnLocalSubnet(_ host: String) -> Bool {
        guard let h = ipv4Value(host) else { return false }
        for i in ipv4Interfaces() {
            guard let a = ipv4Value(i.address), let m = ipv4Value(i.netmask) else { continue }
            if a & m == h & m { return true }
        }
        return false
    }

    static func ipv4Value(_ s: String) -> UInt32? {
        let p = s.split(separator: ".").compactMap { UInt32($0) }
        guard p.count == 4, p.allSatisfy({ $0 < 256 }) else { return nil }
        return p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]
    }
}

public enum Tailnet {
    public static let cliCandidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
        "/usr/bin/tailscale",
    ]

    public static var cliPath: String? {
        cliCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func status() -> TailnetStatus? {
        guard let cli = cliPath, let data = run(cli, ["status", "--json"]) else { return nil }
        return parse(data)
    }

    /// Makes Tailscale send disco traffic to a peer so an idle or DERP-only path upgrades to direct
    /// before the first byte of a transfer. Returns the endpoint line ("via 192.168.3.77:41641") if any.
    @discardableResult
    public static func nudge(_ ip: String) -> String? {
        guard let cli = cliPath, let data = run(cli, ["ping", "--c", "2", "--timeout", "2s", ip], timeout: 6),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").last.map(String.init)
    }

    static func parse(_ data: Data) -> TailnetStatus? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var users: [Int64: TailnetUser] = [:]
        for (_, raw) in root["User"] as? [String: Any] ?? [:] {
            guard let u = raw as? [String: Any], let id = (u["ID"] as? NSNumber)?.int64Value else { continue }
            users[id] = TailnetUser(id: id, loginName: u["LoginName"] as? String ?? "",
                                    displayName: u["DisplayName"] as? String ?? "",
                                    profilePicURL: (u["ProfilePicURL"] as? String).flatMap(URL.init(string:)))
        }
        let me = root["Self"] as? [String: Any] ?? [:]
        let myUserID = (me["UserID"] as? NSNumber)?.int64Value
        var peers: [TailnetPeer] = []
        for (key, raw) in root["Peer"] as? [String: Any] ?? [:] {
            guard let p = raw as? [String: Any] else { continue }
            let uid = (p["UserID"] as? NSNumber)?.int64Value
            peers.append(TailnetPeer(
                id: p["PublicKey"] as? String ?? key,
                hostName: p["HostName"] as? String ?? "",
                dnsName: p["DNSName"] as? String ?? "",
                ips: p["TailscaleIPs"] as? [String] ?? [],
                os: p["OS"] as? String ?? "",
                online: p["Online"] as? Bool ?? false,
                user: uid.flatMap { users[$0] },
                isMine: uid != nil && uid == myUserID,
                taildropAvailable: (p["TaildropTarget"] as? NSNumber)?.intValue == 1,
                curAddr: p["CurAddr"] as? String ?? "",
                relay: p["Relay"] as? String ?? "",
                peerRelay: p["PeerRelay"] as? String ?? "",
                active: p["Active"] as? Bool ?? false
            ))
        }
        let selfPeer = TailnetPeer(id: "self", hostName: me["HostName"] as? String ?? "", dnsName: me["DNSName"] as? String ?? "",
                                   ips: [], os: "", online: true, user: nil, isMine: true, taildropAvailable: false,
                                   curAddr: "", relay: "", peerRelay: "", active: true)
        return TailnetStatus(
            selfName: selfPeer.displayName,
            selfUser: myUserID.flatMap { users[$0] },
            selfIPs: me["TailscaleIPs"] as? [String] ?? [],
            peers: peers.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending },
            running: (root["BackendState"] as? String) == "Running",
            tailnetName: tailnetName(root)
        )
    }

    /// Tailnets of Apple-ID users are named "xyz@privaterelay.appleid.com"; the MagicDNS name reads better.
    static func tailnetName(_ root: [String: Any]) -> String? {
        let current = root["CurrentTailnet"] as? [String: Any]
        let name = current?["Name"] as? String
        let dns = current?["MagicDNSSuffix"] as? String ?? root["MagicDNSSuffix"] as? String
        if let name, !name.isEmpty, !name.contains("privaterelay.appleid.com") { return name }
        return dns ?? name
    }

    /// The Tailscale.app binary only acts as a CLI when told so; launched from Finder
    /// (no TERM in the environment) it would try to start its GUI instead.
    static func cliProcess(_ path: String, _ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["TAILSCALE_BE_CLI"] = "1"
        p.environment = env
        return p
    }

    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 5) -> Data? {
        let p = cliProcess(path, args)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }
}

/// Fallback for own devices without Tailbolt (e.g. iPhone today): hands files to Taildrop.
public final class TaildropTransfer: @unchecked Sendable {
    public let target: String
    public let urls: [URL]
    public private(set) var process: Process?
    public var onFinish: ((String?) -> Void)?

    public init(target: String, urls: [URL]) {
        self.target = target
        self.urls = urls
    }

    public func start() {
        guard let cli = Tailnet.cliPath else { onFinish?("Tailscale-CLI nicht gefunden"); return }
        let p = Tailnet.cliProcess(cli, ["file", "cp", "--update-interval=0"] + urls.map(\.path) + ["\(target):"])
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self?.onFinish?(proc.terminationStatus == 0 ? nil : (msg?.isEmpty == false ? msg : "Taildrop fehlgeschlagen"))
        }
        process = p
        do { try p.run() } catch { onFinish?("\(error)") }
    }

    public func cancel() { process?.terminate() }
}
