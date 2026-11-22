# Parts of scripts/release.sh that can be tried without releasing anything. Sourced by
# release.sh, and by scripts/test-release-dmg.sh, which runs them on a fixture with
# stand-ins for codesign, notarytool, stapler and spctl.
#
# The caller defines: die, verify_app, IDENTITY, REQUIREMENT, NOTARY_PROFILE.

# What Finder shows as the name of the opened disk image.
DMG_VOLUME_NAME="灵译输入法"
# Where a disk image is mounted right now, so that an exit in the middle can detach it.
DMG_MOUNT=""

# Sends a file to Apple and waits for the verdict. Stops unless it is accepted.
notarize() {  # <zip or disk image>
  local file="$1" result submission status
  result="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)" || true
  submission="$(plutil -extract id raw -o - - <<<"$result" 2>/dev/null || true)"
  status="$(plutil -extract status raw -o - - <<<"$result" 2>/dev/null || true)"
  if [[ "$status" != Accepted ]]; then
    echo "$result" >&2
    [[ -z "$submission" ]] || xcrun notarytool log "$submission" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    die "notarization of $(basename "$file") did not succeed (status: ${status:-none}); nothing was published. Fix and run again"
  fi
}

# Writes a compressed, read-only disk image that holds the app and nothing else: the app
# installs itself when it is opened from there, so there is no Applications shortcut and
# no background picture.
build_dmg() {  # <stapled RimeLingo.app> <image to write> <scratch directory>
  local app="$1" dmg="$2" staging="$3/dmg-root"
  rm -rf "$staging" && mkdir -p "$staging"
  ditto "$app" "$staging/RimeLingo.app"
  hdiutil create -quiet -volname "$DMG_VOLUME_NAME" -srcfolder "$staging" -fs HFS+ \
    -format UDZO -imagekey zlib-level=9 -ov "$dmg" || die "cannot create $(basename "$dmg")"
  [[ "$(hdiutil imageinfo -format "$dmg" 2>/dev/null)" == UDZO ]] || die "$(basename "$dmg") is not a compressed read-only image"
}

# Signs the image itself: the signature is what Gatekeeper judges when the image is opened.
sign_dmg() {  # <image>
  local dmg="$1" details
  codesign --sign "$IDENTITY" --timestamp "$dmg" || die "cannot sign $(basename "$dmg")"
  codesign --verify --strict --test-requirement="=$REQUIREMENT" "$dmg" \
    || die "$(basename "$dmg") is not signed with a Developer ID Application certificate of the team"
  details="$(codesign --display --verbose=2 "$dmg" 2>&1)"
  grep -q '^Timestamp=' <<<"$details" || die "no secure timestamp: $(basename "$dmg")"
}

# After notarization: attaches the ticket and asks Gatekeeper what it makes of the image.
staple_dmg() {  # <image>
  local dmg="$1"
  xcrun stapler staple "$dmg" || die "cannot staple $(basename "$dmg")"
  xcrun stapler validate "$dmg" || die "the ticket stapled to $(basename "$dmg") is not valid"
  spctl --assess --type open --context context:primary-signature "$dmg" \
    || die "Gatekeeper rejects $(basename "$dmg")"
}

detach_dmg() {
  [[ -n "$DMG_MOUNT" ]] || return 0
  hdiutil detach -quiet "$DMG_MOUNT" || hdiutil detach -quiet -force "$DMG_MOUNT" || true
  DMG_MOUNT=""
}

# Opens the image the way a user's Mac does, read-only, and checks what is inside.
check_dmg() {  # <image> <mount point>
  local dmg="$1" mount="$2" listing name
  mkdir -p "$mount"
  hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$mount" "$dmg" \
    || die "cannot open $(basename "$dmg")"
  DMG_MOUNT="$mount"
  listing="$(/bin/ls -A "$mount")"
  [[ "$listing" == "RimeLingo.app" ]] || die "the disk image holds more than RimeLingo.app: $(tr '\n' ' ' <<<"$listing")"
  name="$(diskutil info -plist "$mount" | plutil -extract VolumeName raw -o - - 2>/dev/null || true)"
  [[ "$name" == "$DMG_VOLUME_NAME" ]] || die "the disk image is named '${name:-?}', not '$DMG_VOLUME_NAME'"
  verify_app "$mount/RimeLingo.app"
  xcrun stapler validate "$mount/RimeLingo.app" || die "the app in the disk image has no valid notarization ticket"
  spctl --assess --type execute "$mount/RimeLingo.app" || die "Gatekeeper rejects the app in the disk image"
  detach_dmg
}

# Asks the server for the first byte of a URL with a GET (the path a download takes; HEAD
# can be answered differently). Leaves the total size it reports in REMOTE_SIZE, and the
# response headers of every hop plus the final URL in REMOTE_HEADERS.
REMOTE_SIZE=""
REMOTE_HEADERS=""
probe_download() {  # <url>
  REMOTE_HEADERS="$(curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors -r 0-0 -D - -o /dev/null \
    -w 'effective-url: %{url_effective}\n' "$1" | tr -d '\r' || true)"
  REMOTE_SIZE="$(awk 'tolower($1) == "content-range:" { sub(/.*\//, "", $0); total = $0 } END { print total }' <<<"$REMOTE_HEADERS")"
}
