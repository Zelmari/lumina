# Notes: things that have caused errors

Living list of traps we have actually hit. Add to it when a bug costs more
than a few minutes.

## AX is not a reliable oracle

- `AXWindows` can succeed but omit a live window. Seen with Ghostty, Safari,
  and Electron apps. One enumeration missing a window is not proof it closed.
- Adopt the frontmost app's `kAXFocusedWindowAttribute` window on every
  refresh. It is readable even when `AXWindows` is empty, and it is how
  AeroSpace picks up Chromium/Electron windows without any accessibility
  wake-up flag.
- Never GC a model window just because one AX enumeration omitted it. Real
  removal is CG's call; AeroSpace revalidates cached elements directly and
  treats the window list as additive.
- The read can also fail outright (`kAXErrorCannotComplete`) under the 50ms
  messaging timeout. "Failed" and "empty" are different: a failed read says
  nothing; a successful empty list is evidence. `enumerateWindows` keeps them
  apart for this reason.
- `_AXUIElementGetWindow` intermittently fails (`-25201`). The frame-matching
  fallback is ambiguous when two windows share geometry (Electron splash and
  the real window). Ambiguity means "no answer", never "no window".
- PID 168 is WindowServer and never answers AX. A failed read only matters for
  pids that own managed windows; treating every failure as actionable marked
  every refresh unresolved and spammed retries.
- Lock screen and display sleep make every AX window disappear. The
  mass-removal guard exists for that; layout passes must not delete the model.

## CGWindowIDs are boot-scoped

- IDs are only unique within one boot. Persisted `originals`/`stash` from an
  earlier boot can land on a recycled ID and restore an unrelated frame.
  `unstashLeftovers` only trusts files whose `bootSessionUUID` matches
  `kernBootUUID()`.
- Even within a boot IDs get recycled after a window closes. Avoid long-lived
  state keyed only by CGWindowID.

## Chromium / Electron

- The accessibility tree is lazy. `AXManualAccessibility` (fallback
  `AXEnhancedUserInterface`) wakes it, but setting the flag repeatedly while
  Chromium is building the tree keeps tearing it down: `AXWindows` stays
  empty and newly launched windows are never adopted. Set it once per PID and
  only when an owned window's AX element cannot be resolved, never
  preemptively during launch.
- Opening an Electron app usually shows a splash window first. The splash can
  be adopted (often classified floating) before the real window replaces it
  with a new CGWindowID. A rebind must re-run classification
  (`tileFloater`/`floatLeaf`) or the float role sticks to the real window.
- A rebind is a property of the window, not of the focused space. Rebinding
  only `session.focusedSpace` leaves dead IDs in other spaces, and those
  windows can no longer be stashed, focused, or restored.
- Frame writes are best effort. An app can return success and still drop or
  clamp the move (Ghostty snaps to its terminal grid). Restore paths read the
  frame back and re-issue once.
- If a Chromium app stops tiling, grep the log for:
  - `refresh ax empty unmanaged pid=`
  - `refresh ax read failed unmanaged pid=`
  - `refresh unresolved window id`

## Refresh and event handling

- One refresh at launch is not enough. `kAXWindowCreatedNotification` can be
  missed while the AX observer is still installing, so late windows never get
  adopted. Post-launch polls (8 x 0.75s, shorter burst on activation with no
  owned window) cover the gap.
- A layout pass that breaks on the 200ms budget must schedule a continuation
  for the nodes it did not visit; otherwise those tiles keep stale frames
  until some unrelated event.
- Removing a model window on the first missed enumeration churns live windows
  in and out of the tree (remove, re-adopt, new node, ratios reset). The
  removal gate is: CG also dropped the id -> real removal; failed AX read ->
  defer while CG lists it; floating entries (Spotlight keeps a hidden CG
  window) get a bounded consecutive-miss grace.
- `shouldSuspendMassRemoval` only guards the lock screen. It is not a general
  "lots of windows disappeared" guard.

## Focus and activation

