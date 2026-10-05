# Lumina

Window / tiling manager for macOS. Spiral tiling (Hyprland dwindle with permanent splits) and emulated workspaces, without disabling SIP.

Lumina is a guest on macOS. Quitting it restores managed windows to their pre-tiling frames (they may overlap) and leaves apps open.

## Requirements

- Apple silicon only (arm64). Intel is not supported.
- macOS 15.2 or later (including macOS 26 Tahoe and macOS 27 Golden Gate).
- Accessibility for **Lumina Agent** (`com.zelmari.lumina.agent`), not the menu extra and not a Homebrew symlink of `lumina`.
- Do not run another tiling WM beside it.
- Stage Manager: unsupported. Turn it off. Layouts may fight; Lumina must not crash.
- System Settings → Desktop & Dock → Windows: turn **off** “Drag windows to screen edges to tile”, “Drag windows to menu bar to fill screen”, and “Hold Option key while dragging windows to tile”. Lumina does not write those settings.

v1 manages **one display**. See [docs/install.md](docs/install.md) to build and install, and [docs/compat.md](docs/compat.md) for app-specific notes.

## Configuration

Config lives at `~/.config/lumina/lumina.toml`. It hot-reloads on save, including in-place writes; `lumina reload` reports parse errors.

A partial file **merges onto the shipped defaults**: omit a key and its default stays. Invalid values (`space-count` out of range, bad `gaps` or `launch-tiling`) reject the file and keep the last good config. An unknown chord or command skips just that binding, with a diagnostic you can read in `lumina status`.

### Options

| Key | Values | Default | Meaning |
|---|---|---|---|
| `space-count` | 1–10 | `10` | Workspaces. The menu strip always shows at least 5 and grows with use. |
| `focus-follows-mouse` | bool | `false` | Focus the tile under the pointer. |
| `launch-tiling` | `z-order`, `float-existing`, `new-only` | `z-order` | What happens to windows already open when Lumina starts. |
| `launch-apps` | array of bundle ids | `[]` | Apps opened when the agent starts, e.g. `["com.apple.Terminal"]`. |
| `[gaps] inner` | 0–128 | `8` | Gap between tiles. |
| `[gaps] outer` | 0–128 | `8` | Gap between tiles and the screen edges. |
| `[native-tabs] apps` | array of bundle ids | Terminal, Ghostty | Apps whose tabs are separate windows (macOS native tabbing). |

`float-existing` and `new-only` currently behave the same (v1): windows already open float, new ones tile.

### Window rules

```toml
[[window-rule]]
app-id = "com.example.app"       # bundle id
title-regex = ".*Preferences"    # optional
action = "float"                 # tile | float | ignore
```

Rules are evaluated in order; a later rule can override an earlier `tile`. System UI (Spotlight, Control Center, permission sheets, PiP, …) is hard-floated in code.

### Bindings

```toml
[bindings]
alt-h = "focus left"
cmd-shift-1 = "workspace 1"
```

Chord syntax: modifiers `alt` (Option), `cmd`/`super`, `ctrl`/`control`, and `shift`, in any order, plus one key. At least one non-shift modifier is required. Keys: `h j k l`, `minus`, `equal`, `leftSquareBracket`, `rightSquareBracket`, `b`, `f`, `q`, `space`, `1`–`9`, `0`.

Commands: `focus left|down|up|right`, `swap left|down|up|right`, `resize grow|shrink`, `float-toggle`, `balance`, `fullscreen lumina|native`, `close`, `workspace 1..10|prev|next`, `move-node-to-workspace 1..10`.

## Default keyboard shortcuts

| Shortcut | Action |
|---|---|
| `⌥H` `⌥J` `⌥K` `⌥L` | Focus left / down / up / right |
| `⌥⇧H` `⌥⇧J` `⌥⇧K` `⌥⇧L` | Swap with the neighbour left / down / up / right |
| `⌥-` `⌥=` | Resize the focused tile shrink / grow |
| `⌥B` | Balance (equalize split weights) |
| `⌥F` | Fullscreen (Lumina): fill the display and park siblings |
| `⌥⇧F` | Fullscreen (native macOS, toggles) |
| `⌥Space` | Float toggle: retile a floater / float a tile |
| `⌥Q` | Close the focused window |
| `⌥[` `⌥]` | Previous / next workspace |
| `⌥1` … `⌥9`, `⌥0` | Workspace 1 … 10 |
| `⌥⇧1` … `⌥⇧9`, `⌥⇧0` | Move the focused window to workspace 1 … 10 and follow it |

Native tabs (Terminal, Ghostty): macOS implements each tab as a separate window. Lumina keeps one tile per app window and swaps the backing window when you switch tabs. Add other apps to `[native-tabs] apps` if they show the same behavior.

## CLI

`lumina <command>` talks to the agent on the current Space:

