# Lumina — Advancement plan (AeroSpace-inspired)

Status: proposal. There is no product SPEC in the repo any more. This file is the
working plan for rebuilding the agent layer so the failures we keep patching stop
recurring. It is not a product contract and it does not override `AGENTS.md`.
For every `git`/`gh` action, **`AGENTS.md` wins** — read it before touching git.

Research base: AeroSpace `main` @ `74a1bf17` (2026-10-01) plus `docs/guide.adoc`.
File references below are AeroSpace paths, used as the thing to imitate.

---

## 1. Why this plan exists

Lumina's agent mutates an incremental model from individual AX events, then tries
to repair that model with retries, tags, verification, and rollback. AeroSpace
treats every event as a hint to re-read the world and re-apply a declarative
layout. Almost every bug from the last week is an incremental-model bug:

| Symptom | Current cause | Fixed by |
|---|---|---|
| Discord opened but never tiled | splash window replaced after the create ladder ended | A2 |
| Close didn't reflow until focus | destroy/CG lag; model kept a dead tile | A2 |
| A window pinned on top | focus loop raised the target up to 4 times | A4 |
| Quit all didn't untile | `originalFrame` registry held a tile-shaped frame | A8 |
| Cmd-Q quit the wrong app | dead window kept a space "occupied"; activation cascade yanked spaces | A2, A4 |
| Endless defensive state | per-window retry budgets, in-flight generations, stash verification, destroy rechecks | A2, A3, A5 |

**Success criteria for this plan**

- No new per-symptom patch is needed for a month of dogfooding.
- The agent has one scheduling mechanism (refresh sessions) and one way to apply
  frames (declarative layout), not a dozen.
- Net line count in `Sources/LuminaAgent` goes **down**, while moving behavior
  that can be pure into `LuminaLayout` and under CI tests.

---

## 2. Principles to copy from AeroSpace

1. **Events are hints, not semantics.** `kAXWindowCreatedNotification`,
   destroyed, moved, resize, app launch/activate all just schedule a full
   refresh (`layout/refresh.swift`, `MacApp.swift:375-390`). One cancellable
   session re-reads `kAXWindowsAttribute` for every app and reconciles by
   CGWindowID. This is what makes splash windows, lost notifications, and
   reordered events non-problems.
2. **Declarative layout, convergence by repetition.** Every session recomputes
   and re-applies all visible workspaces. There is no diffing of intended vs
   current frames; the next pass fixes drift.
3. **Best-effort AX writes.** `setFrame` writes size → position → size, ignores
   the result, and does not read back (`MacApp.swift:411-419`). Failures are not
   evidence; they are retried by the next session. No `MessagingTimeout`
   anywhere. Animations are disabled via `AXEnhancedUserInterface`
   (`MacApp.swift:424-436`).
4. **Window identity is CGWindowID via the one private API**
   (`_AXUIElementGetWindow`). Liveness is exactly "the private call succeeds";
   otherwise the window is GC'd and re-registered on the next enumeration.
5. **Focus is synced from the OS, then applied once.** AeroSpace reads the
   frontmost app's `kAXFocusedWindowAttribute`, makes that window's workspace
   visible, and applies focus in this order: set `kAXMain`, raise, activate
   (`MacApp.swift:130-148`). No retry loops.
6. **Close reconciles focus in the same session.** When a window is removed,
   focus goes to the MRU window of the same workspace (or stays on the empty
   workspace); if macOS promoted another app, AeroSpace re-asserts the intended
   focus (`MacWindow.swift:78-106`).
7. **Hiding is position-only.** Park at the monitor's bottom corner without
   touching size; unhide visible workspaces first, then hide invisible ones
   (`refresh.swift:156-201`, `MacWindow.swift:140-154`). No verification, no
   `orderOut`, no minimize. 1px remnant accepted.
8. **Quit recenters, it does not restore.** On quit every window is placed back
   in the visible area keeping its size (`appBundleUtil.swift:26-53`). There is
   **no persisted registry of pre-tiling frames anywhere.**
9. **Isolation.** One dedicated run-loop thread per app, cancellable jobs
   (`MacApp.swift:65-96,150-172`). A hung app stalls only itself.
10. **Testable seams.** Golden AX dumps recorded with a `debug-windows` command
    test the heuristics; in-memory `TestApp`/`TestWindow` seams test the tree and
    commands.

---

## 3. Target architecture

