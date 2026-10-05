#if os(macOS)
import Darwin
import Foundation
import LuminaLayout

/// Cross-process agent registry. Load-modify-save runs on the main queue, the
/// status queue, and spawn callbacks, so both operations take a lock and saves
/// go through a unique temp file plus rename.
final class RegistryStore: @unchecked Sendable {
    let path: String
    private let lock = NSLock()

    init(path: String) { self.path = path }

    func load() -> InstanceRegistry {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let decoded = try? InstanceRegistry.decode(data)
        else {
            return InstanceRegistry(bootSessionUUID: "")
        }
        return decoded
    }

    func save(_ registry: InstanceRegistry) {
        lock.lock()
        defer { lock.unlock() }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        // Unique temp name: two savers must not interleave into one file.
        let tmp = path + ".\(UUID().uuidString).tmp"
        guard let data = try? InstanceRegistry.encode(registry) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: tmp))
        } catch {
            return
        }
        if rename(tmp, path) != 0 {
            try? FileManager.default.removeItem(atPath: tmp)
        }
    }
}
#endif
