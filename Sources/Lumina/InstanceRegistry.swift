#if os(macOS)
import Darwin
import Foundation
import LuminaLayout

/// Cross-process agent registry. Load-modify-save runs on the main queue, the
/// status queue, and spawn callbacks, so compound updates must go through
/// `mutate`; plain `load`/`save` take the same lock and saves go through a
/// unique temp file plus rename.
final class RegistryStore: @unchecked Sendable {
    let path: String
    private let lock = NSLock()
    /// Decoded registry, kept in memory: every poll and click used to read and
    /// JSON-decode the file. The extra is the only writer, and all writes go
    /// through this store, so the cache cannot go stale in normal operation.
    private var cache: InstanceRegistry?

    init(path: String) { self.path = path }

    func load() -> InstanceRegistry {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()
    }

    /// Read-modify-write under one lock so a concurrent save cannot erase the
    /// rows this update just added.
    @discardableResult
    func mutate(_ body: (inout InstanceRegistry) -> Void) -> InstanceRegistry {
        lock.lock()
        defer { lock.unlock() }
        var registry = loadUnlocked()
        body(&registry)
        saveUnlocked(registry)
        return registry
    }

    func save(_ registry: InstanceRegistry) {
        lock.lock()
        defer { lock.unlock() }
        saveUnlocked(registry)
    }

    private func loadUnlocked() -> InstanceRegistry {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let decoded = try? InstanceRegistry.decode(data)
        else {
            let empty = InstanceRegistry(bootSessionUUID: "")
            cache = empty
            return empty
        }
        cache = decoded
        return decoded
    }

    private func saveUnlocked(_ registry: InstanceRegistry) {
        cache = registry
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
