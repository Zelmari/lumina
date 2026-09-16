# Lumina

Window / tiling manager for macOS. Inspired by Hyprland (automatic spiral tiling) and AeroSpace (emulated spaces, no SIP).

Lumina is a guest on macOS, not a replacement WM. It never requires disabling SIP. It never quits apps or destroys windows to keep a layout pretty. Quitting Lumina should feel like it was never there: apps stay open, frames stay put (they may overlap).

v1 is **one display**. Do not run another tiling WM beside it (readme only; no detection).

Min OS **macOS 15.2 on Apple silicon**. Intel is out of v1 (binary is arm64-only). Test on Apple silicon 15.2+, macOS 26 Tahoe, and macOS 27 Golden Gate. Current shipping OS is macOS 27 (as of 2026-09-15).

This file is the product contract. `DESIGN_DOC_LUMINA.md` is the mechanism. If they disagree, **this file wins** for behavior; the design wins for types, paths, IPC, and signing.

## Tiling

Algorithm: **spiral** only (Hyprland dwindle with `preserve_split` on). Splits are permanent on the tree, not recomputed from W/H.

- 1 window → usable screen area (see Chrome), with configured outer gaps.
- New window → split the **focused** tiled window 50/50. If focus is a floater, split the last focused tiled leaf on that space. If the space has no tiled leaf (empty tree), the new tiled window becomes the root.
- Wide display (width ≥ height): first split is **side by side**. After that, each new split alternates axis (H → V → H…).
- Tall display: first split is **top and bottom**, then the same alternation.
- Close → sibling takes the space; tree collapses. No holes. Last tiled window closed → empty tree; space stays.
- Split ratios persist on the tree for that space (survive space switches; in-memory only — a quit, crash, or new boot rebuilds from the launch tiling policy).
- Balance command: set every container on the **current** space to equal child weights (recursive).
- Resize `⌥ -/=`: move the parent split by **5% of that container** per press, along the parent axis. Clamp to each child’s min size. Do not change the other axis.

Focus `H/J/K/L` is **spatial** (not tree-walk). Exact rule in the design. Product constraints:

- Tiled windows: eligible if their **frame** lies in that direction.
- Floating windows: eligible if their **center** sits in that direction.
- Winner: nearest by center-to-center distance. Tie: lower `CGWindowID`.

Swap `⇧ H/J/K/L` uses the same candidate.

- Two tiles: exchange leaves in the tree.
- Tile and floater: exchange roles (floater takes the tile slot, old leaf floats at its last frame).
- Two floaters: exchange on-screen frames. Neither is inserted into the tree.

**Start of an instance** (same boot): unstash leftover slivers if any, then apply **launch tiling** to managed windows on the bound display. Default (`z-order`): spiral front-to-back in current z-order, then **refocus the original frontmost**. Config can switch that to `float-existing` or `new-only` (v1: same behavior — already-open windows float and stay toggleable; windows opened after this start tile). Rebuild target:

- Same-boot **crash** (token kept): that instance’s last focused Lumina space if still valid, else space 1.
- **Quit this Space** then Start, first bind, or new boot: **space 1**.

A window is managed only if its **center** lies on the bound display. Never move a window onto the bound display to make it managed. Centers on any other display → unmanaged.

## Floating

Tile unless it looks like a dialog.

Window rules in config, match `app-id` (bundle id, + optional title regex): `tile`, `float`, or `ignore`. First match wins, with these limits:

- `ignore` always wins.
- A `tile` rule **cannot** override: roles (utility / panel / sheet / tooltip / popover), named system UI, PiP / HUDs.
- A `tile` rule **can** override the no-zoom heuristic and the min-size floor (that is allow-tiled).

Always float (even if a rule said `tile`):

- roles: utility / panel / sheet / tooltip / popover
- system UI (Spotlight, Notification Center, Control Center, permission sheets, screen-sharing picker, loginwindow)
- PiP / mini-players / HUDs — float, do not steal focus
- Visual Intelligence capture UI and Siri HUD / overlay (Golden Gate). The dedicated **Siri.app** (Dock app) is a normal window: tile unless it looks like a dialog.

Float unless a `tile` rule or the terminal allow-list says otherwise:

- windows with no zoom button. Terminal allow-list: Terminal, iTerm2, Alacritty, Ghostty, Kitty, WezTerm (bundle ids in the design)
- windows below a min size (~400×300)

Default config ships a `float` rule for System Settings (`com.apple.systempreferences` / `com.apple.Preferences`). User can change it.

Default **ignore-list** is empty of third-party apps. There is no separate config key: `ignore` is a `[[window-rule]]` action. Commented example rules may ship in the TOML. System UI is handled by the always-float list, not ignore.

