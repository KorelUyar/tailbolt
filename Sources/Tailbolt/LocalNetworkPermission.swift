import Foundation
import Network

/// macOS 15+ asks "… möchte Geräte im lokalen Netzwerk finden" the first time an app talks to a LAN
/// address. Triggering that prompt deliberately (Apple's TN3179 trick: open a UDP connection to a
/// link-local address, send nothing) means it appears during setup instead of silently failing the
/// first LAN-turbo attempt mid-transfer. Tailscale traffic through utun never needs this permission.
enum LocalNetworkPermission {
    private static var connection: NWConnection?

    static func prime() {
        guard connection == nil else { return }
        let c = NWConnection(host: NWEndpoint.Host("fe80::1"), port: 48484, using: .udp)
        c.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled, .waiting:
                // Whatever the outcome, the system now knows the user's answer; drop the socket.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    connection?.cancel()
                    connection = nil
                }
            default: break
            }
        }
        connection = c
        c.start(queue: .global(qos: .utility))
    }
}
