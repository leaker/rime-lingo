#!/usr/bin/env bash
# Builds the release disk image from an existing RimeLingo.app, without signing it:
#
#   bash scripts/make-dmg.sh <RimeLingo.app> <output.dmg>
#
# For a look at the image's window before a release, and for putting an app that is
# already notarized into a new image without building it again. It is the same build_dmg
# that scripts/release.sh uses; release.sh then signs, notarizes and staples the image,
# which this script leaves to whoever publishes the result. The app is only copied.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
die() { echo "make-dmg: $*" >&2; exit 1; }

[[ $# -eq 2 ]] || die "usage: bash scripts/make-dmg.sh <RimeLingo.app> <output.dmg>"
APP="$1" DMG="$2"
[[ -f "$APP/Contents/Info.plist" ]] || die "not an app: $APP"
[[ "$DMG" == *.dmg ]] || die "the output must be named *.dmg: $DMG"
[[ -d "$(dirname "$DMG")" ]] || die "no such folder: $(dirname "$DMG")"

source "$ROOT/scripts/release-functions.sh"
WORK="$(mktemp -d -t rimelingo-make-dmg)"
trap 'detach_dmg; rm -rf "$WORK"' EXIT

check_dmg_tools
build_dmg "$APP" "$DMG" "$WORK"
echo "written (not signed, not notarized): $DMG"
