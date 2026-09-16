# Lumina — Design

Product behavior lives in the spec. This doc is how v1 is built. Target: one person + AI. Min OS **macOS 15.2 on Apple silicon**. Intel is out of v1 (arm64-only binary). Test on an M3 Air **and** on macOS 26 Tahoe / 27 Golden Gate — AX, Window Manager tiling, and TCC all moved after Sonoma.

If this file and the spec disagree on **behavior**, the spec wins. This file wins on types, paths, IPC, signing, and algorithms the spec defers.

Facts below are checked against public Apple docs, AeroSpace (still the closest analogue), and macOS 15.2–27 behavior as of 2026-09-15. Product forks in §23 are decided.

## 1. Identity

| | |
|---|---|
| Name | Lumina |
| Bundle id (menu extra) | `com.zelmari.lumina` |
| Bundle id (agent) | `com.zelmari.lumina.agent` |
| CLI | `lumina` (thin socket client) |
| Repo | `Zelmari/lumina` |
| Config | `~/.config/lumina/lumina.toml` only |
| Session | `~/Library/Application Support/Lumina/spaces/<instanceId>/session.json` |
| Instance registry | `~/Library/Application Support/Lumina/instances.json` |
| Menu extra socket | `$TMPDIR/lumina-$UID/menu.sock` |
| Logs | `~/Library/Logs/Lumina.log` + `os_log` subsystem `com.zelmari.lumina` |
| License | MIT |
| Min OS | macOS 15.2, Apple silicon only |

## 2. Stack

