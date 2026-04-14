import Foundation
import Network

let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
var timestampOn: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_TIMESTAMP, &timestampOn, socklen_t(MemoryLayout<Int32>.size))

var addr = sockaddr_in()
addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
addr.sin_family = sa_family_t(AF_INET)
addr.sin_port = in_port_t(0) // auto
addr.sin_addr.s_addr = INADDR_ANY.bigEndian

let bindResult = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}

// Find bound port
var boundAddr = sockaddr_in()
var len = socklen_t(MemoryLayout<sockaddr_in>.size)
withUnsafeMutablePointer(to: &boundAddr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(fd, $0, &len)
    }
}
let boundPort = Int(UInt16(bigEndian: boundAddr.sin_port))
print("Bound to port: \(boundPort)")

let senderFd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
var targetAddr = sockaddr_in()
targetAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
targetAddr.sin_family = sa_family_t(AF_INET)
targetAddr.sin_port = in_port_t(boundPort).bigEndian
inet_pton(AF_INET, "127.0.0.1", &targetAddr.sin_addr)

let msgData = "Hello".data(using: .utf8)!
msgData.withUnsafeBytes { ptr in
    withUnsafePointer(to: &targetAddr) { tAddr in
        tAddr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            sendto(senderFd, ptr.baseAddress, ptr.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
}

// Recv
let bufferSize = 65536
let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
let controlBufSize = 256
let controlBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: controlBufSize)

var iov = iovec(iov_base: buffer, iov_len: Int(bufferSize))
var msg = msghdr()

msg.msg_name = nil
msg.msg_namelen = 0
msg.msg_iov = withUnsafeMutablePointer(to: &iov) { $0 }
msg.msg_iovlen = 1
msg.msg_control = UnsafeMutableRawPointer(controlBuf)
msg.msg_controllen = socklen_t(controlBufSize)
msg.msg_flags = 0

let bytesRead = recvmsg(fd, &msg, 0)
print("Bytes read: \(bytesRead)")
print("Msg controllen: \(msg.msg_controllen)")

if let controlPtr = msg.msg_control, msg.msg_controllen >= 12 {
    let cmsgPtr = controlPtr.assumingMemoryBound(to: cmsghdr.self)
    print("cmsg_len: \(cmsgPtr.pointee.cmsg_len)")
    print("cmsg_level: \(cmsgPtr.pointee.cmsg_level)")
    print("cmsg_type: \(cmsgPtr.pointee.cmsg_type)")
} else {
    print("No control message")
}
