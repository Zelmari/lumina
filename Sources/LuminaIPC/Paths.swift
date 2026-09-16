import Foundation
#if os(macOS)
import Darwin
#endif

/// Darwin `sockaddr_un.sun_path` is 104 bytes including the trailing NUL.
public let unixSocketPathMaxBytes = 103

public func unixSocketPathFits(_ path: String) -> Bool {
    path.utf8.count <= unixSocketPathMaxBytes
}

public enum LuminaPaths {
    public static func runtimeRoot(uid: uid_t, tmpdir: String) -> String {
        "\(tmpdir)/lumina-\(uid)"
    }

    public static func menuSocketPath(uid: uid_t, tmpdir: String) -> String {
        runtimeRoot(uid: uid, tmpdir: tmpdir) + "/menu.sock"
    }

    /// Path that actually fits in `sockaddr_un`. macOS `$TMPDIR` is often already ~48 bytes.
    public static func resolvedMenuSocketPath(uid: uid_t, tmpdir: String) -> String {
        let primary = menuSocketPath(uid: uid, tmpdir: tmpdir)
        if unixSocketPathFits(primary) { return primary }
        return "/tmp/lumina-\(uid)-menu.sock"
    }

    public static func agentSocketPath(
        uid: uid_t,
        tmpdir: String,
        instanceId: String,
        supportFallback: String?
    ) -> (primary: String, fallback: String?) {
        let primary = runtimeRoot(uid: uid, tmpdir: tmpdir) + "/spaces/\(instanceId)/agent.sock"
        let fallback = supportFallback.map { $0 + "/spaces/\(instanceId)/agent.sock" }
        return (primary, fallback)
    }

    /// Same inputs always yield the same path; extra, agent, and CLI must share this.
    public static func resolvedAgentSocketPath(
        uid: uid_t,
        tmpdir: String,
        instanceId: String,
        supportFallback: String?
    ) -> String {
        let pair = agentSocketPath(
            uid: uid,
            tmpdir: tmpdir,
            instanceId: instanceId,
            supportFallback: supportFallback
        )
        let candidates = [
            pair.primary,
            pair.fallback,
            runtimeRoot(uid: uid, tmpdir: tmpdir) + "/\(instanceId).sock",
            "/tmp/lumina-\(uid)/\(instanceId).sock",
        ].compactMap { $0 }
        return candidates.first(where: unixSocketPathFits)
            ?? "/tmp/lumina-\(uid)/\(instanceId).sock"
    }

    public static func sessionPath(supportRoot: String, instanceId: String) -> String {
        supportRoot + "/spaces/\(instanceId)/session.json"
    }

    public static func instancesPath(supportRoot: String) -> String {
        supportRoot + "/instances.json"
    }

    public static func configPath(home: String) -> String {
        home + "/.config/lumina/lumina.toml"
    }
}

public func peerEuidAllowed(peer: uid_t, selfEuid: uid_t) -> Bool {
    peer == selfEuid
}

public func kernBootUUID() -> String? {
    #if os(macOS)
    var size = 0
    sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0)
    guard size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0) == 0 else { return nil }
    return String(cString: buf)
    #else
    return nil
    #endif
}
