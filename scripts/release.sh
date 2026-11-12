#!/usr/bin/env bash
# Build an ad-hoc-signed release and a cask for Zelmari/homebrew-tap.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?Usage: scripts/release.sh VERSION}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo 'Expected a version such as 0.1.0 (without v).' >&2
  exit 1
fi
export LUMINA_VERSION="$VERSION"
export LUMINA_BUILD_NUMBER="${LUMINA_BUILD_NUMBER:-1}"
./scripts/bundle.sh
APP=dist/Lumina.app
codesign --verify --deep --strict "$APP"
[[ "$("$APP/Contents/MacOS/lumina" version)" == "lumina $VERSION" ]]
ARCHIVE="Lumina-${VERSION}-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/$ARCHIVE"
(cd dist && shasum -a 256 "$ARCHIVE" > SHA256SUMS)
SHA="$(shasum -a 256 "dist/$ARCHIVE" | cut -d ' ' -f 1)"
mkdir -p dist/tap/Casks
cat > dist/tap/Casks/lumina.rb <<CASK
cask "lumina" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/Zelmari/lumina/releases/download/v#{version}/Lumina-#{version}-arm64.zip"
  name "Lumina"
  desc "Menu bar window tiling manager"
  homepage "https://github.com/Zelmari/lumina"

  depends_on arch: :arm64
  depends_on macos: ">= :sequoia"

  app "Lumina.app"
  binary "#{appdir}/Lumina.app/Contents/MacOS/lumina"

  caveats <<~EOS
    Requires macOS 15.2 or later.
    Lumina is ad-hoc signed and is not notarized by Apple.
    If macOS blocks launch, review Privacy & Security in System Settings
    and choose Open Anyway if you trust this release.
    Grant Accessibility to Lumina Agent when prompted.
    Quit Lumina using Quit all before upgrading or uninstalling.
    Disable Launch at Login before uninstalling.
  EOS
end
CASK
printf 'Release files: dist/%s, dist/SHA256SUMS\nCask: dist/tap/Casks/lumina.rb\n' "$ARCHIVE"