Native tab groups: **only the visible tab is a tile**. Hidden tab windows are ignored until they become the on-screen tab. Heuristic is in the design (on-screen `CGWindowID`); it will be wrong for some apps.

If an app fights the model, float or ignore it. Document misses in `docs/compat.md`.

## Spaces

Lumina does **not** use macOS Spaces.

- Own virtual spaces inside the **one** native Mac Space that instance was started on.
- A second Lumina on another native Mac Space is a **separate instance**: own tree, stash, session, socket. No shared window state. Config is shared. At most one instance per native Space. One menu extra for the session.
- Persistent spaces **for this boot**. Default **5**. Configurable **1–10**.
- Keys **1–9 and 0** always map to spaces 1–10 (0 = 10). Unused numbers are no-ops if you configured fewer than 10.
- Spaces stay alive when empty. Numbered 1–N, no names.
- Switch is instant (no Mac Space animation).
- Each space keeps its tree, focus, ratios, and floaters.
- Move window to space N **and follow**. If the window was luminaFS, drop luminaFS on the source (unstash siblings), insert as a **tile** at focus on the destination.
- Next/prev space **wraps**.
- Shrinking the configured space count: windows on dropped spaces pour onto space 1. If the focused space was dropped, focus space 1.
- Do not register ⌘Tab. Observe app activation: if the app’s relevant window lives on another Lumina space, switch to that space.

Hidden-space windows are **not** Dock-minimized and **not** `orderOut`. macOS will not accept a fully off-screen frame; park them as a **1-pixel vertical sliver in a bottom corner** of the bound display (see design). A few pixels remain visible. Mission Control will look wrong; that is accepted.

## Fullscreen

**Native fullscreen Space** (Control-Command-F, or green button when it actually creates a new Mac Space): window leaves the Lumina tree. Remaining windows reflow as if it closed. Remember `{space, parent, indexInParent, ratios, floating?}` **in memory only**. Un-fullscreen: if Lumina is still running on the original Mac Space and the bookmark exists, put the window back in that slot; if the sibling is gone, insert at focus. If Lumina was quit (bookmark gone), leave it native. If the fullscreened app is closed, drop the bookmark.

Public detector (no SkyLight required): our window is gone from this display’s on-screen list, the pid is still alive, and `NSWorkspace.activeSpaceDidChangeNotification` fired (or `kAXFullScreenAttribute` became true). If SkyLight says the current space id changed, that wins. If unsure whether a new native Space appeared, do **not** take the native-FS path.

**In-place green button / Apple Window Manager** (no new Mac Space):

- Frame fills the usable rect (design: slop) → **Lumina fullscreen**.
- Half / quarter / other Apple snap → treat as a user fight: **snap back to the computed tile**. Do not enter luminaFS. Do not leave Apple’s frame.
- If the window actually moved to a new native Space, use the native-fullscreen path instead.

**Lumina fullscreen (keybind or in-place fill):** focused window expands to the usable screen. Other nodes on that space stay in the tree but are not shown (same 1px sliver as a hidden space). Toggle restores exact frames. Not a native Space. One Lumina-fullscreen window per space.

While luminaFS is on:

- **New window:** classify first. Float / ignore / sheet → visible on top, luminaFS stays. Tile → insert in the tree and sliver until luminaFS ends.
- **Close the luminaFS window:** drop luminaFS, unstash siblings, collapse as a normal close.
- **Option-F again:** restore the fullscreened window’s frame and unstash siblings.

## Minimize and Hide

Yellow button / ⌘M must not leave a hole. **Undo minimize immediately** (unminimize + keep the tile). Other apps’ yellow buttons cannot be disabled from outside; snap-back is the behavior.

⌘H (Hide application): **unhide immediately**, same as minimize. Do not leave a hole.

`⌥ Q`: press the window’s close button via AX. Never force-quit the app, never `SIGKILL`.

## Input

Modifier: **Option**. Option+Shift for move / destructive actions. First-run **instructs** the user to turn off macOS “Hold Option key while dragging windows to tile” (and the other Desktop & Dock window-tiling toggles) so the modifier does not fight the system WM. Lumina does not write those settings.

Defaults:

- `⌥ H/J/K/L` focus spatially
- `⌥ ⇧ H/J/K/L` swap in that direction (including floater ↔ tile, floater ↔ floater)
- `⌥ -/=` resize 5% of the parent split
- `⌥ 1–9, 0` switch space
- `⌥ ⇧ 1–9, 0` move window to that space and follow
- `⌥ [` / `⌥ ]` previous / next space (wrap)
- `⌥ B` balance current space
- `⌥ F` Lumina fullscreen
- `⌥ ⇧ F` native fullscreen
- `⌥ Space` float / tile
- `⌥ Q` close **window** (never force-quit the app)