- Follow the activated app to the workspace containing its focused window,
  but only when the native focused window id changed since the last sync.
  Re-processing the same window on every activation caused focus ping-pong
  between apps (AeroSpace's `lastKnownNativeFocusedWindowId` guard).
- Re-writing every tile frame on every refresh makes apps repaint and
  flicker even when nothing changed. Skip windows already at their tile.
- Do not read back and retry a frame write because it "did not land": apps
  clamp sizes (Ghostty snaps to its terminal grid) and macOS clamps park
  positions, so the check never passes and retries forever. Re-issue on the
  next refresh instead, as AeroSpace does.

## Hiding windows

- macOS never lets a window go fully off screen. Park just past a screen
  corner, position only, and accept the clamp; a 1px sliver stays visible.
  Do not verify the parked position against the requested one.
- Treat a window already outside the visible area as parked and leave it
  alone. Re-park only when it is back on screen.

## Build, deploy, test

- `swift build` only writes `.build/`. The menu extra launches
  `dist/Lumina.app/Contents/Helpers/Lumina Agent.app`. Always run
  `scripts/bundle.sh` after a change or you are testing an old binary. This
  caused a long, wrong diagnosis once.
- `swift test` needs the Xcode toolchain:
  `export DEVELOPER_DIR=/Applications/Xcode.app`. CommandLineTools lacks the
  `Testing` module.
- CI runs on Linux (`swift test --filter LuminaLayoutTests`,
  `LuminaIPCTests`). Keep `LuminaLayout` and `LuminaIPC` free of macOS-only
  APIs.
- Do not launch or kill Lumina while the user is working on the machine;
  deploy and let them drive. Log-only diagnosis is enough most of the time.

## Workspaces and quit

- New windows belong to the space that was focused when the event burst
  started (`pendingRefresh.space`), not necessarily the visible one.
- Quit restores `originalFrame` through `restoreWindow`, rejecting a saved
  original that is really the current engine tile (`isEngineTile`).
- `session.json` is per instance. On a fresh start the menu extra moves every
  session file under `spaces/` to `pending-unstash`; the next agent loads
  them, now gated by boot session.
- Unmanaged windows are what "follow" the user across workspaces. If a window
  trails across spaces, it was never adopted (or its stash failed), not a
  z-order problem.

## Second-pass audit — 2026-10-04 (new issues, not in FINDINGS.md)

Seven read-only passes over `Sources/`, `Tests/`, `scripts/`, `docs/`, CI.
Everything below is new relative to `FINDINGS.md`. Fixing in progress; keep
this list current as items land.

### Medium

1. `Classify.swift:167-179` — `break` outside the `switch` exits the rule
   loop; a matching `.tile` rule shadows every later `.float`/`.ignore` rule.
2. `Reconcile.swift:117-150` + `AgentRuntime.swift:653-678` — removal-gate
   miss counters advance on passes the lock-screen suspension check then
   discards, so live windows can be removed after unlock.
3. `AgentRuntime.swift:441-444` vs `InputPolicy.swift:38-48` —
   `appActivated` adds `(!hasWindows && elapsed > 0.4)`, so it follows
   activation off an empty workspace, the opposite of the documented guard.
4. `Config.swift:342-349` + `AgentRuntime.swift:2249-2261` — `applyReload`
   passes no `defaults`; a deleted/unreadable config becomes `""` → bundled
   defaults with no warning, silently resetting `spaceCount` and friends.
5. `Spatial.swift:101-109` + `AgentRuntime.swift:1148-1152` — two-floater
   swap only exchanges `lastOnscreenFrame`; no caller applies it and
   `applyFrames` overwrites it from the live frame, so the swap is inert.
6. `Balance.swift:133-165,269-283` — `clampOverflow` visits containers in
   Dictionary/hash order and resolves the first offender, so which window is
   floated varies between launches; >32 offenders silently leave mins broken.
7. `SpaceSwitch.swift:63-69`, `Tree.swift:223-231`,
   `AgentRuntime.swift:1136-1137` — retiling a floater while
   `luminaFullscreen != nil` inserts an unstashed tiled leaf; it stays visible
   at its float position with role `.tiled`.
8. `Fullscreen.swift:39-57,74-86` — `enterLuminaFS` never updates
   `focusedWindow`/`lastTiledLeaf`, so auto-fill entry leaves a stashed
   sibling focused and the Option-F exit gate dead.
9. `Balance.swift:104-120,184-198` — `floatLeaf` on the FS node clears
   `luminaFullscreen` via `Tree.remove` without `markUnstashed` (extends 4.3).
10. `AgentRuntime.swift:2092-2106,2041-2049` — `spatialWindows()` omits the
    FS filter `spatialTarget()` has, so FFM/title-bar swap can target parked
    siblings while Lumina-FS is active.
11. `AgentRuntime.swift:699,812-832` + `Reconcile.swift:57-92` — recycled
    CGWindowIDs are never detected: `reconcile` sees the id on both sides and
    reports no delta, so the `onCreate` reuse branches are unreachable.
12. `AgentRuntime.swift:1877-1893` + `ExtraApp.swift:412-431` —
    `unstashLeftovers` filters only by boot UUID, never `instanceId`/
    `displayUUID`, so multi-display restarts restore other displays' windows.
13. `AXAdapter.swift:55-56,96-113,125-132,432-445` — `idCache`/`minSizeCache`
    are keyed by raw element address but the old element is released when
    `tracked[id]` is replaced; a recycled address can inherit stale state.
14. `AXAdapter.swift:54-61` — adapter caches are unsynchronized and reachable
    from the main-thread SIGTERM `stop()` concurrent with the mutation queue.
15. `AXAdapter.swift:302-315` — `disableAnimations` creates a new app element
    and reads/writes it without a messaging timeout; timeouts are per-object,
    so every frame write can stall the queue for the system default.
16. `AgentRuntime.swift:1105-1114,1335-1338,1416-1419,1340-1348` — `setFrame`
    increments `generation` on the `inout` copy; the title-bar snap-back, the
    `applyFrames` retry, `applyLayout`, and the FS block discard it, so our
    own move/resize echo is handled as user input (extends 3.2).
17. `Config.swift:271-287` — `raw.bindings` is a Dictionary iterated in hash
    order; chords that normalize to the same `Chord` resolve "last wins"
    nondeterministically and the diagnostic is false.
18. `ExtraApp.swift:118-145` — `startOnThisSpace` treats a live agent that
    has not bound its socket yet as absent and spawns a second agent.
19. `ExtraApp.swift:298-309,219-238` — `pollStatusBody` never sends `.yield`
    to losing claimants and crash-recovered agents start `isCurrent = true`,
    so two agents can run hotkeys/frames concurrently.
20. `ExtraApp.swift:156-170` — a failed spawn orphans `pending-unstash`
    session files (the frames are never restorable) (extends 2.10).
21. `AgentRuntime.swift:130-139` — a socket bind failure is only logged; the
    agent keeps running with hotkeys and tiling, invisible to the extra, and
    every Start spawns another agent.
22. `CLIArgs.swift:40-42`, `Codec.swift:86-87`,
    `AgentRuntime.swift:1155-1158,1210-1212` — out-of-range workspace ids
    pass CLI validation, no-op in the handler, and still return success.

### Low

23. `AXObserverHub.swift:42-65` — `AXObserverAddNotification` is never paired
    with `AXObserverRemoveNotification`; dead/rebound elements accumulate.
24. `AgentRuntime.swift:1172-1177` vs `1449-1453` — `move-node-to-workspace`
    skips `lastLuminaSpaceChange`, `lastSyncedNativeFocusedId`, and the
    pre-switch focus/frame captures that `switchSpace` performs.
25. `AgentRuntime.swift:2108-2121` vs `976-995` — `dropPid` omits
    `lastWindowClosedAt`, `lastSyncedNativeFocusedId`, `moveStart`, and
    `resizeDebounce` cleanup that `removeDestroyedWindow` performs.
26. `AXAdapter.swift:307-316` — if the prior-value read fails,
    `AXEnhancedUserInterface` is set `false` and never restored.
27. `AXAdapter.swift:134-154` — the documented legacy
    `AXEnhancedUserInterface` wake fallback is not implemented;
    `.attributeUnsupported` permanently marks the pid delivered.
28. `SocketServer.swift:24-48` — `start()` leaks `listenFD` on both throw
    paths and ignores a failed `listen()`.
29. `SocketServer.swift:114-118` — a client that stops reading can block the
    server in `write`, wedging all later IPC (extends 2.2/2.4).
30. `AgentApp.swift:15-29` — the `argv.first` socket fallback accepts any
    flag `takeFlag` did not consume (e.g. `--crash-recover`) (extends 3.10).
31. `AXAdapter.swift:339-341` — `framesClose` is dead code.
32. `SpaceSwitch.swift:36-50` — `moveNodeToWorkspace` removes from the source
    before an `insertSpiral` that can no-op — silent window loss (extends 4.9).
33. `Fullscreen.swift:102-118` — `insertWhileLuminaFS` assumes the insert
    succeeded; on failure it stashes the visible FS window itself.
34. `Config.swift:387-390` — `applySpaceCount` pours floaters left at
    `.stashed` role, so they stay parked on the destination (extends 4.6).
35. `MenuSocket.swift:63-86` — the menu server does one unlooped 4096-byte
    read; the `ipcMaxLineBytes` guard is unreachable (extends 2.4).
36. `ExtraApp.swift:107-115` — the boot `.reattach` branch never runs
    `startAttachDecision`, leaving a live, on-screen yielded agent idle.
37. `AgentSpawner.swift:64-71` — the `DispatchSourceProcess` handler captures
    `src` strongly while the source owns its handler: a leak per watched pid.
38. `MenuSocket.swift:19-23` — on the `/tmp` fallback path the server tries
    to `chmod("/tmp", 0700)` (extends 2.10).
39. `ExtraApp.swift:220-238` — a failed crash-respawn leaves a dead registry
    row and a stale `lastCurrentInstanceId` with no retry.
40. `Protocol.swift:115-116,129` — `.double(3.0)` encodes as `3` and decodes
    as `.int(3)`: `JSONValue` does not round-trip whole doubles.
41. `LuminaCLI.swift:168-172` — `printResponse` re-encodes without
    `.sortedKeys`, so CLI JSON field order is randomized per process.
42. `LuminaCLI.swift:15-16`, `CLIArgs.swift:10-11`, `Log.swift:16,52-55` —
    `lumina debug` prints a constant and `LuminaLog.debug()` has no callers.
43. `Log.swift:90-97` + `AgentSpawner.swift:117` — the log fd is cached with
    no rotation/size cap and no close-on-exec; children inherit it.
44. `Codec.swift:24-26` + client decoders — protocol version is checked on
    requests but never on responses.
45. `Codec.swift:86,91-111` — present-but-invalid enum args report
    `missing args`, hiding the real problem.
46. `Protocol.swift:10-12` — `IPCRequest`'s `args` default is ignored by the
    synthesized decoder, so a request without `args` is "malformed JSON".
47. `Paths.swift:59-60` — `resolvedAgentSocketPath` returns the last
    candidate even when none fits; a long instance id yields an over-long
    path and a headless agent (extends 2.10).
48. `LuminaIPCTests.swift:101,115-123` — the long-tmpdir test asserts a
    literal and `contains(uuid)`, so fallback/order regressions pass.
49. `docs/install.md:18` vs `bundle.sh:15-19` — docs say "debug `.app`"; the
    script builds `-c release`.
50. `README.md:27` — says 155 tests; the tree declares 156.
51. `SessionPolicyTests.swift:219-224` — the second assertion of
    `noOpIdGreaterThanCount` is vacuous (`Session.empty` already focuses 1).
52. `BalanceTests.swift:182-195` — `resizeIgnoredForFloatingAndSingleLeaf`
    exits at the first guard; the floating-role check is never reached.
53. `SessionPolicyTests.swift:412-418` — `detectorPredicates` never exercises
    the `skyLightIdChanged` native-fullscreen signal.

### Notes

- FINDINGS 5.1 and 5.4 look stale: `README.md:5` now says quitting restores
  pre-tiling frames, and the README lists both test targets.
- FINDINGS §6 says `AXEnhancedUserInterface` wakes Chromium; only
  `AXManualAccessibility` is set (`AXAdapter.swift:147`).