| Command | Description |
|---|---|
| `focus left\|down\|up\|right` | Focus the neighbouring window |
| `swap left\|down\|up\|right` | Swap the focused window with a neighbour |
| `resize grow\|shrink` | Resize the focused tile |
| `float-toggle` | Retile a floater / float a tile |
| `balance` | Equalize split weights |
| `fullscreen lumina\|native` | Enter or exit fullscreen |
| `close` | Close the focused window |
| `workspace 1..10\|prev\|next` | Switch workspace |
| `move-node-to-workspace 1..10` | Move the focused window and follow |
| `list-windows` | Print managed windows as JSON |
| `list-workspaces` | Print workspaces as JSON |
| `verify` | Check tiling invariants; exit 1 on any issue |
| `status` | Print agent status as JSON |
| `debug-windows` | Write a model dump (live AX frames, refresh summary) |
| `debug-ax <pid>` | Dump an app's accessibility attributes as JSON |
| `reload` | Reload the config; prints the parse error on failure |
| `pause` / `resume` | Stop / resume managing windows |
| `start` | Start Lumina on this Space |
| `quit` / `exit` | Quit Lumina and untile every window |
| `open-config` | Open the config file |
| `grant-accessibility` | Re-show the Accessibility prompt (after `tccutil reset`) |
| `version` | Print the version |

## Menu extra

- The workspace strip shows digits 1…N, where N is `max(5, highest used workspace)` capped at `space-count`. Click a digit to switch.
- The menu has Open Config, Grant Accessibility…, Reload, Pause/Resume, Start on this Space, Launch at Login, Quit this Space, and Quit all.
- Warnings (Secure Input blocking hotkeys, Accessibility denied, invalid config, hotkey conflict) appear in the strip and its tooltip.

## Test harness

`scripts/harness.sh` drives the real CLI against the running agent. It opens TextEdit windows and walks through focus, swap, float, fullscreen, resize/balance, opening on a fresh workspace, closing a single window (reflow), two workspace round trips (geometry stability), move-to-workspace, the menu-extra workspace count, config reload, and native tabs on a dedicated Ghostty instance, then cleans up. It asserts that no tracked window leaves the model and that geometry converges.

`lumina verify` runs after every step and checks: duplicate windows, windows visible on an inactive workspace, tiles overlapping or outside the display, a layout hole that does not span the usable rect, stale focus, a retained dead AX element, a tiled window not at its tile, and a hidden-workspace window still on screen.

An independent oracle, `scripts/cgwindows.swift`, reads real CG window border coordinates (not Lumina's model). `assert_live_geometry` fails on tile/tile overlap, a focused tile with no live window, a real frame far from its model frame, and a tiled area that no longer spans the model's tiles; floater-over-tile is recorded as a note.

Requirements: macOS, Accessibility and Automation permission for the process running the harness, and Lumina running on this Space. The script owns TextEdit and opens/kills a test Ghostty instance; do not run it while you are editing a document.

| Env | Meaning |
|---|---|
| `LUMINA` | Path to the CLI (default: bundled app, `PATH`, then `.build/debug`) |
| `WINDOW_COUNT` | How many test windows to open (default 3) |
| `KEEP_WINDOWS=1` | Leave the documents open for inspection |
| `QUIT_TEST=1` | Finish by quitting Lumina and checking every restore target is usable |
| `RECORD=1` | Write per-step `list-windows`/`list-workspaces`/`verify`/`debug-windows` artifacts plus `geometry.txt` under `artifacts/` |
| `VERBOSE=1` | Print the per-window geometry table every step |
| `TABS_TEST=0` | Skip the native-tabs section |
| `LUMINA_LOG` | Agent log path (default `~/Library/Logs/Lumina.log`) |

## Known behavior

- Mission Control looks wrong: hidden-workspace windows are parked as a **1px vertical sliver** in a bottom corner (macOS will not accept a fully off-screen frame). A few pixels remain visible. Dock on the bottom + autohide makes the remnant less obvious.
- Secure Input (password fields, 1Password, some terminals) makes Option hotkeys go dead. The menu extra shows “hotkeys blocked: Secure Input”; that is not a crash.
- Reboot is a **fresh start**: one new agent on the current native Space, no restored layout. A second instance on another native Space is session-scoped; Start again after reboot if you want it.
- Without SkyLight, swipe-back onto an **empty** Lumina space is not auto-detected. Use **Start on this Space** to attach (slivers count). Swipe-away still drops hotkeys.
- A window that refuses to shrink below its real minimum (some Electron apps) is floated rather than allowed to overlap its neighbour. Dwindle splits are never rebalanced to accommodate it.
- A window that was already tiled before Lumina ever saw it untrusted has no recoverable original; quit recenters it once. Pause, resize it, and resume to record a new original.

## Status

Layout and IPC are unit-tested with SwiftPM (207 tests; Linux toolchain is fine). The menu extra, agent, and CLI are macOS-only and are not compiled by CI. The ad-hoc-signed `.app` (extra + nested agent + CLI) is assembled with `scripts/bundle.sh` on Apple silicon; SwiftPM does not emit that bundle layout by itself.

On macOS, `swift test` needs the Xcode toolchain (`export DEVELOPER_DIR=/Applications/Xcode.app`); Command Line Tools lack the `Testing` module.

## Layout

```
Sources/Lumina/          menu extra
Sources/LuminaAgent/     agent
Sources/LuminaCLI/       socket client (`lumina`)
Sources/LuminaLayout/    pure tree, config, verify (no AppKit)
Sources/LuminaIPC/       JSON-lines protocol
Tests/LuminaLayoutTests/ pure tree, config, verify tests
Tests/LuminaIPCTests/    protocol tests
scripts/bundle.sh        assemble and sign dist/Lumina.app
scripts/harness.sh       end-to-end harness
scripts/cgwindows.swift  CG oracle used by the harness
docs/                    install and compatibility notes
plans/                   engineering notes (gitignored)
artifacts/               harness output (gitignored)
```

## License

MIT.
