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

/// A window as native-tab reconciliation sees it. `onScreen` means CG lists
/// it on screen and it is not a stash sliver. Frames are AX/CG top-left space.
public struct NativeTabWindow: Equatable, Sendable {
    public var id: UInt32
    public var frame: Rect
    public var onScreen: Bool

    public init(id: UInt32, frame: Rect, onScreen: Bool) {
        self.id = id
        self.frame = frame
        self.onScreen = onScreen
    }
}

/// What to do with one native-tab app's model entries this pass. `rebinds`
/// swap a tile onto the backing window that is now showing. `drop` removes
/// inactive backing windows that must not occupy a tile.
public struct NativeTabResolution: Equatable, Sendable {
    public var rebinds: [RebindPair]
    public var drop: [UInt32]

    public init(rebinds: [RebindPair] = [], drop: [UInt32] = []) {
        self.rebinds = rebinds
        self.drop = drop
    }
}

/// One tile per visual window for apps whose tabs are separate NSWindows.
///
/// macOS native tabs keep every tab's NSWindow alive. The selected tab is on
/// screen. The others sit at the same frame and are usually off screen; during
/// a switch CG briefly lists both. Those ids share a frame, so they collapse
/// onto the focused id (or the only on-screen id).
///
/// A real new window (Ghostty Cmd+N, Terminal's new window) is also on screen,
/// at its own frame. It is a separate cluster and is not rebound or dropped,
/// so the caller can insert it as its own tile. An off-screen window whose
/// frame matches none of the on-screen windows (a stash on another workspace)
/// is left alone.
public func resolveNativeTabs(
    managed: [NativeTabWindow],
    live: [NativeTabWindow],
    focusedId: UInt32?,
    frameSlop: Double = 8
) -> NativeTabResolution {
    let visible = live
        .filter { $0.onScreen && $0.frame.w >= 50 && $0.frame.h >= 50 }
        .sorted { $0.id < $1.id }
    var clusters: [[NativeTabWindow]] = []
    for window in visible {
        if let index = clusters.firstIndex(where: {
            framesMatch($0[0].frame, window.frame, slop: frameSlop)
        }) {
            clusters[index].append(window)
        } else {
            clusters.append([window])
        }
    }

    var used: Set<UInt32> = []
    var rebinds: [RebindPair] = []
    var drop: [UInt32] = []
    for cluster in clusters {
        let active: NativeTabWindow
        if let focusedId, let match = cluster.first(where: { $0.id == focusedId }) {
            active = match
        } else if cluster.count == 1, let only = cluster.first {
            active = only
        } else {
            // Several backing windows share a frame and focus did not pick
            // one. Guessing would steal a real window. The next pass retries.
            continue
        }
        let clusterIds = Set(cluster.map(\.id))
        let members = managed.filter { window in
            if used.contains(window.id) { return false }
            if clusterIds.contains(window.id) { return true }
            // Inactive tabs are off screen at the selected tab's frame.
            // An on-screen window belongs only to its own cluster.
            return !window.onScreen && framesMatch(window.frame, active.frame, slop: frameSlop)
        }
        let memberIds = Set(members.map(\.id))
        if memberIds.contains(active.id) {
            for id in memberIds.subtracting([active.id]).sorted() {
                drop.append(id)
            }
        } else if let keeper = members.filter({ clusterIds.contains($0.id) }).min(by: { $0.id < $1.id })?.id
            ?? members.min(by: { $0.id < $1.id })?.id
        {
            rebinds.append(RebindPair(from: keeper, to: active.id))
            for id in memberIds.subtracting([keeper]).sorted() {
                drop.append(id)
            }
        }
        used.formUnion(memberIds)
        used.insert(active.id)
    }
    return NativeTabResolution(rebinds: rebinds.sorted(), drop: drop.sorted())
}

private func framesMatch(_ a: Rect, _ b: Rect, slop: Double) -> Bool {
    abs(a.x - b.x) <= slop && abs(a.y - b.y) <= slop
        && abs(a.w - b.w) <= slop && abs(a.h - b.h) <= slop
}

/// Decides which model windows a refresh is allowed to destroy.
///
/// A window missing from a *failed* AX read tells us nothing at all: busy apps
/// time out `AXWindows`, so the window is deferred without counting a miss.
/// `removed` ids CG has also dropped are destroyed immediately, unless the
/// agent still holds a live AX element for them (`elementLive`): CG's list can
/// transiently omit a live parked window, and deleting one leaves it buried
/// off-screen with no way back.
///
/// When the AX read *succeeded* and omitted the window, CG may still list a
/// lingering record (Electron windows that closed, hidden retention windows).
/// Every class counts misses then: floating entries after `grace`, tiled and
/// stashed entries after twice that, so a dead tile cannot pin a split
/// forever while a transient omission still has room to recover.
public struct RemovalGate: Equatable, Sendable {
    private var misses: [UInt32: Int]
    /// Consecutive passes a live-element veto has deferred an id. The veto
    /// protects a live parked window from a transient CG omission, but a
    /// closed window whose element still answers must not be pinned forever.
    private var vetoMisses: [UInt32: Int]
    private let grace: Int

    public init(grace: Int = 2) {
        self.misses = [:]
        self.vetoMisses = [:]
        self.grace = grace
    }

    public mutating func classify(
        removed: [UInt32],
        cgLive: Set<UInt32>,
        pidOf: [UInt32: Int32],
        axFailedPids: Set<Int32>,
        floatingIds: Set<UInt32>,
        elementLive: Set<UInt32> = []
    ) -> (real: [UInt32], deferred: [UInt32]) {
        var real: [UInt32] = []
        var deferred: [UInt32] = []
        var next: [UInt32: Int] = [:]
        var nextVeto: [UInt32: Int] = [:]
        for id in removed {
            if elementLive.contains(id) {
                let miss = (vetoMisses[id] ?? 0) + 1
                if miss > grace * 3 {
                    real.append(id)
                } else {
                    deferred.append(id)
                    nextVeto[id] = miss
                }
                continue
            }
            guard cgLive.contains(id) else {
                real.append(id)
                continue
            }
            if let pid = pidOf[id], axFailedPids.contains(pid) {
                deferred.append(id)
                continue
            }
            // The AX read succeeded and omitted the window, but CG still
            // lists it. That is a lingering record (a closed Electron
            // window) as often as it is a transient omission, so every class
            // counts misses. Tiled entries get a longer grace because losing
            // a live parked window is worse than a stale tile for a moment.
            let miss = (misses[id] ?? 0) + 1
            let limit = floatingIds.contains(id) ? grace : grace * 2
            if miss > limit {
                real.append(id)
            } else {
                deferred.append(id)
                next[id] = miss
            }
        }
        misses = next
        vetoMisses = nextVeto
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
