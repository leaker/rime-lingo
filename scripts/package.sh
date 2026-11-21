#!/usr/bin/env bash
# Produces dist/RimeLingo-<version>.pkg: installs RimeLingo.app to /Library/Input Methods (and
# RimeLingo Settings.app to /Applications) and
# registers it for the installing user. Unsigned unless RIMELINGO_INSTALLER_IDENTITY
# (a "Developer ID Installer" certificate) is set.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(awk -F'"' '/MARKETING_VERSION/ {print $2; exit}' project.yml)"

[[ "${SKIP_BUILD:-0}" == 1 ]] || RIMELINGO_REQUIRE_TIMESTAMP=$([[ "${RIMELINGO_SIGN_IDENTITY:--}" == "-" ]] && echo 0 || echo 1) bash scripts/build-app.sh

STAGE="$ROOT/build/pkg-stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
mkdir -p "$STAGE/root/Library/Input Methods" dist
ditto --noextattr --noqtn build/Release/RimeLingo.app "$STAGE/root/Library/Input Methods/RimeLingo.app"
# Settings also goes to /Applications so it is easy to find (Launchpad, Spotlight).
mkdir -p "$STAGE/root/Applications"
ditto --noextattr --noqtn "build/Release/RimeLingo.app/Contents/Applications/RimeLingo Settings.app" "$STAGE/root/Applications/RimeLingo Settings.app"
# Extended attributes would be archived as ._* AppleDouble files in the payload.
xattr -cr "$STAGE/root"

# Bundles are relocatable by default: Installer would follow any other RimeLingo.app with the
# same bundle ID (a dev build, a copy in Downloads) and update it in place instead of
# installing to /Library/Input Methods, leaving the input method unregistered.
pkgbuild --analyze --root "$STAGE/root" "$STAGE/components.plist" >/dev/null
plutil -convert xml1 "$STAGE/components.plist"
perl -0pi -e 's#(<key>BundleIsRelocatable</key>\s*)<true/>#$1<false/>#g' "$STAGE/components.plist"
if grep -A1 BundleIsRelocatable "$STAGE/components.plist" | grep -q '<true/>'; then
  echo "error: a bundle is still relocatable" >&2; exit 1
fi
COPYFILE_DISABLE=1 pkgbuild --root "$STAGE/root" --install-location / \
  --component-plist "$STAGE/components.plist" \
  --identifier io.github.leaker.inputmethod.rimelingo.pkg --version "$VERSION" \
  --scripts scripts/pkg/scripts "$STAGE/RimeLingo-component.pkg" >/dev/null

# Keep in sync with project.yml (deploymentTarget), Package.swift (platforms) and
# scripts/write-update-manifests.sh (minimumSystemVersion).
MIN_MACOS=15.0
MIN_MACOS_LABEL="${MIN_MACOS%.0}"   # "15" for user-facing text
cat > "$STAGE/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>RimeLingo $VERSION</title>
  <welcome file="welcome.html" mime-type="text/html"/>
  <license file="LICENSE"/>
  <conclusion file="conclusion.html" mime-type="text/html"/>
  <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
  <installation-check script="rimelingoCheckSystem()"/>
  <script><![CDATA[
function rimelingoCheckSystem() {
  if (system.compareVersions(system.version.ProductVersion, '$MIN_MACOS') < 0) {
    my.result.type = 'Fatal';
    my.result.title = 'RimeLingo 需要 macOS $MIN_MACOS_LABEL 或更高版本';
    my.result.message = '当前系统是 macOS ' + system.version.ProductVersion + '，请先升级系统再安装。\nRimeLingo requires macOS $MIN_MACOS_LABEL or later.';
    return false;
  }
  return true;
}
  ]]></script>
  <volume-check><allowed-os-versions><os-version min="$MIN_MACOS"/></allowed-os-versions></volume-check>
  <domains enable_localSystem="true"/>
  <choices-outline><line choice="default"><line choice="rimelingo"/></line></choices-outline>
  <choice id="default"/>
  <choice id="rimelingo" visible="false"><pkg-ref id="io.github.leaker.inputmethod.rimelingo.pkg"/></choice>
  <pkg-ref id="io.github.leaker.inputmethod.rimelingo.pkg" version="$VERSION" onConclusion="none">RimeLingo-component.pkg</pkg-ref>
</installer-gui-script>
XML
cp scripts/pkg/resources/*.html "$STAGE/"
# The installer's license page: what the package contains, then MIT and GPL-3.0 in full.
{
  cat scripts/pkg/LICENSE-header.txt
  printf '\n\n==== MIT License (RimeLingo original code) ====\n\n'
  cat LICENSE
  printf '\n\n==== GNU General Public License v3.0 ====\n\n'
  cat licenses/native-plugins/librime-octagram.LICENSE.txt
} > "$STAGE/LICENSE"

SIGN_ARGS=()
[[ -n "${RIMELINGO_INSTALLER_IDENTITY:-}" ]] && SIGN_ARGS=(--sign "$RIMELINGO_INSTALLER_IDENTITY")
productbuild --distribution "$STAGE/distribution.xml" --resources "$STAGE" --package-path "$STAGE" \
  ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} "dist/RimeLingo-$VERSION.pkg" >/dev/null
rm -rf "$STAGE"
echo "==> dist/RimeLingo-$VERSION.pkg ($(du -h "dist/RimeLingo-$VERSION.pkg" | cut -f1))"
