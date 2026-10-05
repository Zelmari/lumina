#if os(macOS)
import Darwin
import Foundation
import LuminaIPC
import LuminaLayout

/// Thread-safe stop flag shared between the owner and the read loop.
private final class SubscriptionStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}

/// Long-lived status subscription to one agent. The agent pushes one snapshot
/// on subscribe and one per strip-visible change; this reads them until
/// stopped or the connection drops, then reconnects with backoff and re-syncs
/// from the initial snapshot.
final class AgentSubscription: @unchecked Sendable {
    let instanceId: UUID
    /// Called on the subscription queue with each snapshot.
    var onStatus: ((AgentStatus) -> Void)?
    /// Called on the subscription queue when the connection becomes healthy
    /// or drops.
    var onHealth: ((Bool) -> Void)?

    private let socketPath: String
    private let log: LuminaLog
    private let queue: DispatchQueue
    private let stopped = SubscriptionStopFlag()
    private var fd: Int32 = -1
    private var reconnectDelay: TimeInterval = 0.25
    private var healthReported = false

    init(instanceId: UUID, socketPath: String, log: LuminaLog) {
        self.instanceId = instanceId
        self.socketPath = socketPath
        self.log = log
        self.queue = DispatchQueue(label: "com.zelmari.lumina.extra.sub.\(instanceId.uuidString)")
    }

    func start() {
        queue.async { [weak self] in self?.run() }
    }

    func stop() {
        stopped.set()
        queue.async { [weak self] in
            guard let self, self.fd >= 0 else { return }
            close(self.fd)
            self.fd = -1
        }
    }

    private func run() {
        while !stopped.value {
            guard let fd = LuminaSocket.connect(path: socketPath) else {
                backoff()
                continue
            }
            self.fd = fd
            let request = IPCRequest(id: UUID().uuidString, cmd: "subscribe")
            guard let line = try? encode(request),
                  let data = line.data(using: .utf8),
                  LuminaSocket.writeAll(fd, data)
            else {
                close(fd)
                self.fd = -1
                backoff()
                continue
            }
            reconnectDelay = 0.25
            reportHealth(true)
            while !stopped.value,
                  let payload = LuminaSocket.readLineBlocking(fd, stop: { [stopped] in stopped.value })
            {
                guard let notification = try? decodeNotification(payload),
                      notification.event == "status",
                      let object = notification.data?.object
                else { continue }
                onStatus?(AgentStatus(json: object))
            }
            close(fd)
            self.fd = -1
            if !stopped.value {
                reportHealth(false)
                backoff()
            }
        }
    }

    private func reportHealth(_ healthy: Bool) {
        guard healthReported != healthy else { return }
        healthReported = healthy
        if !healthy {
            log.info("subscription down instance=\(instanceId.uuidString)")
        }
        onHealth?(healthy)
    }

    private func backoff() {
        guard !stopped.value else { return }
        Thread.sleep(forTimeInterval: reconnectDelay)
        reconnectDelay = min(reconnectDelay * 2, 4)
    }
}

extension AgentStatus {
    /// Build a status from an agent payload. Shared by the polled
    /// `status` reply and pushed subscription snapshots.
    init(json obj: [String: JSONValue]) {
        self.init(
            secureInput: obj["secureInput"]?.bool ?? false,
            axTrusted: obj["axTrusted"]?.bool ?? false,
            configError: obj["configError"]?.string,
            paused: obj["paused"]?.bool ?? false,
            instanceId: obj["instanceId"]?.string,
            space: obj["space"]?.int,
            displayGone: obj["displayGone"]?.bool ?? false,
            hotkeyError: obj["hotkeyError"]?.string,
            spaceCount: obj["spaceCount"]?.int,
            visibleSpaceCount: obj["visibleSpaceCount"]?.int,
            isCurrent: obj["isCurrent"]?.bool ?? false,
            hasOnScreenIncludingSlivers: obj["hasOnScreenIncludingSlivers"]?.bool ?? false,
            skylightSpaceId: obj["skylightSpaceId"]?.int.map { UInt64($0) }
        )
    }
}
#endif
