# Lumina v1 — Agent breakpoints

This is the implementation plan for agents. It is not the product contract.

- Behavior: `plans/SPEC_LUMINA.md` wins.
- Types, paths, IPC, signing, algorithms the spec defers: `plans/DESIGN_DOC_LUMINA.md` wins.
- Git and GitHub (branches, commits, PRs, push, CI, merge): **`AGENTS.md` wins. Read it before the first `git` or `gh` command in the session. Do not copy, shorten, or replace those rules here.**
- If this file and spec/design disagree on product behavior, **do not invent a third behavior**. Stop and fix this file against spec/design.
- If this file and `AGENTS.md` disagree on git/GitHub, **`AGENTS.md` wins.**

Implement **one breakpoint at a time**, in order, unless a later BP lists an explicit parallel exception. Do not start a BP whose `Depends on` is unfinished. Do not pull work from a later BP “while you are here.” Each BP has a single primary task and a hard `Done when`.

This plan uses git throughout (commits after breakpoints, pushes for CI, PRs when asked). That does **not** authorize a different git workflow. Every git action is bound by `AGENTS.md`.

No live Accessibility test suite in v1 (spec non-goal). Prove layout/config/IPC with unit tests. Prove AX/hotkeys/spaces with the manual matrix in BP-38.

---

## How to execute

1. Read `AGENTS.md` (Git and GitHub) if you have not already this session. You will commit, and you may push or open a PR; those rules apply even when a breakpoint does not mention git.
2. Read this BP’s **Spec / Design** cites before touching code.
3. Implement only the files listed. New files are allowed inside those modules; do not add a sixth SwiftPM target.
4. Run the BP’s tests (or the named `swift test --filter`) before marking it done.
5. If an external API is missing or renamed, fail soft the way the design says. Do not switch to SIP, SkyLight writes, Input Monitoring, Screen Recording, or an event tap.
6. Keep `LuminaLayout` and `LuminaIPC` AppKit-free so `swift test --filter LuminaLayoutTests` and `LuminaIPCTests` work on a Linux toolchain.
7. When the user asked for commits, or when finishing a breakpoint that you were told to land in git: commit (and push/PR if required) **only** as `AGENTS.md` specifies. Do not merge PRs unless `AGENTS.md` and the user allow it.

---

## Git / GitHub

Do not keep a second copy of git policy in this plan. **Open `AGENTS.md` and follow Git and GitHub.** In particular: stay on `main` unless told to branch; conventional branch names and commit/PR titles; PRs need a real description; never merge unless told; push so CI can run; CI must be green before the final commit and before opening a PR.

---

## Product snapshot (what v1 is)

macOS guest tiling WM. One display. Spiral tiling (Hyprland dwindle **with permanent splits**). Emulated Lumina spaces inside the native Mac Space the instance was started on. Quitting leaves apps open and frames where they are (they may overlap). Never disable SIP. Never force-quit user apps.

**Look:** no tile borders, no overlay windows. Gaps only. Menu extra is one `NSStatusItem` (`LSUIElement`): either space digits `1…N` or the single control “Start on this Space.” Hidden-space windows are a 1px vertical sliver in a bottom corner — Mission Control looks wrong; accepted.

**Feel:** Option as modifier. Instant space switch. Click-to-focus. Keyboard swap/resize always work. Mouse snap-back/swap is best-effort AX.

**v1 OS:** macOS 15.2+ Apple silicon, arm64-only. Test on 15.2, 26 Tahoe, 27 Golden Gate. Intel is out.

---

## Tech stack (verified 2026-09-16)

