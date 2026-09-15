# Lumina

Window / tiling manager for macOS. Spiral tiling (Hyprland dwindle with permanent splits) and emulated spaces, without disabling SIP.

Lumina is a guest on macOS. Quitting it leaves apps open and frames where they are.

## Requirements

- Apple silicon only (arm64). Intel is not supported.
- macOS 15.2 or later (including macOS 26 Tahoe and macOS 27 Golden Gate).
- Accessibility for **Lumina Agent** (`com.zelmari.lumina.agent`), not the menu extra and not a Homebrew symlink.
- Do not run another tiling WM beside it.
- Stage Manager: unsupported. Turn it off.
- System Settings → Desktop & Dock → Windows: turn **off** “Drag windows to screen edges to tile”, “Drag windows to menu bar to fill screen”, and “Hold Option key while dragging windows to tile”. Lumina does not write those settings.

v1 manages **one display**. Config lives at `~/.config/lumina/lumina.toml`.

## Status

Not packaged yet. Layout engine (`LuminaLayout`) builds with SwiftPM and is unit-tested without AppKit (Linux toolchain is fine). The `.app` (menu extra + nested agent) will be an Xcode / bundle-script product; SwiftPM does not emit a signed two-process app.

See [docs/install.md](docs/install.md) and [docs/compat.md](docs/compat.md).

## Layout

```
Sources/Lumina/          menu extra
Sources/LuminaAgent/     agent
Sources/LuminaCLI/       socket client (`lumina`)
Sources/LuminaLayout/    pure tree (no AppKit)
Sources/LuminaIPC/       JSON-lines protocol
Tests/LuminaLayoutTests/
docs/
```

## License

MIT.
