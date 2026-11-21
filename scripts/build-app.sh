#!/usr/bin/env bash
# Builds and assembles a complete, signed RimeLingo.app at build/Release/RimeLingo.app:
#   Contents/MacOS/RimeLingo                      input method
#   Contents/Helpers/rimelingo                    CLI (+ its resource bundle)
#   Contents/Applications/RimeLingo Settings.app  settings
#   Contents/Frameworks/librime + rime-plugins, Contents/SharedSupport
# Used by install-dev.sh and release.sh. Signs ad-hoc unless RIMELINGO_SIGN_IDENTITY is set.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-Release}"
DERIVED="$ROOT/build/DerivedData"
OUT="$ROOT/build/Release"
IDENTITY="${RIMELINGO_SIGN_IDENTITY:--}"

cd "$ROOT"
[[ -d Packages/RimeLingoKit/Frameworks/CRime.xcframework ]] || bash scripts/fetch-librime.sh
[[ -f build/SharedSupport/default.yaml ]] || bash scripts/fetch-dicts.sh
# RimeLingo's own data changes more often than the dictionaries: always refresh it.
ditto SharedSupport build/SharedSupport
# Refresh public metadata even when reusing an older dictionary build cache.
/usr/bin/python3 scripts/dictionary-metadata.py --shared-dir build/SharedSupport
command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen" >&2; exit 1; }
xcodegen generate --quiet

echo "==> building apps ($CONFIG)"
xcodebuild -project RimeLingo.xcodeproj -scheme RimeLingo -configuration "$CONFIG" -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build -quiet
BUILT="$DERIVED/Build/Products/$CONFIG"

echo "==> building CLI"
swift build --package-path Packages/RimeLingoKit -c release --product rimelingo >/dev/null
CLI_DIR="$(swift build --package-path Packages/RimeLingoKit -c release --show-bin-path)"

rm -rf "$OUT" && mkdir -p "$OUT"
APP="$OUT/RimeLingo.app"
ditto "$BUILT/RimeLingo.app" "$APP"
# Not Contents/MacOS: the file system is case-insensitive and "rimelingo" would replace "RimeLingo".
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Applications"
cp "$CLI_DIR/rimelingo" "$APP/Contents/Helpers/rimelingo"
ditto "$CLI_DIR/RimeLingoKit_RimeLingoCore.bundle" "$APP/Contents/Helpers/RimeLingoKit_RimeLingoCore.bundle"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/Helpers/rimelingo" 2>/dev/null || true
ditto "$BUILT/RimeLingo Settings.app" "$APP/Contents/Applications/RimeLingo Settings.app"

# Local builds are signed ad-hoc by default. Set RIMELINGO_SIGN_IDENTITY to a certificate
# hash to use a real identity — but make sure it is not revoked: macOS treats code
# signed with a revoked certificate as malware (kills it and moves the app to Trash).
echo "==> signing with: $IDENTITY"
TIMESTAMP=--timestamp
[[ "$IDENTITY" == "-" ]] && TIMESTAMP=--timestamp=none
# Development builds tolerate an unreachable timestamp service; release.sh sets
# RIMELINGO_REQUIRE_TIMESTAMP=1 (notarization needs secure timestamps).
sign() {
  codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" "$@" 2>/dev/null && return 0
  [[ "${RIMELINGO_REQUIRE_TIMESTAMP:-0}" == 1 ]] && { echo "timestamp service unavailable" >&2; return 1; }
  codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$@"
}
for lib in "$APP"/Contents/Frameworks/librime.1.dylib "$APP"/Contents/Frameworks/rime-plugins/*.dylib; do sign "$lib"; done
sign "$APP/Contents/Helpers/RimeLingoKit_RimeLingoCore.bundle"
sign --entitlements Apps/RimeLingo/RimeLingo.entitlements "$APP/Contents/Helpers/rimelingo"
sign --entitlements Apps/RimeLingoSettings/RimeLingoSettings.entitlements "$APP/Contents/Applications/RimeLingo Settings.app"
sign --entitlements Apps/RimeLingo/RimeLingo.entitlements "$APP"
codesign --verify --deep --strict "$APP"

# Xcode registers every build product with LaunchServices. A build product that shares
# the installed input method's bundle id then becomes the copy the system resolves, and
# the input method launcher refuses it (LaunchInputMethod() status -50) because it is
# not in an Input Methods directory: the installed input method can no longer be
# started on demand. Keep the build products out of the LaunchServices database.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [[ -x "$LSREGISTER" ]]; then
  for product in "$BUILT/RimeLingo.app" "$BUILT/RimeLingo Settings.app" "$APP" "$APP/Contents/Applications/RimeLingo Settings.app"; do
    "$LSREGISTER" -u "$product" >/dev/null 2>&1 || true
  done
fi
echo "==> built $APP"
