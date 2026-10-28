import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct SocketError: Error, CustomStringConvertible {
    public let message: String
    /// English text for the peer when this error is reported over the wire; `message` may be localized.
    public let english: String
    public init(_ message: String) { self.message = message; self.english = message }
    public init(_ message: String, english: String) { self.message = message; self.english = english }
    static func errno(_ what: String) -> SocketError {
        SocketError("\(what): \(String(cString: strerror(Foundation.errno)))")
    }
    public var description: String { message }
}

/// Anything the protocol can run over: a plain tailnet TCP socket or an encrypted LAN connection.
public protocol ByteStream: AnyObject {
    var remoteAddress: String { get }
    func sendAll(_ ptr: UnsafeRawPointer, _ count: Int) throws
    /// Reads up to `count` bytes. Returns 0 on orderly shutdown.
    func recvSome(_ ptr: UnsafeMutableRawPointer, _ count: Int) throws -> Int
    func recvExact(_ ptr: UnsafeMutableRawPointer, _ count: Int) throws
    func setReceiveTimeout(_ seconds: TimeInterval)
    func shutdown()
    func close()
}

extension ByteStream {
    public func sendAll(_ data: Data) throws {
        try data.withUnsafeBytes { try sendAll($0.baseAddress!, $0.count) }
    }

    public func recvExact(_ ptr: UnsafeMutableRawPointer, _ count: Int) throws {
        var got = 0
        while got < count {
            let n = try recvSome(ptr + got, count - got)
            if n == 0 { throw SocketError(String(localized: "Connection closed")) }
            got += n
        }
    }
}

/// Thin blocking wrapper around a TCP socket. All transfer I/O runs on dedicated threads,
/// so blocking calls keep the hot path simple and fast.
public final class Socket: ByteStream {
    public let fd: Int32
    public let remoteAddress: String
    private var closed = false
    private let lock = NSLock()

    static let bufferSize: Int32 = 8 << 20

    init(fd: Int32, remoteAddress: String) {
        self.fd = fd
        self.remoteAddress = remoteAddress
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var size = Socket.bufferSize
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        tuneLiveness(dead: 20)
    }

    deinit { close() }

