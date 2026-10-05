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

## Spec-first harness (methodology)

The harness must encode intended, user-visible behavior, not mirror the
implementation. Rules for this branch:

1. **Red first.** Every behavior gets a failing harness assertion before the
   fix. T0 is the Terminal-tab regression that must fail on `main`.
2. **Independent oracle.** Measurement comes from the OS and the CLI — a
   standalone `CGWindowList` helper under `scripts/` plus `lumina` commands —
   never from the code's own model. `lumina verify` is a diagnostic, not the
   only oracle.
3. **Absolute expectations**, not just relative diffs: one logical window =
   one tile; a lone window fills the usable rect; tiles cover the usable
   rect; hidden-workspace windows are outside the display; every managed id
   exists in the OS window list.
4. **Golden geometry** for deterministic scenarios, diffed on every run and
   updated only deliberately.
5. **Logs are diagnostics.** Quit restore is checked with real window bounds
   after quit, not by grepping the agent log.
6. **Negative cases** included: last tab closed, tab dragged out into its
   own window, quit from fullscreen, app hidden at launch.

## Design

Two routes, tried in order. The exact route needs a runtime probe first.

### T0 — Red-first harness regression (Terminal tabs)

Write the T6 Terminal-tab section and run it against `main` **before any
product change**: one Terminal window, add tabs, switch forward/back several
times. It must fail (managed window count grows by one per tab visited,
`verify` reports tiles with no matching on-screen window). Commit the test
first so the fix commit is verifiable against a real red baseline.

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

### T4 — Config (decided: top-level app list)

Add a top-level table, parsed once at startup/reload:

```toml
[native-tabs]
apps = ["com.apple.Terminal", "com.mitchellh.ghostty"]
```

Default empty. Consulted when a window is adopted: those bundle ids get
tab-group handling (exact route if T1 succeeds, otherwise the T3 rebind).

Why this and not a `[[window-rule]]`:

- Window rules are **per window**, optionally title-matched, ordered with
  last-match-wins, and answer tile/float/ignore. Native tabbing is an
  **app-level** property of the app's windowing implementation, and it must
  be known before a window is classified and adopted.
- Mixing it into rule ordering invites contradictions (`action = "float"`
  plus `tabs = "native"`) and title dependence that the behavior does not
  have.
- A top-level list has no ordering or title semantics, is trivial to expose
  in `status`/debug output (`nativeTabsApps`), and leaves room to add
  options later (e.g. `mode = "auto" | "rebind"`) without a breaking change.

If T1's exact detection is reliable, the list can default to the two known
apps; it stays as an escape hatch either way. Document both apps in
`docs/compat.md`.

### T5 — Bound the overflow loop

- Clear `overflowStrikes` when the window's element is unresolvable, when
  it leaves the tree, and after N consecutive `overflowCheck` passes
  without a confirmed refusal; cap `overflowCheck` scheduling.

### T6 — Harness: Terminal.app tabs

Extend `scripts/harness.sh` with a native-tabs section:

1. Open one Terminal window (`open -n -a Terminal`).
2. Add tabs with System Events (`keystroke "t" using command down`). This
   requires Accessibility permission for the harness runner. **The user has
   confirmed they will grant it at the prompt**, so treat a permission
   failure as a hard error with a clear message — not a silent skip.
3. Switch tabs forward/back (`keystroke "]" using command down`, then
   `"["`), several times.
4. Assert with the independent oracle and the CLI: managed Terminal window
   count stays 1; the one tile fills the usable rect; `verify` clean; no
   window ids lost; geometry converges and is stable; record artifacts.
5. Close the extra tabs (Cmd-W via System Events) and the window; assert the
   count returns to baseline.
6. Keep the existing TextEdit suite and all current assertions unchanged.

Add `--tabs-only`/`TABS_TEST=1` so this section can run alone while
iterating, and include it in the default run.

### T7 — Docs

- README "Known behavior" and `docs/compat.md`: native tabs are one logical
  window; list Terminal/Ghostty; link the upstream Ghostty page; note the
  config flag and the harness coverage.

