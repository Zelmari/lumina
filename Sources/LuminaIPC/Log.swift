import Foundation
#if os(macOS)
import Darwin
import OSLog
#elseif canImport(Glibc)
import Glibc
#endif

public enum LogCategory: String, Sendable {
    case agent
    case extra
    case cli
}

public final class LuminaLog: @unchecked Sendable {
    public var debugEnabled: Bool
    public let category: LogCategory
    private let fileURL: URL?
    private let lock = NSLock()
    private var appendFD: Int32 = -1
    private var appendInode: UInt64 = 0
    /// Rotate to `<name>.1` once the log passes this size.
    private let maxLogBytes: off_t = 10 * 1024 * 1024
    private let stamp: DateFormatter
    #if os(macOS)
    private let oslog: Logger
    #endif

    public init(category: LogCategory, fileURL: URL? = nil, debugEnabled: Bool? = nil) {
        self.category = category
        self.fileURL = fileURL
        if let debugEnabled {
            self.debugEnabled = debugEnabled
        } else {
            self.debugEnabled = ProcessInfo.processInfo.environment["LUMINA_DEBUG"] == "1"
        }
        #if os(macOS)
        oslog = Logger(subsystem: "com.zelmari.lumina", category: category.rawValue)
        #endif
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        stamp = formatter
    }

    public static func defaultFileURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Logs/Lumina.log")
    }

    public func info(_ message: String) {
        write(level: "info", message: message)
    }

    public func debug(_ message: String) {
        guard debugEnabled else { return }
        write(level: "debug", message: message)
    }

    public func error(_ message: String) {
        write(level: "error", message: message)
        if category == .cli {
            if let data = (message + "\n").data(using: .utf8) {
                try? FileHandle.standardError.write(contentsOf: data)
            }
        }
    }

    private func write(level: String, message: String) {
        #if os(macOS)
        switch level {
        case "error": oslog.error("\(message, privacy: .public)")
        case "debug": oslog.debug("\(message, privacy: .public)")
        default: oslog.info("\(message, privacy: .public)")
        }
        #endif
        guard let fileURL else { return }
        lock.lock()
        defer { lock.unlock() }
        let line = "[\(stamp.string(from: Date()))] [\(category.rawValue)] \(level) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let fd = openedAppendFD(fileURL)
        guard fd >= 0 else { return }
        flockFD(fd, lock: true)
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                _ = systemWrite(fd, base, raw.count)
            }
        }
        flockFD(fd, lock: false)
    }

    private func openedAppendFD(_ fileURL: URL) -> Int32 {
        if appendFD >= 0 {
            var st = stat()
            if stat(fileURL.path, &st) == 0, UInt64(st.st_ino) == appendInode, st.st_size <= maxLogBytes {
                return appendFD
            }
            // Missing, replaced (external rotation/truncation), or past the
            // size cap: drop the cached fd and reopen.
            close(appendFD)
            appendFD = -1
        }
        rotateLogIfNeeded(fileURL)
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, mode_t(0o644))
        appendFD = fd
        if fd >= 0 {
            var st = stat()
            appendInode = stat(fileURL.path, &st) == 0 ? UInt64(st.st_ino) : 0
        }
        return fd
    }

    private func rotateLogIfNeeded(_ fileURL: URL) {
        var st = stat()
        guard stat(fileURL.path, &st) == 0, st.st_size > maxLogBytes else { return }
        rename(fileURL.path, fileURL.path + ".1")
    }
}

#if os(macOS)
// Darwin.flock is `struct flock` (fcntl); bind flock(2) by symbol name.
@_silgen_name("flock")
private func posixFlock(_ fd: Int32, _ operation: Int32) -> Int32

private func flockFD(_ fd: Int32, lock: Bool) {
    _ = posixFlock(fd, lock ? LOCK_EX : LOCK_UN)
}

private func systemWrite(_ fd: Int32, _ buf: UnsafeRawPointer, _ count: Int) -> Int {
    write(fd, buf, count)
}
#else
private func flockFD(_ fd: Int32, lock: Bool) {
    _ = fd
    _ = lock
}

private func systemWrite(_ fd: Int32, _ buf: UnsafeRawPointer, _ count: Int) -> Int {
    Glibc.write(fd, buf, count)
}
#endif
