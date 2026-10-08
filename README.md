# Lumina

Window tiling manager for macOS. Spiral tiling (Hyprland dwindle with permanent splits) and emulated workspaces, without disabling SIP.

Lumina is a guest on macOS. Quitting it restores managed windows to their pre-tiling frames (they may overlap) and leaves apps open.

## Quick start

Apple silicon, macOS 15.2 or later. Install steps are in [docs/install.md](docs/install.md). How the targets fit together is in [docs/architecture.md](docs/architecture.md). Contributor workflow is in [CONTRIBUTING.md](CONTRIBUTING.md).

Layout and IPC tests need no AppKit and run in CI:

```sh
swift test --filter LuminaLayoutTests
swift test --filter LuminaIPCTests
```

On a Mac, `./scripts/bundle.sh` builds an ad-hoc-signed `dist/Lumina.app`. Grant Accessibility to **Lumina Agent**.

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
| `pre-park-new-windows` | bool | `true` | Park a new window in the stash corner the moment it is created, so its default frame is not visible until the tile lands. |
| `speculative-tile` | bool | `false` | Write a new standard window straight to its predicted tile instead of the corner; falls back to the corner on any doubt. |
| `hide-until-tiled-apps` | array of bundle ids | `[]` | Hide these apps at launch and reveal them only after their first window is tiled (opt-in). |
| `[gaps] inner` | 0–128 | `8` | Gap between tiles. |
| `[gaps] outer` | 0–128 | `8` | Gap between tiles and the screen edges. |
| `[native-tabs] apps` | array of bundle ids | Terminal, Ghostty | Apps whose tabs are separate windows (macOS native tabbing). |

`float-existing` and `new-only` currently behave the same (v1): windows already open float, new ones tile.

New windows are detected with `AXCreated`/`AXWindowCreated` plus a bounded launch watch that starts at `willLaunch`, so a window that exists before its observer installs is still caught in the first frames. It is parked in the stash corner before the adoption pass; with `speculative-tile` it is written straight to the tile it is about to occupy. Apps listed in `hide-until-tiled-apps` stay hidden until that pass has tiled their first window, then are revealed and reactivated.

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

Native tabs (Terminal, Ghostty): macOS implements each tab as a separate window. Lumina keeps one tile per visual window and swaps the backing window when you switch tabs. A separate window (Cmd+N) is its own tile. Add other apps to `[native-tabs] apps` if they show the same behavior.

## CLI

`lumina <command>` talks to the agent on the current Space. Exit codes: `0` success, `1` command error or `verify` issues, `2` no agent running on this Space. Commands that return data print one JSON value. Commands with nothing to return print `ok`. Errors go to stderr and are appended to `~/Library/Logs/Lumina.log`.

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
| `ping` | One IPC round trip; prints pong JSON |
| `bench [--count N] [--warmup W] [--max-p95-ms X]` | Measure IPC round-trip latency; exit 1 when p95 exceeds `X` |
| `debug-windows` | Write a model dump (live AX frames, refresh summary, refresh latency) |
| `debug-ax <pid>` | Dump an app's accessibility attributes as JSON |
| `reload` | Reload the config; prints the parse error on failure |
| `pause` / `resume` | Stop / resume managing windows |
| `start` | Start Lumina on this Space |
| `quit` / `exit` | Quit Lumina and untile every window |
| `open-config` | Open the config file |
| `grant-accessibility` | Re-show the Accessibility prompt (after `tccutil reset`) |
| `current-token` | Print this Space's instance id as JSON |
| `strip-buttons` | Print menu-extra digit frames as JSON (screen points, top-left) |
| `version` | Print the version |
| `debug` | Print `LUMINA_DEBUG` and exit. Does not contact the agent |
| `help` | Print command usage (`--help` and `-h` do the same) |

## Menu extra

- The workspace strip shows digits 1…N, where N is `max(5, highest used workspace)` capped at `space-count`. Click a digit to switch.
- The strip updates immediately: a click highlights the digit on the spot, and the agent pushes every workspace/pause/current change over a subscription (with a 250ms–3s adaptive poll as a safety net).
- The menu has Open Config, Grant Accessibility…, Reload, Pause/Resume, Start on this Space, Launch at Login, Quit this Space, and Quit all.
- Warnings (Secure Input blocking hotkeys, Accessibility denied, invalid config, hotkey conflict) appear in the strip and its tooltip.

## Automation

The CLI is non-interactive. Commands print JSON. `verify` exits 0 when the model is consistent and 1 with a JSON issue list otherwise. `status` exits 2 when no agent is running on this Space. `lumina debug-ax <pid>` dumps an app's real accessibility attributes.

`scripts/harness.sh` is the end-to-end suite. It needs a running Lumina and Accessibility plus Automation permission, so CI does not run it. Reproduce a bug as a failing harness assertion, then fix until the harness is green. `RECORD=1` keeps per-step geometry under `artifacts/`.

## Test harness

`scripts/harness.sh` drives the real CLI against a running agent. It opens TextEdit, checks `lumina verify` and live window frames after every step, then cleans up. It does not quit Lumina. No tracked window may leave the model, and geometry has to converge.

