import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Session key handed from receiver to sender inside the (WireGuard-protected) accept message.
/// LAN data connections bypass Tailscale, so they carry their own encryption derived from it.
public struct SessionKey: Sendable {
    public let bytes: Data   // 32 bytes

    public static func random() -> SessionKey {
        SessionKey(bytes: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    public init?(base64: String) {
        guard let d = Data(base64Encoded: base64), d.count == 32 else { return nil }
        bytes = d
    }

    init(bytes: Data) { self.bytes = bytes }

    public var base64: String { bytes.base64EncodedString() }

    /// Every data connection gets its own key (HKDF over the connection index), so each side can use
    /// a simple counter nonce without ever reusing (key, nonce) across connections.
    func connectionKey(transferID: String, connection: Int) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: bytes),
                               salt: Data(transferID.utf8),
                               info: Data("tailbolt-lan-v2/\(connection)".utf8),
                               outputByteCount: 32)
    }
}

/// AES-256-GCM record layer over a plain socket (hardware AES: 7–9 GB/s per core on Apple Silicon).
/// Wire format per record: `uint32 big-endian length` + ciphertext + 16-byte tag.
/// Nonce = 4-byte direction + 8-byte counter, AAD = transfer id. Both sides see the identical plaintext
/// byte stream as the plain protocol, so all framing code is shared.
public final class SecureStream: ByteStream {
    public enum Role { case sender, receiver }

    static let maxRecord = 1 << 20

    private let socket: Socket
    private let key: SymmetricKey
    private let aad: Data
    private let sealDirection: UInt32
    private let openDirection: UInt32
    private var sealCounter: UInt64 = 0
    private var openCounter: UInt64 = 0
    private var plain = Data()
    private var plainOffset = 0
    private var recordBuffer = Data(count: maxRecord + 16)

    public var remoteAddress: String { socket.remoteAddress }

    public init(socket: Socket, key: SessionKey, transferID: String, connection: Int, role: Role) {
        self.socket = socket
        self.key = key.connectionKey(transferID: transferID, connection: connection)
        self.aad = Data(transferID.utf8)
        self.sealDirection = role == .sender ? 1 : 2
        self.openDirection = role == .sender ? 2 : 1
    }

    private static func nonce(_ direction: UInt32, _ counter: UInt64) -> AES.GCM.Nonce {
        var bytes = Data(count: 12)
        bytes.withUnsafeMutableBytes { p in
            p.storeBytes(of: direction.bigEndian, as: UInt32.self)
            p.storeBytes(of: counter.bigEndian, toByteOffset: 4, as: UInt64.self)
        }
        return try! AES.GCM.Nonce(data: bytes)
    }

    public func sendAll(_ ptr: UnsafeRawPointer, _ count: Int) throws {
        var off = 0
        while off < count {
            let n = min(SecureStream.maxRecord, count - off)
            let box = try AES.GCM.seal(UnsafeRawBufferPointer(start: ptr + off, count: n), using: key,
                                       nonce: SecureStream.nonce(sealDirection, sealCounter), authenticating: aad)
            sealCounter += 1
            var len = UInt32(box.ciphertext.count + box.tag.count).bigEndian
            try withUnsafeBytes(of: &len) { try socket.writev([$0, box.ciphertext.withUnsafeBytes { $0 }, box.tag.withUnsafeBytes { $0 }]) }
            off += n
        }
    }

    public func recvSome(_ ptr: UnsafeMutableRawPointer, _ count: Int) throws -> Int {
        if plainOffset >= plain.count {
            guard try fillRecord() else { return 0 }
        }
        let n = min(count, plain.count - plainOffset)
        plain.withUnsafeBytes { src in
            ptr.copyMemory(from: src.baseAddress! + plainOffset, byteCount: n)
        }
        plainOffset += n
        return n
    }

    /// Reads and authenticates the next record. Returns false on a clean EOF at a record boundary.
    private func fillRecord() throws -> Bool {
        var lenBytes: UInt32 = 0
        var got = 0
        try withUnsafeMutableBytes(of: &lenBytes) { p in
            while got < 4 {
                let n = try socket.recvSome(p.baseAddress! + got, 4 - got)
                if n == 0 {
                    if got == 0 { return }
                    throw SocketError("Verbindung geschlossen")
                }
                got += n
            }
        }
        if got == 0 { return false }
        let len = Int(UInt32(bigEndian: lenBytes))
        guard len >= 16, len <= SecureStream.maxRecord + 16 else { throw SocketError("Ungültiger Datensatz") }
        try recordBuffer.withUnsafeMutableBytes { try socket.recvExact($0.baseAddress!, len) }
        let box = try AES.GCM.SealedBox(nonce: SecureStream.nonce(openDirection, openCounter),
                                        ciphertext: recordBuffer[0..<(len - 16)], tag: recordBuffer[(len - 16)..<len])
        do {
            plain = try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw AuthenticationFailure()
        }
        openCounter += 1
        plainOffset = 0
        return true
    }

    public func setReceiveTimeout(_ seconds: TimeInterval) { socket.setReceiveTimeout(seconds) }
    public func shutdown() { socket.shutdown() }
    public func close() { socket.close() }
}

/// A LAN record failed to authenticate — wrong key, replay, or someone who isn't our peer.
public struct AuthenticationFailure: Error, CustomStringConvertible {
    public var description: String { "Authentifizierung der LAN-Verbindung fehlgeschlagen" }
}
