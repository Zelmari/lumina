# Releasing Lumina

Releases use ad hoc signing. No Apple Developer account or signing secrets are needed. The app is not notarized; first launch may require approval in macOS Privacy & Security. Do not remove quarantine attributes in the cask.

## Build and check locally

On Apple silicon with Xcode's toolchain:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
./scripts/release.sh 0.1.0
```

This creates `dist/Lumina-0.1.0-arm64.zip`, `dist/SHA256SUMS`, and `dist/tap/Casks/lumina.rb`. Bundle and CLI versions come from the release version. Before publishing, test the downloaded archive on a clean account: first launch, Accessibility for the nested agent, configuration shortcut, menu controls, quit, reopen, and optional login launch. Quit all before replacing a running build.

## GitHub Release

Commit the release changes first. Tag that commit and push the tag:

```sh
git tag -a v0.1.0 -m 'Lumina 0.1.0'
git push origin v0.1.0
```

The release workflow runs tests, packages the app, checks its signature and CLI version, and creates a **draft** release with the ZIP, checksum, and generated cask. Review its notes, download and smoke-test the archive, then publish the draft. Do not move published version tags or replace released archives: their hashes are pinned by the tap.

## Personal Homebrew tap

Create the public GitHub repository `Zelmari/homebrew-tap`. After publishing the release, copy its `lumina.rb` asset into `Casks/lumina.rb` in that repository and commit it. The generated file contains the exact archive checksum; do not use `sha256 :no_check`.

Users install with:

```sh
brew tap Zelmari/tap
brew install --cask Zelmari/tap/lumina
```

To update, quit Lumina using Quit all, then:

```sh
brew update
brew upgrade --cask Zelmari/tap/lumina
```

The cask installs the app into Applications and links the bundled CLI. It declares macOS Sequoia or later; Lumina itself enforces the more precise macOS 15.2 minimum. Accessibility is still granted manually. Before uninstalling, disable Launch at Login and quit all, then run `brew uninstall --cask Zelmari/tap/lumina`. User configuration is retained.

Repeat the tag, draft review, publish, and cask update for each version. Tap updates are manual, so GitHub Actions needs no cross-repository token.
