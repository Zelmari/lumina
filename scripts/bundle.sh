#!/usr/bin/env bash
# Assemble Lumina.app (menu extra + nested agent + CLI). Apple silicon only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "scripts/bundle.sh requires Apple silicon (arm64)." >&2
  exit 1
fi

# Extra product cannot be named "Lumina": APFS is usually case-insensitive,
# so it would clobber the "lumina" CLI in .build and in Contents/MacOS.
swift build -c release --arch arm64 --product LuminaExtra
swift build -c release --arch arm64 --product lumina
swift build -c release --arch arm64 --product lumina-agent

BIN="$(swift build -c release --arch arm64 --show-bin-path)"
DIST="${ROOT}/dist"
APP="${DIST}/Lumina.app"
CONTENTS="${APP}/Contents"
MACOS="${CONTENTS}/MacOS"
HELPER="${CONTENTS}/Helpers/Lumina Agent.app"
HELPER_MACOS="${HELPER}/Contents/MacOS"
RES="${CONTENTS}/Resources"
HELPER_RES="${HELPER}/Contents/Resources"

rm -rf "${APP}"
mkdir -p "${MACOS}" "${HELPER_MACOS}" "${RES}" "${HELPER_RES}"

cp "${BIN}/LuminaExtra" "${MACOS}/LuminaExtra"
cp "${BIN}/lumina" "${MACOS}/lumina"
cp "${BIN}/lumina-agent" "${HELPER_MACOS}/lumina-agent"
if cmp -s "${MACOS}/LuminaExtra" "${MACOS}/lumina"; then
  echo "CLI and extra binaries collided; Contents/MacOS cannot hold both Lumina and lumina on APFS." >&2
  exit 1
fi
cp "${ROOT}/Sources/Lumina/Info.plist" "${CONTENTS}/Info.plist"
cp "${ROOT}/Sources/LuminaAgent/Info.plist" "${HELPER}/Contents/Info.plist"
cp "${ROOT}/Sources/Lumina/Resources/lumina.toml" "${RES}/lumina.toml"
python3 "${ROOT}/scripts/make-agent-icon.py" "${HELPER_RES}/AppIcon.icns"

cat > "${CONTENTS}/PkgInfo" <<'EOF'
APPL????
EOF
cat > "${HELPER}/Contents/PkgInfo" <<'EOF'
APPL????
EOF

# Ad-hoc sign inner then outer for local debug. Developer ID is documented in docs/install.md.
# Default ad-hoc designated requirement includes cdhash, so every rebuild looks like a new
# TCC client and Accessibility "stays on" for a dead binary. Pin DR to bundle id.
codesign --force --sign - \
  --identifier com.zelmari.lumina.agent \
  --requirements '=designated => identifier "com.zelmari.lumina.agent"' \
  --entitlements "${ROOT}/Sources/LuminaAgent/LuminaAgent.entitlements" \
  "${HELPER}"
codesign --force --sign - \
  --identifier com.zelmari.lumina \
  --requirements '=designated => identifier "com.zelmari.lumina"' \
  --entitlements "${ROOT}/Sources/Lumina/Lumina.entitlements" \
  "${APP}"

echo "Built ${APP}"
file "${MACOS}/LuminaExtra" "${MACOS}/lumina" "${HELPER_MACOS}/lumina-agent"
