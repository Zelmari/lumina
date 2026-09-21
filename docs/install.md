# Install

Apple silicon, macOS 15.2 or later. Do not run another tiling WM. Turn Stage Manager off. In System Settings → Desktop & Dock → Windows, turn off Apple’s window-tiling options (including “Hold Option key while dragging windows to tile”).

## Homebrew

Not yet. Shipping path is a personal tap after Developer ID + notarization. Official `homebrew/cask` comes later (Gatekeeper requires a signed + notarized binary; a quarantine-strip `postflight` will not be accepted).

## From source

Layout and IPC tests (no AppKit; Linux OK):

```sh
swift test --filter LuminaLayoutTests
swift test --filter LuminaIPCTests
```

On an Apple silicon Mac, assemble a debug `.app`:

```sh
./scripts/bundle.sh
```

That produces `dist/Lumina.app`:

| Binary | Path | Bundle id |
|---|---|---|
| Menu extra | `Contents/MacOS/LuminaExtra` | `com.zelmari.lumina` |
| Agent | `Contents/Helpers/Lumina Agent.app` | `com.zelmari.lumina.agent` |
| CLI | `Contents/MacOS/lumina` | socket client only |

`file` on all three Mach-Os should be arm64, not universal. `Contents/MacOS/lumina version` prints the CLI version.

Grant Accessibility to **Lumina Agent**, not the menu extra and not a Homebrew symlink of `lumina`. `bundle.sh` pins the ad-hoc designated requirement to the agent bundle id so local rebuilds should keep that grant. A Developer ID build still uses the cert’s requirement (see below).

Launch at login is opt-in (default off) via the menu extra (`SMAppService.mainApp`). It starts the extra, which does a **fresh** start (one agent, space 1). Do not ship `Contents/Library/LaunchAgents/`.

## Developer ID (not from this script)

Identity placeholders only — do not commit secrets.

```sh
# Sign nested agent first, then the outer app, then notarize the outer, staple the dmg.
codesign --force --options runtime --sign "Developer ID Application: <NAME> (<TEAMID>)" \
  --entitlements Sources/LuminaAgent/LuminaAgent.entitlements \
  "dist/Lumina.app/Contents/Helpers/Lumina Agent.app"
codesign --force --options runtime --sign "Developer ID Application: <NAME> (<TEAMID>)" \
  --entitlements Sources/Lumina/Lumina.entitlements \
  dist/Lumina.app
xcrun notarytool submit dist/Lumina.dmg --keychain-profile "<PROFILE>" --wait
xcrun stapler staple dist/Lumina.dmg
```

Do not set `com.apple.security.cs.disable-library-validation`. Sandbox stays off.

After the outer `codesign --force`, check the helper still has its own designated requirement:

```sh
codesign -d -r- "dist/Lumina.app/Contents/Helpers/Lumina Agent.app"
```

`--force` on the outer bundle can replace that requirement. If it did, sign the helper again and re-check before notarizing.

## Config

`~/.config/lumina/lumina.toml`. Missing file: Lumina writes a copy of the bundled default on first launch.

## Uninstall

Quit all. Unregister launch-at-login from the menu extra. Delete (optional) `~/.config/lumina/`, then `~/Library/Application Support/Lumina/`, `~/Library/Logs/Lumina.log`, and `$TMPDIR/lumina-$UID`. Drag `Lumina.app` to Trash. The Accessibility grant for `com.zelmari.lumina.agent` stays in System Settings until you remove it.
