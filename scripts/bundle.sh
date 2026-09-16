#!/usr/bin/env bash
# Assemble Lumina.app (menu extra + nested agent + CLI). Apple silicon only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "scripts/bundle.sh requires Apple silicon (arm64)." >&2
  exit 1
fi

swift build -c release --arch arm64

BIN="$(swift build -c release --arch arm64 --show-bin-path)"
DIST="${ROOT}/dist"
APP="${DIST}/Lumina.app"
CONTENTS="${APP}/Contents"
MACOS="${CONTENTS}/MacOS"
HELPER="${CONTENTS}/Helpers/lumina-agent.app"
HELPER_MACOS="${HELPER}/Contents/MacOS"
RES="${CONTENTS}/Resources"

rm -rf "${APP}"
mkdir -p "${MACOS}" "${HELPER_MACOS}" "${RES}" "${HELPER}/Contents/Resources"

cp "${BIN}/Lumina" "${MACOS}/Lumina"
cp "${BIN}/lumina" "${MACOS}/lumina"
cp "${BIN}/lumina-agent" "${HELPER_MACOS}/lumina-agent"
cp "${ROOT}/Sources/Lumina/Info.plist" "${CONTENTS}/Info.plist"
cp "${ROOT}/Sources/LuminaAgent/Info.plist" "${HELPER}/Contents/Info.plist"
cp "${ROOT}/Sources/Lumina/Resources/lumina.toml" "${RES}/lumina.toml"
cp "${ROOT}/Sources/Lumina/Lumina.entitlements" "${CONTENTS}/Lumina.entitlements"
cp "${ROOT}/Sources/LuminaAgent/LuminaAgent.entitlements" "${HELPER}/Contents/LuminaAgent.entitlements"

cat > "${CONTENTS}/PkgInfo" <<'EOF'
APPL????
EOF
cat > "${HELPER}/Contents/PkgInfo" <<'EOF'
APPL????
EOF

# Ad-hoc sign inner then outer for local debug. Developer ID is documented in docs/install.md.
codesign --force --sign - --entitlements "${ROOT}/Sources/LuminaAgent/LuminaAgent.entitlements" "${HELPER}"
codesign --force --sign - --entitlements "${ROOT}/Sources/Lumina/Lumina.entitlements" "${APP}"

echo "Built ${APP}"
file "${MACOS}/Lumina" "${MACOS}/lumina" "${HELPER_MACOS}/lumina-agent"