```
AX / NSWorkspace / hotkey / CLI / timer
              │  (any event, reason recorded)
              ▼
      scheduleRefresh(reason)          ← coalesced; one session in flight
              │
              ▼
      refreshSession()                 ← serial, cancellable
        1. enumerate AX windows per known app (kAXWindowsAttribute)
        2. GC model windows whose element is gone
        3. classify + insert/rebind new windows (CGWindowID identity)
        4. normalize (native FS / minimize / hidden app)
        5. declarative layout for visible spaces
        6. hide windows of invisible spaces (unhide first)
        7. reconcile focus + apply native focus once
        8. persist session (stash + counters)
```

**Stays**

- `LuminaLayout`: pure tree, spiral, frames, focus/swap math, config, stash
  frames. It is well tested and platform-free.
- `LuminaIPC`: protocol, socket, CLI.
- `applyFrames` as a declarative executor over `frames(space:usable:gaps:)`.
- Session file for crash recovery (`session.json`) and window rules.
- The empty-workspace and liveness guards added in `9df595f`/`24dce9c` as
  *policy*, reimplemented inside the session.

**Goes (delete, do not leave dead paths)**

- `pendingCreates`, `retryCreate`, the `appLaunched` poll ladder,
  `adoptWindows` call sites as event handlers.
- `scheduleDestroyRecheck`, `destroyRecheckPending`, `ghost` pruning in
  `applyFrames`, `resolvedElement` liveness probing as a control-flow gate.
- `SetFrameResult` branching that changes model state (`floatLeaf` on
  `notLanded`), `unlandedRetryCounts`, `failureIsEvidence`.
- `pendingStashRetries`, `stashAndRetry`, `stashLanded` verification,
  `markVisible` rollback.
- `knownOriginals`, `originalFrame`, `SessionFile.originals`,
  `refreshOriginalsFromLive`, `stashKnownOriginal` (see A8).
- `focusWindow` retry loop; `lastFocusedByPid` can collapse into the model's
  per-space `focusedWindow` + `lastTiledLeaf`.
- Menu-string parsing and x-coordinate hit testing in `StatusItemController`.

---

## 4. Breakpoints

Implement one at a time, in order. `Depends on` is a hard gate. Each BP leaves
`main` green and the app usable. Manual AX matrix is in §6.

### BP-A1 — Pure reconcile delta + AX seam

**Depends on:** none.
**Goal:** make the refresh decision logic pure and testable before rewriting the
agent.

**Files:** new `Sources/LuminaLayout/Reconcile.swift`,
`Tests/LuminaLayoutTests/ReconcileTests.swift`, `Sources/LuminaAgent/AXAdapter.swift`
(extract a narrow `AXWindowSource` accessor behind the existing calls).

**Tasks**

1. Define `LiveWindow { id, pid, bundleId, frame, onScreen }` and
   `ReconcileDelta { added, removed, rebindCandidates }`.
2. `public func reconcile(modelIds: Set<UInt32>, live: [LiveWindow]) -> ReconcileDelta`.
   Deterministic, no AppKit.
3. Add the `AXWindowSource` protocols (`windows(pid:)`, `frame(of:)`) so the
   agent session can be driven by a fake in tests. Do not move AX code into
   `LuminaLayout`.
4. New macOS-only `LuminaAgentTests` target behind `#if os(macOS)` in
   `Package.swift`; CI (Linux) keeps running only layout/IPC tests.

**Done when:** `reconcile` has tests for: new id, missing id, id present but
off-screen (do not GC), duplicate ambiguity; `swift test --filter
LuminaLayoutTests` passes on a Linux toolchain and `LuminaAgentTests` compiles
on macOS.

### BP-A2 — Refresh sessions replace event-by-event mutation

**Depends on:** A1.
**Goal:** one coalesced session owns discovery, removal, adoption, and layout.

**Files:** `AgentRuntime.swift` (core), `MutationQueue.swift`,
`AXObserverHub.swift`, `Reconcile.swift`.

**Tasks**

1. `scheduleRefresh(reason: String)`: record the reason, coalesce with a 40ms
   debounce, cancel/replace any in-flight session (AeroSpace
   `scheduleCancellableCompleteRefreshSession`).
2. `refreshSession()`:
   - enumerate `adapter.windows(pid:)` for every known app pid plus the
     frontmost app;
   - `reconcile` against `session.allWindowIds`;
   - GC removed ids (close on focused space, remove elsewhere, forget all maps);
   - classify/insert added ids. **Assignment space:** the focused space at the
     time the *refresh was scheduled* (preserves the fix from `9df595f` when the
     user switches during the debounce);
   - rebind when a pid lost one id and gained one (exactly one each), like
     AeroSpace's partition.
