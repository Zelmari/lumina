# Lumina

Window / tiling manager for macOS. Spiral tiling (Hyprland dwindle with permanent splits) and emulated spaces, without disabling SIP.

Lumina is a guest on macOS. Quitting it restores managed windows to their pre-tiling frames (they may overlap) and leaves apps open.

## Requirements

- Apple silicon only (arm64). Intel is not supported.
- macOS 15.2 or later (including macOS 26 Tahoe and macOS 27 Golden Gate).
- Accessibility for **Lumina Agent** (`com.zelmari.lumina.agent`), not the menu extra and not a Homebrew symlink of `lumina`.
- Do not run another tiling WM beside it.
- Stage Manager: unsupported. Turn it off. Layouts may fight; Lumina must not crash.
- System Settings → Desktop & Dock → Windows: turn **off** “Drag windows to screen edges to tile”, “Drag windows to menu bar to fill screen”, and “Hold Option key while dragging windows to tile”. Lumina does not write those settings.

v1 manages **one display**. Config lives at `~/.config/lumina/lumina.toml`. `launch-apps` defaults to empty. The default config has **10 workspaces** (`Option-1` … `Option-0`); a partial config file merges onto the shipped defaults, so keys you omit keep their default values.

## Known behavior

- Mission Control looks wrong: hidden-space windows are parked as a **1px vertical sliver** in a bottom corner (macOS will not accept a fully off-screen frame). A few pixels remain visible. Dock on the bottom + autohide makes the remnant less obvious.
- Secure Input (password fields, 1Password, some terminals) makes Option hotkeys go dead. The menu extra shows “hotkeys blocked: Secure Input”; that is not a crash.
- Reboot is a **fresh start**: one new agent on the current native Space, no restored layout. A second instance on another native Space is session-scoped; Start again after reboot if you want it.
- Without SkyLight, swipe-back onto an **empty** Lumina space is not auto-detected. Use **Start on this Space** to attach (slivers count). Swipe-away still drops hotkeys.
- Native tabs (Terminal, Ghostty): macOS implements each tab as a separate window. Lumina keeps one tile per app window and swaps the backing window when you switch tabs. Apps are listed under `[native-tabs]` in the config (both ship by default).

## Status

Layout and IPC are unit-tested with SwiftPM (206 tests; Linux toolchain is fine). The menu extra, agent, and CLI are macOS-only and are not compiled by CI. The ad-hoc-signed `.app` (extra + nested agent + CLI) is assembled with `scripts/bundle.sh` on Apple silicon; SwiftPM does not emit that bundle layout by itself.

On macOS, `swift test` needs the Xcode toolchain (`export DEVELOPER_DIR=/Applications/Xcode.app`); Command Line Tools lack the `Testing` module.

For testing the running app, `lumina verify` prints machine-checkable tiling invariants and exits non-zero on any violation: duplicate windows, windows visible on an inactive workspace, tiles overlapping or outside the display, a layout hole that does not span the usable rect, stale focus, a retained dead AX element, a tiled window not actually at its tile, and a hidden-workspace window still on screen. `scripts/harness.sh` drives TextEdit windows through open, focus, swap, float, fullscreen, workspace switch, move, resize, reload and close, calling `verify` after each step, asserting no tracked window leaves the model, and checking that geometry is stable across a workspace round trip. `RECORD=1` writes per-step `list-windows`/`list-workspaces`/`verify`/`debug-windows` artifacts plus a `geometry.txt` table under `artifacts/`; `VERBOSE=1` prints that table every step; `QUIT_TEST=1` finishes by quitting Lumina and checking that every managed window was restored to a usable size. Point `LUMINA` at the CLI and run it on the Mac.

See [docs/install.md](docs/install.md) and [docs/compat.md](docs/compat.md). Known issues from a full-repo audit are tracked in [plans/FINDINGS.md](plans/FINDINGS.md).

## Layout

```
Sources/Lumina/          menu extra
Sources/LuminaAgent/     agent
Sources/LuminaCLI/       socket client (`lumina`)
Sources/LuminaLayout/    pure tree (no AppKit)
Sources/LuminaIPC/       JSON-lines protocol
Tests/LuminaLayoutTests/ pure tree tests
Tests/LuminaIPCTests/    protocol tests
docs/                    install and compatibility notes
plans/                   engineering notes and audit findings
```

## License

MIT.
