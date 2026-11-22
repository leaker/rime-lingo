#!/usr/bin/env bash
# Runs the disk image steps of scripts/release.sh (scripts/release-functions.sh) on a
# fixture folder in a temporary directory. hdiutil, ditto and diskutil are the real ones;
# codesign, xcrun (notarytool, stapler), spctl and curl are stand-ins that record how they
# were called. No Keychain, no network, nothing signed, sent to Apple or published.
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
DMG="$WORK/RimeLingo-0.3.0.dmg"

# Building: compressed and read-only, holding the app as it was, under the product's name.
build_dmg "$WORK/build/RimeLingo.app" "$DMG" "$WORK"
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
detach_dmg
! mounted "$WORK/look" || fail "detach_dmg left the image mounted"
detach_dmg  # nothing mounted: must be harmless

# A second build replaces the first, and leftovers in the staging folder do not get in.
touch "$WORK/dmg-root/leftover"
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

# release.sh publishes the image and checks it, but the manifest must not learn about it.
grep -qF '"$ZIP" "$OUT/latest.json" "$OUT/latest.json.sig" "$DMG" ||' "$ROOT/scripts/release.sh" || fail "release.sh does not upload the disk image"
grep -qF 'write-release-manifest.py "$ZIP" "$VERSION" "$BUILD" "$MIN_MACOS" "$OUT"' "$ROOT/scripts/release.sh" || fail "the manifest call changed"
if grep -qi 'dmg' "$ROOT/scripts/write-release-manifest.py"; then fail "the manifest writer mentions the disk image"; fi
# Nothing leaves this Mac before the first confirmation: both submissions come after it.
FIRST_CONFIRM="$(grep -n '^confirm "submit' "$ROOT/scripts/release.sh" | cut -d: -f1)"
[[ -n "$FIRST_CONFIRM" ]] || fail "cannot find the first confirmation in release.sh"
while IFS=: read -r line _; do
  [[ "$line" -gt "$FIRST_CONFIRM" ]] || fail "release.sh line $line submits to Apple before the first confirmation"
done < <(grep -n '^notarize ' "$ROOT/scripts/release.sh")
[[ "$(grep -c '^notarize ' "$ROOT/scripts/release.sh")" == 2 ]] || fail "release.sh must notarize the app and the disk image"

echo 'PASS: image built compressed and read-only with only the app, contents and name checked on the mount, detached on failure, signing, notarization, stapling, Gatekeeper, download probe, release.sh order'
