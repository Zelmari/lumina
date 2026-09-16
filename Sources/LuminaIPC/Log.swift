import Foundation

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

    public init(category: LogCategory, fileURL: URL? = nil, debugEnabled: Bool? = nil) {
        self.category = category
        self.fileURL = fileURL
        if let debugEnabled {
            self.debugEnabled = debugEnabled
        } else {
            self.debugEnabled = ProcessInfo.processInfo.environment["LUMINA_DEBUG"] == "1"
        }
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
        let line = "[\(category.rawValue)] \(level) \(message)\n"
        guard let fileURL else { return }
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
        _ = fm.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        flockFile(handle, lock: true)
        _ = try? handle.seekToEnd()
        if let data = line.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
        flockFile(handle, lock: false)
    }
}

#if os(macOS)
import Darwin

private func flockFile(_ handle: FileHandle, lock: Bool) {
    let fd = handle.fileDescriptor
    _ = Darwin.flock(fd, lock ? LOCK_EX : LOCK_UN)
}
#else
private func flockFile(_ handle: FileHandle, lock: Bool) {
    _ = handle
    _ = lock
}
#endif