3. All AX/NSWorkspace handlers (`handleAX`, `appLaunched`, `appTerminated`,
   `spaceChanged`, `didWake`, close/insert commands) call `scheduleRefresh`.
   Delete the launch poll ladder, `retryCreate`, `pendingCreates`,
   `scheduleDestroyRecheck`.
4. Keep title-change and rules re-classification by running it inside the
   session (no separate timers).
5. On enable/start/wake, run one session; on wake do not trust a mass-empty
   result (see A7).

**Done when:** with the app running, deleting/creating windows and app launches
never require a focus change to settle; a `refreshSession` line with `added=`/
`removed=` counts is logged; no `retryCreate`/`destroy recheck` strings remain.

**Manual:** Discord splash → real window tiles <1.5s; VSCode close → sibling
fills without focusing anything; Cursor window churn does not lose the tile.

### BP-A3 — Best-effort AX writes

**Depends on:** A2.
**Goal:** stop making permanent state decisions from write results.

**Files:** `AXAdapter.swift`, `AgentRuntime.swift`, `LuminaLayout/Stash.swift`.

**Tasks**

1. `setFrame`: size → position → size, no read-back requirement for control
   flow. Return a struct for logging only (`ok/error codes`).
2. Wrap writes in the `AXEnhancedUserInterface` animation toggle (copy the
   AeroSpace trick; restore the previous value after).
3. Delete float-on-`notLanded`, `unlandedRetryCounts`, `failureIsEvidence`,
   and the `unlandedSetFrameAction` calls. A window that refuses its tile stays
   in the tree at its own frame and is retried by the next session; log a
   per-window consecutive-failure count for diagnostics only.
4. Keep the in-flight generation map **only** to suppress our own
   moved/resized notifications while the user might be dragging; rename it to
   say so and stop consulting it for pruning/removal.
5. Drop the system-wide 50ms AX timeout. Per-window 150ms is tolerable; do not
   set a global timeout.

**Done when:** no model mutation depends on a write result; `swift test`
passes; Spotify-style slow accepters tile or stay put without floating.

### BP-A4 — Focus sync + native focus once

**Depends on:** A2.
**Goal:** match AeroSpace's focus behavior and delete the retry loop that caused
pinning.

**Files:** `AgentRuntime.swift`, `InputPolicy.swift`, `SpaceSwitch.swift`.

**Tasks**

1. `nativeFocus(id)` = set `kAXMain` → `kAXRaiseAction` → `activate`, once.
   No verification loop, no repeated raises. A failed activation is fixed by
   the next activation notification/session.
2. `appActivated`: read the frontmost app's `kAXFocusedWindowAttribute`; if the
   window is known, make its space visible and focus it (AeroSpace
   `updateFocusCache`). If unknown, schedule a refresh; do not invent a target.
3. Keep the empty-space/liveness guard as an explicit product choice (AeroSpace
   always follows; we intentionally do not follow off a space with no live
   window). Reimplement it as `shouldFollowActivation(spaceHasLiveWindow:)`
   inside the session, using the same pure predicate.
4. On window removal in the session: set focus to the same space's MRU tiled
   window, else floaters, else keep the empty space; re-assert native focus only
   if the frontmost app's window changed (AeroSpace `garbageCollect`).
5. Delete `focusWindow` attempts/retries; `lastFocusedByPid` reduces to the
   space's own `focusedWindow`/`lastTiledLeaf` plus `windowAnywhere` lookups.

**Done when:** `workspace focus` logs appear at most once per switch; a window
can never be raised more than once per focus request; closing the last window
leaves the user on that space.

### BP-A5 — Position-only hiding, unhide-before-hide

**Depends on:** A2.
**Goal:** make hidden-space behavior as boring as AeroSpace's.

**Files:** `AgentRuntime.swift`, `LuminaLayout/Stash.swift`, `SpaceSwitch.swift`.

**Tasks**

1. Park by **position only** (size unchanged), bottom corner, `+1px` offset
   (`hideInCorner`). Keep the Zoom special case.
2. In every session, process visible workspaces first (layout + unhide), then
   hide the invisible ones (AeroSpace order to reduce flicker).
3. Delete `stashLanded`, `scheduleStashRetry`, `pendingStashRetries`,
   `stashAndRetry`, `markVisible` rollback and the associated tests. Stash
   frames are re-issued on every session, so a failed park is corrected next
   pass.
4. Keep `session.json` stash entries for crash recovery only.
5. Document the 1px remnant in README again (was true before).

