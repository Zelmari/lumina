# macOS native tabs (NSWindowTabGroup) — plan

Status: proposed. Branch: `feat/macos-native-tabs`. Not started.
Owner: agent. Review/merge: user after manual testing.

## Problem

Apps that use macOS **native tabbing** (Terminal.app, Ghostty) implement each
tab as a separate `NSWindow` in an `NSWindowTabGroup`. The accessibility and
CG window APIs report every tab as its own window; only the active tab is
on-screen. This is a documented macOS API limitation, not a Ghostty bug
(ghostty.org/docs/help/macos-tiling-wms; AeroSpace tracks native-tab
detection as a 1.0 blocker; yabai has signal workarounds).

Lumina currently does this on every tab switch:

1. The newly active tab's window becomes the frontmost app's focused window,
   so `adoptFocusedWindow` (AgentRuntime) hands it to `onCreate`, which tiles
   it as a new leaf.
2. The previously active tab goes off-screen but stays in the model: Ghostty
   and Terminal still enumerate all tab windows, so `reconcile` never sees it
   as removed.
3. `classify` only ignores off-screen windows at adoption time, so the model
   grows by one invisible tile per tab visited.

Observed live (Ghostty pid 76551): five layer-0 windows, one on-screen
(`14792`), four off-screen twins (`14817`, `14891`, `15764`, `15918`), three
of them adopted as tiles over time. Safari does not reproduce because it
draws its own tab bar inside one `NSWindow`, so the CGWindowID never changes.

Side effect: ghost tabs whose AX element later disappears keep
`overflowStrikes` non-empty, so `applyFrames` schedules `overflowCheck`
refreshes every ~0.2 s forever (340 in one session, 11:43:48–11:45:12) with
removals deferred. This must be bounded independently of the tab work.

## Goals

- One tile per logical window (tab group), not per backing `NSWindow`.
- Switching tabs **rebinds** the tile's backing window id instead of adding
  or removing leaves; switching back rebinds again.
- No behavior change for apps that do not use native tabs (Safari, browsers,
  editors, games).
- The harness can reproduce and assert this with Terminal.app tabs and still
  covers everything a human would test manually.

## Non-goals

- Custom tab bars, or floating Ghostty/Terminal.
- Two genuinely separate windows of the same app tiled side by side.
- Multi-display tab semantics beyond the current one-display model.

## Design

Two routes, tried in order. The exact route needs a runtime probe first.

### T1 — Probe AX tab metadata (diagnostic, keeper)

Add a debug dump of `AXUIElementCopyAttributeNames` (and values for
tab-related attributes) for candidate windows and their children:
`lumina debug-ax <pid>` or extend `debug-windows`. The SDK exposes
`kAXTabGroupRole` (`AXTabGroup`), `kAXTabsAttribute` (`AXTabs`), and
`kAXSelectedChildrenAttribute` (`AXSelectedChildren`).

Questions to answer on Terminal.app and Ghostty:
- Is there an `AXTabGroup` element, and is it on the window or a child?
- Do `AXTabs` / `AXSelectedChildren` identify the selected tab?
- Can a tab element be mapped to its backing `CGWindowID`
  (`_AXUIElementGetWindow` on the tab element, or an `AXWindow` attribute)?
- If yes for Terminal + Ghostty, use the exact route (T2); otherwise T3.

### T2 — Exact tab-group detection (if T1 succeeds)

- Pure `TabGroupInfo` mapping in `LuminaLayout` (no AppKit), fed by adapter
  reads: selected tab id, tab member ids, group window id.
- On refresh: if a focused window belongs to a tab group, keep the group's
  existing tile and rebind it to the active tab; inactive tab ids are never
  adopted. Closing the group's last tab removes the tile normally.

### T3 — Off-screen twin rebind heuristic (fallback)

- Pure predicate, unit-testable:
  `tabSwapCandidate(newId, managedWindows, live, focusedId)` is true when
  same pid, both standard windows, the candidate is on-screen and now
  focused/main, and exactly one managed sibling of that pid just went
  off-screen (was on-screen before) with a similar frame.
- On adoption, if true, `rebindOwned(from: old, to: new)` instead of
  inserting; remember the previous tab ids per pid so switching back
  rebinds again. Never applies to `.floating`/dialog/hard-float windows.

### T4 — Opt-in config

- `[[window-rule]]` gains `tabs = "native"` (or `action = "native-tabs"`)
  applied only to listed bundle ids; default off. Document
  `com.apple.Terminal` and `com.mitchellh.ghostty` in `docs/compat.md`.
- Keep the generic path behind this flag so a heuristic misfire cannot
  affect other apps.

### T5 — Bound the overflow loop

- Clear `overflowStrikes` when the window's element is unresolvable, when
  it leaves the tree, and after N consecutive `overflowCheck` passes
  without a confirmed refusal; cap `overflowCheck` scheduling.

### T6 — Harness: Terminal.app tabs

Extend `scripts/harness.sh` with a native-tabs section:

1. Open one Terminal window (`open -n -a Terminal`).
2. Add tabs: System Events `keystroke "t" using command down` (requires
   Accessibility for the harness runner). If not permitted, skip the tab
   steps with a clear warning and keep the window-level checks.
3. Switch tabs forward/back (`keystroke "]" using command down`, then
   `"["`), several times.
4. Assert: managed Terminal window count stays 1; `verify` clean; no window
   ids lost; geometry converges and is stable; record artifacts.
5. Close the extra tabs (Cmd-W via System Events) and the window.
6. Keep the existing TextEdit suite and all current assertions unchanged.

Add `--tabs-only`/`TABS_TEST=1` so this section can run alone while
iterating, and include it in the default run when permission allows.

### T7 — Docs

- README "Known behavior" and `docs/compat.md`: native tabs are one logical
  window; list Terminal/Ghostty; link the upstream Ghostty page; note the
  config flag and the harness coverage.

## Test plan

- Unit (CI, Linux): tab detector pure logic — tab switch, two real windows
  of the same app, closing one tab, tab dragged out to its own window, app
  without tabs, floating windows excluded.
- Harness (macOS): existing suite + Terminal tab section; assert no tile is
  added per switch, count returns to one when tabs close; run
  `QUIT_TEST=1` and `RECORD=1` variants.
- Manual matrix for the user: Terminal.app and Ghostty, forward/back tab
  switches, new/closed tabs, `lumina verify` + `artifacts/` geometry.
- CI: Linux layout/IPC tests green; macOS bundle builds and signs.

## Risks and rollback

- Heuristic misfire: opt-in rule, default off; each step is its own commit
  and can be reverted independently.
- T1 shows no window mapping: fall back to T3; exact route dropped.
- System Events permission missing: tab steps skip with a warning; manual
  testing still covers it.
- Tab windows on other native Spaces are out of scope; they stay ignored as
  they are today.

## Process

- Work on `feat/macos-native-tabs` only; one logical change per commit.
- Push after each loop so CI runs; keep CI green before opening the PR.
- Open a PR with summary, test plan, and known gaps; do not merge. The user
  manually tests Terminal + Ghostty and decides.

## Open questions

1. Does Terminal/Ghostty expose `AXTabGroup`/`AXTabs` with a window mapping?
   (T1 answers before any heuristic code is written.)
2. Config shape: `tabs = "native"` on `[[window-rule]]` vs a top-level
   `[native-tabs]` bundle-id list.
3. Should the tile keep the group's original slot when the user drags one
   tab out into its own window (out of scope now; decide if it appears).
