// [INPUT]: 已安装的本机虚拟键盘桥，固定单字节请求和回执。
// [OUTPUT]: 一次左 Control + 左 Option + V、Q 或 T。回执不代表听写状态。
// [POS]: 仅在遥控器所有权及回车屏蔽均已确认后调用。
import Darwin
import Foundation

enum TypelessBridge {
    private static let path = "/var/run/sayall-vhid-bridge.sock"

    static var available: Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK && info.st_uid == getuid()
            && info.st_mode & 0o077 == 0
    }

    static func post(_ command: UInt8) -> Bool {
        guard [0x76, 0x71, 0x74].contains(command), available else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: 800_000)
        var yes: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) == 0,
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0,
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0
        else { return false }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        address.sun_len = UInt8(length)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8CString.map { UInt8(bitPattern: $0) })
        }
        // A full socket backlog must never wedge the HID run loop.
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
        }
        guard connected == 0, fcntl(fd, F_SETFL, flags) == 0 else { return false }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == 0 else { return false }
        var request = command
        var reply: UInt8 = 0
        return write(fd, &request, 1) == 1 && read(fd, &reply, 1) == 1 && reply == 0x31
    }
}