### T8 — Dwindle-preserving minimum-size policy

Problem: boot builds a uniform dwindle, then the observed-minimum path
rebalances split ratios to satisfy AXMinSize/practical minimums, so the
layout is visibly not 50/50 (Ghostty narrower, Safari/Discord wider), and
sometimes a window is floated instead. Log evidence: `layout overflow:
clamping with observed minimum sizes` ~1 s after every boot and on
workspace returns; `floated overflow window=15918` in one session.

Decision: dwindle splits are the product. A window whose real minimum
cannot fit its tile is **floated**, not accommodated by distorting its
siblings. `clampOverflow` ratio rebalancing is removed from the launch /
insert / observed paths (or reduced to a hard-floor case), and the
observed-minimum path floats the offender.

Test-first: unit tests for the float-vs-fit decision; harness assertion
that a boot with N fitting windows yields uniform ratios, and that a
deliberately oversized-minimum window floats rather than changing sibling
geometry. Include AXMinSize and observed minimums in `debug-windows`.

### T9 — Trusted originals for quit restore

Problem: originals are polluted with engine frames captured when a window
was adopted while already tiled. Session evidence: Ghostty `15918`
original `723x449 @8,499` (tile quadrant), twin `14817` `1454x907` (full
usable), VSCode `15452` `723x449 @739,499`. `isEngineTile` only rejects a
frame equal to the *current* layout's tile, so stale tiles from earlier
sessions are restored as if they were the user's geometry; windows that
never had a trusted original restore to a stale tile or a cascade.

Design:
- Pure `looksLikeEngineFrame(rect, usable)`: edges aligned to the usable
  rect and size close to usable or usable/2, /3, /4 on either axis
  (within gap slop).
- Never store an engine-shaped frame as `originalFrame`/`knownOriginals`.
- At quit, treat an engine-shaped original as untrusted and recenter to a
  sane size instead of restoring the tile.
- Preserve the earliest trusted original across sessions; never overwrite
  a trusted original with an untrusted one.

Test-first: unit tests for the detector (full/half/quarter, gaps, normal
frames, off-display frames); harness quit check uses the independent
oracle to assert live bounds equal the pre-tiling bounds for a controlled
scenario, instead of grepping the agent log.

Note: a window that was already tiled before Lumina ever saw it untrusted
has no recoverable original; it will recenter once, after which the user's
first manual resize while paused (or the next clean adoption) becomes the
trusted original.

## Test plan

- Unit (CI, Linux): tab detector pure logic — tab switch, two real windows
  of the same app, closing one tab, tab dragged out to its own window, app
  without tabs, floating windows excluded.
- Unit (CI, Linux): `looksLikeEngineFrame` and the dwindle float-vs-fit
  decision (T8/T9).
- Harness (macOS): existing suite + Terminal tab section; assert no tile is
  added per switch, count returns to one when tabs close; uniform dwindle
  ratios when windows fit; a real minimum floats instead of distorting
  siblings; quit restore checked with live bounds via the independent
  oracle. Run `QUIT_TEST=1` and `RECORD=1` variants.
- Manual matrix for the user: Terminal.app and Ghostty, forward/back tab
  switches, new/closed tabs, 3-window launch sizing, quit-all restore;
  `lumina verify` + `artifacts/` geometry.
- CI: Linux layout/IPC tests green; macOS bundle builds and signs.

## Risks and rollback

- Heuristic misfire: top-level opt-in list, default empty; each step is its
  own commit and can be reverted independently.
- T1 shows no window mapping: fall back to T3; exact route dropped.
- System Events permission is expected and will be granted at the prompt; if
  it is later revoked, the tab section fails loudly with a clear message
  instead of passing quietly.
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
2. Should the tile keep the group's original slot when the user drags one
   tab out into its own window (out of scope now; decide if it appears).

Resolved: config shape is the top-level `[native-tabs] apps` list (T4).
