# Parts of scripts/release.sh that can be tried without releasing anything. Sourced by
# release.sh, and by scripts/test-release-dmg.sh, which runs them on a fixture with
# stand-ins for codesign, notarytool, stapler and spctl.
#
# The caller defines: die, verify_app, IDENTITY, REQUIREMENT, NOTARY_PROFILE.

# What Finder shows as the name of the opened disk image.
DMG_VOLUME_NAME="灵译输入法"
# Where a disk image is mounted right now, so that an exit in the middle can detach it.
DMG_MOUNT=""

# The Finder window of the opened image, in points from the top-left corner of its
# content. scripts/gen-dmg-background.swift draws the background for these numbers.
RELEASE_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The picture lives inside the app, so the image holds nothing but the app: a file of its
# own at the top would show in Finder for anyone who has hidden files shown.
DMG_BACKGROUND="$RELEASE_SCRIPTS/../Apps/RimeLingo/Resources/DiskImageBackground.tiff"
DMG_BACKGROUND_IN_APP="Contents/Resources/DiskImageBackground.tiff"
DMG_BACKGROUND_IN_IMAGE="RimeLingo.app/$DMG_BACKGROUND_IN_APP"
DMG_WINDOW_WIDTH=640
DMG_WINDOW_HEIGHT=400
# What the saved window size adds to the content: the title bar, and room for the path bar
# Finder shows at the bottom when it is turned on for every window (the window's own
# setting does not hide it). Without a path bar the picture just shows a little more paper.
DMG_WINDOW_CHROME=56
DMG_ICON_X=144
DMG_ICON_Y=196
DMG_ICON_SIZE=128
DMG_TEXT_SIZE=13

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

# The pinned libraries scripts/dmg-layout.py writes and reads a .DS_Store with. uv fetches
# them on first use and runs from its cache afterwards.
dmg_layout() {  # <write|read|selftest> ...
  uv run --quiet --no-project --with ds-store==1.3.4 --with mac-alias==2.2.4 \
    python "$RELEASE_SCRIPTS/dmg-layout.py" "$@"
}

# To be called before anything is sent to Apple: building the image must not be what
# finds out that uv or the libraries cannot be had.
check_dmg_tools() {
  command -v uv >/dev/null || die "uv is required to lay out the disk image: brew install uv"
  [[ -f "$DMG_BACKGROUND" ]] || die "the disk image's background is missing: $DMG_BACKGROUND"
  dmg_layout selftest >/dev/null \
    || die "the disk image layout tool does not run (uv fetches ds-store and mac-alias from PyPI the first time; is the network up?)"
}

# Fails unless the window layout on a mounted image is the designed one: the app's icon
# where the background expects it, in an icon view without bars, over that background.
check_dmg_layout() {  # <mount point>
  local mount="$1" layout bounds size
  [[ -f "$mount/.DS_Store" ]] || die "the disk image has no window layout (.DS_Store)"
  layout="$(dmg_layout read "$mount/.DS_Store")" || die "cannot read the disk image's window layout"
  layout_value() { plutil -extract "$1" raw -o - - <<<"$layout" 2>/dev/null || true; }
  [[ "$(layout_value view)" == icnv ]] || die "the disk image does not open in icon view"
  [[ "$(layout_value 'icons.RimeLingo\.app.0')" == "$DMG_ICON_X" && "$(layout_value 'icons.RimeLingo\.app.1')" == "$DMG_ICON_Y" ]] \
    || die "the app's icon is not at $DMG_ICON_X, $DMG_ICON_Y in the disk image's window"
  [[ "$(layout_value background.path)" == "/$DMG_BACKGROUND_IN_IMAGE" && "$(layout_value bookmark.path)" == "$DMG_BACKGROUND_IN_IMAGE" ]] \
    || die "the disk image's window does not show $DMG_BACKGROUND_IN_IMAGE as its background"
  [[ "$(layout_value background.volume)" == "$DMG_VOLUME_NAME" ]] || die "the background is looked for on another volume than $DMG_VOLUME_NAME"
  bounds="$(layout_value window.WindowBounds)"
  [[ "$bounds" == *", {$DMG_WINDOW_WIDTH, $((DMG_WINDOW_HEIGHT + DMG_WINDOW_CHROME))}}" ]] || die "the disk image's window is $bounds, not $DMG_WINDOW_WIDTH x $DMG_WINDOW_HEIGHT"
  [[ "$(layout_value window.ShowToolbar)$(layout_value window.ShowSidebar)$(layout_value window.ShowStatusBar)$(layout_value window.ShowPathbar)" == falsefalsefalsefalse ]] \
    || die "the disk image's window shows a toolbar, sidebar, status bar or path bar"
  size="$(layout_value icon_view.iconSize)"
  [[ "${size%.*}" == "$DMG_ICON_SIZE" && "$(layout_value icon_view.arrangeBy)" == none \
    && "$(layout_value icon_view.labelOnBottom)" == true && "$(layout_value icon_view.backgroundType)" == 2 ]] \
    || die "the disk image's icon view is not ${DMG_ICON_SIZE} pt icons, placed by hand, named below, over a picture"
}