    /// Makes a silently dead link fail within ~`dead` seconds instead of minutes: keepalive probes every 5 s
    /// after 10 s idle, and a retransmission-drop timer. Blocked sends give up after `dead` + 10 s.
    public func tuneLiveness(dead: Int32) {
        #if canImport(Darwin)
        var v: Int32 = 10
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &v, socklen_t(MemoryLayout<Int32>.size))
        v = 5
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &v, socklen_t(MemoryLayout<Int32>.size))
        v = 3
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &v, socklen_t(MemoryLayout<Int32>.size))
        v = dead
        setsockopt(fd, IPPROTO_TCP, TCP_RXT_CONNDROPTIME, &v, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var tv = timeval(tv_sec: Int(dead) + 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Gathers several buffers into one send (header + payload without a user-space copy).
    public func writev(_ parts: [UnsafeRawBufferPointer]) throws {
        var iov = parts.map { iovec(iov_base: UnsafeMutableRawPointer(mutating: $0.baseAddress), iov_len: $0.count) }
        var total = parts.reduce(0) { $0 + $1.count }
        while total > 0 {
            let n = Darwin.writev(fd, &iov, Int32(iov.count))
            if n < 0 {
                if Foundation.errno == EINTR { continue }
                if Foundation.errno == EAGAIN || Foundation.errno == EWOULDBLOCK { throw SocketError(String(localized: "Timed out while sending")) }
                throw SocketError.errno("send")
            }
            if n == 0 { throw SocketError(String(localized: "Connection closed")) }
            var left = n
            total -= n
            // Drop fully written parts, advance the partially written one.
            while left > 0, let first = iov.first {
                if first.iov_len <= left {
                    left -= first.iov_len
                    iov.removeFirst()
                } else {
                    iov[0].iov_base = first.iov_base! + left
                    iov[0].iov_len = first.iov_len - left
                    left = 0
                }
            }
        }
    }

    /// Connects with a timeout (non-blocking connect + poll), then switches back to blocking mode.
    public static func connect(host: String, port: UInt16, timeout: TimeInterval) throws -> Socket {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = Int32(SOCK_STREAM)
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let first = res else {
            throw SocketError(String(localized: "Can’t resolve address \(host)"))
        }
        defer { freeaddrinfo(res) }

        var lastError = SocketError(String(localized: "Connection to \(host) failed"))
        var cur: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cur {
            cur = ai.pointee.ai_next
            let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if fd < 0 { continue }
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            var r = Darwin.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
            if r != 0 && Foundation.errno == EINPROGRESS {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let pr = poll(&pfd, 1, Int32(timeout * 1000))
                if pr == 1 {
                    var err: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                    r = err == 0 ? 0 : -1
                    if err != 0 { lastError = SocketError(String(localized: "Connection to \(host): \(String(cString: strerror(err)))")) }
                } else {
                    lastError = SocketError(String(localized: "Timed out connecting to \(host)"))
                    r = -1
                }
            } else if r != 0 {
                lastError = .errno("connect")
            }
            if r == 0 {
                _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
                return Socket(fd: fd, remoteAddress: host)
            }
            Darwin.close(fd)
        }
        throw lastError
    }

    public func setReceiveTimeout(_ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    public func sendAll(_ ptr: UnsafeRawPointer, _ count: Int) throws {
        var sent = 0
        while sent < count {
            let n = Darwin.send(fd, ptr + sent, count - sent, 0)
            if n < 0 {
                if Foundation.errno == EINTR { continue }
                if Foundation.errno == EAGAIN || Foundation.errno == EWOULDBLOCK { throw SocketError(String(localized: "Timed out while sending")) }
                throw SocketError.errno("send")
            }
            if n == 0 { throw SocketError(String(localized: "Connection closed")) }
            sent += n
        }
    }

    /// Reads up to `count` bytes. Returns 0 on orderly shutdown.
    public func recvSome(_ ptr: UnsafeMutableRawPointer, _ count: Int) throws -> Int {
        while true {
            let n = Darwin.recv(fd, ptr, count, 0)
            if n < 0 {
                if Foundation.errno == EINTR { continue }
                if Foundation.errno == EAGAIN || Foundation.errno == EWOULDBLOCK {
                    throw SocketError(String(localized: "Timed out"))
                }
                throw SocketError.errno("recv")
            }
            return n
        }
    }

    /// Non-destructive check whether the peer has hung up (used while blocked on user decisions).
    public func peerHasClosed() -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let r = poll(&pfd, 1, 0)
        if r <= 0 { return false }
        if pfd.revents & Int16(POLLHUP | POLLERR) != 0 { return true }
        var byte: UInt8 = 0
        let n = Darwin.recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return n == 0
    }

    public func shutdown() {
        lock.lock(); defer { lock.unlock() }
        if !closed { _ = Darwin.shutdown(fd, SHUT_RDWR) }
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        if !closed {
            closed = true
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }
}

/// Dual-stack TCP listener (IPv6 socket accepting mapped IPv4).
public final class Listener {
    private let fd: Int32
    public let port: UInt16

    public init(port: UInt16) throws {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.errno("socket") }
        var one: Int32 = 1
        var zero: Int32 = 0
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &zero, socklen_t(MemoryLayout<Int32>.size))
        var size = Socket.bufferSize
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        #if canImport(Darwin)
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        #endif
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_any
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard r == 0 else {
            let e = SocketError.errno(String(localized: "Port \(String(port)) in use"))
            Darwin.close(fd)
            throw e
        }
        guard listen(fd, 64) == 0 else {
            Darwin.close(fd)
            throw SocketError.errno("listen")
        }
        self.fd = fd
        self.port = port
    }

    public func accept() throws -> Socket {
        while true {
            var storage = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let cfd = withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(fd, $0, &len) }
            }
            if cfd < 0 {
                if Foundation.errno == EINTR || Foundation.errno == ECONNABORTED { continue }
                throw SocketError.errno("accept")
            }
            return Socket(fd: cfd, remoteAddress: Listener.describe(&storage))
        }
    }

    public func close() {
        _ = Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    static func describe(_ storage: inout sockaddr_storage) -> String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let len = socklen_t(storage.ss_len)
        _ = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }
        var s = String(cString: host)
        if s.hasPrefix("::ffff:") { s.removeFirst(7) }
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
        return s
    }
}

public enum TailnetAddress {
    /// Tailscale hands out 100.64.0.0/10 and fd7a:115c:a1e0::/48. Loopback is allowed for local testing.
    public static func isAllowed(_ ip: String) -> Bool {
        if ip == "127.0.0.1" || ip == "::1" { return true }
        if ip.lowercased().hasPrefix("fd7a:115c:a1e0:") { return true }
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, parts[0] == 100, (64...127).contains(parts[1]) { return true }
        return false
    }
}

/// `TAILBOLT_DEBUG=1` prints connection-level decisions to stderr (receiver guards, worker failures).
public enum Debug {
    public static let enabled = ProcessInfo.processInfo.environment["TAILBOLT_DEBUG"] == "1"
    public static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let ts = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
        FileHandle.standardError.write("[\(ts)] \(message())\n".data(using: .utf8)!)
    }
}