- Swift 6. Current toolchain as of this writing: Swift 6.4 / Xcode 27 (Xcode 26 is fine on a Tahoe host).
- Layout engine: pure Swift, no AppKit, unit-tested (Linux toolchain OK).
- Agent: AppKit + Accessibility, no SwiftUI.
- Menu extra: AppKit `NSStatusItem` only (`LSUIElement`).
- Config: TOML via [dduan/TOMLDecoder](https://github.com/dduan/TOMLDecoder) (TOML 1.1).
- IPC: Unix socket, JSON-lines, mode `0600`.
- Packaging: SwiftPM for packages; **the `.app` is built with Xcode or a documented bundle script**. SwiftPM does not produce a signed two-process app. Ship **arm64 only** (no universal, no Intel).
- Updates: Homebrew. No Sparkle. No telemetry.
- No Screen Recording permission. No SIP disable. No Dock injection. No private SkyLight **writes**.

## 3. Processes

Three roles, **three** binaries inside one `.app`. The CLI is not the agent.

    Lumina.app
      Contents/MacOS/Lumina                 menu extra (LSUIElement)
      Contents/Helpers/lumina-agent.app     agent (own Info.plist, bundle id com.zelmari.lumina.agent)
      Contents/MacOS/lumina                 CLI: socket client only

Login item is `SMAppService.mainApp.register()` on the menu extra. Do **not** ship a `Contents/Library/LaunchAgents/` plist for the menu extra — that is a different API (`SMAppService.agent`). No per-instance LaunchAgent.

Homebrew links `Contents/MacOS/lumina` onto `PATH`.

**Agent** owns Accessibility, the tree, sliver stash, optional SkyLight read, its socket, layout passes. This is the **only** process that may appear in System Settings → Privacy → Accessibility. Wrap as `lumina-agent.app` with bundle id `com.zelmari.lumina.agent` so TCC keys on bundle id + signature, not path. Same grant covers every instance (same binary).

**Menu extra** is the one status item for the session. No AX. Routes CLI-equivalent commands to the agent bound to the **current** native Space. Spawns / restarts agents. If it dies, agents keep running (they are detached); hotkeys for the current Space are owned by that agent.

**CLI** never calls AX, never registers hotkeys, never execs itself as the AX process. Resolves the current native Space token, then talks to that instance’s socket. `lumina start` launches the **agent bundle** for the current Space if missing; if an agent is already bound but not marked current, attach marks it current (recovery when SkyLight is missing and the space is empty). Other commands fail with `agent not running on this Space` if that socket is down.

**Instances.** At most one agent per native Space. Starting on a Space that already has an agent attaches. Starting on a different Space spawns a second agent. Trees, stashes, sockets, session files are not shared. Config (`lumina.toml`) is shared.

    $TMPDIR/lumina-$UID/menu.sock
    $TMPDIR/lumina-$UID/spaces/<instanceId>/agent.sock
    fallback: ~/Library/Application Support/Lumina/spaces/<instanceId>/agent.sock

Create dirs `0700`, socket `0600`. Do not use `$XDG_RUNTIME_DIR` as the primary path.

**Spawn.** Menu extra `posix_spawn`s the agent bundle with `POSIX_SPAWN_SETSID` (detached process group). It is not a child the extra will kill on exit. The extra monitors the agent pid + socket; if the pid dies **this boot**, it restarts that agent (crash recover). There is no per-instance KeepAlive LaunchAgent.

**`instances.json` writer.** The **menu extra is the only writer**. Agents never write this file. Extra records a spawn, updates `lastCurrentInstanceId`, and removes a row when it sees pid death (kqueue) after a `quit` (no restart) or on `quit-all`. If the extra is down when an agent quits, the row goes stale (dead pid); extra on next launch treats dead pids as absent. Agent crash: extra sees pid death **this boot** and restarts with the **same** `instanceId` — the row stays.

**`instances.json`:**

```json
{
  "bootSessionUUID": "<kern.bootsessionuuid>",
  "lastCurrentInstanceId": "<uuid or null>",
  "agents": [
    {
      "instanceId": "<uuid>",
      "pid": 1234,
      "skylightSpaceId": 12,
      "displayUUID": "<CFUUID string>",
      "socket": "/var/folders/…/lumina-501/spaces/<uuid>/agent.sock"
    }
  ]
}
```

`skylightSpaceId` may be `null`.

**Menu extra launch:**

- Live agent pids in the registry still running → reattach sockets, recompute current, do **not** wipe. (Extra crashed; agents stayed up.)
- No live agent pids **or** `bootSessionUUID` ≠ `kern.bootsessionuuid` → spec fresh start: unstash leftover slivers from every `session.json`, delete those files and the registry, start **one** agent on the current native Space, run `launch-apps`, launch-tiling onto **space 1**. Do not revive a second instance.

**Launch-at-login:** `SMAppService.mainApp` starts the menu extra. The extra does the fresh-start path above. It does **not** walk old tokens.

**Hotkeys.** Each agent registers the default binds only **while its token is current**, and unregisters when the user leaves that native Space. That avoids two processes owning `⌥H`. Brief gap on space switch is accepted.

**Why two process roles:** Accessibility stays in the long-lived agent. The bar can crash. Crash unstash is the agent reading its session file on the next start.

## 4. First launch

1. User opens `Lumina.app`.
2. Menu extra starts the agent if needed.
3. One-page sheet:
   - what Lumina is
   - Accessibility is required for **Lumina Agent**
   - Stage Manager off
   - no other tiling WM
   - System Settings → Desktop & Dock → Windows: turn **off** drag-to-edge tiling, drag-to-menu-bar fill, and **Hold Option key while dragging windows to tile**. Instruct; do not write those defaults.
4. Open the Accessibility pane (deep link); poll `AXIsProcessTrusted` on the **agent** until granted, or keep the sheet up. No silent no-op.
5. Ask launch-at-login (off unless they say yes). `SMAppService.mainApp.register()`.
6. Write default config if missing.
7. Fresh bind on this Space (mint `instanceId`, record display UUID + optional SkyLight id). Agent start path only (§9): unstash leftover slivers, run `launch-apps` if this is the first agent of the boot, then launch tiling onto **space 1**. Do not tile twice.

If AX is denied: menu extra stays up, agent idles, sheet stays relevant.

Ad-hoc signed debug builds will re-prompt Accessibility on every new signature. Developer ID from the first build you share with anyone, including yourself on a second Mac.

## 5. Native Space binding

Mint `instanceId` (UUID) at bind. That id is the token. It is **not** a SkyLight space id and **not** a set of CGWindowIDs.

Also cache, best-effort:

- `skylightSpaceId` from `dlsym` SkyLight (`SLSMainConnectionID` + `SLSManagedDisplayGetCurrentSpace` or equivalent). Fail soft; may be null.
- `displayUUID` from `CGDisplayCreateUUIDFromDisplayID` on the bound `NSScreen`’s `NSScreenNumber`. Bound screen = screen containing the focused window at bind, else `NSScreen.main`.

Tiling must work if every private symbol is missing.

**Who is current** (recompute on `NSWorkspace.activeSpaceDidChangeNotification`, on wake, after stash/unstash, and when the extra receives `start`). Record the **reason** for the recompute (`spaceChange` | `wake` | `stash` | `start` | `other`). Order:

1. If SkyLight current id equals this agent’s `skylightSpaceId` → current.
2. Else if SkyLight current id equals another **live** agent’s cached id → not current.
3. Else public: if this agent has ≥1 managed window with width ≥ 8 **and** height ≥ 8 in `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` on the bound display → current. (Slivers are 1×N and do not qualify. No Screen Recording; ids and bounds only. Do not read `kCGWindowName`. Do not treat `kCGWindowOwnerName == nil` as a permission probe.)
4. Else (no large on-screen window), public path only:
   - reason `spaceChange` → **not current**. Swipe-away must drop hotkeys even from an empty Lumina space.
   - reason `start` → **current** (user asserted attach). This is the recovery for swipe-back onto an empty space without SkyLight.
   - reason `wake` / `stash` / `other` and this instance is `lastCurrentInstanceId` → stay current (last window closed, user did not swipe). Do not flap.
   - otherwise → not current.
5. Two agents claim current: menu extra’s `lastCurrentInstanceId` wins; the loser unregisters hotkeys.

Limitation (document in README): without SkyLight, swipe-**back** onto an empty Lumina space does not auto-detect (no ≥8×8 window). Menu extra shows “Start on this Space”.

**`start`: attach vs spawn** (when no agent is already current):

- If a live agent has **any** on-screen window on the bound display, including 1px slivers → **attach** that agent (mark current, register hotkeys, reconcile). Slivers distinguish “I swiped back onto this native Space” from “I am on a different native Space.” Two agents with on-screen slivers: `lastCurrentInstanceId` wins.
- Else → **spawn** a new agent for this native Space.

**Do not** use “the set of CGWindowIDs that happened to be on screen at launch” as the token.

SkyLight **writes** (`SLSMoveWindowsToManagedSpace`, `SLSAddWindowsToSpaces`, bridged variants) are forbidden. Wrap every private call. Never crash on a missing symbol. Never link SkyLight hard. Do not disable library validation to make `dlopen` work; if the read cannot load, public path only.

**While not on the bound Space**

- Unregister this instance’s hotkeys
- No layout mutations
- No stealing windows that appear on the other native Space (that Space’s agent, if any, owns them)
- Agent stays alive; slivers stay parked

**While on the bound Space:** register hotkeys; normal operation.

**Reconcile on becoming current.** Enumerate AX windows on the bound display. Classify any unknown managed candidate. Drop vanished ids from the tree and from `floating`. One layout pass. Re-stash any managed window that is not on the focused Lumina space. Do not skip this after a swipe-back.

**Menu extra** is session-global. It always reflects the **current** native Space: digits + menu if an agent is **current** here; otherwise “Start on this Space”. It never drives a non-current instance’s tree. Two `NSStatusItem`s are forbidden.

**CLI** asks the menu extra `current-token` (menu.sock). If the extra is down, the CLI runs the same public heuristic against `instances.json` and talks to that agent socket.

## 6. Data model

In-memory **per agent**. On disk: shared config + per-instance session file + instance registry.

**In-memory `Session`** (not all of this is written to disk):

    Session
      instanceId                 // UUID we mint
      nativeSpaceToken           // == instanceId; kept as alias in prose
      spaceCount                 // 1...10, default 5; owned by config
      focusedSpace: SpaceId
      spaces: [Space]
      rules: [WindowRule]        // from config
      paused: Bool               // pause == enable off; RAM only; crash/boot unpauses

    SpaceId = 1...10             // key 0 → 10

    Space
      id: SpaceId
      focusedWindow: CGWindowID? // tiled leaf or floater on this space; nil if none
      lastTiledLeaf: NodeId?     // last focused tiled leaf; used when focus is a floater
      root: NodeId?              // nil = empty tiled tree (space still exists)
      floating: [WindowRef]      // not in the tree; not in frames()
      luminaFullscreen: NodeId?  // at most one; points at a tiled leaf
      lastDisplayFrame: Rect     // usable rect when last shown

    Node
      id: NodeId
      parent: NodeId?
      children: [NodeId]         // n-ary; spiral v1 always 2 when splitting
      axis: horizontal | vertical
      ratio: [Double]            // child weights, default equal. Double, not Float.
      leaf: WindowRef?           // only if children.isEmpty; role tiled | luminaFS | stashed

    WindowRef
      cgWindowId: CGWindowID     // from _AXUIElementGetWindow
      pid: pid_t
      bundleId: String?
      role: tiled | floating | stashed | nativeFS | luminaFS | ignored
      lastOnscreenFrame: Rect    // AX/top-left space, always kept when visible
      nativeFSBookmark: Bookmark?

    Bookmark
      spaceId, parentId, indexInParent, ratioSnapshot, wasFloating

**On disk (`session.json`):**

```json
{
  "instanceId": "<uuid>",
  "bootSessionUUID": "<kern.bootsessionuuid>",
  "focusedSpace": 1,
  "displayUUID": "<uuid>",
  "stash": [
    {
      "cgWindowId": 123,
      "pid": 456,
      "bundleId": "com.apple.Terminal",
      "lastOnscreenFrame": { "x": 0, "y": 0, "w": 800, "h": 600 }
    }
  ]
}
```

Write on each Lumina-space switch, on quit, and debounced on crash-sensitive paths. Do **not** persist `paused`. Frames are AX/top-left.

The tree, ratios, floaters-as-tiles, luminaFS id, and native-FS bookmarks are **in-memory only**. They do not survive quit, crash, or reboot.

**Same-boot agent crash:** unstash this file, then launch-tiling onto `focusedSpace` if it is still in 1…space-count, else space 1.

**Quit this Space then Start / first bind / new boot / extra up with no live agents:** unstash leftovers, launch-tiling onto **space 1**. Do not restore `focusedSpace` from a previous instance’s session file after a quit. Native-FS bookmarks are already gone.

**Floaters** live in `Space.floating`, not in the tree. Option-Space tiled → floating: remove the leaf, collapse, append to `floating`, keep `lastOnscreenFrame`. Floating → tiled: remove from `floating`, `insertSpiral` at focus. `frames()` never sees them. Swap tile↔floater: floater takes the leaf slot, old leaf moves to `floating`. Two-floater swap: exchange `lastOnscreenFrame` only.

**Empty tree:** `root == nil`. No tiled leaves. Space still exists. Next tiled insert: `newLeaf` becomes `root`. `focusedWindow` may still point at a floater. Whenever `focusedWindow` is a tiled leaf, copy that node into `lastTiledLeaf`.

**Spiral insertion (v1):** if `root == nil`, `newLeaf` becomes `root`. Else take the focused **tiled** leaf (if `focusedWindow` is a floater, use `lastTiledLeaf`; if that is nil, treat as empty). Replace it with a container whose children are `[oldLeaf, newLeaf]`, axis = opposite of parent’s axis. Root first split: `horizontal` (side by side) if usable width ≥ height, else `vertical`. Ratios `[0.5, 0.5]`. Close: remove leaf, promote sibling, collapse empty containers. Last tiled window gone → `root = nil`; space stays.

**Launch tiling (`z-order`).** After unstash, on the rebuild space (crash: `focusedSpace` if valid, else 1; otherwise **space 1**):

1. Collect managed, center-on-bound-display, classify-as-tile windows from `CGWindowListCopyWindowInfo(.optionOnScreenOnly)`, **front-to-back** (index 0 = frontmost). Skip ignore / hard-float / hidden native tabs.
2. Insert each in that order with `insertSpiral`, focusing the new leaf after each insert (same as a live new window).
3. After the batch, focus the original frontmost if it is still a tiled leaf on this space.

**Launch tiling (`float-existing` / `new-only`).** v1: these are **aliases**. Do not insert already-open windows into the tree; classify them floating (unless ignore / hard-float). Windows that appear after this start follow normal classify. Option-Space still tiles a floater.

**Identity.** There is no public AX unique window id. Preferred match: `_AXUIElementGetWindow` → `CGWindowID`, plus `pid`. If the private function is missing, fall back to `(pid, role, position, size)` and accept worse matching. Bundle id is never unique. `kAXIdentifierAttribute` is not a window id.

**Coordinate space.** All layout math is **AX / CoreGraphics: origin top-left of the menu-bar display, Y down**. AppKit `NSScreen.visibleFrame` is bottom-left, Y up — convert at the adapter. Never mix the two in `LuminaLayout`.

## 7. Window state machine

    ignored ------------------------------------------------ (rules / system UI / hidden native tab)
       |
       v
    unmanaged --> tiled <----> floating
                   |              |
                   |--> stashed <--     (other Lumina space, or covered by luminaFS)
                   |              |
                   |--> luminaFS        (in-tree maximize)
                   |              |
                   +--> nativeFS        (left tree, Mac fullscreen Space)

| Event | Action |
|---|---|
| New window | classify → ignore / float / tile-insert at focus |
| Close | drop node, collapse, forget bookmark |
| Option-Space | tiled ↔ floating. Tiled → floating: remove leaf, collapse, append `Space.floating`, keep lastOnscreenFrame. Floating → tiled: remove from `floating`, insertSpiral at focus |
| Switch Lumina space away | visible tiled+floating on that space → sliver stash |
| Switch Lumina space here | unstash this space’s windows to lastOnscreenFrame, apply tree |
| Option-F | toggle luminaFS on focused leaf; others slivered, stay in tree. Toggle off restores those frames |
| Close the luminaFS window | drop luminaFS, unstash siblings, collapse as close |
| Move luminaFS window to space N | drop luminaFS on source (unstash siblings), insert as tile at dest focus, follow |
| New window while luminaFS | classify. float/ignore → visible, do not raise luminaFS away. tile → insert in tree, sliver until luminaFS ends |
| Native fullscreen Space (green / ⌃⌘F **and** a new Mac Space appeared) | in-memory bookmark, detach from tree, reflow; do not stash |
| Un-native-FS | if this instance is still running on that native Space **and** the in-memory bookmark exists, reinsert at bookmark (sibling gone → insert at focus); else leave native |
| In-place fill (native Space did not change; frame fills usable rect) | enter luminaFS; Option-F or zoom again restores |
| In-place half/quarter Apple snap (native Space did not change; frame is not a fill) | user fight → snap back to the computed tile; do not enter luminaFS; do not leave Apple’s frame |
| Yellow / ⌘M | unminimize immediately; keep role |
| ⌘H Hide | unhide immediately; keep role |
| App activation from stash | switch to that window’s Lumina space, unstash, focus. Multi-window app: the window that AX reports as focused/main; if none, the most recently focused Lumina window of that pid |
| AX set-frame fail | retry once; then float and log |
| Classify as dialog | float, do not insert |

**Native fullscreen detector (public).** A managed window takes the native-FS path only if: its pid is still alive, it is absent from this display’s on-screen CGWindowList (or `kAXFullScreenAttribute` is true), **and** `NSWorkspace.activeSpaceDidChangeNotification` fired (or SkyLight current id changed). If none of those fire, do not guess a new Space — treat frame changes as in-place fill/half/fight.

**Native tabs.** AX reports each tab as its own `AXWindow`. Visible tab = its `CGWindowID` is in `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` with width ≥ 8 and height ≥ 8. If a new AX window of pid P is **not** on-screen, and pid P already has an on-screen window, treat the new one as a hidden tab → `ignored`. When the user switches tabs, the newly on-screen id is promoted (tile or float per rules); the old one is ignored. This is the public heuristic AeroSpace/Ghostty still wrestle with; it will be wrong for some apps. `docs/compat.md` records them.

**Own mutations.** Every `setFrame` / stash / unstash the agent performs increments `generation` on that `WindowRef`. `AXMoved` / `AXResized` / `AXWindowMiniaturized` with `generation` matching the in-flight apply are ignored.

User fight, snap back to the computed tile: an `AXResized` that is not ours, on a tiled window, after mouse-up (or after events go quiet ~50ms). Same for an Apple Window Manager / green-button **half or quarter** snap that did not create a native Space.

Not a fight: a fill of the usable rect with no new native Space → enter luminaFS.

## 8. Geometry

Usable rect, every layout pass:

    NSScreen.visibleFrame   // already minus menu bar, visible Dock, notch
      - gaps.outer on all four sides

Inner gaps between sibling tiles only. One window still gets outer gap, no inner.

`frames(tree, usable, gaps)`: for a container with children `c[i]`, weights `w[i]` (default equal), axis horizontal:

    innerTotal = gaps.inner * (n - 1)
    run = usable.minX
    for i in 0..<n:
      span = (usable.width - innerTotal) * (w[i] / sum(w))
      childRect = (run, usable.minY, span, usable.height)
      run += span + gaps.inner

Vertical: same on Y. Recurse. Leaves get that rect. Floaters are not in `frames`.

Do **not** subtract menu bar, Dock, or `safeAreaInsets` on top of `visibleFrame`. That double-counts the notch on the M3 Air.

If Dock autohides, `visibleFrame` already expands. Do not reserve a Dock-sized hole.

No borders in v1. No overlay windows.

If a window’s min size cannot fit its computed tile: **clamp the sibling first** along the parent axis so both leaves meet that window’s AX min size (and the 80pt floor on a user resize). If both still cannot fit, **float** the window that will not fit, collapse its leaf, sibling takes the space. Never leave a sliver **tile** on-screen (the stash sliver is a different, intentional 1px remnant). Prefer floating the newly inserted / just-resized window when both are over min.

A window is managed only if its **center** (AX frame) lies on the bound display. Do not `setFrame` a window onto the bound display to make it managed. Centers on any other display → unmanaged. If the bound display UUID is gone, see §17.

Target: from AX event to last setFrame ≤ 50ms on a quiet desktop. Bursts: coalesce on a **serial** `MutationQueue`, one layout pass per batch. AX callbacks are not Sendable; hop onto that queue. This budget will miss under Chrome/Electron; that is accepted. Do not block the main thread on a synchronous AX round-trip to every app — apply, then read back.

**Fill vs half/quarter (in-place, no new Space).** Compare the window frame to the usable rect, AX coordinates, 12pt slop:

- **Fill** → luminaFS: every edge is within 12pt of the matching usable edge, **and** area(window ∩ usable) / area(usable) ≥ 0.92.
- **Half/quarter fight** → snap back: not a fill, and width is within 12pt of `usable.width/2` or `usable.width/4`, or height within 12pt of `usable.height/2` or `usable.height/4`.
- Anything else that is an untagged `AXResized` on a tiled window → snap back as a user fight.

**Spatial focus.** Candidates: current space, role tiled or floating, not stashed/ignored. `F` = focused frame, `C` = candidate frame, both AX. Direction left shown; others by rotation.

- Half-plane (left): any pixel of `C` has `x < F.center.x` — equivalent `C.minX < F.center.x`. Tiles use the **frame**, not the center.
- Strip: `C` intersects the infinite band of `F.minY…F.maxY` (left/right) or `F.minX…F.maxX` (up/down).
- **Tiled** eligible if it is in the half-plane **and** (in the strip, or no tiled candidate is in the strip).
- **Floating** eligible only if its **center** is in the half-plane (`C.center.x < F.center.x` for left).
- Score: Euclidean distance `F.center` to `C.center`. Winner = min score. Tie: lower `CGWindowID`. None eligible: no-op.

**Swap.** Same candidate.

- Two tiles: exchange the two leaves in the tree (parents, indices, ratios stay).
- Tile + floater: remove the floater from `Space.floating` and put it in the tile’s leaf slot; move the old leaf into `floating` at `lastOnscreenFrame`.
- Two floaters: exchange `lastOnscreenFrame` and `setFrame` both. Neither enters the tree.

**Resize `⌥ -/=`.** Parent container of the focused tiled leaf, along `parent.axis`. `delta = 0.05 * sum(parent.ratio)`. Grow: add `delta` to the focused child’s weight, subtract `delta` from the sibling (v1: one sibling). Shrink: opposite. Clamp so each child’s resulting frame meets that window’s min size and is ≥ 80pt on that axis. Ignore if focused is floating or is the only tiled leaf.

## 9. Stash

Off-space (and luminaFS-covered) windows go to a sliver, not minimized, not `orderOut`.

macOS clamps frames that sit fully off the display. Do **not** park at `(-10000, y)`.

- Save `lastOnscreenFrame` before moving.
- Park as a **1×N or N×1** strip in a **bottom corner of the bound display**, just outside `visibleFrame` but still accepted by WindowServer (AeroSpace: 1px vertical line in the bottom-left or bottom-right corner). Prefer the corner that does not sit on another display. v1 is one display: bottom-right, unless the Dock is on the right, then bottom-left.
- Session file per instance: see §6. Not the tree.
- **Same-boot agent crash (token kept):** unstash this file’s leftovers first, then launch-tiling onto `focusedSpace` if valid, else space 1.
- **Quit then Start / first bind / new boot / extra with no live agents:** unstash leftovers, launch-tiling onto **space 1**.

Mission Control will show the pile. Accepted. README: Dock on the bottom + autohide makes the 1px remnant less visible.

Sleep/wake: WindowServer sometimes moves slivers. After wake, re-stash any managed window that is not on the focused Lumina space.

## 10. Layout pipeline

    AX / NSWorkspace / hotkey / socket
            |
            v
      serial MutationQueue
            |
            v
      classify + update tree     // pure
            |
            v
      compute frames             // pure, unit-tested, AX coordinates
            |
            v
      apply via AX setFrame      // adapter, retried once, tagged with generation

Debounce window-create bursts (~30–50ms). Do not run apply from two queues. See §26 for isolation and AX timeouts.

Set position and size separately (`kAXPositionAttribute`, `kAXSizeAttribute`). Some apps clamp on resize; set size then position, then size again if the read-back missed.

Pure functions to test:

- `insertSpiral(tree, focus, usableIsWide) -> tree`
- `remove(tree, node) -> tree`
- `frames(tree, usableRect, gaps) -> [NodeId: Rect]`
- `balance(tree) -> tree`
- `focusSpatial(windows, from, dir) -> WindowRef?`
- `classify(...)` on fixtures
- config parse/reject
- command parse

## 11. Classification

Default: tile unless it looks like a dialog.

Order:

1. Config rules, first match wins: `ignore` / `float` / `tile` on `app-id` (bundle id) + optional title regex.
   - `ignore` always wins (skip the rest).
   - `float` floats and stops.
   - `tile` marks the window allow-tiled and continues. It **does not** force-tile a sheet, system UI, or PiP.
2. Hard float / ignore (even if a rule said `tile`):
   - roles: utility, panel, sheet, tooltip, popover
   - bundle ids (hard float / ignore, not a user rule): `com.apple.Spotlight`, `com.apple.notificationcenterui`, `com.apple.controlcenter`, `com.apple.loginwindow`, `com.apple.ScreenSharing`, `com.apple.screencaptureui`, `com.apple.UserNotificationCenter`
   - PiP / HUD: float, do not `raise` / steal focus (layer or role; record misses in `docs/compat.md`)
   - Visual Intelligence capture UI and Siri HUD / overlay (Golden Gate). Bundle ids recorded in `docs/compat.md` as discovered. The dedicated **Siri.app** (Dock) is a normal app — not on this list.
3. Soft float (a `tile` rule, or the terminal allow-list, overrides):
   - no zoom button, except terminal allow-list: `com.apple.Terminal`, `com.googlecode.iterm2`, `org.alacritty`, `com.mitchellh.ghostty`, `net.kovidgoyal.kitty`, `com.github.wez.wezterm`
   - size below 400×300
4. Hidden native tab → ignore (see §7)
5. Else tile

Default config ships `[[window-rule]] app-id = "com.apple.systempreferences"` / `com.apple.Preferences` `action = "float"`. User can change or delete it. There is **no separate ignore-list key**; `ignore` is a window-rule action. Default third-party ignore rules: none. Commented example rules may appear in the default TOML. Public `docs/compat.md` lists known-bad apps as we find them.

Title regex in rules may not fire on first AX event (some apps set the title late). Re-classify once on `kAXTitleChangedNotification` if the window is still unmanaged/floating from a title miss. Never log titles at default info.

## 12. Input

Register hotkeys with `RegisterEventHotKey` (Carbon). Min OS 15.2: Option-only and Option-Shift combos are accepted again (Apple restored this in 15.2 after blocking it in 15.0). Do not install a `CGEventTap` in v1.

If Option+H cannot be registered, fail that bind loudly in the menu extra; do not silently take Input Monitoring.

| Key | Command |
|---|---|
| Option-h/j/k/l | focus spatial |
| Option-Shift-h/j/k/l | swap spatial |
| Option-minus/equal | resize along parent |
| Option-1–9,0 | workspace N |
| Option-Shift-1–9,0 | move-node-to-workspace N + follow |
| Option-[ / ] | workspace prev / next (wrap) |
| Option-b | balance |
| Option-f | lumina-fullscreen |
| Option-Shift-f | native-fullscreen |
| Option-space | float/tile |
| Option-q | close window |

Do not register ⌘Tab, ⌘`, Mission Control, screenshot (⌘⇧3/4/5), or Visual Intelligence (⌘⇧Space, ⌘⇧6). Cmd-Tab space switching is **observe** `NSWorkspace.didActivateApplicationNotification` + AX focused window.

Focus-follows-mouse off by default. When on: `NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved)` is **not** used (that path leans on Input Monitoring). Use AX `kAXMouseMoved` is not public. v1 FFM: observe `NSWorkspace` / AX focused-window is already click-to-focus; for true hover-focus without a tap, poll mouse location against tiled/floating frames on the **MutationQueue** at 20 Hz only while FFM is on and this instance is current. Entering a candidate’s frame focuses it (AX raise not required). Ignore while `generation` apply is in flight and while `NSEvent.pressedMouseButtons != 0`. Scroll-over-unfocused: do not intercept.

Title-bar swap probe: on untagged `AXMoved` end, swap only if `NSPasteboard.general.changeCount` did **not** increase during the move, the pointer sits over another tile, and displacement ≥ 20pt. If the pasteboard changed or anything is unclear, **do not swap**.

**Secure Input:** poll `IsSecureEventInputEnabled()`. When true, show a status-item warning (“hotkeys blocked: Secure Input”); do not restart the agent.

Pause: `lumina pause` / menu Pause → this **instance** ignores hotkeys and AX layout mutations; windows stay put. `lumina resume` undoes that. Other instances are unaffected.

Minimize: observe `kAXWindowMiniaturizedNotification`, immediately deminiaturize. Miniaturize is async via the Dock on macOS 13+; if the window is still miniaturized on the next AX tick, try again once.

Hide: observe `kAXUIElementDestroyed` is wrong — use application-hidden / windows `AXHidden` / `NSWorkspace` hide. Immediately unhide (`NSRunningApplication.unhide` or AX raise of the hidden windows) and keep roles. Same generation tagging so the unhide is not treated as user focus.

Mouse, no Input Monitoring, no event tap:

- Click-to-focus: AX focused-window notifications (macOS already focuses on click).
- User-resize snap-back: `AXResized` not tagged with our generation, after ~50ms quiet → snap to computed tile. Same for Apple half/quarter snap (no new Space).
- Title-bar swap: see probe above. Keyboard swap always works.

## 13. Config

Path: `~/.config/lumina/lumina.toml` only.

FSEvents on that file → parse → if invalid, keep last good tree+config, set menu extra to error, log + stderr. If valid, apply live (gaps, binds, space count, rules, FFM, launch-apps is **not** re-run on reload). Shrinking space count: windows on dropped spaces pour onto space 1; if `focusedSpace` was dropped, `focusedSpace = 1`.

Missing file: write defaults, continue.

Validation (reject the file, keep last good):

- `space-count`: integer 1…10
- `gaps.inner` / `gaps.outer`: integer 0…128
- `focus-follows-mouse`: bool
- `launch-tiling`: `z-order` | `float-existing` | `new-only`
- `launch-apps`: array of strings (bundle ids). Empty OK. Unknown ids: log, skip
- `bindings` values: must be a known command string (below). Duplicate chords: last wins, log
- Unknown top-level keys: log and ignore
- `[[window-rule]]`: `app-id` required string; `title-regex` optional; `action` one of `tile` | `float` | `ignore`. Bad regex: skip that rule, log

Schema is **Lumina’s**, inspired by AeroSpace, not compatible with `aerospace.toml`. No binding modes in v1.

    space-count = 5
    focus-follows-mouse = false
    # z-order | float-existing | new-only
    # v1: float-existing and new-only are aliases (already-open float; later windows tile)
    launch-tiling = "z-order"
    launch-apps = []                       # e.g. ["com.apple.Terminal"]

    [gaps]
    inner = 8
    outer = 8

    [bindings]
    alt-h = "focus left"
    alt-j = "focus down"
    alt-k = "focus up"
    alt-l = "focus right"
    alt-shift-h = "swap left"
    alt-shift-j = "swap down"
    alt-shift-k = "swap up"
    alt-shift-l = "swap right"
    alt-minus = "resize shrink"
    alt-equal = "resize grow"
    alt-leftSquareBracket = "workspace prev"
    alt-rightSquareBracket = "workspace next"
    alt-b = "balance"
    alt-f = "fullscreen lumina"
    alt-shift-f = "fullscreen native"
    alt-space = "float-toggle"
    alt-q = "close"
    alt-1 = "workspace 1"
    alt-2 = "workspace 2"
    alt-3 = "workspace 3"
    alt-4 = "workspace 4"
    alt-5 = "workspace 5"
    alt-6 = "workspace 6"
    alt-7 = "workspace 7"
    alt-8 = "workspace 8"
    alt-9 = "workspace 9"
    alt-0 = "workspace 10"
    alt-shift-1 = "move-node-to-workspace 1"
    alt-shift-2 = "move-node-to-workspace 2"
    alt-shift-3 = "move-node-to-workspace 3"
    alt-shift-4 = "move-node-to-workspace 4"
    alt-shift-5 = "move-node-to-workspace 5"
    alt-shift-6 = "move-node-to-workspace 6"
    alt-shift-7 = "move-node-to-workspace 7"
    alt-shift-8 = "move-node-to-workspace 8"
    alt-shift-9 = "move-node-to-workspace 9"
    alt-shift-0 = "move-node-to-workspace 10"

    [[window-rule]]
    app-id = "com.apple.systempreferences"
    action = "float"

    [[window-rule]]
    app-id = "com.apple.Preferences"
    action = "float"

## 14. CLI / IPC

JSON-lines, UTF-8, one object per line, no length prefix. Max line 1 MiB; over that, close the connection. Unknown `cmd`: `{"ok":false,"error":"unknown cmd"}`. Malformed JSON: one error line, stay up.

    → {"v":1,"id":"<uuid>","cmd":"workspace","args":{"id":3}}
    ← {"v":1,"id":"<uuid>","ok":true}
    ← {"v":1,"id":"<uuid>","ok":false,"error":"agent not running on this Space"}

`id` is echoed. `v` must be `1`. Extra args ignored.

**Agent socket** (current Space unless noted):

| cmd | args | ok data |
|---|---|---|
| `workspace` | `{id: 1…10}` | no-op (ok) if `id > space-count` |
| `move-node-to-workspace` | `{id: 1…10}` | no-op (ok) if `id > space-count` |
| `focus` | `{dir: "left"\|"down"\|"up"\|"right"}` | — |
| `swap` | `{dir: "left"\|"down"\|"up"\|"right"}` | — |
| `resize` | `{delta: "grow"\|"shrink"}` | — |
| `balance` | `{}` | — |
| `float-toggle` | `{}` | — |
| `fullscreen` | `{mode: "lumina"\|"native"}` | — |
| `close` | `{}` | AX press close button on focused window |
| `pause` | `{}` | — |
| `resume` | `{}` | — |
| `reload` | `{}` | re-read TOML |
| `quit` | `{}` | this instance only |
| `list-windows` | `{}` | `{windows:[{cgWindowId,pid,bundleId,role,space,x,y,w,h}]}` |
| `list-workspaces` | `{}` | `{focused: N, count: N, spaces:[{id, focused, windowCount}]}` |

`pause` / `resume` cover enable off/on. Do not ship a second `enable` verb.

**Menu extra socket** (`menu.sock`):

| cmd | args | ok data |
|---|---|---|
| `current-token` | `{}` | `{instanceId}` or error if none |
| `start` | `{}` | if already current: ok. If a live agent has any on-screen window here (incl. slivers): attach (mark current, hotkeys, reconcile). Else spawn. |
| `quit-all` | `{}` | `quit` every agent, then extra exits |
| `open-config` | `{}` | `open -t` the TOML |
| `status` | `{}` | `{secureInput, axTrusted, configError, paused, instanceId, space}` |

CLI:

- Window commands → resolve `current-token` → agent socket. If no agent: stderr `agent not running on this Space`, exit 2.
- `lumina start` / `quit-all` / `open-config` → menu extra. If extra is down, `start` launches `Lumina.app` (`NSWorkspace`) and retries 2s.
- `lumina quit` → current agent `quit`.
- `lumina debug` / `LUMINA_DEBUG=1` → debug logs.

`quit` (agent): unstash every sliver to `lastOnscreenFrame`, write session empty stash, unregister hotkeys, tell the extra it is exiting (extra is the `instances.json` writer — extra drops the row). If extra is down, just exit; leftover registry row is a dead pid. Apps stay up. Extra stays if any instance remains. Next `start` on this Space is a **new** instance, launch-tiling onto **space 1**.

`quit-all`: extra sends `quit` to every agent socket, waits up to 500ms per agent for pid exit, then `SIGTERM` any remaining `lumina-agent` pids (the agent is ours; never `SIGKILL` user apps, never `SIGKILL` the agent — unstash must run). Wait 200ms more, wipe registry, extra exits. Leftover slivers recover on next start. Login item stays registered if the user opted in; **next login is a fresh start**, not a revive of these tokens.

## 15. Menu extra

If an instance is **current** on this native Space: `1 2 3 4 5` (or 1…N). Current Lumina space highlighted. Click → workspace N.

Menu: Open Config (`open -t` the TOML; fallback TextEdit), Reload, Pause/Resume, Start on this Space (**hidden** while current — attach is a no-op), Launch at Login, Quit this Space, Quit all.

If no instance is **current** here: the item is a single control, “Start on this Space”. That includes “agent bound but not detected current” (SkyLight missing, empty space after swipe-back). Do not show another Space’s digits.

When Secure Input is on, or config is invalid, or AX is off: warning mark + tooltip. No prefs window. Never two status items.

## 16. Permissions

| Permission | Who | Required |
|---|---|---|
| Accessibility | agent bundle | yes |
| Input Monitoring | — | no |
| Screen Recording | — | never. Window **ids and bounds** from `CGWindowListCopyWindowInfo` are used; **`kCGWindowName` titles** are not. Do not infer permission from `kCGWindowOwnerName` being nil — Golden Gate has leaked owner names without the grant |
| Automation | — | no |

Private SkyLight: optional read of the current Space id. Tiling must work with those symbols missing.

## 17. Failure

| Failure | Response |
|---|---|
| AX flipped off | pause mutations, sheet in menu extra |
| set-frame fails twice | float that window |
| agent crash | menu extra restarts that agent (same instanceId); agent unstashes from **its** session file, then applies launch tiling onto `focusedSpace` if valid else space 1. If the menu extra is also dead, slivers wait until next start (that path is a fresh start, space 1) |
| bad TOML reload | keep last good, surface error |
| window id vanishes | drop node, collapse |
| display UUID gone | pause this instance; menu extra tooltip. Same UUID back → resume, one layout pass, re-stash off-space slivers. Different display → stay paused |
| sleep/wake | re-query frames, one layout pass, re-stash off-space slivers if WindowServer moved them |
| Secure Input | hotkeys dead; warn in menu extra |
| SkyLight symbol missing | public space-binding path only |

## 18. Tests + log

Unit tests required (fixtures in `Tests/LuminaLayoutTests/Fixtures/`):

- spiral insert/remove/collapse; empty-tree insert (`root == nil`); last-window close → empty tree
- `frames` with inner/outer gaps, 1 child and 2 children, wide vs tall; floaters absent from `frames`
- ratio persist; balance recursive; resize ±5% clamp to min size and ≥80pt
- min-size overflow: clamp sibling first; both cannot fit → float the oversized leaf
- launch-tiling z-order: front-to-back insert, refocus original frontmost; frontmost ends ~50%
- spatial: tiled eligibility is frame (`C.minX < F.center.x`), not center; tile-in-strip wins over nearer floater whose center is in-direction; two-floater swap is frames only; tie → lower id
- classify: sheet + tile-rule still floats; Terminal no-zoom tiles; 399×299 floats; 400×300 tiles; System Settings default float; Spotlight hard-float; title-regex late; center on other display unmanaged
- config parse/reject (space-count 0, gaps -1, bad regex, unknown cmd string); shrink space-count drops focusedSpace to 1; workspace id > count is no-op
- command parse (`v`, missing args, 1 MiB line)
- generation-tagged ignore of own AX events (mocked)
- current-space public path: `spaceChange` + no large window → not current; `start` → current; last-window-close (`stash`) + lastCurrent → stay current; any on-screen sliver → attach not spawn

No live AX suite in v1. Manual matrix before a shareable build (Apple silicon only: 15.2, 26, 27): Terminal tabs, Safari tabs, Chrome, Finder copy dialog, System Settings (floats by default), Ghostty, iTerm, native fullscreen Space, in-place green fill → luminaFS, in-place half/quarter → snap back, new window during luminaFS (dialog on top / tile slivered), ⌘H unhide, sleep/wake, lid close/open (same UUID resume), screen lock (agent may die; unstash + launch-tiling), Secure Input, two native Spaces with two instances this boot, reboot → one fresh agent + `launch-apps`, Stage Manager on (must not crash), Apple Option-drag tiling on, Siri.app tiles as a normal window, Visual Intelligence overlay floats, ⌘⇧Space / ⌘⇧6 not stolen, swipe away from empty space drops hotkeys, swipe-back onto empty space without SkyLight needs Start (attach). Do not include Intel in the matrix.

Log level info default; `lumina debug` or `LUMINA_DEBUG=1` bumps to debug. Never log window titles at default info. Bundle ids + window ids are enough.

`os_log` subsystem `com.zelmari.lumina`, category `agent` | `extra` | `cli`. File `~/Library/Logs/Lumina.log`: each process appends (`O_APPEND`) a line prefixed `[agent|extra|cli]`. Take a short `flock` per write. Do not share a seekable file handle across processes.

## 19. Ship

- GitHub Releases: Developer ID + notarized before anyone else runs it. Ad-hoc is for local debug only (AX identity churns).
- Binary **arm64 only**. Do not ship universal / x86_64.
- `.dmg` + a **personal Homebrew tap**. Official `homebrew/cask` requires Gatekeeper (signed + notarized) and will not take a quarantine-strip `postflight`.
- Updates: brew from that tap. Submit to `homebrew/cask` only after notarization is routine.
- README: Apple silicon 15.2+ only, no other WM, Stage Manager off, turn off Apple window-tiling Option-drag, Accessibility for **Lumina Agent**, Mission Control will look wrong, 1px stash remnant, Secure Input, reboot is a fresh start, `launch-apps` (default empty), empty-space swipe-back without SkyLight uses Start.

## 20. Repo

    Sources/Lumina/          menu extra
    Sources/LuminaAgent/     agent
    Sources/LuminaCLI/       socket client
    Sources/LuminaLayout/    pure tree (no AppKit)
    Sources/LuminaIPC/
    Tests/LuminaLayoutTests/
    docs/                    public product docs only (compat, install)
    .gitignore               local SPEC/DESIGN drafts

LuminaLayout has no AppKit. It can be built and unit-tested on Linux with the Swift toolchain. Agent, menu extra, signing, and any real window test require the Mac.

## 21. v1 cut line

**In:** spiral insert on an n-ary tree, spatial focus, 1–10 emulated spaces **this boot**, 1px-corner stash, same-boot crash unstash, one instance per native Mac Space this boot, fresh start on reboot + `launch-apps`, native fullscreen-Space bookmarks (in-memory), Lumina fullscreen (keybind **and** in-place fill), Apple half/quarter snap-back, float rules (split heuristics), native-tab on-screen heuristic, one menu extra routing to the current instance, TOML + live reload, thin CLI, `SMAppService.mainApp` login item, optional SkyLight **read**, ⌘H/⌘M snap-back, mouse snap-back/swap best-effort AX. Min OS 15.2 Apple silicon, arm64-only.

**Out:** borders, overlay windows, Input Monitoring, binding modes, multi-monitor pools, master/accordion insert, named spaces, scratchpad, prefs GUI, Sparkle, App Store, SIP tricks, SkyLight writes, WM detection, pretty Mission Control, Screen Recording, restoring a previous boot’s layout, Intel.

## 22. Build order

1. LuminaLayout + tests (fake rects, spatial focus, spiral, empty tree, floaters-out-of-frames, clamp-then-float, z-order launch tiling)
2. Agent + AX adapter + single-space spiral on one display (identity via `_AXUIElementGetWindow`)
3. Classify + window rules + minimize undo + own-mutation generation
4. 1px-corner stash + session file + agent-start unstash
5. Multi space + hotkeys + socket CLI (thin client)
6. Native fullscreen-Space bookmarks + Lumina fullscreen (in-place fill) + Apple half/quarter snap-back
7. Menu extra + Secure Input + current-Space routing + “Start on this Space”
8. Second instance: per-token sockets, session files, `instances.json`, hotkey register/unregister
9. Config watch + first-launch sheet (incl. Apple tiling)
10. Optional SkyLight read behind the public space heuristic
11. Signed/notarized DMG + personal tap cask

## 23. Decisions

| Choice | Decision |
|---|---|
| Min OS | macOS 15.2 on Apple silicon; arm64-only; Intel out of v1 |
| Tile borders | Out of v1 |
| Second instance | One agent per native Mac Space; separate tree/stash/socket/session; one menu extra; shared config |
| Modifier | Option; first-run **instructs** the user to disable Apple Option-drag tiling (does not write the setting) |
| Mouse | Keyboard always; AX best-effort for snap-back and title-bar swap; no Input Monitoring |
| ⌘H | Unhide immediately, like minimize |
| In-place green-button **fill** | Lumina fullscreen |
| In-place green-button **half/quarter** | Snap back to the Lumina tile |
| Window `tile` rule | Cannot override roles / system UI / PiP; can override no-zoom and min-size |
| System Settings | Default `float` rule |
| Restart after quit | Unstash if needed, then apply launch-tiling onto **space 1** |
| Pause | This instance only; RAM only; not in session.json |
| Native-FS bookmark | In-memory; quit drops it |
| Quit this Space | Always unregister that token from `instances.json` (extra writes) |
| Login item | `SMAppService.mainApp` only; no LaunchAgent plist |
| New boot | Fresh agent on current Space; wipe registry; `launch-apps`; no layout restore; space 1 |
| Resize | 5% of parent split per press |
| luminaFS + new window | Classify: float on top; tile slivered |
| Bound display back | Same UUID resume; different display stay paused |
| `instanceId` | UUID we mint; SkyLight id is a cache, not the token |
| Other-display window | Managed iff center is on the bound display |
| Min-size overflow | Clamp sibling first; if both cannot fit, float the oversized window |
| Launch tiling `z-order` | Front-to-back insert, then refocus original frontmost |
| `float-existing` / `new-only` | v1 aliases: already-open float (toggleable); later windows tile |
| Empty tree | `root == nil` |
| Floaters | `Space.floating`, not in the tree |
| `instances.json` | Menu extra is the only writer |
| Public current-space | `spaceChange` + no large window → not current; Start attaches if any sliver is on-screen, else spawns |

## 24. Key decisions (resolved)

| Decision | Why |
|---|---|
| Spiral with permanent splits, not default Hyprland dwindle | Spec already required alternate-axis; Hyprland default recomputes from W/H |
| Focus is spatial | Spec; tree-neighbor focus is a different product |
| Stash = 1px bottom-corner sliver | WindowServer rejects fully off-screen frames |
| Usable rect = `visibleFrame` − outer gaps | `visibleFrame` already excludes menu, Dock, notch |
| Layout math in AX/top-left | Matches `kAXPositionAttribute`; convert AppKit at the edge |
| Identity = `_AXUIElementGetWindow` + pid | No public AX unique window id |
| Native tabs = on-screen CGWindowList heuristic | Public API; still imperfect |
| CLI is a socket client, not the agent | TCC keys on path + signature; Homebrew symlink must not be the AX process |
| Agent is a nested bundle with its own bundle id | Stable Accessibility identity across upgrades |
| Launch at login = `SMAppService.mainApp` (menu extra) | One login item starts the extra; extra does a **fresh start** (one agent, space 1), does not revive old tokens |
| Crash unstash = that agent on its next start (same boot) | Menu extra restarts a dead agent; no N LaunchAgent labels |
| New boot = fresh | Do not restore layout, spaces, or extra instances; `launch-apps` may open apps |
| `instanceId` is a UUID we mint | SkyLight ids churn across reboot; slivers are on-screen so they cannot be the token |
| Spec wins on behavior | This file wins on types, paths, IPC, signing |
| One instance per native Space | Chosen product; trees/sockets/sessions isolated; config shared |
| One menu extra, not `open -n` two status items | Status items are session-global; two rows of digits is unusable |
| Hotkeys registered only by the current-Space agent | Two agents must not both own `⌥H` |
| No borders in v1 | Overlay windows are their own compositor; not needed to start layout |
| No Input Monitoring | Keyboard swap/resize are enough; mouse is best-effort AX |
| ⌘H unhides immediately | Hide would hole the tree the same way minimize does |
| In-place fill = luminaFS; half/quarter snap back | Fill is “make it big”; a half-tile is Apple fighting Lumina’s layout |
| Session file is stash + flags, not the tree | Spec rebuilds from launch-tiling on every start; ratios are in-memory |
| Socket under `$TMPDIR` | `XDG_RUNTIME_DIR` is not set on macOS |
| SkyLight read optional, writes never | Classic writes fail silent on 15+ with SIP; do not call bridged write variants either |
| Space token is not “windows at launch” | CGWindowIDs churn |
| `pause` == `enable off` | One state |
| No binding modes in v1 | Spec did not ask; one prefix |
| Config is Lumina TOML, not `aerospace.toml` | Different commands; AeroSpace `if.app-id` is deprecated |
| TOMLDecoder | TOML 1.1, pure Swift, current |
| No Screen Recording | Ids/bounds still available; do not use `kCGWindowName`; do not treat `kCGWindowOwnerName == nil` as a permission probe |
| Official homebrew-cask later | Gatekeeper required; personal tap first |
| `.app` via Xcode/script, not SwiftPM alone | Two-process signed bundle |
| Own `setFrame` ignored via generation | Otherwise snap-back fights the layout engine |
| Cannot disable other apps’ yellow buttons | Public AX cannot; snap-back only |
| First-run **instructs** the user to disable Apple Option-drag tiling | Otherwise Option modifier and title-bar drag fight the system WM. No programmatic write. |
| Min OS 15.2 Apple silicon | Option-only `RegisterEventHotKey` restored; Apple Window Manager settings exist. Intel out of v1; 27 is AS-only anyway |
| Clamp min-size then float | Keep tiling when both still fit; never a sliver tile |
| Launch tiling front-to-back then refocus frontmost | The window you were looking at keeps ~50% |
| Quit then Start → space 1 | Quit forgets the instance; crash (token kept) still uses session `focusedSpace` |
| Public current-space drops on `spaceChange` | Spec: swipe away stops hotkeys even from an empty Lumina space. Swipe-back onto empty needs SkyLight or Start |
| Center-on-display membership | Stable; never pull Sidecar windows onto the bound display |
| Extra sole-writes `instances.json` | Two agents + extra must not clobber the registry |
| `ratio` is `Double` | Float drifts across resizes |
| Siri.app tiles; VI / Siri HUD float | Dock app is a real window; overlays are HUDs |
| Do not steal ⌘⇧Space / ⌘⇧6 | Golden Gate Visual Intelligence |
| Split classification heuristics | `tile` is allow-tiled for size/zoom, not a sheet override |
| Spatial focus: frame for tiles, center for floaters | Spec |

## 25. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| AX calls block the process (AeroSpace historically #131; 0.18+ improved, the RPC stall is still real) | high | serial queue, never AX on the UI thread of the menu extra; accept missed 50ms |
| Native tabs misclassified | high | on-screen heuristic + compat doc; float Ghostty/Terminal if needed |
| WindowServer moves slivers (sleep, Mission Control, display wake) | high | re-stash on wake; session file |
| WindowServer kills the agent on screen lock (AeroSpace #2007 on Tahoe 26.3.1+) | high | menu extra restarts the agent; unstash + launch-tiling recover layout, not the pre-lock tree |
| `_AXUIElementGetWindow` disappears | med | position/size fallback; tiling degrades, does not crash |
| SkyLight current-space getter disappears | low | public notification + on-screen test |
| Secure Input looks like “Lumina is dead” | med | status item |
| Ad-hoc signature resets AX every rebuild | med | Developer ID for any kept build |
| Apple Window Manager tiling fights Option | med | first-run sheet |
| Two agents, one hotkey combo | med | register only while token is current |
| Token collision / Space id reuse after reboot | med | treat token as best-effort; on-screen test is the backstop |
| 1px remnant visible, or leaks onto a second display | med | corner choice; v1 one display |
| Title-bar swap misfires on drag-and-drop | med | skip swap when unsure |
| Electron/Chrome ignore setFrame | med | retry once, then float |
| Miniaturize / hide is async | low | second tick |
| Two agents both think they are current (no SkyLight, empty spaces) | med | `lastCurrentInstanceId` on non-`spaceChange` reasons; `spaceChange` + no large window → not current |
| Swipe-back onto empty space, SkyLight missing | med | Menu extra shows Start; attach marks current. Documented |
| Intel user runs the binary | low | arm64-only slice; extra alerts and exits if not arm64 |
| FFM 20 Hz poll misses or focuses during drag | low | ignore while mouse button down and during generation apply |

## 26. Concurrency

- **Menu extra:** `@MainActor` only. No AX. Sockets via `DispatchSource` on a dedicated serial queue, hop UI to MainActor.
- **Agent AppKit / Carbon hotkeys / AXObserver callbacks:** arrive on the main thread; hop immediately onto `MutationQueue`. Do not call AX from the extra; do not call extra-UI from the agent.
- **`MutationQueue`:** one serial `DispatchQueue(label: "com.zelmari.lumina.mutate")`. Exclusive owner of the tree. Coalesce: at most one pending layout pass; later events replace it. If the queue has been running AX for > 200ms, skip remaining windows in that pass, log, continue next pass.
- **AX timeout:** `AXUIElementSetMessagingTimeout(el, 0.05)` per call. Timeout → retry once at 0.05, then float that window.
- AX objects are not Sendable. They never cross queues except as `AXUIElement` used only on `MutationQueue` (create them there from pid).
- `posix_spawn` + `POSIX_SPAWN_SETSID` for detach. Extra watches pid with `kqueue` / `DispatchSourceProcess`.

## 27. Signing, Info.plist, entitlements

Sandbox **off** (AX + Option-only `RegisterEventHotKey`). Hardened runtime **on** for notarization. Do **not** set `com.apple.security.cs.disable-library-validation`.

Menu extra `Info.plist`: `LSUIElement` = true; `CFBundleIdentifier` = `com.zelmari.lumina`; `SMAppService` usage via API not plist; `NSHumanReadableCopyright`; `LSMinimumSystemVersion` = `15.2`. Architectures: **arm64 only**. Runtime: if `uname -m` is not arm64, the extra shows an alert and exits (defense in depth if someone force-runs a slice).

Agent `Contents/Helpers/lumina-agent.app` `Info.plist`: `LSUIElement` = true; `CFBundleIdentifier` = `com.zelmari.lumina.agent`; `NSAppleEventsUsageDescription` is **not** used (no Automation). Accessibility prompt copy lives in the extra’s first-run sheet, not a usage string (TCC Accessibility has no Info.plist key).

Entitlements (both, Developer ID):

```
com.apple.security.app-sandbox = false
com.apple.security.cs.allow-unsigned-executable-memory = false
```

Hardened runtime without library-validation disable. `dlopen` SkyLight as a **system** path (`/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight`). If that fails, public space path only.

Nested helper: sign agent first, then wrap, then sign outer app, then notarize the outer. Staple the dmg.

First-run sheet: extra is `LSUIElement`; use `NSApplication.shared.setActivationPolicy(.accessory)` and `NSApp.activate`; present `NSAlert` as a floating panel. Do not use a Dock icon.

## 28. Keycodes

`RegisterEventHotKey` virtual key codes (ANSI). `alt-h` is keycode `0x04`, not the Option-layer character.

| name | code |
|---|---|
| h j k l | `0x04` `0x26` `0x28` `0x25` |
| minus equal | `0x1B` `0x18` |
| 1 2 3 4 5 | `0x12` `0x13` `0x14` `0x15` `0x17` |
| 6 7 8 9 0 | `0x16` `0x1A` `0x1C` `0x19` `0x1D` |
| leftSquareBracket rightSquareBracket | `0x21` `0x1E` |
| b f q space | `0x0B` `0x03` `0x0C` `0x31` |

ISO extra keys are not default-bound. Users can add keycodes later; v1 named binds are this table only.

## 29. Security

Sockets `0600`, dirs `0700`, under `$TMPDIR/lumina-$UID` and `Application Support/Lumina`. Any process as this user may send JSON-lines and move/close/stash windows. Accepted for a personal WM. Do not listen on TCP. Do not world-raise the socket. After `accept`, drop if peer euid ≠ ours (`getpeereid(3)` or `getsockopt(SOL_LOCAL, LOCAL_PEERCRED)` → `xucred.cr_uid`). Ignore `v` ≠ 1. Cap line size. No auth token in v1.

## 30. Uninstall

Quit all. `SMAppService.mainApp.unregister()`. Delete `~/.config/lumina/` (user’s choice), `~/Library/Application Support/Lumina/`, `~/Library/Logs/Lumina.log`, `$TMPDIR/lumina-$UID`. Accessibility grant for `com.zelmari.lumina.agent` remains in System Settings until the user removes it — document that. Drag `Lumina.app` to Trash.

## 31. `launch-apps`

On the **first agent bind of a boot** only: for each bundle id, `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` → `openApplication`. If already running (`runningApplications` contains that id), skip. Errors log and continue. Config reload does not re-open. Second instance on another native Space does not re-run the list.