**Done when:** switching spaces produces no verification logs, hidden windows
never reappear on the wrong space across 20 switches, and space switching
benchmarks at least as fast as today.

### BP-A6 — Menu extra visual redesign

**Depends on:** none (parallel with A2–A5; only touches `Sources/Lumina`).
**Goal:** look like a product, not a debug string.

**Current problems**

- The title is a string (`"! 1 2 (3) 4 5"`) parsed back for clicks
  (`StatusItemController.swift:53-90`), so hit-testing breaks when the width,
  warning prefix, or tooltip changes.
- No icons, no hover, no per-state color; the warning is a `!`; inactive state
  is a long sentence; per-digit tooltips do not exist.

**Design proposal (choose none/all; each item is independent)**

1. Pure model: `StatusStripModel` in `LuminaLayout` (CI-testable):
   `(spaceCount, focused, paused, warning, current) -> [StatusSegment]` with
   `{ label, state: active|idle|paused|warning, enabled, symbolName? }`.
2. `StatusStripView`: a custom `NSView` in the status button, one tracking
   area per segment. Click routing is per-segment, not coordinate math.
   - Active space: rounded rect in `controlAccentColor` with label in
     `selectedMenuItemTextColor`; idle: `labelColor`; hover: subtle
     `quaternaryLabelColor` background.
   - Compact mode when `spaceCount > 5`: dim inactive idle digits
     (`secondaryLabelColor`) and show only `focused ± 2` plus ellipsis;
     full list in the menu.
   - Paused: strip drops to `secondaryLabelColor` and prefixes an SF Symbol
     `pause.fill`; warning: `exclamationmark.triangle.fill` in system orange,
     replacing the `!` text.
   - Inactive state: `play.fill` + “Start on this Space”, not a bare string.
3. Menu: SF Symbols per item (`1.circle.fill`, `arrow.clockwise`,
   `pause.fill`/`play.fill`, `power`), checkmark on the focused space, and
   shortcut hints (`⌥1`) appended as secondary attributed text — do **not**
   assign `keyEquivalent`, the Carbon hotkeys own those.
4. Appearance: template images and semantic colors only; verify light/dark and
   “Reduce transparency”. No new asset files unless a symbol is missing.
5. Accessibility: each segment gets
   `setAccessibilityLabel("Workspace 3")` / `"Workspace 3, active"`; the menu
   keeps standard item semantics; the status button gets a tooltip summarizing
   state and the secure-input warning.
6. Keep exactly one `NSStatusItem`; the agent still has no AX in the extra.

**Done when:** a pure `StatusStripModelTests` passes in
`LuminaLayoutTests`; clicking every digit at 1, 5, and 10 spaces hits the right
space; states render in light/dark; VoiceOver reads each digit.

### BP-A7 — Per-app isolation and mass-loss recovery

**Depends on:** A2.
**Goal:** one hung app cannot freeze the layout, and lock/wake does not wipe
the model.

**Files:** `AXAdapter.swift`, `AgentRuntime.swift`, new
`Sources/LuminaLayout/WorldSnapshot.swift`.

**Tasks**

1. Give each pid its own serial execution context (AeroSpace uses a thread per
   app; a per-pid queue is enough for us). The session fans out reads and
   joins with a deadline.
2. Keep per-window AX timeout at 150ms; no global system timeout.
3. World snapshot: before GC'ing more than half of the model in one session,
   capture `Session`; if the frontmost app is `loginwindow`, the display is
   asleep, or AX returns errors for every pid, keep the model and restore the
   snapshot on the next successful session (AeroSpace `closedWindowsCache`).
4. Mark a pid as “AX-broken” after repeated all-window read failures and log it
   once; do not drop its windows.

**Done when:** `WorldSnapshot` has pure tests; manual lock-screen and sleep/wake
tests leave the tree intact.

### BP-A8 — Quit semantics: recenter, not registry

**Depends on:** A5, A7. **Decision gate: confirm with the user before coding.**
**Goal:** kill the original-frame registry and its bug class.

**Recommendation:** copy AeroSpace. On quit, place every window back inside the
visible area at a sane size (keep its last size; cascade if a window has no
remembered size) and never park/unpark through a registry.

**Tasks if recenter (recommended)**

1. `stop()`: for each managed window, `setFrame` a recentered/cascaded frame;
   then write an empty stash and exit.
2. Delete `originalFrame`, `knownOriginals`, `SessionFile.originals`,
   `resolveOriginal`, `refreshOriginalsFromLive`, `restoreOriginal`,
   `collectOriginals`, and the `originals` key handling in
   `unstashLeftovers`/`writeSession` (keep decoding old files by ignoring the
   field).
