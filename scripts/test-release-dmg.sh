#!/usr/bin/env bash
# Runs the disk image steps of scripts/release.sh (scripts/release-functions.sh) on a
# fixture folder in a temporary directory. hdiutil, ditto and diskutil are the
# real ones, and so is the layout tool (uv fetches its two pinned libraries from PyPI the
# first time); codesign, xcrun (notarytool, stapler), spctl and curl are stand-ins that
# record how they were called. No Keychain, nothing signed, sent to Apple or published.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The physical path: it is how `mount` names what is mounted below it.
WORK="$(cd "$(mktemp -d -t rimelingo-dmg-test)" && pwd -P)"
fail() { echo "FAIL: $*" >&2; exit 1; }

STUBS="$WORK/stubs"
CALLS="$WORK/calls.log"
mkdir -p "$STUBS"
cat > "$STUBS/codesign" <<'STUB'
#!/bin/bash
echo "codesign $*" >> "$CALLS"
case " $* " in
  *" --display "*) [[ -n "${STUB_NO_TIMESTAMP:-}" ]] || echo "Timestamp=22 Nov 2026 at 10:00:00" >&2 ;;
  *" --verify "*) [[ -z "${STUB_BAD_SIGNATURE:-}" ]] ;;
esac
STUB
cat > "$STUBS/xcrun" <<'STUB'
#!/bin/bash
echo "xcrun $*" >> "$CALLS"
case "$1 $2" in
  "notarytool submit") echo "{\"id\":\"11111111-2222-3333-4444-555555555555\",\"status\":\"${STUB_NOTARY_STATUS:-Accepted}\"}" ;;
  "notarytool log") echo "stub notarization log" ;;
  "stapler staple") [[ -z "${STUB_STAPLE_FAILS:-}" ]] ;;
  "stapler validate") [[ -z "${STUB_TICKET_INVALID:-}" ]] ;;
  *) echo "unexpected: xcrun $*" >&2; exit 64 ;;
