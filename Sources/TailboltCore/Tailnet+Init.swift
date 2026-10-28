import Foundation

// Public factories so app targets can build peers for demos, previews and tests
// (the values parsed from `tailscale status` keep using the internal memberwise inits).

extension TailnetUser {
    public static func make(id: Int64, loginName: String, displayName: String, profilePicURL: URL? = nil) -> TailnetUser {
        TailnetUser(id: id, loginName: loginName, displayName: displayName, profilePicURL: profilePicURL)
    }
}

extension TailnetPeer {
    public static func make(id: String, hostName: String, dnsName: String = "", ips: [String] = [], os: String, online: Bool = true,
                            user: TailnetUser? = nil, isMine: Bool = false, taildropAvailable: Bool = false,
                            curAddr: String = "", relay: String = "", peerRelay: String = "", active: Bool = false) -> TailnetPeer {
        TailnetPeer(id: id, hostName: hostName, dnsName: dnsName, ips: ips, os: os, online: online, user: user,
                    isMine: isMine, taildropAvailable: taildropAvailable, curAddr: curAddr, relay: relay, peerRelay: peerRelay, active: active)
    }
}

extension TailnetStatus {
    public static func make(selfName: String, selfUser: TailnetUser?, selfIPs: [String], peers: [TailnetPeer],
                            running: Bool = true, tailnetName: String?) -> TailnetStatus {
        TailnetStatus(selfName: selfName, selfUser: selfUser, selfIPs: selfIPs, peers: peers, running: running, tailnetName: tailnetName)
    }
}
