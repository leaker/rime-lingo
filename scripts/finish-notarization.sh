#!/usr/bin/env bash
# Finishes a release whose notarization was still in progress when CI ended
# (scripts/release.sh wrote NOTARY_PENDING.txt). Once Apple accepts every submission it
# staples the tickets into the pkg and the app inside the zip, recomputes SHA256SUMS,
# rewrites and re-signs latest.json and latest-beta.json (RIMELINGO_MANIFEST_KEY, from .env).
#
#   bash scripts/finish-notarization.sh <artefact-dir> [--publish]
#
# <artefact-dir> holds the artefacts written by scripts/release.sh.
# --publish is refused: it replaced GitHub Release assets and the
# files on its download host, and this fork has no release host of its own.
# Exit 3 while a submission is still in progress.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$(cd "${1:?usage: finish-notarization.sh <artefact-dir> [--publish]}" && pwd)"
PUBLISH="${2:-}"
if [[ "$PUBLISH" == --publish ]]; then
  echo "finish-notarization.sh: --publish is disabled in RimeLingo: it uploaded to another project's release" >&2
  echo "channel, and this fork has no release host. Run without --publish to staple only." >&2
  exit 2
fi
[[ -f "$ROOT/.env" ]] && { set -a; . "$ROOT/.env"; set +a; }
: "${RIMELINGO_NOTARY_KEY_PATH:?}" "${RIMELINGO_NOTARY_KEY_ID:?}" "${RIMELINGO_NOTARY_ISSUER_ID:?}" "${RIMELINGO_MANIFEST_KEY:?}"
[[ "$RIMELINGO_NOTARY_KEY_PATH" = /* ]] || RIMELINGO_NOTARY_KEY_PATH="$ROOT/$RIMELINGO_NOTARY_KEY_PATH"
NOTARY=(--key "$RIMELINGO_NOTARY_KEY_PATH" --key-id "$RIMELINGO_NOTARY_KEY_ID" --issuer "$RIMELINGO_NOTARY_ISSUER_ID")

MANIFEST="$DIR/latest-beta.json"
[[ -f "$MANIFEST" ]] || MANIFEST="$DIR/latest.json"
VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$MANIFEST")"
PKG="$DIR/RimeLingo-$VERSION.pkg" ZIP="$DIR/RimeLingo-$VERSION.zip" SRC="$DIR/RimeLingo-$VERSION-source.tar.gz"

if [[ -f "$DIR/NOTARY_PENDING.txt" ]]; then
  while IFS=$'\t' read -r file id; do
    status="$(xcrun notarytool info "$id" "${NOTARY[@]}" --output-format json | plutil -extract status raw -o - -)"
    echo "$file ($id): $status"
    case "$status" in
      Accepted) ;;
      "In Progress") echo "still in progress, try again later"; exit 3 ;;
      *) xcrun notarytool log "$id" "${NOTARY[@]}" >&2 || true; exit 1 ;;
    esac
  done < "$DIR/NOTARY_PENDING.txt"
fi

xcrun stapler staple "$PKG" && xcrun stapler validate "$PKG"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ditto -x -k "$ZIP" "$WORK"
xcrun stapler staple "$WORK/RimeLingo.app" && xcrun stapler validate "$WORK/RimeLingo.app"
rm -f "$ZIP" && ditto -c -k --keepParent "$WORK/RimeLingo.app" "$ZIP"
spctl --assess --type install --verbose=2 "$PKG"

(cd "$DIR" && shasum -a 256 "$(basename "$PKG")" "$(basename "$ZIP")" "$(basename "$SRC")" > SHA256SUMS.txt)
python3 - "$DIR" "$VERSION" "$MANIFEST" <<'PY'
import hashlib, json, os, sys
out, version, path = sys.argv[1:4]
manifest = json.load(open(path))
for kind in ("pkg", "zip", "source"):
    entry = manifest["files"][kind]
    data = open(os.path.join(out, entry["name"]), "rb").read()
    entry.update(size=len(data), sha256=hashlib.sha256(data).hexdigest())
manifest["prerelease"] = "-" in version
if "-" in version:
    for stale in ("latest.json", "latest.json.sig"):
        stale_path = os.path.join(out, stale)
        if os.path.exists(stale_path): os.remove(stale_path)
for name in (["latest-beta.json"] if "-" in version else ["latest.json", "latest-beta.json"]):
    with open(os.path.join(out, name), "w") as output:
        json.dump(manifest, output, ensure_ascii=False, indent=2)
        output.write("\n")
PY
for manifest in latest.json latest-beta.json; do
  [[ -f "$DIR/$manifest" ]] || continue
  RIMELINGO_MANIFEST_KEY="$RIMELINGO_MANIFEST_KEY" swift "$ROOT/scripts/sign-manifest.swift" sign "$DIR/$manifest"
done
echo notarized > "$DIR/SIGNING_STATUS"
rm -f "$DIR/NOTARY_PENDING.txt"
cat "$DIR/SHA256SUMS.txt"

echo "stapled; nothing is uploaded"