esac
STUB
cat > "$STUBS/spctl" <<'STUB'
#!/bin/bash
echo "spctl $*" >> "$CALLS"
[[ -z "${STUB_GATEKEEPER_REJECTS:-}" ]]
STUB
cat > "$STUBS/curl" <<'STUB'
#!/bin/bash
echo "curl $*" >> "$CALLS"
[[ -z "${STUB_CURL_FAILS:-}" ]] || exit 22
printf 'HTTP/2 302\r\nlocation: https://release-assets.githubusercontent.com/x\r\n\r\n'
printf 'HTTP/2 206\r\ncontent-range: bytes 0-0/%s\r\n\r\n' "${STUB_REMOTE_BYTES:-4242}"
printf 'effective-url: https://release-assets.githubusercontent.com/x\n'
STUB
chmod +x "$STUBS"/*
export CALLS PATH="$STUBS:$PATH"

die() { echo "release: $*" >&2; exit 1; }
verify_app() { echo "verify_app $1" >> "$CALLS"; [[ -f "$1/Contents/Info.plist" ]] || die "not the app: $1"; }
IDENTITY="Developer ID Application: Fixture (TEAM000000)"
REQUIREMENT="anchor apple generic"
NOTARY_PROFILE="fixture-profile"
source "$ROOT/scripts/release-functions.sh"
trap 'detach_dmg; rm -rf "$WORK"' EXIT

# Runs a step that must stop the release; its output is kept for a look at the reason.
refuses() {  # <what> <expected in the message> <command...>
  local what="$1" expected="$2"; shift 2
  if ( trap detach_dmg EXIT; "$@" ) > "$WORK/refused.log" 2>&1; then fail "$what was accepted"; fi
  grep -qF -- "$expected" "$WORK/refused.log" || fail "$what stopped for another reason: $(cat "$WORK/refused.log")"
}
mounted() { mount | grep -qF " on $1 "; }
called() { grep -qF -- "$1" "$CALLS" || fail "not called: $1"; }

mkdir -p "$WORK/build/RimeLingo.app/Contents/MacOS"
printf 'fixture plist\n' > "$WORK/build/RimeLingo.app/Contents/Info.plist"
printf '#!/bin/sh\n' > "$WORK/build/RimeLingo.app/Contents/MacOS/RimeLingo"
chmod +x "$WORK/build/RimeLingo.app/Contents/MacOS/RimeLingo"
ln -s MacOS/RimeLingo "$WORK/build/RimeLingo.app/Contents/link"
# A built app carries the disk image's background; the image refers to it there.
mkdir -p "$WORK/build/RimeLingo.app/Contents/Resources"
cp "$DMG_BACKGROUND" "$WORK/build/RimeLingo.app/$DMG_BACKGROUND_IN_APP"
DMG="$WORK/RimeLingo-0.3.0.dmg"

# Building: compressed and read-only, holding the app as it was, under the product's name.
check_dmg_tools
build_dmg "$WORK/build/RimeLingo.app" "$DMG" "$WORK"
[[ -z "$DMG_MOUNT" ]] || fail "build_dmg left DMG_MOUNT set"
! mounted "$WORK/dmg-writable" || fail "build_dmg left the image it lays out mounted"
[[ ! -e "$WORK/dmg-writable.dmg" ]] || fail "build_dmg left the writable image behind"
[[ "$(hdiutil imageinfo -format "$DMG" 2>/dev/null)" == UDZO ]] || fail "the image is not UDZO"
: > "$CALLS"
check_dmg "$DMG" "$WORK/mount"
[[ -z "$DMG_MOUNT" ]] || fail "check_dmg left DMG_MOUNT set"
! mounted "$WORK/mount" || fail "check_dmg left the image mounted"
called "verify_app $WORK/mount/RimeLingo.app"
called "xcrun stapler validate $WORK/mount/RimeLingo.app"
called "spctl --assess --type execute $WORK/mount/RimeLingo.app"

hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$WORK/look" "$DMG"
DMG_MOUNT="$WORK/look"
mounted "$WORK/look" || fail "this test cannot see mounted images"
diff -r "$WORK/build/RimeLingo.app" "$WORK/look/RimeLingo.app" || fail "the app in the image differs from the one built"
[[ -L "$WORK/look/RimeLingo.app/Contents/link" ]] || fail "a symbolic link was not kept"
[[ -x "$WORK/look/RimeLingo.app/Contents/MacOS/RimeLingo" ]] || fail "the executable bit was not kept"
if touch "$WORK/look/written" 2>/dev/null; then fail "the mounted image is writable"; fi

# The window: the app is the only thing on the image besides the layout, which Finder never
# lists, so nothing else shows even with hidden files shown. The background is inside the
# app. There is no shortcut to Applications, where an input method does not work.
[[ "$(/bin/ls -A "$WORK/look" | LC_ALL=C sort | tr '\n' ' ')" == ".DS_Store RimeLingo.app " ]] \
  || fail "the image holds: $(/bin/ls -A "$WORK/look" | tr '\n' ' ')"
[[ "$(/bin/ls "$WORK/look")" == "RimeLingo.app" ]] || fail "more than the app is visible in the image"
[[ ! -e "$WORK/look/Applications" && ! -L "$WORK/look/Applications" ]] || fail "the image has an Applications shortcut"
[[ -z "$(find "$WORK/look" -maxdepth 1 -type l)" ]] || fail "the image has a link at its top"
[[ "$(stat -f %Sf "$WORK/look/.DS_Store")" == *hidden* ]] || fail ".DS_Store is not flagged hidden"
[[ "$(stat -f %Sf "$WORK/look/RimeLingo.app")" != *hidden* ]] || fail "the app is hidden"
cmp "$DMG_BACKGROUND" "$WORK/look/$DMG_BACKGROUND_IN_IMAGE" || fail "the background in the image is not the tracked one"
# What the layout file itself says, read back with the tool that wrote it.
LAYOUT="$(dmg_layout read "$WORK/look/.DS_Store")"
says() { plutil -extract "$1" raw -o - - <<<"$LAYOUT"; }
[[ "$(says view)" == icnv ]] || fail "the window is not an icon view"
[[ "$(says 'icons.RimeLingo\.app.0') $(says 'icons.RimeLingo\.app.1')" == "$DMG_ICON_X $DMG_ICON_Y" ]] || fail "the icon is at $(says 'icons.RimeLingo\.app')"
[[ "$(plutil -extract icons raw -o - - <<<"$LAYOUT")" == RimeLingo.app ]] || fail "the layout places more than the app"
[[ "$(says background.path)" == "/$DMG_BACKGROUND_IN_IMAGE" ]] || fail "the layout's background is $(says background.path)"
[[ "$(says background.carbon_path)" == "$DMG_VOLUME_NAME:RimeLingo.app:Contents:Resources:DiskImageBackground.tiff" ]] || fail "the background alias is $(says background.carbon_path)"
[[ "$(says background.volume_path)" == "/Volumes/$DMG_VOLUME_NAME" ]] || fail "the background alias remembers the build's mount point"
[[ "$(says bookmark.path)" == "$DMG_BACKGROUND_IN_IMAGE" ]] || fail "the layout's bookmark is $(says bookmark.path)"
[[ "$(says bookmark.volume_path)" == "/Volumes/$DMG_VOLUME_NAME" ]] || fail "the bookmark remembers the build's mount point"
[[ "$(says icon_view.backgroundType)" == 2 ]] || fail "the window's background is not a picture"
[[ "$(says window.WindowBounds)" == "{{200, 120}, {640, 456}}" ]] || fail "the window is $(says window.WindowBounds)"
[[ "$(says window.ShowToolbar) $(says window.ShowSidebar) $(says window.ShowStatusBar)" == "false false false" ]] || fail "the window shows a bar"
[[ "$(says icon_view.labelOnBottom) $(says icon_view.arrangeBy)" == "true none" ]] || fail "the icons are not placed by hand with names below"
# The picture is drawn for the same numbers, at both resolutions.
grep -qF "let iconCentre = CGPoint(x: $DMG_ICON_X, y: $DMG_ICON_Y)" "$ROOT/scripts/gen-dmg-background.swift" || fail "the background is drawn for another icon position"
grep -qF "let window = CGSize(width: $DMG_WINDOW_WIDTH, height: $DMG_WINDOW_HEIGHT)" "$ROOT/scripts/gen-dmg-background.swift" || fail "the background is drawn for another window"
[[ "$(tiffutil -info "$DMG_BACKGROUND" 2>&1 | grep -c 'Resolution: \(72, 72\|144, 144\)')" == 2 ]] || fail "the background is not a 1x and a 2x rendering"
detach_dmg
! mounted "$WORK/look" || fail "detach_dmg left the image mounted"
detach_dmg  # nothing mounted: must be harmless

# A second build replaces the first, and leftovers in the staging folder do not get in.
touch "$WORK/dmg-root/leftover" "$WORK/dmg-writable.dmg"
build_dmg "$WORK/build/RimeLingo.app" "$DMG" "$WORK"
check_dmg "$DMG" "$WORK/mount"

# What is inside is checked on the mounted image, and a stop in the middle detaches it.
mkdir -p "$WORK/extra/RimeLingo.app/Contents"
cp "$WORK/build/RimeLingo.app/Contents/Info.plist" "$WORK/extra/RimeLingo.app/Contents/"
ln -s /Applications "$WORK/extra/Applications"
hdiutil create -quiet -volname "$DMG_VOLUME_NAME" -srcfolder "$WORK/extra" -fs HFS+ -format UDZO "$WORK/extra.dmg"
refuses "an image with more than the app" "holds more than RimeLingo.app" check_dmg "$WORK/extra.dmg" "$WORK/mount-extra"
! mounted "$WORK/mount-extra" || fail "a refused image stayed mounted"
rm "$WORK/extra/Applications"
hdiutil create -quiet -volname "RimeLingo" -srcfolder "$WORK/extra" -fs HFS+ -format UDZO "$WORK/named.dmg"
refuses "an image under another name" "is named 'RimeLingo'" check_dmg "$WORK/named.dmg" "$WORK/mount-named"
! mounted "$WORK/mount-named" || fail "a refused image stayed mounted"
mkdir -p "$WORK/empty/RimeLingo.app"
hdiutil create -quiet -volname "$DMG_VOLUME_NAME" -srcfolder "$WORK/empty" -fs HFS+ -format UDZO "$WORK/empty.dmg"
refuses "an image whose app fails verify_app" "not the app" check_dmg "$WORK/empty.dmg" "$WORK/mount-empty"
STUB_TICKET_INVALID=1 refuses "an app without a ticket" "no valid notarization ticket" check_dmg "$DMG" "$WORK/mount"
STUB_GATEKEEPER_REJECTS=1 refuses "an app Gatekeeper rejects" "Gatekeeper rejects the app" check_dmg "$DMG" "$WORK/mount"
! mounted "$WORK/mount" || fail "a refused image stayed mounted"
# An image without the designed window is not released, nor one whose layout was changed.
hdiutil create -quiet -volname "$DMG_VOLUME_NAME" -srcfolder "$WORK/build" -fs HFS+ -format UDZO "$WORK/bare.dmg"
refuses "an image without a layout" "has no window layout" check_dmg "$WORK/bare.dmg" "$WORK/mount-bare"
! mounted "$WORK/mount-bare" || fail "a refused image stayed mounted"
( DMG_ICON_X=300; refuses "an image with the icon elsewhere" "icon is not at 300" check_dmg "$DMG" "$WORK/mount" )
( DMG_WINDOW_CHROME=28; refuses "an image whose window has no room for a path bar" "the disk image's window is" check_dmg "$DMG" "$WORK/mount" )
# An app built before the background was part of it cannot make the image.
ditto "$WORK/build/RimeLingo.app" "$WORK/old/RimeLingo.app"
rm "$WORK/old/RimeLingo.app/$DMG_BACKGROUND_IN_APP"
refuses "an app without the background" "does not carry the disk image's background" build_dmg "$WORK/old/RimeLingo.app" "$WORK/old.dmg" "$WORK/old"
[[ ! -e "$WORK/old.dmg" ]] || fail "an image was written for an app without the background"
refuses "a file that is not an image" "cannot open" check_dmg "$WORK/build/RimeLingo.app/Contents/Info.plist" "$WORK/mount"

# Signing: the release identity, a secure timestamp, and the same requirement as the app.
: > "$CALLS"
sign_dmg "$DMG"
called "codesign --sign $IDENTITY --timestamp $DMG"
called "codesign --verify --strict --test-requirement==$REQUIREMENT $DMG"
STUB_BAD_SIGNATURE=1 refuses "a wrongly signed image" "not signed with a Developer ID" sign_dmg "$DMG"
STUB_NO_TIMESTAMP=1 refuses "an image without a timestamp" "no secure timestamp" sign_dmg "$DMG"

# Notarization: only "Accepted" passes, and a refusal shows Apple's log.
: > "$CALLS"
notarize "$DMG"
called "xcrun notarytool submit $DMG --keychain-profile $NOTARY_PROFILE --wait --output-format json"
STUB_NOTARY_STATUS=Invalid refuses "a rejected submission" "did not succeed (status: Invalid)" notarize "$DMG"
grep -qF "stub notarization log" "$WORK/refused.log" || fail "the notarization log was not shown"
STUB_NOTARY_STATUS="In Progress" refuses "an unfinished submission" "did not succeed" notarize "$DMG"

: > "$CALLS"
staple_dmg "$DMG"
called "xcrun stapler staple $DMG"
called "xcrun stapler validate $DMG"
called "spctl --assess --type open --context context:primary-signature $DMG"
STUB_STAPLE_FAILS=1 refuses "an image that cannot be stapled" "cannot staple" staple_dmg "$DMG"
STUB_TICKET_INVALID=1 refuses "an image with a bad ticket" "is not valid" staple_dmg "$DMG"
STUB_GATEKEEPER_REJECTS=1 refuses "an image Gatekeeper rejects" "Gatekeeper rejects RimeLingo-0.3.0.dmg" staple_dmg "$DMG"

# The download check reads the size from a ranged GET and keeps every hop's headers.
: > "$CALLS"
probe_download "https://example.invalid/RimeLingo-0.3.0.dmg"
[[ "$REMOTE_SIZE" == 4242 ]] || fail "probe_download read '$REMOTE_SIZE', not 4242"
grep -q '^location: https://release-assets.githubusercontent.com/x$' <<<"$REMOTE_HEADERS" || fail "the redirect was not kept"
grep -q '^effective-url: ' <<<"$REMOTE_HEADERS" || fail "the final URL was not kept"
grep -q -- ' -r 0-0 ' "$CALLS" || fail "probe_download did not ask for a byte range"
if grep -qE -- ' (-I|--head) ' "$CALLS"; then fail "probe_download used HEAD"; fi
STUB_CURL_FAILS=1 probe_download "https://example.invalid/missing.dmg"
[[ -z "$REMOTE_SIZE" ]] || fail "a failed download reported a size"

# The standalone entry point builds the same image, unsigned, and takes nothing for granted.
: > "$CALLS"
bash "$ROOT/scripts/make-dmg.sh" "$WORK/build/RimeLingo.app" "$WORK/preview.dmg" > /dev/null
check_dmg "$WORK/preview.dmg" "$WORK/mount"
if grep -q -e '^codesign --sign' -e 'notarytool' "$CALLS"; then fail "make-dmg.sh signed or notarized"; fi
if bash "$ROOT/scripts/make-dmg.sh" "$WORK/build" "$WORK/no.dmg" 2>/dev/null; then fail "make-dmg.sh took a folder that is not an app"; fi
[[ ! -e "$WORK/no.dmg" ]] || fail "make-dmg.sh wrote an image for something that is not an app"
# release.sh proves the layout tool runs before anything is sent to Apple.
TOOLS_CHECK="$(grep -n '^check_dmg_tools$' "$ROOT/scripts/release.sh" | cut -d: -f1)"
[[ -n "$TOOLS_CHECK" && "$TOOLS_CHECK" -lt "$(grep -n '^notarize ' "$ROOT/scripts/release.sh" | head -1 | cut -d: -f1)" ]] \
  || fail "release.sh does not check the layout tool before anything is sent to Apple"
( PATH="$STUBS:/usr/bin:/bin"; refuses "a Mac without uv" "uv is required" check_dmg_tools )

# release.sh publishes the image and checks it, but the manifest must not learn about it.
grep -qF '"$ZIP" "$OUT/latest.json" "$OUT/latest.json.sig" "$DMG" ||' "$ROOT/scripts/release.sh" || fail "release.sh does not upload the disk image"
grep -qF 'write-release-manifest.py "$ZIP" "$VERSION" "$BUILD" "$MIN_MACOS" "$OUT"' "$ROOT/scripts/release.sh" || fail "the manifest call changed"
if grep -qi 'dmg' "$ROOT/scripts/write-release-manifest.py"; then fail "the manifest writer mentions the disk image"; fi
# Nothing leaves this Mac before every check that can fail locally: the first submission
# comes after the build is verified, and nothing asks for input.
BUILD_VERIFIED="$(grep -n '^verify_app "$APP"$' "$ROOT/scripts/release.sh" | head -1 | cut -d: -f1)"
[[ -n "$BUILD_VERIFIED" ]] || fail "cannot find the build check in release.sh"
while IFS=: read -r line _; do
  [[ "$line" -gt "$BUILD_VERIFIED" ]] || fail "release.sh line $line submits to Apple before the build is checked"
done < <(grep -n '^notarize ' "$ROOT/scripts/release.sh")
if grep -qE '(^|[^[:alnum:]_])read -r|^confirm ' "$ROOT/scripts/release.sh"; then fail "release.sh asks for input"; fi
[[ "$(grep -c '^notarize ' "$ROOT/scripts/release.sh")" == 2 ]] || fail "release.sh must notarize the app and the disk image"

[[ -z "$(hdiutil info | grep -F "$WORK" || true)" ]] || fail "an image of this test is still attached"

echo 'PASS: image built compressed and read-only with the app in the designed window (background inside the app, layout hidden, nothing else on the image, room for a path bar, no Applications link), make-dmg.sh, contents and name checked on the mount, detached on failure, signing, notarization, stapling, Gatekeeper, download probe, release.sh order'