# Writes a compressed, read-only disk image whose Finder window shows the app over a
# picture that says what to do: double-click it, then click Install. The app installs
# itself when it is opened from there, so there is no Applications shortcut. The picture,
# which is inside the app, and the layout, which Finder never shows.
# The image is not signed here: release.sh does that, scripts/make-dmg.sh does not.
build_dmg() {  # <RimeLingo.app> <image to write> <scratch directory>
  local app="$1" dmg="$2" staging="$3/dmg-root" writable="$3/dmg-writable.dmg" mount="$3/dmg-writable"
  local listing
  cmp -s "$DMG_BACKGROUND" "$app/$DMG_BACKGROUND_IN_APP" \
    || die "$app does not carry the disk image's background ($DMG_BACKGROUND_IN_APP); build it again from this tree"
  rm -rf "$staging" "$writable" "$mount" && mkdir -p "$staging" "$mount"
  ditto "$app" "$staging/RimeLingo.app"
  # Room for the layout, which can only be written once the files are on the volume: it
  # refers to the background by the numbers the volume gave it.
  dd if=/dev/zero of="$staging/.DS_Store" bs=1024 count=64 2>/dev/null

  hdiutil create -quiet -volname "$DMG_VOLUME_NAME" -srcfolder "$staging" -fs HFS+ \
    -format UDRW -ov "$writable" || die "cannot create $(basename "$dmg")"
  hdiutil attach -quiet -readwrite -nobrowse -noautoopen -owners off -mountpoint "$mount" "$writable" \
    || die "cannot open the disk image to lay it out"
  DMG_MOUNT="$mount"
  rm -f "$mount/.DS_Store"
  dmg_layout write "$mount" --app RimeLingo.app --background "$DMG_BACKGROUND_IN_IMAGE" \
    --icon "$DMG_ICON_X" "$DMG_ICON_Y" --window "$DMG_WINDOW_WIDTH" "$DMG_WINDOW_HEIGHT" \
    --icon-size "$DMG_ICON_SIZE" --text-size "$DMG_TEXT_SIZE" --chrome "$DMG_WINDOW_CHROME" || die "cannot write the disk image's window layout"
  check_dmg_layout "$mount"
  chflags hidden "$mount/.DS_Store" || die "cannot hide the layout file"
  # What macOS leaves on a volume it could write to.
  rm -rf "$mount/.fseventsd" "$mount/.Trashes"
  listing="$(/bin/ls -A "$mount" | LC_ALL=C sort | tr '\n' ' ')"
  [[ "$listing" == ".DS_Store RimeLingo.app " ]] || die "unexpected files on the disk image: $listing"
  detach_dmg
  [[ -z "$DMG_MOUNT" ]] || die "cannot close the disk image after laying it out"

  hdiutil convert -quiet "$writable" -format UDZO -imagekey zlib-level=9 -ov -o "$dmg" || die "cannot compress $(basename "$dmg")"
  rm -f "$writable"
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
  hdiutil detach -quiet "$DMG_MOUNT" || hdiutil detach -quiet -force "$DMG_MOUNT" || return 0
  DMG_MOUNT=""
}

# Opens the image the way a user's Mac does, read-only, and checks what is inside.
check_dmg() {  # <image> <mount point>
  local dmg="$1" mount="$2" listing name
  mkdir -p "$mount"
  hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$mount" "$dmg" \
    || die "cannot open $(basename "$dmg")"
  DMG_MOUNT="$mount"
  # The app is the only thing Finder shows, also with hidden files shown: the window's
  # layout (.DS_Store) is the one file Finder never lists.
  listing="$(/bin/ls -A "$mount" | grep -vxF .DS_Store || true)"
  [[ "$listing" == "RimeLingo.app" ]] || die "the disk image holds more than RimeLingo.app: $(tr '\n' ' ' <<<"$listing")"
  name="$(diskutil info -plist "$mount" | plutil -extract VolumeName raw -o - - 2>/dev/null || true)"
  [[ "$name" == "$DMG_VOLUME_NAME" ]] || die "the disk image is named '${name:-?}', not '$DMG_VOLUME_NAME'"
  verify_app "$mount/RimeLingo.app"
  xcrun stapler validate "$mount/RimeLingo.app" || die "the app in the disk image has no valid notarization ticket"
  spctl --assess --type execute "$mount/RimeLingo.app" || die "Gatekeeper rejects the app in the disk image"
  cmp -s "$DMG_BACKGROUND" "$mount/$DMG_BACKGROUND_IN_IMAGE" || die "the disk image's background is not $DMG_BACKGROUND"
  check_dmg_layout "$mount"
  [[ "$(stat -f %Sf "$mount/.DS_Store" 2>/dev/null)" == *hidden* ]] || die ".DS_Store is not hidden in the disk image"
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
