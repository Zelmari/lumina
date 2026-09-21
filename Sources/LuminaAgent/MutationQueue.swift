import Foundation
import LuminaLayout

/// Serial owner of the window tree. AXObserver/hotkeys hop here immediately.
public final class MutationQueue: @unchecked Sendable {
    public static let shared = MutationQueue()

    public let queue = DispatchQueue(label: "com.zelmari.lumina.mutate")
    public var now: () -> Date = Date.init
    public var layoutBudget: TimeInterval = 0.2

    private var pendingLayout: (() -> Void)?
    private var layoutScheduled = false

    public init() {}

    public func hop(_ block: @escaping () -> Void) {
        queue.async(execute: block)
    }

    public func scheduleLayoutPass(_ work: @escaping () -> Void) {
        queue.async {
            self.pendingLayout = work
            guard !self.layoutScheduled else { return }
            self.layoutScheduled = true
            self.queue.asyncAfter(deadline: .now() + 0.04) {
                self.layoutScheduled = false
                let job = self.pendingLayout
                self.pendingLayout = nil
                job?()
            }
        }
    }

    public func shouldSkip(started: Date) -> Bool {
        shouldSkipRemainingWindows(elapsed: now().timeIntervalSince(started), budget: layoutBudget)
    }
}
