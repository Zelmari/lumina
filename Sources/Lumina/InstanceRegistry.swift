#if os(macOS)
import Foundation
import LuminaLayout

final class RegistryStore {
    let path: String
    init(path: String) { self.path = path }

    func load() -> InstanceRegistry {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let decoded = try? InstanceRegistry.decode(data)
        else {
            return InstanceRegistry(bootSessionUUID: "")
        }
        return decoded
    }

    func save(_ registry: InstanceRegistry) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        let tmp = path + ".tmp"
        if let data = try? InstanceRegistry.encode(registry) {
            try? data.write(to: URL(fileURLWithPath: tmp))
            rename(tmp, path)
        }
    }
}
#endif
