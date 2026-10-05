import Foundation

/// A window as the AX/CG layer sees it right now. The refresh session turns
/// every app's live window list into these and diffs them against the model.
public struct LiveWindow: Equatable, Sendable {
    public var cgWindowId: UInt32
    public var pid: Int32
    public var bundleId: String?
    public var frame: Rect
    public var onScreen: Bool

    public init(cgWindowId: UInt32, pid: Int32, bundleId: String? = nil, frame: Rect, onScreen: Bool) {
        self.cgWindowId = cgWindowId
        self.pid = pid
        self.bundleId = bundleId
        self.frame = frame
        self.onScreen = onScreen
    }
}

/// A single id replaced by a new id for the same pid. Electron and native-tab
/// apps mint new CGWindowIDs; rebinding keeps the tree slot instead of
/// close + open.
public struct RebindPair: Equatable, Sendable, Comparable {
    public var from: UInt32
    public var to: UInt32

    public init(from: UInt32, to: UInt32) {
        self.from = from
        self.to = to
    }

    public static func < (lhs: RebindPair, rhs: RebindPair) -> Bool {
        lhs.from < rhs.from
    }
}

/// What changed between the model and a fresh enumeration. `added` and
/// `removed` exclude ids that became rebinds. `recycled` holds ids that are
/// still live but now belong to a different pid: the CGWindowID was reused,
/// so the old model entry must be torn down and the live window re-adopted.
/// Sorted for deterministic tests.
public struct ReconcileDelta: Equatable, Sendable {
    public var added: [UInt32]
    public var removed: [UInt32]
    public var rebinds: [RebindPair]
    public var recycled: [UInt32]

    public init(
        added: [UInt32] = [],
        removed: [UInt32] = [],
        rebinds: [RebindPair] = [],
        recycled: [UInt32] = []
    ) {
        self.added = added
        self.removed = removed
        self.rebinds = rebinds
        self.recycled = recycled
    }

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && rebinds.isEmpty && recycled.isEmpty }
}

/// Diff the model's ids against a live enumeration. A pid that lost exactly
/// one id and gained exactly one id in the same pass is a rebind; anything
/// else is a plain add or remove.
///
/// `rebindableIds` limits which removed ids may be paired. Electron-style
/// replacement happens while the placeholder is still young; without the cap,
/// a close followed by an unrelated open in one pass would hand the new
/// window the old window's slot on another workspace. Nil disables the cap.
public func reconcile(
    model: Set<UInt32>,
    modelPids: [UInt32: Int32],
    live: [LiveWindow],
    rebindableIds: Set<UInt32>? = nil
) -> ReconcileDelta {
    var liveById: [UInt32: LiveWindow] = [:]
    for w in live { liveById[w.cgWindowId] = w }

    let removedIds = model.subtracting(liveById.keys)
    let addedIds = Set(liveById.keys).subtracting(model)
    // Same id on both sides but a different owner: the CGWindowID was
    // recycled while the model still points at the old window. These stay out
    // of added/removed and the rebind pairing; the agent tears the old entry
    // down and re-adopts the live window.
    let recycledIds = model.filter { id in
        guard let liveWindow = liveById[id], let modelPid = modelPids[id] else { return false }
        return modelPid != liveWindow.pid
    }

    var removedByPid: [Int32: [UInt32]] = [:]
    for id in removedIds {
        guard let pid = modelPids[id] else { continue }
        removedByPid[pid, default: []].append(id)
    }
    var addedByPid: [Int32: [UInt32]] = [:]
    for id in addedIds {
        guard let w = liveById[id] else { continue }
        addedByPid[w.pid, default: []].append(id)
    }

    var rebinds: [RebindPair] = []
    for (pid, removed) in removedByPid {
        guard removed.count == 1, let added = addedByPid[pid], added.count == 1 else { continue }
        if let rebindableIds, !rebindableIds.contains(removed[0]) { continue }
        rebinds.append(RebindPair(from: removed[0], to: added[0]))
    }

    let rebindFrom = Set(rebinds.map(\.from))
    let rebindTo = Set(rebinds.map(\.to))
    return ReconcileDelta(
        added: addedIds.subtracting(rebindTo).sorted(),
        removed: removedIds.subtracting(rebindFrom).sorted(),
        rebinds: rebinds.sorted(),
        recycled: recycledIds.sorted()
    )
}

/// Decides which model windows a refresh is allowed to destroy.
///
/// CG's window list is the aliveness truth for tiled and stashed windows: a
/// "successful" AX read that omits one is not evidence of death (Ghostty
/// intermittently drops live windows from `AXWindows`), so those are deferred
/// for as long as WindowServer still lists them. There is no miss cap.
///
/// A window missing from a *failed* AX read tells us nothing at all: busy apps
/// time out `AXWindows`, so the window is deferred without counting a miss.
/// `removed` ids CG has also dropped are destroyed immediately.
///
/// Floating entries are the only capped class. Hidden retention windows
/// (Spotlight keeps a CG window alive while its UI is dismissed) must not pin
/// model entries forever, so they are removed after a few consecutive misses.
public struct RemovalGate: Equatable, Sendable {
    private var misses: [UInt32: Int]
    private let grace: Int

    public init(grace: Int = 2) {
        self.misses = [:]
        self.grace = grace
    }

    public mutating func classify(
        removed: [UInt32],
        cgLive: Set<UInt32>,
        pidOf: [UInt32: Int32],
        axFailedPids: Set<Int32>,
        floatingIds: Set<UInt32>
    ) -> (real: [UInt32], deferred: [UInt32]) {
        var real: [UInt32] = []
        var deferred: [UInt32] = []
        var next: [UInt32: Int] = [:]
        for id in removed {
            guard cgLive.contains(id) else {
                real.append(id)
                continue
            }
            if let pid = pidOf[id], axFailedPids.contains(pid) {
                deferred.append(id)
                continue
            }
            guard floatingIds.contains(id) else {
                deferred.append(id)
                continue
            }
            let miss = (misses[id] ?? 0) + 1
            if miss > grace {
                real.append(id)
            } else {
                deferred.append(id)
                next[id] = miss
            }
        }
        misses = next
        return (real, deferred)
    }
}

/// A refresh that would drop most of the model is suspicious while the screen
/// is locked or asleep: AX goes dark and every window looks closed. Keep the
/// model for this pass; the next session after unlock retries. When the screen
/// is not locked, trust the diff even if it is large (a real mass close).
public func shouldSuspendMassRemoval(modelCount: Int, removedCount: Int, screenLocked: Bool) -> Bool {
    guard screenLocked, modelCount >= 3, removedCount > 0 else { return false }
    return removedCount * 2 > modelCount
}