Do not steal ⌘Tab, ⌘`, Mission Control, screenshot (⌘⇧3/4/5), or Visual Intelligence (⌘⇧Space, ⌘⇧6).

Focus-follows-mouse: **off** by default, configurable on. When on: entering a tiled or floating window on the current space focuses it; does not raise. Ignore FFM during our own `setFrame` and during a drag. No delay. Even when FFM is off: hovering another window and **scrolling it** must work without focusing it. Do not install a scroll tap; leave that to macOS.

Click-to-focus. Drag-and-drop between apps must not start a layout move.

Pause: this **instance** ignores hotkeys and tiling updates; other instances are unaffected. `pause` and `enable off` are the same state. Pause is in-memory; a crash or new boot unpauses.

Keyboard swap and resize always work.

Mouse, best-effort via Accessibility only (no Input Monitoring):

- Click-to-focus via AX focused-window notifications.
- User resizes a tiled window and fights the layout → snap back on release, if AX tells us it was a user resize. Layout-driven `setFrame` must not count as a user fight.
- Apple half/quarter snap (green button or Window Manager, no new Space) → snap back to the computed tile, same as a user-resize fight.
- Drag a tiled window onto another tile → swap, only if we can tell a title-bar move from a drag-and-drop. If we cannot tell, **do not swap**. Keyboard swap remains.

Secure Input (password fields, 1Password, some terminals) will make Option hotkeys go dead. Surface that in the menu extra; do not treat it as a Lumina crash.

Bindings use Carbon **virtual key codes** (see design). `alt-h` is the H key, not the character Option produces on a non-US layout.

## Chrome

- Configurable `gaps.inner` and `gaps.outer` (px). TOML: `[gaps]` `inner` / `outer`. Default both **8**. Range 0–128.
- Outer gap remains when only one window. No smart-gaps.
- Inner gap is between sibling tiles only.
- No tile borders in v1. No overlay windows.
- Usable rect = `NSScreen.visibleFrame` minus `gaps.outer`. `visibleFrame` already excludes the menu bar, a visible Dock, and the camera housing. If Dock autohides, do not leave a Dock-sized hole.
- If an app refuses to shrink below a minimum, don’t create a sliver tile. **Clamp the sibling first** so both tiles meet min size; if that is impossible, **float** the window that will not fit and collapse its leaf.

## Menu bar

One menu extra for the session (not one per instance). It talks to the instance bound to the **current** native Mac Space.

- If an instance is **current** here: space digits (click to switch), menu: Open Config, Reload, Pause/Resume, Start on this Space (**hidden**), Launch at Login, Quit this Space, Quit all
- If no instance is current here (none bound, or bound but not detected — empty swipe-back without SkyLight): “Start on this Space”; do not drive another Space’s tree. Start attaches if an agent is already bound.

Open Config: `open -t` on `~/.config/lumina/lumina.toml`; if that fails, TextEdit.

Two status items are not acceptable.

## Lifecycle

**Bound display.** The `NSScreen` that contains the focused window at bind, else `NSScreen.main`. v1 manages that display only.

**Start** on the active Mac Space. Needs Accessibility for the **agent** binary (not the menu extra, not a Homebrew symlink). Unstash leftover slivers if any, bind an instance to that Space, apply launch tiling onto **space 1**. Starting again on a Space that already has an instance is a no-op (attach) — if that instance was not detected as current (SkyLight missing, empty space after a swipe back), attach **marks it current** and re-registers hotkeys. How we tell “already has an instance” without SkyLight: any on-screen window of that agent, **including 1px slivers**. Starting on a different native Space (no slivers of another agent on-screen) creates a second instance **for this boot**.

**launch-apps.** Config list of bundle ids. When the **first agent of a boot** binds, open each id with `NSWorkspace` if that app is not already running. Do not spawn a second copy. Do not move already-running apps. Later instances on other native Spaces do not re-run this list.

**While running:** an instance does not follow the user to other native Mac Spaces. Swipe away → that instance’s hotkeys and management stop until its Space is focused again. Windows stay where it parked them. If another instance is bound to the Space you swiped to, that one is live. Without SkyLight, swipe-**back** onto an **empty** Lumina space may not auto-detect; **Start on this Space** attaches and marks it current. Swipe-away still drops hotkeys (space-change notification).

**Quit this Space:** drop that instance’s hotkeys, unstash its slivers onto its bound native Space, keep last on-screen frames, allow overlap, do not close apps, **unregister that instance**, stop that instance. Other instances keep running.

**Quit all:** the same, for every instance, then the menu extra exits.

**Crash (same boot, menu extra still up):** that instance’s agent unstashes from **its** session file, then applies launch tiling onto that instance’s last focused Lumina space if still valid, else space 1. Token kept.

**New boot / launch-at-login / menu extra coming up with no live agents:** do **not** restore the previous layout, spaces, apps, or instance map. Unstash leftover 1px slivers from any old session files (so windows are not stuck), wipe the instance registry and those session files, bind **one** fresh agent on the current native Space, run `launch-apps`, apply launch tiling onto **space 1**. Launch-at-login is opt-in, default off; it starts the menu extra, which does this fresh start. A second instance is session-scoped — after reboot you Start again on the other native Space if you want it.

**Display gone:** if the bound display UUID disappears (lid, Sidecar, unplug), pause that instance and say so in the menu extra. **Same UUID returns** → auto-resume, one layout pass, re-stash off-space slivers. **A different display appears** → stay paused; do not steal the layout onto it.

Stage Manager: unsupported. Must not crash. Layouts may fight. README only.

## Coexistence

First-run / README, not detection:

- Stage Manager: off
- No other tiling WM
- System Settings → Desktop & Dock → Windows: turn **off** “Drag windows to screen edges to tile”, “Drag windows to menu bar to fill screen”, and “Hold Option key while dragging windows to tile”
- Native Space gestures do not switch Lumina spaces

v1: one display. Sidecar / AirPlay / lid-close: do not invent a second space pool.

## Config

Plain-text TOML at `~/.config/lumina/lumina.toml`, live reload. Covers: space count (1–10), gaps, FFM, launch tiling policy, `launch-apps`, keybinds, window rules (`tile` / `float` / `ignore`). Exact schema in the design doc. `app-id` in a window rule is the bundle id. Unknown keys: log and ignore. Invalid types / out-of-range: keep last good config, error in the menu extra.

CLI for the same actions as the keybinds, plus pause/resume, quit, quit-all, reload, start, list-windows, list-workspaces. Schema in the design.

Any process running as the same user can drive the socket. That is accepted for a personal WM.

## Non-goals (v1)

Multi-monitor space pools, master/accordion layouts, named spaces, scratchpad, mouse insert-on-drop, space swipe gestures, SIP / Dock injection / scripting additions, detecting other WMs, pretty Mission Control, Screen Recording permission, App Store, Sparkle, live AX test suite, binding modes, tile borders, Input Monitoring, restoring a previous boot’s layout, Intel Macs.

Private SkyLight **reads** for the current native Space id are allowed if they fail soft. No private writes. Overlay borders, Input Monitoring, and binding modes stay out.

## Decisions

| Choice | Decision |
|---|---|
| Min OS | macOS 15.2 on Apple silicon; arm64-only; Intel out of v1 |
| Tile borders | Out of v1 |
| Second instance | Allowed this boot: one instance per native Mac Space; one menu extra |
| New boot / login | Fresh agent on the current Space; no restored layout; `launch-apps` may open apps |
| Modifier | Option; first-run **instructs** the user to disable Apple Option-drag tiling |
| Mouse swap / snap-back | Keyboard always; mouse best-effort AX; no Input Monitoring |
| ⌘H | Unhide immediately, like minimize |
| In-place green-button **fill** | Lumina fullscreen |
| In-place green-button **half/quarter** | Snap back to the Lumina tile |
| New window during luminaFS | Classify: float on top; tile slivered in-tree |
| Window `tile` rule | Cannot override roles / system UI / PiP; can override no-zoom and min-size |
| System Settings | Default `float` rule |
| Resize step | 5% of the parent split |
| Restart after quit (same boot) | Unstash if needed, then apply launch-tiling onto **space 1** |
| Pause | This instance only; in-memory |
| Native-FS bookmark | In-memory; quit drops it |
| Quit this Space | Unregisters that instance |
| Bound display back | Same UUID → resume; different display → stay paused |
| Other-display window | Managed iff **center** is on the bound display; never moved onto it |
| Min-size overflow | Clamp sibling first so both fit; if impossible, float the one that will not fit |
| Launch tiling `z-order` | Front-to-back spiral, then refocus the original frontmost |
| `float-existing` / `new-only` | v1: same — already-open windows float (toggleable); later windows tile |
| Rebuild space | Crash: last focused if valid; quit-then-start / new boot / first bind: space 1 |
| CPU | Apple silicon only |
| Empty swipe-back without SkyLight | Not auto-detected; Start attaches if any sliver of that agent is on-screen |
