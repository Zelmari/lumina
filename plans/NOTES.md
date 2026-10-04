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