3. Crash recovery restores the *last on-screen frames* from `stash`, not
   “originals”.

**Tasks if restore is kept instead**

- Add `originalTrusted: Bool` provenance; never trust a frame equal to the
  engine tile; skip persistence for untrusted entries; show a config note.

**Done when:** quitting from any state leaves windows visible and untiled;
`session.json` no longer contains `originals`; tests updated; docs updated.

### BP-A9 — Diagnostics and compatibility

**Depends on:** A2.
**Goal:** make the next misbehaving app a one-command report, like AeroSpace.

**Files:** `LuminaCLI.swift`, `Protocol.swift`, `docs/compat.md`,
`AgentRuntime.swift`.

**Tasks**

1. `lumina debug-windows`: JSON dump of model windows, AX ids, frames, roles,
   last apply result, and classification inputs; written under
   `~/Library/Application Support/Lumina/debug/`.
2. `os_signpost` intervals around session start/end and every AX get/set
   (AeroSpace does exactly this); no user-facing alerts for transient failures.
3. Menu warning states: paused, AX lost, display gone, config error (reuse the
   `ExtraWarning` plumbing).
4. `docs/compat.md`: record apps that need `float`/`ignore`, beginning with
   Cursor (Computer Use), Zoom, and any app seen in the debug dumps.

**Done when:** a debug dump is enough to classify an app without reproducing;
signposts appear in Instruments.

---

## 5. Menu extra: visual reference

```
current, not paused:      [ 1  2  3  4  5 ]        active = accent pill
current, paused:          [ ⏸  1  2  3  4  5 ]     strip dimmed
current, warning:         [ ⚠  1  2  3  4  5 ]     orange triangle, tooltip
inactive:                 [ ▶ Start on this Space ]
>10/compact (>5 spaces):  [ 1 … 3 4 5 … 9 0 ]      focused ± 2 + ellipsis
```

Every state also has a full menu equivalent; the strip is a shortcut, never the
only way to act.

---

## 6. Test and manual matrix

**Automated (CI, Linux)**

- Layout/IPC only, and the new pure modules: `Reconcile`,
  `WorldSnapshot`, `StatusStripModel`, existing geometry/tree tests.

**Automated (macOS, new `LuminaAgentTests`)**

- Fake `AXWindowSource` drives complete sessions: splash swap, lost destroy,
  off-screen-but-alive, one id replaced by one id (rebind), mass loss.

**Manual AX matrix (run after each AX-touching BP)**

1. Launch with Ghostty + Safari + VSCode open → 3 tiles.
2. Open Discord on a new space → tiles (splash swap), stays on that space.
3. Close one of two tiles → sibling fills immediately, no focus needed.
4. Close the last window on a space → stay on the empty space.
5. Cmd-Tab to an app on another space → follows once, no pinning.
6. 20 space switches with hidden windows → no wrong-space reappearances.
7. Quit all → every window visible and untiled.
8. Lock screen, unlock, sleep/wake → tree intact.
9. Menu extra: click each digit at 5 and 10 spaces, paused + warning states,
   light/dark appearance.

---

## 7. Risks and rollback

- A2 is the risky rewrite. It lands as its own commit series with the app
  usable at each step; rollback is `git revert` of the BP commit. Do not mix
  A3–A5 into the A2 commit.
- Product-visible changes: quit recenter (A8), no float-on-write-failure (A3),
  focus no longer retried (A4). Document each in README when it lands.
- Keep `LuminaLayout`/`LuminaIPC` AppKit-free or CI goes red.
- If a symptom returns after A2, prefer extending the session (one more
  reconcile rule) over reintroducing timers or per-window retries.

---

## 8. Open decisions (need the user)

1. **Quit:** recenter (recommended, AeroSpace) vs. keep original-frame restore.
2. **Activation follow:** keep our “do not follow off a space with no live
   window” guard, or copy AeroSpace's unconditional follow + post-removal
   re-assert. Recommendation: keep the guard; add AeroSpace's re-assert too.
3. **Menu extra:** pill strip vs. minimal digits; compact threshold; symbol set.
4. **Isolation:** per-pid `DispatchQueue` (simpler) vs. thread + run loop
   (closer to AeroSpace). Recommendation: per-pid queue first; only go to
   threads if a real hang shows up.
5. **Float policy:** after A3, an app that never accepts its tile stays in the
   tree at its own frame. Add an explicit “float after N sessions” later only if
   dogfooding demands it.