The walk covers focus, swap, resize, balance, float, Lumina fullscreen and native fullscreen, close and reflow, workspace round trips, `workspace 0` as workspace 10, pause and resume, config reload, the menu-extra workspace count, and the CLI commands in the table above. A Ghostty section checks native tabs, Cmd-N as a new tile, and a multi-workspace tour: five windows with focus and swap, a move onto an empty workspace and back, nine tiles, a tenth that no longer fits, and `lumina close`. Resize grow, shrink, and balance each have to move a tile.

`FEATURE_TEST` reloads a temporary config (gaps, float and ignore rules, a rejected file, focus-follows-mouse, launch-tiling, speculative tile, hide-until-tiled) and restores the config file. It runs even when `BENCH=0`. It is skipped, and the run can still pass, when `cgwindows` or the config file is missing.

`demo/showcase.sh` is a separate Ghostty-only recording, not a test. Each workspace is visited once: five windows with focus, one swap, resize, balance, float, and Lumina fullscreen; a window moved onto the empty workspace; one tab, one new window, and native fullscreen; then nine tiles, one that no longer fits, and two closes that reflow the layout. Run it from inside Ghostty. It keeps the launching window, closes every Ghostty it opened, and quits Lumina. The crowd of nine was measured on 2026-10-06 for a 1454×907 tile area with 8 pt gaps. The harness covers the same behaviors with assertions and does not quit.

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
| `NEW_WINDOW_TEST=0` | Skip the Ghostty Cmd-N new-window section |
| `GHOSTTY_SPACES_TEST=0` | Skip the multi-workspace Ghostty section |
| `BENCH=0` | Skip the latency section |
| `BENCH_COUNT` / `BENCH_WARMUP` | Pings and warmup for `lumina bench` (default 50 / 5) |
| `BENCH_MAX_P95_MS` | Fail when IPC round-trip p95 exceeds this (default 25) |
| `BENCH_STRICT=1` | Gate on launch-to-frame (default 500ms) and menu-push latency (default 250ms) |
| `BENCH_LAUNCH_MAX_MS` / `BENCH_MENU_MAX_MS` | Thresholds for the strict gates |
| `BENCH_COLD_MAX_MS` | Strict gate for the CG-measured cold launch, including the app's own launch time (default 3000ms) |
| `LAUNCH_TEST=0` | Skip the cold-launch CG measurement. Runs even when `BENCH=0` |
| `FEATURE_TEST=0` | Skip the config checks (gaps, float and ignore rules, a rejected config file, focus-follows-mouse, launch-tiling, speculative-tile, hide-until-tiled). They edit the config and restore the file. Runs even when `BENCH=0` |
| `SHIELD_BOOT_TEST=1` | Also quit and restart Lumina to check a hidden app is revealed at boot |
| `LUMINA_LOG` | Agent log path (default `~/Library/Logs/Lumina.log`) |
| `CONFIG_PATH` | Config the feature sections edit and restore (default `~/.config/lumina/lumina.toml`) |

## Known behavior

- Mission Control looks wrong: hidden-workspace windows are parked as a **1px vertical sliver** in a bottom corner (macOS will not accept a fully off-screen frame). A few pixels remain visible. Dock on the bottom + autohide makes the remnant less obvious.
- Secure Input (password fields, 1Password, some terminals) makes Option hotkeys go dead. The menu extra shows “hotkeys blocked: Secure Input”; that is not a crash.
- Reboot is a **fresh start**: one new agent on the current native Space, no restored layout. A second instance on another native Space is session-scoped; Start again after reboot if you want it.
- Without SkyLight, swipe-back onto an **empty** Lumina space is not auto-detected. Use **Start on this Space** to attach (slivers count). Swipe-away still drops hotkeys.
- A window that refuses to shrink below its real minimum (some Electron apps) is floated rather than allowed to overlap its neighbour. Dwindle splits are never rebalanced to accommodate it.
- A window that was already tiled before Lumina ever saw it untrusted has no recoverable original; quit recenters it once. Pause, resize it, and resume to record a new original.

## Status

Layout and IPC are unit-tested with SwiftPM. Linux CI runs those suites. macOS CI compiles the menu extra, agent, and CLI and runs the same tests. The harness stays local. The ad-hoc-signed `.app` (extra + nested agent + CLI) is assembled with `scripts/bundle.sh` on Apple silicon; SwiftPM does not emit that bundle layout by itself.

On macOS, `swift test` needs the Xcode toolchain (`export DEVELOPER_DIR=/Applications/Xcode.app`); Command Line Tools lack the `Testing` module.

## Layout

```
Sources/Lumina/          menu extra (SwiftPM product LuminaExtra)
Sources/LuminaAgent/     per-display agent
Sources/LuminaCLI/       `lumina` socket client
Sources/LuminaLayout/    pure tree, config, verify (no AppKit)
Sources/LuminaIPC/       JSON-lines protocol
Tests/                   layout and IPC tests (what both CI jobs run)
scripts/bundle.sh        assemble and sign dist/Lumina.app
scripts/harness.sh       macOS end-to-end harness (not in CI)
scripts/cgwindows.swift  CG window oracle used by the harness
demo/showcase.sh         Ghostty showcase
docs/                    install, compatibility, architecture
CONTRIBUTING.md          how to build, test, and send a change
```

## License

MIT. See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).