| Piece | Decision | External check |
|---|---|---|
| Language | Swift 6 (`swiftLanguageModes: [.v6]`). Tools version 6.3 in `Package.swift` is the floor. Host may be Swift 6.3.3 or 6.4 / Xcode 26–27. Do not bump tools version unless the compiler requires it. | Xcode 27 ships Swift 6.4 (2026-09-14). |
| Layout | Pure Swift, no AppKit, AX/top-left coords. | Design §2, §6, §20. |
| Agent | AppKit + Accessibility. No SwiftUI. | Design §2. |
| Menu extra | AppKit `NSStatusItem`, `LSUIElement`. No AX. | Design §2, §15. |
| Config | TOML 1.1 via [dduan/TOMLDecoder](https://github.com/dduan/TOMLDecoder) ≥ 0.4.4. Decoder only — write defaults by **copying** the bundled `lumina.toml`. | TOMLDecoder 0.4.4 (2026-03-24) implements TOML 1.1.0. |
| IPC | Unix socket, JSON-lines, `0600`, dirs `0700`. | Design §14, §29. |
| Hotkeys | Carbon `RegisterEventHotKey`, virtual key codes. No `CGEventTap`. | Option-only combos blocked in 15.0, restored in 15.2 ([Apple Forums 763878](https://developer.apple.com/forums/thread/763878)). |
| Login item | `SMAppService.mainApp.register()` on the extra. No LaunchAgent plist. | [SMAppService.mainApp](https://developer.apple.com/documentation/servicemanagement/smappservice). |
| Packaging | SwiftPM packages + documented bundle script for the signed two-process `.app`. arm64 only. | SwiftPM does not emit this bundle layout. |
| Updates | Out of v1 code. Homebrew tap is BP-37 docs only. No Sparkle. | Spec non-goal. |

Private APIs allowed: `_AXUIElementGetWindow` (identity), optional SkyLight **reads** via `dlsym`. Both fail soft. No private writes. Do not set `com.apple.security.cs.disable-library-validation`.

---

## Repo starting state (do not re-create)

Skeleton only. Empty types, empty tests, no TOMLDecoder dependency.

```
Sources/Lumina/          menu extra (library target, no @main)
Sources/LuminaAgent/     agent (library target, no @main)
Sources/LuminaCLI/       `lumina` executable, empty main
Sources/LuminaLayout/    empty enum
Sources/LuminaIPC/       empty enum
Tests/LuminaLayoutTests/ empty + Fixtures/.gitkeep
Tests/LuminaIPCTests/    empty
Sources/Lumina/Resources/lumina.toml   default config (already matches design §13)
Info.plist + entitlements already match design §1 / §27
Package.swift            macOS 15.2, Swift 6, apple targets gated `#if os(macOS)`
```

Convert `Lumina` and `LuminaAgent` to `executableTarget` with `@main` in BP-11 / BP-28. Do not add Xcode-only source-of-truth until BP-37; SwiftPM remains the compile graph.

---

## Global invariants (every BP)

- Spec behavior over clever WM behavior. Guest, not replacement.
- One bound `NSScreen` per instance. Manage a window iff its **AX center** is on that display. Never `setFrame` a window onto the bound display to make it managed.
- Layout math is AX / CoreGraphics: origin top-left of the menu-bar display, Y down. Convert AppKit at the adapter only. Never mix coordinate spaces in `LuminaLayout`.
- Usable rect = converted `NSScreen.visibleFrame` minus `gaps.outer` on all four sides. Do **not** also subtract menu bar, Dock, notch, or `safeAreaInsets`. Apple: `visibleFrame` already excludes dock, menu bar, and camera housing ([NSScreen.visibleFrame](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe)). If Dock autohides, do not invent a Dock-sized hole. Do not cache `visibleFrame`.
- Floaters live in `Space.floating`, never in the tree, never in `frames()`.
- Empty tiled tree: `root == nil`. Space still exists.
- `ratio` is `[Double]`, not `Float`.
- `paused` is RAM only. Never write it to `session.json`.
- Tree, ratios, floaters-as-tiles, luminaFS id, native-FS bookmarks are in-memory only.
- `instances.json`: menu extra is the **only** writer. Agents never write it.
- Accessibility is the **agent bundle** `com.zelmari.lumina.agent`, not the extra, not `lumina` on PATH.
- No Screen Recording. Use `CGWindowListCopyWindowInfo` for **ids and bounds only**. Do not read `kCGWindowName`. Do not treat `kCGWindowOwnerName == nil` as a permission probe (Golden Gate can leak owner names; Apple DTS: use `CGPreflightScreenCaptureAccess` if you ever need the permission state — v1 does not need that permission at all).
- No Input Monitoring. No event tap. No SIP. No Dock injection. No SkyLight writes (`SLSMoveWindowsToManagedSpace`, `SLSAddWindowsToSpaces`, `SLSManagedDisplaySetCurrentSpace`, bridged variants).
- Do not register ⌘Tab, ⌘`, Mission Control, ⌘⇧3/4/5, ⌘⇧Space, ⌘⇧6.
- `⌥ Q` = AX press close button. Never `SIGKILL` a user app. Never force-quit.
- `quit-all` may `SIGTERM` leftover **lumina-agent** pids after waiting; never `SIGKILL` the agent (unstash must run).
- Sandbox off. Hardened runtime on at ship time. arm64 only.
- Never log window titles at default info. Bundle id + `CGWindowID` only.
- Bindings are Carbon virtual key codes (`alt-h` is `kVK_ANSI_H` = `0x04`), not Option-layer characters.

---

## Module map

| Module | Owns | May import |
|---|---|---|
| `LuminaLayout` | Rect, tree, frames, spatial, classify (pure), config types/parse, launch-tiling, current-space heuristic (pure), session structs that are not AX | Foundation, TOMLDecoder. **No AppKit.** |
| `LuminaIPC` | JSON-lines codec, command enum, socket path helpers (pure), peer-euid check wrappers that are testable | Foundation. **No AppKit.** |
| `LuminaAgent` | AX adapter, MutationQueue, hotkeys, stash apply, sockets server, SkyLight dlsym, start paths | LuminaLayout, LuminaIPC, AppKit, ApplicationServices, Carbon, Darwin |
| `Lumina` | Status item, first-run sheet, `instances.json`, spawn/kqueue, menu.sock, SMAppService | LuminaIPC, AppKit, ServiceManagement, Darwin. **No AX.** |
| `LuminaCLI` | argv → JSON, current-token resolve, talk to sockets | LuminaIPC. No AX, no hotkeys. |

Logging helpers: small API in `LuminaIPC` (or a file per process) so all three binaries share the line format. Do not create a sixth target.

---

## BP-01 — Layout primitives and session types

**One task:** Put the in-memory data model into `LuminaLayout` as value types with no layout algorithm yet.

**Spec:** Spaces 1…10; empty tree still exists; floaters not in the tree; one luminaFS per space; managed membership is a later BP.

**Design:** §6 types (`Session`, `SpaceId`, `Space`, `Node`, `WindowRef`, `Bookmark`, `Rect`). Coordinate space comment on `Rect`.

**External:** n/a (pure types).

**Depends on:** nothing.

**Files:** `Sources/LuminaLayout/*.swift`. Split files by type if the module file would exceed a few hundred lines. Keep the `LuminaLayout` enum as a namespace if useful.

**Implement:**

1. `Rect` in AX space: `x, y, w, h` as `Double`. Helpers: `minX/maxX/minY/maxY`, `center`, `contains(point:)`, `intersection`, `area`. Integers from AX still go through `Double`.
2. `NodeId` (UUID or monotonic `UInt64`; pick one and use it everywhere — prefer monotonic `UInt64` allocated by the tree so tests are stable).
3. `SpaceId` = `Int` 1…10. Key `0` maps to 10 only at the bind/CLI layer, not here.
4. `Axis` = `horizontal | vertical`. `Direction` = `left | down | up | right`.
5. `Gaps` = `inner, outer` `Int`.
6. `WindowRole` = `tiled | floating | stashed | nativeFS | luminaFS | ignored`.
7. `WindowRef`: `cgWindowId: UInt32`, `pid`, `bundleId`, `role`, `lastOnscreenFrame`, `nativeFSBookmark`, `generation: UInt64` (starts 0).
8. `Bookmark`: `spaceId, parentId, indexInParent, ratioSnapshot, wasFloating`.
9. `Node`: `id, parent, children, axis, ratio, leaf`. Invariant comments: leaf only if `children.isEmpty`; spiral v1 splits always produce 2 children.
10. `Space`: `id, focusedWindow, lastTiledLeaf, root, floating, luminaFullscreen, lastDisplayFrame`.
11. `Session`: `instanceId, nativeSpaceToken` (alias of `instanceId`), `spaceCount`, `focusedSpace`, `spaces`, `paused`.
12. Factory: `Session.empty(spaceCount:)` builds spaces `1...count`, `focusedSpace = 1`, all `root == nil`, `paused = false`.
13. No AppKit. No CG types — `CGWindowID` is `UInt32`.

**Tests:** construct a session; space 1 exists when empty; `Rect.center` math; `SpaceId` rejects 0 and 11 at the type boundary (failable init or `precondition` in debug + `SpaceId.make` returning nil).

**Done when:** `swift test --filter LuminaLayoutTests` compiles and the type tests pass. No insert/frames yet.

**Do not:** implement spiral, frames, classify, or config.

---

## BP-02 — Spiral insert, remove, collapse

**One task:** Binary spiral tree mutations with **permanent** split axes.

**Spec:** 1 window = root. New window splits the focused tiled leaf 50/50. Focus on a floater → split `lastTiledLeaf`. No tiled leaf → new window becomes root. Wide (`width ≥ height`) first split is side by side (`horizontal`); tall first split is top and bottom (`vertical`); then alternate. Close → sibling takes space, collapse; last tiled close → `root = nil`. Ratios persist on the tree.

**Design:** §6 spiral insertion. Container children `[oldLeaf, newLeaf]`, axis = opposite of parent’s axis. Root first split from usable W/H. Ratios `[0.5, 0.5]`.

**External:** Hyprland dwindle splits are **not** permanent unless `preserve_split` is on ([Hyprland wiki, Dwindle](https://wiki.hypr.land/Configuring/Layouts/Dwindle-Layout/)). Lumina is the `preserve_split` model: **never** recompute axis from current W/H after the split is made.

**Depends on:** BP-01.

**Files:** `Sources/LuminaLayout/` tree mutation. `Tests/LuminaLayoutTests/`.

**Implement:**

1. `insertSpiral(session:space:newLeaf:focus:usableIsWide:) -> Session` (or tree-level equivalent).
   - If `root == nil`, `newLeaf` becomes `root`, focus it, copy into `lastTiledLeaf`.
   - Else target = focused tiled leaf if `focusedWindow` is that leaf; else `lastTiledLeaf`; else treat as empty.
   - Replace target with a new container: children `[old, new]`, `ratio [0.5, 0.5]`.
   - Axis: if replacing root (old was root leaf), `horizontal` if `usableIsWide` else `vertical`. Else opposite of parent’s axis.
   - Focus the new leaf; set `lastTiledLeaf`.
2. `remove(session:space:node:) -> Session`.
   - Remove leaf. If sibling exists, promote sibling into parent’s slot (or become root). Collapse empty containers.
   - Last tiled leaf → `root = nil`. Space remains. Clear `luminaFullscreen` if it pointed at the removed node.
   - Drop the `WindowRef` from any leftover indexes.
3. Keep parent pointers, child indices, and ratios consistent. v1 spiral always 2 children; n-ary is allowed in the type but insert does not create n>2.
4. `usableIsWide` is passed in (usable.w ≥ usable.h). Do not peek AppKit.

**Tests (fixtures):**

- 1 insert → root leaf.
- 2nd insert on wide → horizontal container, two leaves, equal ratio.
- 3rd insert focuses one child → that child becomes a vertical container (axis alternated).
- Tall first split is vertical.
- Close non-root leaf → sibling promoted, no hole.
- Close last tiled → `root == nil`.
- Insert after empty tree works.
- Axis does **not** flip if you later pass the opposite `usableIsWide` into `frames` (that’s BP-03); the tree axis is stored.

**Done when:** those tests pass. No geometry yet.

**Do not:** compute pixel frames, balance, or resize.

---

## BP-03 — `frames()` geometry

**One task:** Pure function from tree + usable rect + gaps → leaf rects.

**Spec:** Outer gap remains with one window. No smart-gaps. Inner gap only between sibling tiles. Floaters absent.

**Design:** §8 formula. Horizontal: `innerTotal = inner * (n-1)`; each child span = `(usable.width - innerTotal) * (w[i] / sum(w))`. Vertical analog on Y. Recurse. Leaves get the rect.

**External:** `visibleFrame` conversion is **not** this BP (adapter). This BP takes an already-AX usable rect.

**Depends on:** BP-02.

**Implement:**

1. `frames(root:nodes:usable:gaps:) -> [NodeId: Rect]` for leaves only.
2. If `root == nil`, return `[:]`.
3. Weights default equal if `ratio` empty or count mismatch — but insert always writes `[0.5,0.5]`; still guard divide-by-zero (`sum == 0` → equal weights).
4. Do not include floaters, stashed, ignored, nativeFS.
5. luminaFS leaf is still in the tree; `frames()` still returns its computed tile rect. The agent will ignore that rect while luminaFS is on (later BPs). Do not special-case luminaFS here.

**Tests:**

- 1 child: rect = usable (already outer-gapped by caller). No inner subtracted.
- 2 children horizontal, inner 8, outer already applied: two spans share `(width - 8)`, gap 8 between.
- 2 children vertical.
- Wide vs tall trees from BP-02 fixtures.
- Floater list is not an input; adding a `Space.floating` entry does not change `frames`.
- Nested spiral 3 windows: frontmost-first insert geometry is stable and deterministic.

**Done when:** `frames` tests pass for 1 and 2 children, wide and tall.

**Do not:** apply via AX, clamp min-size (that’s BP-04).

---

## BP-04 — Balance, resize ±5%, min-size clamp-then-float

**One task:** Ratio edits and overflow policy.

**Spec:** Balance = every container on the **current** space, equal child weights, recursive. Resize `⌥ -/=`: move parent split by **5% of that container** per press, along parent axis. Clamp to each child’s min size. Do not change the other axis. Min-size overflow: clamp the sibling first so both meet min; if impossible, **float** the window that will not fit and collapse its leaf. Prefer floating the newly inserted / just-resized window when both are over min. Never leave a sliver **tile**.

**Design:** §8 resize: `delta = 0.05 * sum(parent.ratio)`. Grow: add delta to focused child’s weight, subtract from sibling. Clamp so each child’s resulting frame meets that window’s min size **and ≥ 80pt** on that axis. Ignore if focused is floating or the only tiled leaf. `ratio` is `Double`.

**External:** Hyprland `splitratio` is a different numeric model (0.1–1.9 around 1.0). Do not copy it. Lumina uses child weights that sum to any positive total.

**Depends on:** BP-03.

**Implement:**

1. `balance(space) -> space` — recurse all containers, set each `ratio` to equal `1.0` per child (or `0.5/0.5`).
2. `resize(space:focusedLeaf:delta:grow|shrink:minSizes:usable:gaps) -> (space, floated: WindowRef?)`.
   - Compute proposed weights, then `frames`, then if a child pixel size < max(minSize, 80) on the parent axis, shrink the delta until both fit.
   - If even delta 0 cannot fit (min sizes already overflow), do not leave the tree invalid: float the oversized leaf (prefer the focused / newly inserted one), `remove` it, append to `floating` with `lastOnscreenFrame` unchanged.
3. `clampOverflow(space:minSizes:usable:gaps) -> (space, floated: [WindowRef])` used after insert and after display-frame change. Walk leaves; if a leaf cannot fit, clamp sibling first along parent axis; if both cannot, float the offender.
4. Min size 0 means “unknown” — only the 80pt floor applies on **user resize**. Insert/layout overflow with unknown min size does not float unless the computed span would be < 1pt (never a sliver tile).

**Tests:**

- Balance recursive: nested container both 0.5 after uneven ratios.
- Grow 5%: focused weight +0.05*sum, sibling −same; frames match.
- Clamp to 80pt: cannot shrink below 80px on that axis given usable/gaps.
- Two mins that still fit after sibling clamp → both stay tiled, ratios adjusted.
- Two mins that cannot both fit → oversized leaf floated, sibling is root or promoted, `frames` has no sliver.
- Resize ignored for floating focus and for single leaf.

**Done when:** those tests pass.

**Do not:** AX read of min size (adapter later). Here min sizes are arguments.

---

## BP-05 — Spatial focus and swap (pure)

**One task:** Directional candidate pick + three swap cases.

**Spec:** Focus H/J/K/L is spatial, not tree-walk. Tiled eligible if **frame** lies in that direction. Floating eligible if **center** sits in that direction. Winner: nearest center-to-center. Tie: lower `CGWindowID`. Swap uses the same candidate. Two tiles: exchange leaves in the tree. Tile + floater: exchange roles (floater takes tile slot, old leaf floats at last frame). Two floaters: exchange on-screen frames; neither enters the tree.

**Design:** §8 exact half-plane / strip rules (left shown; rotate). Tiled: half-plane **and** (in strip, or no tiled candidate is in the strip). Floating: center in half-plane only. Score Euclidean `F.center` to `C.center`.

**External:** n/a (product rule). Do not copy i3/Hyprland tree-neighbor focus.

**Depends on:** BP-01 (needs frames of candidates; may take `[SpatialWindow]` not a live tree).

**Implement:**

1. `struct SpatialWindow { id, role: tiled|floating, frame, cgWindowId }`.
2. `focusSpatial(windows:from:dir) -> SpatialWindow?`. None eligible → nil (no-op).
3. Half-plane left: tiled `C.minX < F.center.x`; floating `C.center.x < F.center.x`.
4. Strip left/right: `C` intersects `F.minY…F.maxY`. Up/down: `F.minX…F.maxX`.
5. `swap(session:space:a:b)`:
   - tiled/tiled: swap `leaf` WindowRefs on the two nodes; parents/indices/ratios stay.
   - tiled/floating: remove floater from `floating`, put it in the tile’s leaf; old leaf → `floating` at `lastOnscreenFrame`.
   - floating/floating: swap `lastOnscreenFrame` only.
6. Candidates: current space, role tiled or floating, not stashed/ignored/nativeFS. luminaFS window is tiled-in-tree; it is eligible if shown (agent will only pass visible ones).

**Tests:**

- Tiled eligibility is frame (`C.minX < F.center.x`), not center — a tile whose center is not left of F but whose left edge is, is eligible.
- Tile in strip wins over a nearer floater whose center is in-direction.
- Tie → lower `CGWindowID`.
- Two-floater swap is frames only; tree `root` unchanged.
- Tile/floater role exchange.
- Two-tile leaf exchange preserves ratios.
- No candidate → nil.

**Done when:** design §18 spatial bullets pass.

**Do not:** call AX raise. This is pure.

---

## BP-06 — Launch tiling policies (pure)

**One task:** Build a space from an ordered window list.

**Spec:** After unstash, on the rebuild space: default `z-order` = spiral front-to-back in current z-order, then **refocus the original frontmost**. `float-existing` and `new-only` are **aliases in v1**: already-open windows float (toggleable); windows opened after this start tile.

**Design:** §6 launch tiling. Collect managed, center-on-bound-display, classify-as-tile, **front-to-back** (index 0 = frontmost). `insertSpiral` each, focusing the new leaf after each insert. After batch, focus original frontmost if still a tiled leaf. Rebuild space: crash → `focusedSpace` if still in 1…count else 1; quit-then-start / first bind / new boot → **space 1**. This BP takes `(policy, windowsFrontToBack, rebuildSpaceId)` and does not know about boots.

**Depends on:** BP-02, BP-05.

**Implement:**

1. `enum LaunchTiling { case zOrder, floatExisting, newOnly }` with `floatExisting` and `newOnly` sharing one implementation.
2. `applyLaunchTiling(session:spaceId:policy:windows:usableIsWide) -> Session`.
   - `z-order`: insert each as tiled via `insertSpiral`; record first window as original frontmost; at end set `focusedWindow` / `lastTiledLeaf` to that id if still a tiled leaf.
   - alias policy: put each window into `Space.floating` with its frame; do not insert; `root` stays nil.
3. Caller is responsible for “already-open vs later” — this function only handles a batch.

**Tests:**

- z-order 3 windows: frontmost ends as a leaf whose frame is ~50% (first insert is root; second splits it 50/50; third splits whatever was focused — focusing new leaf each time means window 0 is split, then the newest is focused, so **window 0 stays the first child of root** and occupies ~50% after 3 inserts). Assert that, and that focus returns to window 0.
- alias: 3 windows all in `floating`, `root == nil`.
- Empty list: no-op.

**Done when:** design §18 launch-tiling bullets pass.

**Do not:** CGWindowList. Windows are fixtures.

---

## BP-07 — Classify (pure)

**One task:** Window → ignore / float / tile from rules + heuristics. No AX.

**Spec:** Default tile unless it looks like a dialog. Rules match `app-id` + optional title regex; first match wins. `ignore` always wins. `tile` cannot override roles (utility/panel/sheet/tooltip/popover), named system UI, PiP/HUDs; **can** override no-zoom heuristic and min-size floor. Always float those hard roles / system UI / PiP. Soft float: no zoom (except terminal allow-list) and size below ~400×300. Hidden native tab → ignore. Center on other display → unmanaged (not a classify action — caller skips). Default config floats System Settings. Native tabs: only visible tab is a tile.

**Design:** §11 order 1…5. Hard bundle ids listed. Terminal allow-list bundle ids listed. Title regex re-classify is an agent concern; here accept `title: String?` and `titleKnown: Bool`.

**External:** AX role/subrole names from Apple HIServices (`AXSheet`, `AXDrawer`, `AXPopover`, `AXHelpTag`, `AXFloatingWindow`, `AXSystemFloatingWindow`, `AXDialog`, `AXSystemDialog`, `AXStandardWindow`). Bundle ids from design, not guessed.

**Depends on:** BP-01.

**Input fixture type:**

```
ClassifyInput:
  bundleId, title, role, subrole, hasZoomButton, width, height,
  isOnScreen, pidAlreadyHasOnScreenWindow,
  layerOrIsHUD, isPiP, isVisualIntelligenceOrSiriHUD
  centerOnBoundDisplay: Bool
```

**Implement `classify(input, rules) -> ClassifyResult` where result is `unmanaged | ignored | floating | tiled` plus `allowTiled` flag used internally:**

1. If `!centerOnBoundDisplay` → `unmanaged`.
2. Hidden native tab: `!isOnScreen && pidAlreadyHasOnScreenWindow` → `ignored`.
3. Rules, first match:
   - `ignore` → `ignored` (stop).
   - `float` → `floating` (stop).
   - `tile` → set `allowTiled = true`, continue.
4. Hard float even if `allowTiled`:
   - role in `{AXSheet, AXDrawer, AXPopover, AXHelpTag}` or subrole in `{AXFloatingWindow, AXSystemFloatingWindow}` (utility/panel).
   - `AXDialog` / `AXSystemDialog`: this is “looks like a dialog.” Float unless `allowTiled` (spec did not put “dialog” on the cannot-override list; tile rule may force-tile a dialog-looking standard window, but **cannot** override sheet/utility/PiP). If not `allowTiled`, float.
   - bundle id in hard list: `com.apple.Spotlight`, `com.apple.notificationcenterui`, `com.apple.controlcenter`, `com.apple.loginwindow`, `com.apple.ScreenSharing`, `com.apple.screencaptureui`, `com.apple.UserNotificationCenter`.
   - PiP / HUD / Visual Intelligence capture / Siri HUD flags. Do not raise (agent later). **Siri.app is not on this list.**
5. Soft float unless `allowTiled` or terminal allow-list:
   - terminals: `com.apple.Terminal`, `com.googlecode.iterm2`, `org.alacritty`, `com.mitchellh.ghostty`, `net.kovidgoyal.kitty`, `com.github.wez.wezterm`.
   - no zoom button → float (terminals skip this).
   - `width < 400 || height < 300` → float (400×300 tiles; 399×299 floats).
6. Else `tiled`.

**Tests:**

- Sheet + tile-rule still floats.
- Terminal no-zoom tiles.
- 399×299 floats; 400×300 tiles.
- System Settings default float rule (`com.apple.systempreferences` and `com.apple.Preferences`).
- Spotlight hard-float even with tile-rule.
- Title-regex miss: title nil + float-rule on title → does not match; title later matches (second call).
- Center on other display → unmanaged.
- Hidden tab heuristic → ignored.
- Siri.app (`com.apple.siri` or whatever fixture uses) with standard window → tile unless dialog heuristic.
- PiP flag → float.

**Done when:** design §18 classify bullets pass.

**Do not:** AX. Record unknown VI/Siri-HUD bundle ids in `docs/compat.md` only when discovered (BP-38).

---

## BP-08 — Config parse and validate

**One task:** TOML → `Config` with reject-and-keep-last-good semantics.

**Spec:** `~/.config/lumina/lumina.toml`. Covers space count 1–10, gaps, FFM, launch tiling, `launch-apps`, keybinds, window rules. Unknown keys: log and ignore. Invalid types / out-of-range: keep last good, error for the extra.

**Design:** §13 schema and validation. Duplicate chords: last wins, log. Bad regex: skip that rule, log. `launch-apps` unknown ids: log, skip (at launch time, not parse time — parse accepts any string). No binding modes. Not `aerospace.toml`.

**External:** Add `.package(url: "https://github.com/dduan/TOMLDecoder", from: "0.4.4")` to `Package.swift`; depend from `LuminaLayout`. TOMLDecoder is decode-only.

**Depends on:** BP-01.

**Implement:**

1. `Config` Codable matching the default file already at `Sources/Lumina/Resources/lumina.toml`. Use kebab-case keys via `CodingKeys` (`space-count`, `focus-follows-mouse`, `launch-tiling`, `launch-apps`, `title-regex`, `app-id`).
2. `Bindings` is `[String: String]` then parsed to `[(chord: Chord, command: Command)]`.
3. Known command strings: exactly the design table (`focus left`, `swap down`, `resize shrink`, `workspace 10`, `move-node-to-workspace 3`, `workspace prev`, `fullscreen lumina`, `float-toggle`, `close`, `balance`, …). Unknown command string → **file invalid**.
4. Chord parser: `alt-h`, `alt-shift-1`, `alt-leftSquareBracket`, `alt-minus`, `alt-equal`, `alt-space`, `alt-0`. Map to virtual key codes from design §28 (copy the table; those match `HIToolbox/Events.h` `kVK_ANSI_*`).
5. After Codable decode, second pass over raw TOML table (TOMLDecoder can expose `TOMLDeserializer` / decode to `[String: Any]`) to log unknown top-level keys. Extra keys must not fail decode.
6. `parseConfig(text:defaults:) -> Result<Config, ConfigError>`. Range checks: `space-count` 1…10, gaps 0…128 integers, FFM bool, `launch-tiling` enum.
7. `loadOrDefault(path:bundledDefault:)`: missing file is **not** this BP’s FS write (agent/extra write it in BP-18/29). Here: if text empty/missing → return bundled default parsed.
8. Invalid file function: `applyReload(current:newText) -> (config: Config, error: String?)` — on failure return `current` + error string.

**Tests:**

- Default bundled TOML parses.
- `space-count = 0` reject; `gaps.inner = -1` reject; bad regex skips that rule but file still valid; unknown command string rejects file.
- Unknown top-level key ignored (file valid).
- Duplicate chord last wins.
- Shrink space-count is **not** applied here; that’s a session transform tested in this module: `applySpaceCount(session:newCount)` — dropped spaces pour onto space 1; if `focusedSpace` dropped, `focusedSpace = 1`. Test that. Wire it to live reload in BP-33.
- `workspace id > count` no-op is a command handler test (BP-09/21); add a pure `func resolveWorkspace(id:count) -> SpaceId?` that returns nil if `id > count` (nil means no-op).

**Done when:** design §18 config bullets that are parse/reject/shrink pass.

**Do not:** FSEvents, live AX, or writing `~/.config`.

---

## BP-09 — IPC protocol codec

**One task:** JSON-lines request/response types and parser (no sockets yet).

**Spec:** CLI for the same actions as keybinds, plus pause/resume, quit, quit-all, reload, start, list-windows, list-workspaces. Any same-user process may drive the socket (accepted).

**Design:** §14. `v` must be 1. `id` echoed. Extra args ignored. Unknown cmd → `{"ok":false,"error":"unknown cmd"}`. Malformed JSON: one error line, stay up. Max line 1 MiB; over that, close (socket BP enforces close; codec returns `.lineTooLong`).

**External:** JSON via `JSONEncoder`/`JSONDecoder` (Foundation). UTF-8. No length prefix.

**Depends on:** nothing (can parallel BP-01…08). **Parallel exception:** may start after BP-01 types exist for list-windows payload, or use IPC-local DTOs.

**Implement:**

1. `IPCRequest { v, id, cmd, args: JSONObject }`.
2. `IPCResponse { v, id, ok, error?, data? }`.
3. `enum AgentCmd` with associated values matching the agent table. `enum ExtraCmd` for `current-token | start | quit-all | open-config | status`.
4. `parseLine(_ :) -> ParseResult`. `v != 1` → error (design §29: ignore `v` ≠ 1 — respond error, do not execute).
5. Missing required args (e.g. `focus` without `dir`) → `ok:false` with a stable error string.
6. `encode` one object per line, no pretty-print, newline terminated.

**Tests:**

- Round-trip `workspace` `{id:3}`.
- Unknown cmd.
- Missing args.
- `v: 2` rejected.
- Line of 1 MiB + 1 → `lineTooLong`.
- Extra args ignored (`focus` with unused key still parses).

**Done when:** design §18 command-parse bullets pass under `LuminaIPCTests`.

**Do not:** bind sockets.

---

## BP-10 — Logging

**One task:** Shared log line format: `os_log` + `~/Library/Logs/Lumina.log`.

**Spec:** (implicit via design). Debug via `lumina debug` / `LUMINA_DEBUG=1` is CLI (BP-22); this BP only the logger.

**Design:** §18. Subsystem `com.zelmari.lumina`, category `agent | extra | cli`. File: each process appends `O_APPEND`, line prefixed `[agent|extra|cli]`. Short `flock` per write. Do not share a seekable handle across processes. Never log titles at info.

**External:** `os.Logger` ([OSLog](https://developer.apple.com/documentation/os/logger)). `flock(2)` on Darwin. `open(2)` `O_APPEND`.

**Depends on:** nothing. **Parallel exception:** after BP-09 or standalone.

**Implement:**

1. `LuminaLog` in `LuminaIPC` (Foundation + Darwin `#if os(macOS)` for flock; on Linux tests, file write without flock is OK).
2. Info default; `debug` when env `LUMINA_DEBUG=1` or a process-local flag.
3. API: `info/debug/error(_ message:)` interpolating only bundle ids, pids, window ids, paths.
4. Create `~/Library/Logs` if needed. Do not log the message to stdout except CLI stderr for errors.

**Tests:** debug-off drops debug lines to the file; flock doesn’t deadlock a single process writing twice.

**Done when:** a unit test writes two lines with the `[agent]` prefix.

**Do not:** wire every call site yet; later BPs use it as they go.

---

## BP-11 — Agent process skeleton and MutationQueue

**One task:** Boot an AppKit agent with a serial mutation queue and AX timeout policy. No tiling yet.

**Spec:** Agent owns Accessibility, tree, stash, optional SkyLight, its socket, layout passes.

**Design:** §3 agent role. §26: AXObserver/hotkeys arrive on main; hop immediately to `MutationQueue` = `DispatchQueue(label: "com.zelmari.lumina.mutate")`. Exclusive owner of the tree. Coalesce: at most one pending layout pass. If a pass has been running AX > 200ms, skip remaining windows, log, continue next pass. `AXUIElementSetMessagingTimeout(el, 0.05)` per call; timeout → retry once at 0.05, then float. AX objects are not Sendable; create them on MutationQueue from pid. §27: `LSUIElement`, min 15.2, arm64 runtime check can live in the extra; agent may also exit if not arm64.

**External:** [AXUIElementSetMessagingTimeout](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout) — timeout must be positive; 0 resets. Pass system-wide element for a process-global timeout **and** set per-element if you recreate elements. [AXIsProcessTrusted](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions) — prompt is the extra’s job; agent only checks.

**Depends on:** BP-01, BP-10.

**Files:** convert `LuminaAgent` to `executableTarget` with `@main`. `Package.swift` exclude Info.plist/entitlements stays.

**Implement:**

1. `@main struct AgentApp`: `NSApplication` + `setActivationPolicy(.accessory)`, no Dock icon.
2. Parse argv/env: `instanceId`, socket path, display UUID, optional SkyLight id, `--crash-recover` flag (used BP-18). Menu extra will pass these in BP-31; until then, allow env `LUMINA_INSTANCE_ID`.
3. `MutationQueue` wrapper: `func hop(_ block: @escaping () -> Void)`, `func scheduleLayoutPass(_ work:) ` coalescing.
4. On start: if not `AXIsProcessTrusted()`, idle: no observers, no layout, stay alive (extra shows the sheet).
5. Set messaging timeout on `AXUIElementCreateSystemWide()` to 0.05s.
6. Run `NSApp.run()`.

**Tests:** none live AX. Unit-test coalesce: three `scheduleLayoutPass` before drain → work ran once. Unit-test 200ms skip with a fake clock if you inject a timer; otherwise a small `MutationQueue` test with a mock `now`.

**Done when:** `swift build --target LuminaAgent` succeeds; agent launches, logs, and exits on SIGTERM without crashing. Idle without AX.

**Do not:** enumerate windows, register hotkeys, or open sockets.

---

## BP-12 — AX adapter (identity, coords, setFrame, generation)

**One task:** Talk to one window: id, frame get/set, generation tagging.

**Spec:** Identity is public-enough: `_AXUIElementGetWindow` + pid. setFrame retry once; then float and log.

**Design:** §6 identity. Fallback `(pid, role, position, size)` if private function missing. §7 own mutations increment `generation`; ignore `AXMoved`/`AXResized`/`AXWindowMiniaturized` whose generation matches in-flight. §8 set position and size separately (`kAXPositionAttribute`, `kAXSizeAttribute`); size then position then size again if read-back missed. §26 timeout policy. Coordinate conversion at this adapter.

**External:** `_AXUIElementGetWindow` is undocumented and used by AeroSpace/Rectangle ([AeroSpace README](https://github.com/nikitabobko/AeroSpace) — single private API). Declare via a tiny bridging header or `@_silgen_name`. Treat `kCGNullWindowID` (0) as failure (AeroSpace bug #2169). AX attributes: `kAXPositionAttribute`, `kAXSizeAttribute` are `AXValue` of type `CGPoint`/`CGSize`. AppKit `visibleFrame` is bottom-left Y-up; AX is top-left Y-down relative to the menu-bar display. Conversion: `ax.y = menuBarScreen.frame.maxY - ns.y - ns.height` using `NSScreen.screens[0]` (menu-bar screen) as the Y origin, not `NSScreen.main`.

**Depends on:** BP-11.

**Implement:**

1. `AXAdapter` used **only** on MutationQueue.
2. `windowId(for: AXUIElement) -> UInt32?` via `_AXUIElementGetWindow`; fallback matcher.
3. `frame(of:) -> Rect?` AX coords.
4. `setFrame(_:of:tag: WindowRef) -> SetFrameResult`:
   - increment `generation`, store in-flight.
   - `AXUIElementSetAttributeValue` size, position, size.
   - read back; if missed, retry once (full sequence).
   - still wrong → `.failed` (caller floats).
5. `shouldIgnoreAXGeometry(window:)` true if in-flight generation matches.
6. `pressClose(of:)`: copy `kAXCloseButtonAttribute`, `AXUIElementPerformAction(button, kAXPressAction)` ([AXUIElementPerformAction](https://developer.apple.com/documentation/applicationservices/1462091-axuielementperformaction)).
7. `isMinimized`, `deminiaturize`, `unhide` helpers (used BP-16).
8. `hasZoomButton`: `kAXZoomButtonAttribute` present and not null.
9. `role`/`subrole`/`title`/`bundleId` (bundle id from `NSRunningApplication(pid)` not from AX title).
10. Wrap every private call. Missing `_AXUIElementGetWindow` → fallback, log once.

**Tests:** `shouldIgnoreAXGeometry` mocked (design §18). Coordinate conversion unit tests with fake `menuBarHeight` / screen frame numbers (pure functions extracted from the adapter).

**Done when:** conversion tests pass; adapter compiles; generation ignore tests pass.

**Do not:** layout apply loop (BP-14). Do not read `kCGWindowName`.

---

## BP-13 — Bound display, enumeration, center membership

**One task:** Know the bound `NSScreen` and list managed candidates.

**Spec:** Bound display = `NSScreen` containing the focused window at bind, else `NSScreen.main`. v1 manages that display only. Window managed iff **center** on bound display. Never move a window onto it to manage it.

**Design:** §5 `displayUUID` from `CGDisplayCreateUUIDFromDisplayID` on `NSScreenNumber`. §16 window ids/bounds from `CGWindowListCopyWindowInfo(.optionOnScreenOnly)`.

**External:** [CGDisplayCreateUUIDFromDisplayID](https://developer.apple.com/documentation/colorsync/cgdisplaycreateuuidfromdisplayid(_:)). `NSScreen.deviceDescription["NSScreenNumber"]` ([deviceDescription](https://developer.apple.com/documentation/appkit/nsscreen/devicedescription)). Cache UUID at bind; on removal Apple’s UUID API can fail — compare cached UUID (design §17). `CGWindowListCopyWindowInfo` returns bounds in CG/AX space (top-left).

**Depends on:** BP-12.

**Implement:**

1. `BoundDisplay { uuid, nsScreen, axFrame, axVisibleFrame, usableRect(gaps) }`. Recompute frames every layout pass (do not cache `visibleFrame`).
2. `usableRect`: convert `visibleFrame` to AX, then inset `gaps.outer` on all four sides.
3. `enumerateAXWindows(on:)`: `NSWorkspace.runningApplications` (regular + accessory as needed), `AXUIElementCreateApplication(pid)`, `kAXWindowsAttribute`. Skip `kCGNullWindowID`.
4. `onScreenCGWindows(display:)`: `CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)` filtered by bounds intersecting the display’s AX frame. Use `kCGWindowNumber`, `kCGWindowBounds`, `kCGWindowOwnerPID`, `kCGWindowLayer`. Not names.
5. Membership: `rect.center` inside bound display’s **full** `axFrame` (not usable). Other display → unmanaged.
6. `usableIsWide` = `usable.w >= usable.h`.

**Tests:** membership function with two fake display rects. UUID parse. Do not hit live CG in unit tests.

**Done when:** agent can log count of on-screen windows on the bound display without moving any.

**Do not:** insert into the tree yet.

---

## BP-14 — Single-space apply loop (new / close)

**One task:** One Lumina space, spiral apply via AX, on window create/destroy.

**Spec:** New tiled window splits focused tiled leaf. Close reflows. Target AX-event to last setFrame ≤ 50ms on a quiet desktop; coalesce bursts.

**Design:** §10 pipeline: event → MutationQueue → classify+tree (pure) → `frames()` → AX setFrame. Debounce create bursts 30–50ms. One apply queue.

**Depends on:** BP-02, BP-03, BP-04, BP-07, BP-13.

**Implement:**

1. In-memory `Session` with `spaceCount = 1` for now, `focusedSpace = 1`.
2. Subscribe `AXObserver` per pid: `kAXWindowCreatedNotification`, `kAXUIElementDestroyedNotification`, `kAXFocusedWindowChangedNotification`, `kAXWindowMovedNotification`, `kAXWindowResizedNotification`, `kAXTitleChangedNotification` (reclassify later). Also `NSWorkspace.didLaunchApplicationNotification` / `didTerminateApplicationNotification` on **`NSWorkspace.shared.notificationCenter`** (not `NotificationCenter.default`) — Apple requires this ([activeSpaceDidChangeNotification](https://developer.apple.com/documentation/appkit/nsworkspace/activespacedidchangenotification) documents the same center).
3. Create path: debounce 40ms → classify (hardcode empty rules + BP-07 defaults) → tile `insertSpiral` or float append → `applyFrames`.
4. Destroy path: if id in tree, `remove` + collapse; if in `floating`, drop it.
5. `applyFrames`: for each tiled leaf, `setFrame` computed rect. Skip if paused. Tag generation.
6. Focus: on `kAXFocusedWindowChanged`, if the window is ours on this space, update `focusedWindow` / `lastTiledLeaf`. Do not raise.
7. `AX set-frame fail` twice → float that window (BP-04 remove + floating).

**Tests:** tree tests already exist. Optional mock adapter protocol for “apply called with these rects.”

**Done when:** manually, two Terminal windows tile 50/50 on one display with outer/inner gaps 8. Close one → the other fills usable. This is the first on-machine milestone; note it in the log. Unit tests still the authority in CI.

**Do not:** spaces, stash, hotkeys, menu extra.

---

## BP-15 — Live classify (rules, tabs, hard-float)

**One task:** Wire BP-07 to real AX + default rules.

**Spec:** Default config System Settings float. Native tab groups: only the visible tab is a tile; hidden tab AX windows ignored until on-screen. Heuristic will be wrong for some apps → `docs/compat.md`.

**Design:** §7 native tabs: visible = `CGWindowID` in on-screen list with width ≥ 8 and height ≥ 8. New AX window of pid P not on-screen while P already has an on-screen window → hidden tab → ignored. Tab switch: promote new id, ignore old. §11 title-regex re-classify once on `kAXTitleChangedNotification` if still unmanaged/floating from a title miss. PiP/HUD: float, do not `raise` / steal focus.

**Depends on:** BP-14, BP-08 (rules type; may load default rules in-memory without file watch).

**Implement:**

1. Load rules from parsed default config (bundled string) if `~/.config/lumina/lumina.toml` missing — **do not write the file yet** unless you must; writing defaults is BP-29. Reading a missing file → bundled defaults is OK.
2. Pass live `ClassifyInput` from adapter + on-screen set.
3. Title change: re-run classify once; if it becomes tile and currently floating-from-title-miss, `insertSpiral`.
4. Do not steal focus when floating PiP/HUD (do not AX raise, do not `NSRunningApplication.activate`).

**Tests:** classify fixtures already in BP-07. Add a hidden-tab fixture through the agent’s mapper if extracted.

**Done when:** System Settings floats without a user rule file; a Terminal tab switch does not create a second tile for the hidden tab (manual + heuristic unit test).

**Do not:** compat.md essays. One-line note only if you hit a miss.

---

## BP-16 — Minimize and Hide undo

**One task:** Yellow / ⌘M and ⌘H must not hole the tree.

**Spec:** Undo minimize immediately (unminimize + keep the tile). ⌘H unhide immediately, same. Other apps’ yellow buttons cannot be disabled; snap-back is the behavior.

**Design:** §12: observe `kAXWindowMiniaturizedNotification`, immediately deminiaturize. Miniaturize is async via Dock on macOS 13+; if still miniaturized on the next AX tick, try again once. Hide: **not** `kAXUIElementDestroyed`. Use application-hidden / `AXHidden` / `NSWorkspace` hide (`didHideApplicationNotification`). Unhide via `NSRunningApplication.unhide` or AX raise of hidden windows; keep roles. Generation-tag so unhide is not treated as user focus.

**External:** `kAXWindowMiniaturizedNotification` is posted after the window is put in the Dock ([NSAccessibility.windowMiniaturized](https://developer.apple.com/documentation/appkit/nsaccessibility/notification/1528694-windowcreated) family). `NSRunningApplication.unhide()`.

**Depends on:** BP-14.

**Implement:**

1. Miniaturize → hop MutationQueue → if generation in-flight, ignore; else deminiaturize; if still miniaturized next tick, once more.
2. Hide → unhide immediately; do not remove from tree.
3. Do not change role.

**Tests:** mocked generation ignore already required. Optional state-machine test: `onMiniaturize(tagged:)` → no-op; `onMiniaturize(untagged:)` → deminiaturize command emitted.

**Done when:** those unit tests pass. Manual: ⌘M and ⌘H on a tiled Terminal do not leave a hole (BP-38 matrix).

**Do not:** treat hide as close.

---

## BP-17 — 1px-corner stash and `session.json`

**One task:** Park off-space windows as a sliver; persist stash (not the tree).

**Spec:** Hidden-space windows are not Dock-minimized and not `orderOut`. macOS will not accept a fully off-screen frame. Park as a **1-pixel vertical sliver in a bottom corner** of the bound display. A few pixels remain visible. Mission Control looks wrong; accepted.

**Design:** §9. Save `lastOnscreenFrame` first. 1×N or N×1 in a bottom corner of the **bound display**, just outside `visibleFrame` but still on the display (WindowServer-accepted). Prefer the corner that does not sit on another display. v1 one display: **bottom-right**, unless Dock is on the right, then bottom-left. Session path `~/Library/Application Support/Lumina/spaces/<instanceId>/session.json`. Write on space switch, on quit, debounced on crash-sensitive paths. Frames AX/top-left. Stash array fields per design JSON.

**External:** AeroSpace documents that macOS refuses fully off-screen frames and uses a 1px vertical line in the bottom-right or left corner ([AeroSpace guide](https://nikitabobko.github.io/AeroSpace/guide)). Do **not** park at `(-10000, y)`. Detect Dock on the right by `visibleFrame.maxX < frame.maxX` (or `defaults read com.apple.dock orientation` — read only). Apple `NSWindow.setFrameOrigin` notes WindowServer clamps coordinates (historical ±16000); fully off-display still gets pulled back — that is why slivers exist.

**Depends on:** BP-14.

**Implement:**

1. `stashFrame(for:lastHeight:display:dockRight:) -> Rect` — width 1, height = max(lastOnscreenFrame.h, 8) so the sliver is findable, x = `display.axFrame.maxX - 1` (or `minX` if dock right), y = `display.axFrame.maxY - height` (AX Y-down: maxY is the bottom). Keep the strip inside `display.axFrame` (on-screen), even if outside `visibleFrame`.
2. `stash(_ windows)`: save lastOnscreenFrame if current frame is not already a sliver; `setFrame` sliver; role `.stashed` (tiled nodes stay in the tree; floaters stay in `floating` but are physically slivered).
3. `unstash`: `setFrame(lastOnscreenFrame)` then apply tree frames for the destination space.
4. Session encode/decode. Dirs `0700`. Write atomically (write temp + `rename`).
5. Detect leftover slivers: on-screen windows with width ≤ 2 or height ≤ 2 matching a session stash entry, **or** any 1px strip in the stash corners even without a file (crash leftovers).

**Tests:** `stashFrame` bottom-right vs bottom-left. Session JSON round-trip. Do not persist `paused`, tree, or bookmarks.

**Done when:** calling stash/unstash in a unit test with a fake adapter records the right rects; JSON matches design §6.

**Do not:** multi-space switch yet (BP-20 will call these).

---

## BP-18 — Agent start paths (unstash + launch tiling + rebuild space)

**One task:** Every agent boot follows the spec start/crash/quit matrix.

**Spec:** Start of an instance (same boot): unstash leftover slivers if any, then apply launch tiling to managed windows on the bound display. Crash (token kept): rebuild onto last focused Lumina space if still valid, else space 1. Quit this Space then Start / first bind / new boot: space 1.

**Design:** §6 same-boot crash vs quit-then-start. `session.json` `focusedSpace` used **only** on crash recover (token kept). After quit, do not restore `focusedSpace` from an old file. `launch-apps` is BP-34.

**Depends on:** BP-06, BP-17.

**Implement:**

1. Flags: `recoverCrash: Bool` from extra (BP-31). Until extra exists, env `LUMINA_CRASH_RECOVER=1`.
2. Start:
   - Read session file if present.
   - Unstash leftovers (file + heuristic slivers on bound display).
   - Choose rebuild space: crash && focusedSpace in 1…count → that space; else **1**.
   - Apply `launch-tiling` policy from config (default z-order).
   - Wipe native-FS bookmarks (they are RAM; start with none).
   - `paused = false` always on start.
3. After quit path (handler in BP-21): unstash all to lastOnscreenFrame, write session with **empty** stash, do not keep tree.
4. Do not tile twice (no extra layout pass after launch tiling besides apply).

**Tests:** pure function `rebuildSpaceId(crashRecover:sessionFocused:spaceCount) -> SpaceId`. Launch tiling already tested. Integration: session with stash entries → unstash called before tiling (mock adapter order).

**Done when:** those tests pass; a debug agent restart with `LUMINA_CRASH_RECOVER=1` uses focusedSpace 3 from a fixture file.

**Do not:** `launch-apps` (BP-34). Do not wipe `instances.json` (extra).

---

## BP-19 — Carbon hotkeys

**One task:** Register default Option binds with virtual key codes; dispatch into MutationQueue.

**Spec:** Modifier Option; Option+Shift for move/destructive. Defaults listed in spec Input. Bindings use Carbon virtual key codes. Secure Input makes Option hotkeys die — surface later (BP-35). If Option+H cannot register, fail that bind **loudly** (log + flag for extra); do not silently take Input Monitoring.

**Design:** §12 `RegisterEventHotKey`. §28 keycode table. Do not install `CGEventTap`. Pause: this instance ignores hotkeys (unregister or no-op handler). Register only while token is current (BP-32 will unregister on swipe-away; this BP registers on start as current).

**External:** `RegisterEventHotKey` first arg is a virtual key code, not a character ([CGKeyCode](https://developer.apple.com/documentation/coregraphics/cgkeycode); Carbon sample uses key 36 for Return). Design table matches `kVK_ANSI_H/J/K/L/…` in `Events.h`. 15.2+ required for Option-only.

**Depends on:** BP-08 (chord → keycode), BP-14 (commands to call).

**Implement:**

1. `Hotkeys.register(bindings:)` using `optionKey` / `optionKey | shiftKey`.
2. Handler: hop MutationQueue; if `paused`, return.
3. Map commands to the pure functions + apply.
   - focus/swap/resize/balance/float-toggle/close/fullscreen stubs: fullscreen no-ops until BP-24/23; workspace no-ops until BP-20. **Still register the keys** so later BPs only fill the handler.
4. On register failure of any default bind: set `hotkeyError` string including the chord; log.
5. `UnregisterEventHotKey` on pause and on shutdown.

**Tests:** keycode map unit tests against the design table (h=0x04, j=0x26, k=0x28, l=0x25, minus=0x1B, equal=0x18, 1=0x12, 0=0x1D, leftBracket=0x21, rightBracket=0x1E, b=0x0B, f=0x03, q=0x0C, space=0x31).

**Done when:** on a 15.2+ machine, `⌥ L` focuses spatially among two tiled windows. ISO extra keys not default-bound.

**Do not:** event tap fallback. Do not bind Visual Intelligence / Mission Control / screenshots.

---

## BP-20 — Multi-space switch, wrap, move-and-follow

**One task:** 1–10 emulated spaces this boot, instant switch via stash.

**Spec:** Not macOS Spaces. Persistent this boot, default 5, configurable 1–10. Keys 1–9 and 0 always map to 1–10; unused numbers no-op if count < 10. Spaces stay alive empty. Numbered, no names. Each keeps tree, focus, ratios, floaters. Move window to N **and follow**. If the window was luminaFS, drop luminaFS on source (unstash siblings), insert as **tile** at focus on dest. Next/prev wraps. Shrinking count: BP-33. ⌘Tab: observe app activation — if the app’s relevant window lives on another Lumina space, switch there.

**Design:** §7 switch away → sliver stash visible tiled+floating; switch here → unstash + apply tree. App activation from stash: switch to that window’s space, unstash, focus. Multi-window app: AX focused/main window; else most recently focused Lumina window of that pid.

**Depends on:** BP-17, BP-19.

**Implement:**

1. `spaceCount` from config (default 5). Session has N spaces.
2. `switchTo(id)`: if `id > spaceCount`, no-op ok. If same, no-op. Else stash current space windows; unstash dest; apply frames; write session (focusedSpace + stash of hidden); update `focusedSpace`.
3. `workspace prev/next` wrap: `1 → count`, `count → 1`.
4. `move-node-to-workspace N`: take focused window; if luminaFS, clear luminaFS and unstash siblings on source first; remove from source tree/floating; insertSpiral as tile at dest focus (even if it was floating — spec: insert as tile); follow with `switchTo`.
5. `NSWorkspace.didActivateApplicationNotification` via workspace notification center: if paused or not current native space, ignore; else find that pid’s window on another Lumina space → `switchTo`.
6. Write session on each switch.

**Tests:** wrap math; no-op id > count; move-and-follow updates focusedSpace; luminaFS drop on move is a pure session transform (can test before BP-24 has the AX expand, using the flag).

**Done when:** `⌥ 2` hides space-1 windows as slivers and shows space-2; `⌥ ⇧ 2` moves the focused window and follows. `⌥ [` / `]` wrap.

**Do not:** second native-Space instance (BP-32).

---

## BP-21 — Agent socket server

**One task:** Listen on the instance socket and execute `AgentCmd`.

**Spec:** Same actions as keybinds plus pause/resume, quit, reload, list-windows, list-workspaces. Pause = enable off; this instance only; in-memory.

**Design:** §14 agent table. Socket `$TMPDIR/lumina-$UID/spaces/<instanceId>/agent.sock`, fallback `~/Library/Application Support/Lumina/spaces/<instanceId>/agent.sock`. Dirs `0700`, socket `0600`. Do not use `$XDG_RUNTIME_DIR` as primary. After `accept`, drop if peer euid ≠ ours (`getpeereid(3)`). Cap line size; over 1 MiB close. Malformed JSON: one error line, stay up. `pause` unregisters hotkeys and ignores AX layout mutations; windows stay put. `resume` undoes. `quit`: unstash every sliver, write empty stash, unregister hotkeys, tell extra, exit. Apps stay up.

**External:** Darwin `getpeereid` ([OpenBSD getpeereid(3)](https://man.openbsd.org/getpeereid.3); present on macOS via libSystem; Swift stdlib uses it for Unix peer creds on Apple). Prefer `getpeereid` over `LOCAL_PEERCRED`. Do not listen on TCP.

**Depends on:** BP-09, BP-20.

**Implement:**

1. Path helper in `LuminaIPC` (pure): `agentSocketPath(uid:tmpdir:instanceId:supportFallback:)`.
2. Server on a dedicated serial queue; hop commands to MutationQueue; hop responses back.
3. Implement every agent cmd. `fullscreen` / `reload` / `list-*` : reload can re-read TOML in memory (FSEvents is BP-33; `reload` cmd still re-reads the file now). Fullscreen handlers stub until BP-23/24 then fill.
4. `list-windows` / `list-workspaces` payloads exactly as design.
5. Peer euid check immediately after accept.
6. Notify extra on quit: connect to `menu.sock` with an internal `agent-exiting {instanceId,pid}` **only if** you add that cmd — design says extra is the registry writer and watches pid via kqueue, so **do not invent a new cmd**. Extra sees pid death. Agent just exits after unstash.

**Tests:** path helper; peer-euid reject is hard to unit test — test the predicate `peerEuid == geteuid()`. LineTooLong closes (mock). Command dispatch table: `workspace 99` with count 5 → ok no-op.

**Done when:** a hand-rolled `nc -U` or a temporary CLI can `list-workspaces` against a running agent.

**Do not:** CLI argv parse (next BP). Do not write `instances.json`.

---

## BP-22 — CLI (`lumina`)

**One task:** Thin socket client. Not the AX process.

**Spec:** CLI for the same actions. `lumina start` launches extra/agent if needed.

**Design:** §3 CLI never AX, never hotkeys, never execs itself as AX. Resolves current native Space token via extra `current-token`; if extra down, same public heuristic against `instances.json`. Window commands → agent socket; if no agent: stderr `agent not running on this Space`, **exit 2**. `start` / `quit-all` / `open-config` → menu.sock. If extra down, `start` launches `Lumina.app` via `NSWorkspace` and retries 2s. `lumina quit` → current agent `quit`. `lumina debug` / `LUMINA_DEBUG=1` → debug logs. Homebrew will later symlink `Contents/MacOS/lumina`.

**Depends on:** BP-21. Extra cmds will fail until BP-28/30; implement the client anyway.

**Implement:**

1. argv grammar: `lumina <cmd> [args]`. Match command strings to JSON. Examples: `lumina focus left`, `lumina workspace 3`, `lumina fullscreen lumina`, `lumina list-windows`.
2. Connect menu.sock for token; then agent.sock.
3. Print `ok` data as JSON on stdout for list_*; errors on stderr.
4. Do not import AppKit in the CLI **if possible**; `NSWorkspace` open of Lumina.app needs AppKit or `open(1)`. Prefer `/usr/bin/open -a Lumina` when extra is down to keep CLI thinner; design says `NSWorkspace` — `#if os(macOS)` import AppKit is acceptable for `start` only.

**Tests:** argv → `IPCRequest` in `LuminaIPCTests`.

**Done when:** `swift run lumina list-workspaces` talks to a live agent or exits 2 with the spec string.

**Do not:** grant the CLI Accessibility.

---

## BP-23 — Native fullscreen Space bookmarks

**One task:** Detect a **new Mac Space** fullscreen, detach from tree, restore from in-memory bookmark.

**Spec:** Native fullscreen (⌃⌘F or green button when it **creates a new Mac Space**): window leaves the tree; remaining reflow as if closed. Remember `{space, parent, indexInParent, ratios, floating?}` **in memory only**. Un-fullscreen: if Lumina still running on the original Mac Space **and** bookmark exists, put back in that slot; sibling gone → insert at focus. Quit (bookmark gone) → leave it native. App closed → drop bookmark. Public detector: our window gone from this display’s on-screen list, pid alive, **and** `NSWorkspace.activeSpaceDidChangeNotification` fired (or `kAXFullScreenAttribute` became true). SkyLight current id change wins if present. If unsure a new native Space appeared, **do not** take the native-FS path.

**Design:** §7 detector paragraph. Do not stash native-FS windows (they left this display). Bookmark RAM only.

**External:** Observe `NSWorkspace.activeSpaceDidChangeNotification` on the **workspace** notification center. `kAXFullScreenAttribute` is undocumented — wrap, fail soft, never crash. Do not call SkyLight writes to follow the window.

**Depends on:** BP-20.

**Implement:**

1. On AXResized / missing-from-on-screen: if pid alive AND (space-change notification seen recently for this id OR AX fullscreen true OR SkyLight id changed) → native-FS path.
2. Detach: remove from tree/floating, store bookmark on `WindowRef`, role `.nativeFS`. Reflow.
3. On return (window on-screen again on bound display, fullscreen false): if bookmark and instance still current, reinsert at bookmark; else leave native (already native) / insert at focus if it became a normal window without bookmark.
4. `⌥ ⇧ F` / `fullscreen native`: AX press zoom if it toggles native FS, or set `kAXFullScreenAttribute` if settable — prefer performing the standard fullscreen action the app already has (`kAXRaise` is wrong). Common approach: `AXUIElementSetAttributeValue(window, kAXFullScreenAttribute, true)` when present; else press the zoom button. Fail soft.

**Tests:** detector predicate unit tests: missing on-screen + pid dead → not native-FS; missing + pid alive + no space-change + no AX flag → **not** native-FS (treat as in-place in BP-25); missing + pid alive + space-change → native-FS.

**Done when:** those predicates pass. Manual: Safari native fullscreen leaves remaining tiles reflowed (BP-38).

**Do not:** treat in-place green fill as native-FS (next two BPs).

---

## BP-24 — Lumina fullscreen and in-place fill

**One task:** `⌥ F` and in-place green-button **fill** become luminaFS.

**Spec:** Focused window expands to usable screen. Other nodes on that space stay in the tree but are not shown (same 1px sliver). Toggle restores exact frames. Not a native Space. One luminaFS per space. In-place green fill (no new Mac Space): frame fills usable rect (design slop) → luminaFS.

**Design:** §8 fill vs half: 12pt slop; fill = every edge within 12pt of usable **and** `area(window ∩ usable) / area(usable) ≥ 0.92`. §7 Option-F toggle; close luminaFS window later (BP-26).

**Depends on:** BP-17, BP-23 (to know it is **not** native-FS).

**Implement:**

1. `isFill(frame:usable) -> Bool` pure.
2. `enterLuminaFS(space, leaf)`: set `luminaFullscreen`; expand that window to usable (outer gaps still apply — usable already has outer gaps); stash **other** tiled+floating on that space as slivers; they stay in the tree / floating arrays.
3. `exitLuminaFS`: restore fullscreened window’s `lastOnscreenFrame` then apply `frames()`; unstash siblings to computed tiles/float frames.
4. `⌥ F` toggles.
5. In-place fill event (untagged AXResized, no native-FS detector) + `isFill` → enter luminaFS. Do not require the keybind.

**Tests:** `isFill` true for exact usable; true within 12pt; false for half-width. Enter/exit session transforms: siblings role stashed, ids still in tree.

**Done when:** tests pass. Manual: `⌥ F` on one of two tiles; the other becomes a corner sliver; toggle restores.

**Do not:** half/quarter handling (BP-25). Do not create a Mac Space.

---

## BP-25 — User-fight snap-back and Apple half/quarter

**One task:** Untagged tiled resize that is not a fill snaps back to the computed tile.

**Spec:** User resizes a tiled window and fights the layout → snap back on release if AX says user resize. Layout-driven setFrame must not count as a fight. Apple half/quarter snap (green button or Window Manager, no new Space) → snap back to computed tile; do not enter luminaFS; do not leave Apple’s frame. Keyboard resize always works (already BP-04/19).

**Design:** §8 half/quarter: not a fill, and width within 12pt of `usable.width/2` or `/4`, or height within 12pt of `usable.height/2` or `/4`. Anything else untagged `AXResized` on a tiled window → snap back as user fight. Quiet ~50ms after events. Ignore generation-tagged events.

**External:** `kAXWindowResizedNotification` is sent at the **end** of a resize, not during ([kAXWindowResizedNotification](https://developer.apple.com/documentation/applicationservices/kaxwindowresizednotification?language=objc)). Still debounce ~50ms to coalesce. No Input Monitoring to see mouse-up; AX end-of-resize + quiet is the spec.

**Depends on:** BP-12 generation, BP-24 `isFill`.

**Implement:**

1. `classifyInPlaceResize(frame:usable) -> fill | halfQuarter | fight`.
2. On untagged AXResized of a tiled window: wait 50ms quiet; if native-FS detector matches, BP-23; else fill → BP-24; else snap `setFrame` to `frames()[leaf]`.
3. Do not snap floaters (user may size them). Do not snap during pause.

**Tests:** half width → `.halfQuarter`; 12pt off half and not fill → `.fight`; fill takes precedence over half if both could match (a full usable is also a multiple of halves — **fill wins** because you check fill first).

**Done when:** tests pass. Manual: Sequoia/Tahoe/Golden Gate Window Manager half-tile snaps back (BP-38).

**Do not:** mouse title-bar swap (BP-27).

---

## BP-26 — luminaFS interactions (new window, close, already covered move)

**One task:** Spec behavior while luminaFS is on.

**Spec:** New window: classify first. Float/ignore/sheet → visible on top, luminaFS stays. Tile → insert in the tree and sliver until luminaFS ends. Close the luminaFS window: drop luminaFS, unstash siblings, collapse as a normal close. Option-F again: restore fullscreened window’s frame and unstash siblings. Move luminaFS to space N already specified in BP-20.

**Depends on:** BP-24, BP-15, BP-20.

**Implement:**

1. Create path checks `space.luminaFullscreen != nil`.
2. Close path: if closed id == luminaFS leaf, clear flag, unstash, then `remove`.
3. Toggle off path already in BP-24; ensure it restores **exact** frames (lastOnscreenFrame for the FS window, computed frames for others).

**Tests:** session-level: new tiled id appears in tree and in stash while luminaFS set; floating new id in `floating` and not slivered; close FS leaf clears flag.

**Done when:** those tests pass.

**Do not:** start a second luminaFS on the same space (ignore / no-op if already set and user hits ⌥F on another window — spec is one per space; ⌥F toggles the existing one if focus is that window; if focus is a floater, spec says Option-F is lumina fullscreen on the focused window — if focused is floating, **do not** luminaFS a floater; no-op unless you first tile it. Follow “focused window expands”; floaters are not in-tree maximize. Document in code.)

---

## BP-27 — Focus-follows-mouse and title-bar swap (best-effort AX)

**One task:** Optional FFM poll + cautious drag-swap. No Input Monitoring.

**Spec:** FFM off by default. When on: entering a tiled or floating window on the current space focuses it; does not raise. Ignore FFM during our `setFrame` and during a drag. No delay. Even when FFM is off: hovering another window and scrolling it must work without focusing it — **do not install a scroll tap**. Title-bar drag onto another tile → swap only if we can tell a title-bar move from drag-and-drop; if we cannot tell, **do not swap**. Keyboard swap remains. Click-to-focus via AX focused-window. Drag-and-drop between apps must not start a layout move.

**Design:** §12. Do **not** use `NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved)` (leans on Input Monitoring). v1 FFM: poll mouse location vs tiled/floating frames on MutationQueue at **20 Hz** only while FFM on and instance current. Ignore while generation apply in flight and while `NSEvent.pressedMouseButtons != 0`. Title-bar swap probe: on untagged `AXMoved` end, swap only if `NSPasteboard.general.changeCount` did **not** increase during the move, pointer sits over another tile, displacement ≥ 20pt. If pasteboard changed or unclear, do not swap.

**External:** `NSEvent.mouseLocation` is AppKit coords — convert to AX before hit-testing. `NSEvent.pressedMouseButtons`. `NSPasteboard.general.changeCount`. Polling at 20 Hz does not require Input Monitoring.

**Depends on:** BP-05, BP-19.

**Implement:**

1. Timer/source 20 Hz cancelled when FFM off, paused, or not current.
2. Hit-test AX point against current space visible frames (not slivers). Focus via AX focused attribute if needed; **do not raise**.
3. Move probe state machine on AXMoved.
4. Click-to-focus: already have `kAXFocusedWindowChanged` from BP-14.

**Tests:** probe predicate: pasteboard delta → no swap; displacement < 20 → no swap; pointer not over a tile → no swap. FFM ignore while buttons != 0 (pure).

**Done when:** those tests pass. Default config leaves FFM off so CI/manual isn’t flaky.

**Do not:** `CGEventTap`. Do not swap when unsure.

---

## BP-28 — Menu extra status item

**One task:** One `NSStatusItem` reflecting the **current** native Space’s agent.

**Spec:** One menu extra for the session. If an instance is current here: space digits (click to switch), menu Open Config, Reload, Pause/Resume, Start on this Space (**hidden**), Launch at Login, Quit this Space, Quit all. If none current: “Start on this Space”; do not drive another Space’s tree. Two status items are not acceptable. Open Config: `open -t` on `~/.config/lumina/lumina.toml`; if that fails, TextEdit.

**Design:** §15. Extra is `@MainActor` only, no AX. Sockets via `DispatchSource` on a dedicated serial queue; hop UI to MainActor. `LSUIElement`. `status` cmd for Secure Input / AX / configError / paused (fields may be empty until BP-35).

**Depends on:** BP-21 (agent cmds). Token routing BP-30; until then, if exactly one agent.sock exists, talk to it.

**Implement:**

1. Convert `Lumina` to `executableTarget` `@main`.
2. `NSStatusItem` variable length. Title = `1 2 3 4 5` with current space highlighted (use a simple marker, e.g. `(3)` or attributed string — no custom overlay window).
3. Click on a digit → agent `workspace {id}`.
4. Menu items as spec. Start hidden while current.
5. Empty state: single title `Start on this Space`.
6. `menu.sock` at `$TMPDIR/lumina-$UID/menu.sock`, mode `0600`. Serve `ExtraCmd`.
7. `open-config`: `/usr/bin/open -t` path; on failure `open -a TextEdit` path.
8. Never create a second `NSStatusItem`.

**Tests:** none required beyond compile. Manual: one extra only.

**Done when:** extra launches, shows digits if it can reach an agent, menu works for reload/pause/quit this space.

**Do not:** first-run sheet (BP-29). Do not spawn a second extra via `open -n`.

---

## BP-29 — First-run sheet, AX prompt, write default config

**One task:** Instruct the user; wait for agent AX; write defaults if missing.

**Spec:** First-run **instructs** (does not write) to turn off Stage Manager, other tiling WMs, and Desktop & Dock → Windows: drag-to-edge, drag-to-menu-bar fill, **Hold Option key while dragging windows to tile**. Accessibility for **Lumina Agent**. Launch-at-login asked, default off.

**Design:** §4 steps 1–7. Extra `LSUIElement`: `setActivationPolicy(.accessory)`, `NSApp.activate`, `NSAlert` as floating panel. **No Dock icon.** Deep-link Accessibility pane; poll `AXIsProcessTrusted` **on the agent** (agent `status` / a dedicated ping) until granted, or keep the sheet up. No silent no-op. Ad-hoc signatures re-prompt AX every new signature — document, do not “fix” with SIP.

**External:** `AXIsProcessTrustedWithOptions` prompt flag is process-local and asynchronous ([AXIsProcessTrustedWithOptions](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)). Opening the pane: `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` (still used; on Sequoia+ `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility` is an alternate — try the current Settings URL first, fall back). Extra must **not** call the prompt as itself. Poll agent `status.axTrusted`.

**Depends on:** BP-28, agent `status` field `axTrusted`.

**Implement:**

1. First-run flag: e.g. `~/Library/Application Support/Lumina/first-run-done` or “config exists and AX was trusted once.” Missing config → write **copy** of bundled `lumina.toml` to `~/.config/lumina/lumina.toml` (create `0700` dirs).
2. Sheet copy must include the three Apple tiling toggle names **verbatim from the spec**.
3. Button opens Accessibility pane. Poll 0.5s. Sheet stays relevant if denied.
4. Ask launch-at-login; default No. Call SMAppService in BP-34; this BP can set a bool the extra stores.
5. After AX granted, bind/start agent (BP-30/31). Do not tile twice.

**Tests:** default TOML copy is byte-stable with `Sources/Lumina/Resources/lumina.toml`.

**Done when:** cold launch without config writes the default file and shows the sheet until agent AX is granted.

**Do not:** write Dock/tiling defaults. Do not prompt AX as the extra.

---

## BP-30 — Current-space heuristic and Start attach/spawn

**One task:** Who is current; Start attaches or spawns.

**Spec:** At most one instance per native Space. Starting again on a Space that already has an instance is a no-op (attach). If that instance was not detected current (SkyLight missing, empty swipe-back), attach **marks it current** and re-registers hotkeys. How we tell “already has an instance” without SkyLight: any on-screen window of that agent, **including 1px slivers**. Starting on a different native Space (no slivers of another agent on-screen) creates a second instance **this boot**. Without SkyLight, swipe-back onto empty Lumina space may not auto-detect; Start attaches.

**Design:** §5 order 1–5 and start attach vs spawn. Reasons: `spaceChange | wake | stash | start | other`. Public large-window test: width ≥ 8 **and** height ≥ 8. Slivers do not qualify for “current” via step 3, but **do** qualify for attach. `spaceChange` + no large window → **not current** (swipe-away drops hotkeys even from empty space). `start` → current. `wake`/`stash`/`other` + `lastCurrentInstanceId` → stay current (last window closed, user did not swipe). Two claimants: extra’s `lastCurrentInstanceId` wins; loser unregisters hotkeys. Token is minted UUID, **not** the set of CGWindowIDs at launch.

**External:** `NSWorkspace.activeSpaceDidChangeNotification` as swipe detector. Pure function must be unit-tested without SkyLight.

**Depends on:** BP-17 slivers, BP-28 extra.

**Implement:**

1. Pure `func recomputeCurrent(reason:skyLightSelf:skyLightOthers:hasLargeOnScreen:isLastCurrent:otherClaims:) -> Bool` implementing order 1–5 without step 1–2 if SkyLight nil.
2. Extra on `start`: if already current → ok. Else if any live agent has **any** on-screen window on the bound display including slivers → attach (tell that agent reason `start`, register hotkeys, reconcile). Two such agents → `lastCurrentInstanceId` wins. Else spawn (BP-31).
3. Agent: on not current → unregister hotkeys, no layout mutations, do not steal windows. On becoming current → reconcile: enumerate AX, classify unknowns, drop vanished ids, one layout pass, re-stash managed windows not on focused Lumina space.
4. Extra UI: not current → “Start on this Space”, even if an agent is bound but undetected.

**Tests:** design §18 current-space bullets — all of them.

**Done when:** those tests pass and extra shows Start on a simulated not-current state.

**Do not:** SkyLight (BP-36). Public path must work alone.

---

## BP-31 — `instances.json`, posix_spawn, crash restart

**One task:** Extra is the registry and process babysitter.

**Spec:** Crash same boot, extra still up: restart that agent; unstash from **its** session file; launch-tiling onto last focused if valid else space 1; token kept. New boot / extra up with no live agents: do **not** restore layout; unstash leftover slivers from any old session files; wipe registry and those session files; bind **one** fresh agent on current native Space.

**Design:** §3 `instances.json` schema, `bootSessionUUID` = `kern.bootsessionuuid`. Extra **only writer**. Spawn `posix_spawn` of the agent bundle with `POSIX_SPAWN_SETSID`. Extra monitors pid + socket; pid death this boot → restart **same** `instanceId` unless the death followed `quit` / `quit-all`. No per-instance LaunchAgent. Extra launch: live pids → reattach, do not wipe. No live pids **or** boot UUID mismatch → fresh start.

**External:** `sysctl kern.bootsessionuuid` is a stable per-boot UUID (Darwin XNU `bootsessionuuid_string`; preferred over `kern.boottime` which moves with clock steps). `POSIX_SPAWN_SETSID` is Darwin `0x0400` in `<spawn.h>` ([apple/darwin-xnu spawn.h](https://github.com/apple/darwin-xnu/blob/d4061fb0260b3ed486147341b72468f836ed6c8f/bsd/sys/spawn.h)). Watch pid with `kqueue` / `DispatchSource.makeProcessSource`. **TCC:** a posix_spawn child inherits the parent’s TCC responsibility by default ([Qt “responsible process”](https://www.qt.io/blog/the-curious-case-of-the-responsible-process)). Spec requires AX on the **agent** identity. After `posix_spawnattr_init`, also call Darwin `responsibility_spawnattrs_setdisclaim(&attr, 1)` if `dlsym` finds it (fail soft). Verify `status.axTrusted` is the agent, not the extra. Alternative: `NSWorkspace.openApplication` on `Contents/Helpers/lumina-agent.app` — still disclaim if you posix_spawn the inner executable. Signatures: nested helper (BP-37).

**Depends on:** BP-18, BP-30.

**Implement:**

1. Paths: `~/Library/Application Support/Lumina/instances.json`.
2. Read `kern.bootsessionuuid` via `sysctlbyname`.
3. Spawn argv: instanceId, socket path, display UUID, crashRecover flag.
4. On `quit` (agent pid exits after extra initiated quit): remove row, do not restart.
5. On unexpected pid death this boot: restart same instanceId with crashRecover true.
6. Extra start algorithm exactly design §3 “Menu extra launch.”
7. `quit-all`: `quit` each agent socket, wait 500ms per pid, `SIGTERM` remaining **lumina-agent** pids, wait 200ms, wipe registry, extra exits. Login item stays if opted in.

**Tests:** JSON codec; boot UUID mismatch → wipe decision; dead pid treated absent; `quit` vs crash restart branch (pure).

**Done when:** killing the agent pid with extra alive respawns the same instanceId and crash-recover start path runs.

**Do not:** LaunchAgent plists. Do not let agents write the registry.

---

## BP-32 — Second instance isolation

**One task:** Two native Mac Spaces → two agents, one extra, no shared tree, no dual `⌥H`.

**Spec:** Second Lumina on another native Mac Space is a separate instance: own tree, stash, session, socket. Config shared. At most one instance per native Space. One menu extra. An instance does not follow the user. Swipe away → that instance’s hotkeys and management stop until its Space is focused again. Windows stay parked. If another instance is bound to the Space you swiped to, that one is live.

**Design:** §3 hotkeys registered only while token current. Brief gap on switch accepted. Two `NSStatusItem`s forbidden. Extra always reflects **current** native Space.

**Depends on:** BP-30, BP-31, BP-19.

**Implement:**

1. Spawn path when Start finds no slivers of another agent: mint new UUID, new session dir, new socket.
2. On `spaceChange`: every live agent recomputes current; at most one registers hotkeys. Extra updates `lastCurrentInstanceId` when it knows the winner.
3. Config file is the same path for both.
4. Do not share in-memory Session.

**Tests:** hotkey ownership flag: `shouldRegisterHotkeys(isCurrent:paused:)` false if not current. Two instance records in fixture JSON.

**Done when:** manual: two native Spaces, Start on each, `⌥ 2` on space A does not change B’s windows; only the current extra digits drive the current agent. Unit tests for register predicate.

**Do not:** restore the second instance after reboot (fresh start is one agent).

---

## BP-33 — Config live reload (FSEvents)

**One task:** Watch `lumina.toml`, apply or reject.

**Spec:** Live reload. Invalid: keep last good, error in the extra. `launch-apps` is **not** re-run on reload. Shrinking space count: windows on dropped spaces pour onto space 1; if focused space dropped, focus space 1.

**Design:** §13 FSEvents on that file. Apply live: gaps, binds, space count, rules, FFM.

**External:** Watch the **directory** `~/.config/lumina` (atomic save replaces the inode). `FSEventStream` or `DispatchSource.makeFileSystemObjectSource`. Debounce ~50ms.

**Depends on:** BP-08, BP-19, BP-21 `reload`, BP-28 extra error slot.

**Implement:**

1. Agent watches the file; on change parse; invalid → keep last, set `configError`, extra `status` shows it.
2. Valid: apply gaps immediately (one layout pass); re-register hotkeys from new bindings; `applySpaceCount`; replace rules; FFM on/off starts/stops the 20 Hz poll.
3. Extra menu Reload sends `reload` to current agent (and extra may re-read for display only).
4. Unknown keys already logged at parse.

**Tests:** shrink focusedSpace 7 with count 3 → focusedSpace 1 (pure, already BP-08; wire a session test with windows on space 4 pouring to space 1: those window ids move to space 1 tree/floating and get inserted as tiles at focus or appended — spec “pour onto space 1”: unstash them onto space 1, insert as tiles at focus in z-order of the pour. Define: for each dropped space from high to low, take its tiled leaves front-to-back plus floaters, `insertSpiral` / floating-append onto space 1, then delete dropped spaces.

**Done when:** editing gaps in the TOML reflows without restart; a broken TOML leaves the old gaps and the extra shows an error mark.

**Do not:** re-run `launch-apps`.

---

## BP-34 — `launch-apps` and launch-at-login

**One task:** First agent of a boot may open bundle ids; login item starts the extra only.

**Spec:** `launch-apps` when the **first agent of a boot** binds; skip if already running; do not move windows; later instances do not re-run. Launch-at-login opt-in, default off; starts the menu extra, which does a **fresh** start.

**Design:** §31 `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` → `openApplication`. §3 `SMAppService.mainApp`. Extra does not walk old tokens on login.

**External:** [SMAppService.mainApp](https://developer.apple.com/documentation/servicemanagement/smappservice) — main application launches on subsequent logins; this is **not** `SMAppService.agent` / LaunchAgent. `openApplication` at `NSWorkspace`.

**Depends on:** BP-31, BP-29 checkbox.

**Implement:**

1. Extra knows `agents.isEmpty` before the first spawn this boot (after wipe) → pass `runLaunchApps=true` to that agent only.
2. Agent: for each id, if `runningApplications` contains it, skip; else open; errors log and continue.
3. Menu “Launch at Login” toggles `SMAppService.mainApp.register()` / `unregister()`. Status `.requiresApproval` → extra tooltip tells the user to allow in Login Items.
4. Default off; first-run No unless they said yes.

**Tests:** skip-already-running predicate. Do not spawn apps in unit tests.

**Done when:** with `launch-apps = ["com.apple.Terminal"]` on a fresh extra start, Terminal opens if it was not running; second instance on another Space does not open another Terminal.

**Do not:** `SMAppService.agent`. Do not ship `Contents/Library/LaunchAgents/`.

---

## BP-35 — Display gone, sleep/wake, Secure Input, AX denied

**One task:** Failure table in the extra + agent pause/resume behavior.

**Spec:** Bound display UUID disappears (lid, Sidecar, unplug) → pause that instance and say so in the extra. **Same UUID returns** → auto-resume, one layout pass, re-stash off-space slivers. **Different display appears** → stay paused; do not steal the layout onto it. Secure Input: surface in the menu extra; not a crash. AX flipped off: pause mutations, sheet in extra.

**Design:** §17 table. Sleep/wake: re-query frames, one layout pass, re-stash if WindowServer moved slivers. §12 poll `IsSecureEventInputEnabled()`; status-item warning “hotkeys blocked: Secure Input”; do not restart the agent.

**External:** [TN2150 IsSecureEventInputEnabled](https://developer.apple.com/library/archive/technotes/tn2150/_index.html). Display reconfiguration: `NSApplication.didChangeScreenParametersNotification` and/or `CGDisplayRegisterReconfigurationCallback`. Wake: `NSWorkspace.didWakeNotification` on the workspace center. Do not use Screen Recording to “find” the new display.

**Depends on:** BP-28, BP-13 UUID cache.

**Implement:**

1. Agent on screen-parameter change: if bound UUID missing → `paused = true` (display-pause, distinct from user-pause if you need a reason enum; user resume must not override a missing display). Extra tooltip: “display gone.”
2. Same UUID back: unpause (unless user-paused), layout pass, re-stash.
3. New UUID only: stay paused.
4. Wake: layout pass + re-stash off-space.
5. Poll Secure Input ~1s; extra `status.secureInput`. Warning mark + tooltip.
6. AX trust lost: pause mutations; extra brings the first-run/AX sheet back.

**Tests:** UUID compare resume vs stay-paused (pure). Secure Input is a bool on status JSON.

**Done when:** those tests pass; extra shows warning strings for the three conditions (can be driven by fake status).

**Do not:** migrate the tree onto a different display.

---

## BP-36 — Optional SkyLight read

**One task:** Cache current native Space id; fail soft.

**Spec:** Private SkyLight **reads** allowed if they fail soft. No private writes. Tiling must work if every private symbol is missing. If SkyLight says current space id changed, that wins for native-FS detection and for “who is current” step 1–2.

**Design:** §5 `dlsym` `SLSMainConnectionID` + `SLSManagedDisplayGetCurrentSpace` (or equivalent). Wrap every private call. Never crash on missing symbol. Never link SkyLight hard. Do not disable library validation. `dlopen` system path `/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight`. Display argument is the display UUID string.

**External:** These symbols exist in the wild (yabai, others). SkyLight **writes** fail silent on 15+ with SIP ([ShiftPlus notes](https://shiftplus.app/blog/macos-spaces-without-disabling-sip/) — do not call `SLSManagedDisplaySetCurrentSpace` either; that is a write). Hardened runtime without `disable-library-validation` can still `dlopen` **system** frameworks.

**Depends on:** BP-30.

**Implement:**

1. `SkyLightClient` with optional function pointers. Any nil → public path only.
2. On bind, cache `skylightSpaceId` (may be null). Extra stores it in `instances.json`.
3. Recompute current uses design order 1–2 when ids are non-nil.
4. Native-FS detector: SkyLight id change counts as “a new Space appeared.”
5. Log once if `dlopen`/`dlsym` fails.

**Tests:** with pointers nil, public heuristic still used (existing tests). Do not require SkyLight in CI.

**Done when:** agent starts if SkyLight is missing; if present, swipe-back onto an empty Lumina space auto-marks current (manual). Public Start path still required.

**Do not:** `@_silgen_name` link-time dependency. Do not `dlopen` a non-system path.

---

## BP-37 — Bundle layout, signing, arm64-only ship path

**One task:** Build `Lumina.app` as a two-process signed bundle. Not Sparkle, not cask submission (docs only).

**Spec:** Accessibility for the agent binary not a Homebrew symlink. arm64-only. Min OS 15.2.

**Design:** §3 layout:

```
Lumina.app
  Contents/MacOS/Lumina                 extra
  Contents/Helpers/lumina-agent.app     agent bundle id com.zelmari.lumina.agent
  Contents/MacOS/lumina                 CLI
```

§19 GitHub Releases Developer ID + notarized before anyone else runs it. Ad-hoc for local debug (AX identity churns). §27 entitlements already in tree; sandbox false; no unsigned executable memory; no disable-library-validation. Sign agent first, wrap, sign outer, notarize outer, staple dmg. Intel: extra alerts and exits if `uname -m` is not arm64.

**External:** Nested helper signing order is Apple’s standard. Homebrew official cask needs Gatekeeper (signed + notarized); personal tap first (`docs/install.md` already says this). `ARCHS=arm64` only — Xcode 27 `ARCHS_STANDARD` may surprise; pin arm64.

**Depends on:** extras/agent actually having `@main`.

**Implement:**

1. `scripts/bundle.sh`: `swift build -c release --arch arm64`, assemble the tree, copy Info.plists, default toml into extra resources, copy CLI, ad-hoc `codesign` inner then outer for debug.
2. Document Developer ID commands in `docs/install.md` (identity placeholders, not secrets).
3. Runtime arm64 guard in extra `main`.
4. Do not add Sparkle. Do not write a LaunchAgent.
5. Optional `Lumina.xcodeproj` only if the bundle script is insufficient for signing; SwiftPM remains the source graph.

**Done when:** `scripts/bundle.sh` produces a runnable `Lumina.app` on Apple silicon; Accessibility list shows **Lumina Agent**; `Contents/MacOS/lumina version` (or `-h`) works; `file` on all three Mach-Os is arm64, not universal.

**Do not:** Intel slice. Do not notarize from the agent unless the user asks in a later session.

---

## BP-38 — Docs, compat, manual matrix, v1 cut

**One task:** Public docs match the shipped v1; every spec requirement has been implemented in a prior BP.

**Spec non-goals that must remain absent:** multi-monitor space pools, master/accordion, named spaces, scratchpad, mouse insert-on-drop, space swipe gestures, SIP/Dock injection/scripting additions, detecting other WMs, pretty Mission Control, Screen Recording, App Store, Sparkle, live AX test suite, binding modes, tile borders, Input Monitoring, restoring previous boot layout, Intel.

**Design:** §18 manual matrix (Apple silicon only: 15.2, 26, 27). §19 README bullets. §21 v1 cut line.

**Depends on:** BP-01…37. Git/GitHub for any landing commit or PR: `AGENTS.md` (do not merge unless the user says to; CI green first).

**Implement:**

1. README already has the right warnings; ensure it includes: Mission Control looks wrong, 1px remnant, Secure Input, reboot is a fresh start, `launch-apps` default empty, empty-space swipe-back without SkyLight uses Start, Accessibility is the agent, Option-drag tiling off, Stage Manager off, no other WM, Apple silicon 15.2+.
2. `docs/compat.md`: fill rows as found (native tabs misses, VI overlay bundle id, Siri HUD). Keep the empty table structure if nothing found; add Siri.app note already present.
3. `docs/install.md`: bundle script, AX grant target, uninstall paths (already listed). Add `$TMPDIR/lumina-$UID` to uninstall (design §30).
4. Walk the **Spec coverage matrix** below. Any unchecked row is a bug in this plan or in the code — fix the code.
5. Do not add Intel to the matrix.

**Manual matrix (must all be attempted before calling v1 done):**

Terminal tabs, Safari tabs, Chrome, Finder copy dialog, System Settings (floats), Ghostty, iTerm, native fullscreen Space, in-place green fill → luminaFS, in-place half/quarter → snap back, new window during luminaFS (dialog on top / tile slivered), ⌘H unhide, sleep/wake, lid close/open (same UUID resume), screen lock (agent may die; unstash + launch-tiling), Secure Input, two native Spaces with two instances this boot, reboot → one fresh agent + `launch-apps`, Stage Manager on (must not crash), Apple Option-drag tiling on (document fight), Siri.app tiles as a normal window, Visual Intelligence overlay floats, ⌘⇧Space / ⌘⇧6 not stolen, swipe away from empty space drops hotkeys, swipe-back onto empty space without SkyLight needs Start (attach).

**Done when:** coverage matrix is all ✅ in code; README/install/compat match spec; bundle runs on Apple silicon; known non-goals are still out.

---

## Spec coverage matrix

Map every product requirement to a BP. Agents use this at BP-38 and when skipping around.

| Spec requirement | BP |
|---|---|
| Spiral, permanent splits, 50/50 at focus, wide/tall first axis, close collapse, empty tree | 02, 14 |
| Spatial focus + swap (tile/tile, tile/floater, floater/floater) | 05, 19 |
| Resize 5% parent, clamp, 80pt | 04, 19 |
| Balance current space | 04, 19 |
| Launch tiling z-order + aliases; rebuild space crash vs quit/boot | 06, 18 |
| Center-on-bound-display membership; never pull windows over | 13 |
| Classify / rules / hard float / terminals / 400×300 / System Settings float / native tabs | 07, 15 |
| Emulated spaces 1–10, wrap, move-and-follow, pour on shrink, ⌘Tab observe | 20, 33 |
| 1px corner stash, not minimize/orderOut | 17 |
| Native FS bookmark in RAM | 23 |
| luminaFS keybind + in-place fill; half/quarter snap-back | 24, 25 |
| luminaFS new window / close | 26 |
| Minimize + ⌘H undo | 16 |
| Option binds, virtual keycodes, do not steal system chords | 19 |
| FFM off default, 20 Hz poll, no scroll tap | 27 |
| Title-bar swap best-effort; DND must not swap | 27 |
| Pause = enable off, instance only, RAM | 21 |
| Secure Input warning | 35 |
| Gaps, usable = visibleFrame − outer, no borders, min-size clamp-then-float | 03, 04, 13 |
| One menu extra, digits vs Start, Open Config | 28, 30 |
| Bound display, start attach/spawn, swipe-away, empty swipe-back | 13, 30, 32 |
| launch-apps first agent of boot | 34 |
| Quit this Space unstash + unregister; Quit all | 21, 31 |
| Crash same boot token kept; new boot fresh + wipe | 18, 31 |
| Display UUID gone / same UUID resume / different stay paused | 35 |
| Config path, live reload, validation | 08, 33 |
| CLI + sockets + same-user accepted | 09, 21, 22 |
| AX on agent bundle; SIP off; no Screen Recording; no Input Monitoring | 11, 12, 31, 37 |
| SkyLight read optional | 36 |
| First-run instructs Apple tiling off; SMAppService login | 29, 34 |
| arm64 15.2+; Intel out | 37 |
| Guest quit: apps stay, frames stay | 21 |

---

## Suggested file split (do not bikeshed)

`LuminaLayout`: `Rect.swift`, `Model.swift`, `Tree.swift`, `Frames.swift`, `Spatial.swift`, `Classify.swift`, `Config.swift`, `LaunchTiling.swift`, `CurrentSpace.swift`

`LuminaIPC`: `Protocol.swift`, `Codec.swift`, `Paths.swift`, `Log.swift`

`LuminaAgent`: `main.swift`, `MutationQueue.swift`, `AXAdapter.swift`, `AXObserverHub.swift`, `Hotkeys.swift`, `Stash.swift`, `SocketServer.swift`, `SkyLight.swift`, `AgentRuntime.swift`

`Lumina`: `main.swift`, `StatusItemController.swift`, `FirstRun.swift`, `InstanceRegistry.swift`, `AgentSpawner.swift`, `MenuSocket.swift`

`LuminaCLI`: `main.swift`

---

## Out of v1 (if a BP tempts you)

Borders, overlays, Input Monitoring, binding modes, multi-monitor pools, master/accordion, named spaces, scratchpad, prefs GUI, Sparkle, App Store, SIP tricks, SkyLight writes, WM detection, pretty Mission Control, Screen Recording, restoring a previous boot’s layout, Intel, `enable` as a second verb, `$XDG_RUNTIME_DIR` as primary socket root, `orderOut` stash, parking at `(-10000, y)`, `open -n` second extra.
