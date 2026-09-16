import Foundation

public enum LuminaPaths {
    public static func runtimeRoot(uid: uid_t, tmpdir: String) -> String {
        "\(tmpdir)/lumina-\(uid)"
    }

    public static func menuSocketPath(uid: uid_t, tmpdir: String) -> String {
        runtimeRoot(uid: uid, tmpdir: tmpdir) + "/menu.sock"
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
