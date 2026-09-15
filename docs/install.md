# Install

Apple silicon, macOS 15.2 or later. Do not run another tiling WM. Turn Stage Manager off. In System Settings → Desktop & Dock → Windows, turn off Apple’s window-tiling options (including “Hold Option key while dragging windows to tile”).

## Homebrew

Not yet. Shipping path is a personal tap after Developer ID + notarization. Official `homebrew/cask` comes later.

## From source

Layout tests (no AppKit):

```sh
swift test --filter LuminaLayoutTests
```

The menu extra and agent are not a SwiftPM `.app`. That bundle will be built with Xcode or a documented bundle script, signed as:

| Binary | Bundle id |
|---|---|
| Menu extra | `com.zelmari.lumina` |
| Agent | `com.zelmari.lumina.agent` |
| CLI | `lumina` (socket client only) |

Grant Accessibility to **Lumina Agent**, not the menu extra and not a Homebrew symlink of `lumina`.

Launch at login is opt-in (default off) via the menu extra.

## Config

`~/.config/lumina/lumina.toml`. Missing file: Lumina writes defaults on first launch.

## Uninstall

Quit all. Unregister launch-at-login from the menu extra. Delete `~/.config/lumina/` (optional), `~/Library/Application Support/Lumina/`, `~/Library/Logs/Lumina.log`. Drag `Lumina.app` to Trash. The Accessibility grant for `com.zelmari.lumina.agent` stays in System Settings until you remove it.
