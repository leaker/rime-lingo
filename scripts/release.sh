#!/usr/bin/env bash
# Builds, notarizes and publishes one release of RimeLingo from this Mac:
#
#   RIMELINGO_SIGN_IDENTITY="Developer ID Application: <name> (FKKCZM5CBJ)" bash scripts/release.sh
#
# It takes no arguments: the version is MARKETING_VERSION in project.yml (and the CLI's
# `version:`), the build number is CURRENT_PROJECT_VERSION. Both must be bumped and
# committed first.
#
# What gets published, to GitHub Releases of the public repository leaker/rime-lingo:
#   RimeLingo-<version>.zip   the signed, notarized, stapled RimeLingo.app
#   latest.json               the manifest (version, build, size and SHA-256 of the zip)
#   latest.json.sig           its Ed25519 signature
#   RimeLingo-<version>.dmg   the same app in a signed, notarized, stapled disk image
#                             (its window says how to install; scripts/make-dmg.sh builds
#                             the same image unsigned for a look beforehand)
# Every installed release build checks latest.json once a day, verifies the signature,
# downloads the zip and replaces its own files in place. Publishing is therefore the same
# as installing on every user's Mac within about a day.
# The disk image is for people: it is what a first install is downloaded as. The manifest
# does not mention it and the updater never fetches it.
#
# One-time setup:
#   1. Manifest signing key (Ed25519, private half stays in the login Keychain):
#        swift scripts/sign-manifest.swift keygen
#      It prints the PUBLIC key. Paste it into `manifestPublicKey` in
#      Packages/RimeLingoKit/Sources/RimeLingoCore/Update/UpdateConfiguration.swift and
#      commit. While that constant is the placeholder, the updater in the apps is inert.
#      Losing the private key means no installed copy can ever be updated again, and the
#      Keychain is its only home: keep a copy offline (the commands are at the top of
#      scripts/sign-manifest.swift, with what protects the Keychain item and what does not).
#      Backup key, so that losing or leaking that key does not strand installed copies:
#        swift scripts/sign-manifest.swift keygen --backup
#      Paste the PUBLIC key it prints into `manifestBackupPublicKey` in the same file, and
#      the output of
#        swift scripts/sign-manifest.swift prove --backup
#      into `manifestBackupKeyProof`. Commit, then move the private half to offline storage
#      and delete it from the Keychain (commands at the top of scripts/sign-manifest.swift).
#      Installed copies accept a manifest signed by either key. This script refuses to
#      release while the backup constant is the placeholder, is not a usable key, or does
#      not match the proof; it does not ask for the backup private key.
#   2. Notarization credentials, stored by notarytool in the Keychain under a profile name:
#        xcrun notarytool store-credentials "rimelingo-notary"
#      Another name goes into RIMELINGO_NOTARY_PROFILE.
#   3. `gh auth login`, and the repository leaker/rime-lingo must exist, be PUBLIC and be
#      this clone's `origin`.
#
# The first install on a Mac is not done by the updater: the user opens the disk image and
# double-clicks the app, which offers to install itself into ~/Library/Input Methods
# (Apps/RimeLingo/InstallerApp.swift). The release notes written below say so; README.md
# keeps the manual way under 「手动安装」.
#
# Running it is the decision to publish: it asks nothing. It prints what it is about to send
# to Apple and what it is about to publish, and every check that can fail runs before
# anything leaves this Mac.
#
# Releasing with the backup key (the everyday key is lost or has leaked): restore the
# backup private key into the Keychain (`swift scripts/sign-manifest.swift import --backup`,
# described at the top of that file; never with the key on a command line), put a NEW
# everyday public key into
# `manifestPublicKey`, commit, and run this script with RIMELINGO_SIGN_WITH_BACKUP_KEY=1.
# The manifest is then signed with `sign --backup` and checked against
# `manifestBackupPublicKey`; the everyday private key is not needed for that release.
#
# The release notes start with the section of CHANGELOG.md for this version, if there is
# one (scripts/promote-changelog.sh writes it; only plain x.y.z versions are released).
# If publishing stops part-way, the script prints the commands that undo what was done.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REPO="leaker/rime-lingo"
TEAM="FKKCZM5CBJ"
IDENTITY="${RIMELINGO_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${RIMELINGO_NOTARY_PROFILE:-rimelingo-notary}"
SIGN_WITH_BACKUP_KEY="${RIMELINGO_SIGN_WITH_BACKUP_KEY:-}"
OUT="$ROOT/dist/release"
APP="$ROOT/build/Release/RimeLingo.app"
CONFIGURATION="Packages/RimeLingoKit/Sources/RimeLingoCore/Update/UpdateConfiguration.swift"
PLACEHOLDER_KEY="REPLACE_BEFORE_FIRST_RELEASE"
# Keep identical to UpdateConfiguration.developerIDRequirement: what the updater demands
# of a downloaded bundle is checked here before it is published.
REQUIREMENT="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$TEAM\""
# Keep identical to UpdateConfiguration.allowedHosts.
ALLOWED_HOSTS="github.com objects.githubusercontent.com release-assets.githubusercontent.com"

die() { echo "release: $*" >&2; exit 1; }
step() { echo "==> $*"; }
sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
size() { stat -f %z "$1"; }
# Highest of dotted numeric versions on stdin.
highest() { sort -t. -k1,1n -k2,2n -k3,3n | tail -1; }

# ---------------------------------------------------------------- refusals

[[ $# -eq 0 ]] || die "takes no arguments; the version comes from project.yml"

VERSION="$(awk -F'"' '/MARKETING_VERSION/ {print $2; exit}' project.yml)"
BUILD="$(awk -F'"' '/CURRENT_PROJECT_VERSION/ {print $2; exit}' project.yml)"
MIN_MACOS="$(awk -F'"' '/^[[:space:]]*macOS:/ {print $2; exit}' project.yml)"
CLI_VERSION="$(awk -F'"' '/^[[:space:]]*version: "/ {print $2; exit}' Packages/RimeLingoKit/Sources/rimelingo/RimeLingo.swift)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "MARKETING_VERSION '$VERSION' is not x.y.z"
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || die "CURRENT_PROJECT_VERSION '$BUILD' is not a positive number"
[[ "$MIN_MACOS" =~ ^[0-9]+\.[0-9]+$ ]] || die "cannot read the deployment target from project.yml"
[[ "$CLI_VERSION" == "$VERSION" ]] || die "version mismatch: project.yml $VERSION, CLI $CLI_VERSION"
TAG="v$VERSION"
ZIP="$OUT/RimeLingo-$VERSION.zip"
DMG="$OUT/RimeLingo-$VERSION.dmg"

[[ -z "$(git status --porcelain)" ]] || die "the working tree is not clean; commit or stash first"
[[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || die "not on main"
ORIGIN="$(git remote get-url origin 2>/dev/null)" || die "this clone has no 'origin' remote"
[[ "$ORIGIN" =~ github\.com[:/]leaker/rime-lingo(\.git)?/?$ ]] || die "origin ($ORIGIN) is not github.com/$REPO"
git fetch --quiet --tags origin || die "cannot fetch from origin"
COMMIT="$(git rev-parse HEAD)"
[[ "$COMMIT" == "$(git rev-parse origin/main 2>/dev/null)" ]] || die "HEAD is not what origin/main points at; push first"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then die "tag $TAG already exists"; fi
LATEST="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' | sed 's/^v//' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | highest || true)"
if [[ -n "$LATEST" ]]; then
  [[ "$(printf '%s\n%s\n' "$LATEST" "$VERSION" | highest)" == "$VERSION" && "$LATEST" != "$VERSION" ]] \
    || die "version $VERSION is not newer than the latest tag v$LATEST"
  PREVIOUS_BUILD="$(git show "v$LATEST:project.yml" | awk -F'"' '/CURRENT_PROJECT_VERSION/ {print $2; exit}')"
  [[ "$PREVIOUS_BUILD" =~ ^[0-9]+$ && "$BUILD" -gt "$PREVIOUS_BUILD" ]] \
    || die "build $BUILD is not higher than build ${PREVIOUS_BUILD:-?} of v$LATEST"
fi

source_key() {  # <constant name>
  sed -n 's/^[[:space:]]*public static let '"$1"' = "\(.*\)"$/\1/p' "$CONFIGURATION"
}
SOURCE_KEY="$(source_key manifestPublicKey)"
[[ -n "$SOURCE_KEY" ]] || die "cannot read manifestPublicKey from $CONFIGURATION"
[[ "$SOURCE_KEY" != "$PLACEHOLDER_KEY" ]] \
  || die "manifestPublicKey is still the placeholder; run 'swift scripts/sign-manifest.swift keygen', paste the key, commit"
SOURCE_BACKUP_KEY="$(source_key manifestBackupPublicKey)"
[[ -n "$SOURCE_BACKUP_KEY" ]] || die "cannot read manifestBackupPublicKey from $CONFIGURATION"
[[ "$SOURCE_BACKUP_KEY" != "$PLACEHOLDER_KEY" ]] \
  || die "manifestBackupPublicKey is still the placeholder; run 'swift scripts/sign-manifest.swift keygen --backup', paste the key, commit"
[[ "$SOURCE_BACKUP_KEY" != "$SOURCE_KEY" ]] || die "manifestBackupPublicKey is the same key as manifestPublicKey: it backs nothing up"
# The apps silently leave out a constant that is not a usable key, and a mangled everyday
# key switches the updater off for good: both must be exactly what keygen printed.
swift scripts/sign-manifest.swift check-key "$SOURCE_KEY" >/dev/null \
  || die "manifestPublicKey ($SOURCE_KEY) is not a usable Ed25519 public key; paste the output of 'swift scripts/sign-manifest.swift pubkey' again"
swift scripts/sign-manifest.swift check-key "$SOURCE_BACKUP_KEY" >/dev/null \
  || die "manifestBackupPublicKey ($SOURCE_BACKUP_KEY) is not a usable Ed25519 public key: installed copies would not accept the backup key"
# The backup private key is offline, so its proof of possession stands in for it: without
# this a wrong backup constant would only show on the day the backup key is needed.
SOURCE_BACKUP_PROOF="$(source_key manifestBackupKeyProof)"
[[ -n "$SOURCE_BACKUP_PROOF" ]] || die "cannot read manifestBackupKeyProof from $CONFIGURATION"
[[ "$SOURCE_BACKUP_PROOF" != "$PLACEHOLDER_KEY" ]] \
  || die "manifestBackupKeyProof is still the placeholder; run 'swift scripts/sign-manifest.swift prove --backup' while the backup key is in the Keychain, paste the proof, commit"
swift scripts/sign-manifest.swift check-proof "$SOURCE_BACKUP_KEY" "$SOURCE_BACKUP_PROOF" >/dev/null \
  || die "manifestBackupKeyProof was not made with the private key of manifestBackupPublicKey: one of the two constants is wrong"
# The key this release is signed with. The backup private key is offline by design and is
# only looked for when it is asked for.
case "$SIGN_WITH_BACKUP_KEY" in
  1) SIGN_FLAGS=(--backup); SIGNING_KEY="$SOURCE_BACKUP_KEY"; SIGNING_KEY_NAME="backup signing key" ;;
  ""|0) SIGN_FLAGS=(); SIGNING_KEY="$SOURCE_KEY"; SIGNING_KEY_NAME="signing key" ;;
  *) die "RIMELINGO_SIGN_WITH_BACKUP_KEY must be 1 or unset, not '$SIGN_WITH_BACKUP_KEY'" ;;
esac
KEYCHAIN_KEY="$(swift scripts/sign-manifest.swift pubkey ${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"})" \
  || die "no manifest $SIGNING_KEY_NAME in the login Keychain (see the one-time setup at the top of this script)"
[[ "$KEYCHAIN_KEY" == "$SIGNING_KEY" ]] \
  || die "the Keychain's $SIGNING_KEY_NAME ($KEYCHAIN_KEY) is not the one in the source ($SIGNING_KEY): installed copies would reject this release"

[[ -n "$IDENTITY" ]] || die "set RIMELINGO_SIGN_IDENTITY to the Developer ID Application identity of team $TEAM"
[[ "$IDENTITY" != "-" ]] || die "an ad-hoc signature cannot be released"
IDENTITY_LINE="$(security find-identity -v -p codesigning | grep -F -- "$IDENTITY" | head -1 || true)"
[[ -n "$IDENTITY_LINE" ]] || die "signing identity '$IDENTITY' is not in the Keychain (or not valid)"
[[ "$IDENTITY_LINE" == *"Developer ID Application:"* && "$IDENTITY_LINE" == *"($TEAM)"* ]] \
  || die "'$IDENTITY' is not a Developer ID Application certificate of team $TEAM:$IDENTITY_LINE"

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || die "notarytool profile '$NOTARY_PROFILE' is missing or rejected (xcrun notarytool store-credentials \"$NOTARY_PROFILE\")"

command -v gh >/dev/null || die "gh is required: brew install gh"
gh auth status >/dev/null 2>&1 || die "gh is not signed in (gh auth login)"
[[ "$(gh repo view "$REPO" --json visibility --jq .visibility 2>/dev/null)" == PUBLIC ]] \
  || die "$REPO does not exist or is not public: the updater reads its releases without a token"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then die "release $TAG already exists on GitHub"; fi
# Publishing needs to push the tag and create the release: find out now, not after the
# build has been notarized. Neither check changes anything.
[[ "$(gh api "repos/$REPO" --jq .permissions.push 2>/dev/null)" == true ]] \
  || die "the account gh is signed in with cannot push to $REPO (gh auth status)"
PUSH_CHECK="$(git push --dry-run origin "$COMMIT:refs/tags/$TAG" 2>&1)" \
  || die "git cannot push tag $TAG to origin (dry run; do the credentials git uses have write access?): $PUSH_CHECK"

# ---------------------------------------------------------------- build and verify

# notarize, the disk image steps and probe_download.
source "$ROOT/scripts/release-functions.sh"
# The disk image's window is laid out by a Python tool that uv runs (and fetches the first
# time): find out that it runs now, not after the app has been notarized.
check_dmg_tools

# Fails unless the bundle, and the code inside it that the seal covers only as files, is
# signed the way the updater will insist on.
verify_app() {  # <RimeLingo.app>
  local app="$1" code details
  for code in "$app" "$app/Contents/Applications/RimeLingo Settings.app" "$app/Contents/Helpers/rimelingo"; do
    [[ -e "$code" ]] || die "missing from the bundle: ${code#"$app"/}"
    codesign --verify --deep --strict --test-requirement="=$REQUIREMENT" "$code" \
      || die "not signed with a Developer ID Application certificate of team $TEAM: $code"
    details="$(codesign --display --verbose=2 "$code" 2>&1)"
    grep -q '^Signature=adhoc' <<<"$details" && die "ad-hoc signature: $code"
    grep -Eq 'flags=0x[0-9a-f]+\(.*runtime.*\)' <<<"$details" || die "hardened runtime is off: $code"
    grep -q "^TeamIdentifier=$TEAM\$" <<<"$details" || die "wrong team: $code"
    grep -q '^Timestamp=' <<<"$details" || die "no secure timestamp: $code"
  done
  [[ "$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" == "$VERSION" ]] || die "bundle version is not $VERSION"
  [[ "$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")" == "$BUILD" ]] || die "bundle build is not $BUILD"
}

step "building RimeLingo $VERSION ($BUILD) at ${COMMIT:0:12}"
RIMELINGO_SIGN_IDENTITY="$IDENTITY" RIMELINGO_REQUIRE_TIMESTAMP=1 bash scripts/build-app.sh
[[ -z "$(git status --porcelain)" ]] || die "the build changed tracked files; commit them and start again"
verify_app "$APP"

cat <<EOF

Sending to Apple for notarization:
  version   $VERSION (build $BUILD), commit $COMMIT
  signed as $IDENTITY_LINE
  files     a zip of $APP,
            then a disk image of the notarized app (a second submission)
  profile   $NOTARY_PROFILE
Nothing is published by this step. Once both are accepted:
  repository  https://github.com/$REPO (public)
  tag         $TAG
  assets      RimeLingo-$VERSION.zip, latest.json, latest.json.sig, RimeLingo-$VERSION.dmg
EOF

rm -rf "$OUT" && mkdir -p "$OUT"
WORK="$(mktemp -d -t rimelingo-release)"
# What publishing has done so far: empty, tagged, pushed, draft, published.
PUBLISH_STAGE=""
on_exit() {
  detach_dmg
  rm -rf "$WORK"
  case "$PUBLISH_STAGE" in ""|published) return ;; esac
  {
    echo
    echo "release: publishing stopped part-way (after: $PUBLISH_STAGE). Installed copies see nothing unless"
    echo "         'gh release view $TAG --repo $REPO' shows a published release. If it is published,"
    echo "         leave it and check its four assets by hand. Otherwise undo what was done and run"
    echo "         this script again (it builds and notarizes again):"
    if [[ "$PUBLISH_STAGE" == draft ]]; then
      echo "           gh release delete $TAG --repo $REPO --yes"
    fi
    if [[ "$PUBLISH_STAGE" == pushed || "$PUBLISH_STAGE" == draft ]]; then
      echo "           git push --delete origin $TAG"
    fi
    echo "           git tag -d $TAG"
  } >&2
}
trap on_exit EXIT

step "notarizing (this waits for Apple)"
ditto -c -k --keepParent "$APP" "$WORK/notarize.zip"
notarize "$WORK/notarize.zip"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

step "packing and checking the archive as an installed copy will see it"
ditto -c -k --keepParent "$APP" "$ZIP"
ditto -x -k "$ZIP" "$WORK/extracted"
[[ "$(ls -A "$WORK/extracted")" == "RimeLingo.app" ]] || die "the archive holds more than RimeLingo.app"
verify_app "$WORK/extracted/RimeLingo.app"
xcrun stapler validate "$WORK/extracted/RimeLingo.app"
spctl --assess --type execute "$WORK/extracted/RimeLingo.app" || die "Gatekeeper rejects the archived app"

# Built from the stapled app, so the copy inside opens without asking Apple. The image
# carries its own signature and ticket: Gatekeeper judges it before anything inside.
step "building, signing and notarizing the disk image (this waits for Apple again)"
build_dmg "$APP" "$DMG" "$WORK"
sign_dmg "$DMG"
notarize "$DMG"
staple_dmg "$DMG"
step "checking the disk image as a new user will open it"
check_dmg "$DMG" "$WORK/mount"

step "writing and signing the manifest"
python3 scripts/write-release-manifest.py "$ZIP" "$VERSION" "$BUILD" "$MIN_MACOS" "$OUT"
swift scripts/sign-manifest.swift sign ${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"} "$OUT/latest.json"
swift scripts/sign-manifest.swift verify "$OUT/latest.json" "$SIGNING_KEY"

NOTES="$WORK/notes.md"
SECTION="$(awk -v v="$VERSION" '
  index($0, "## [" v "]") == 1 { on = 1; next }
  on && /^## / { exit }
  on && /^\[[^]]+\]: / { next }
  on { print }' CHANGELOG.md 2>/dev/null || true)"
{
  if [[ -n "${SECTION//[[:space:]]/}" ]]; then printf '%s\n\n' "$SECTION"; fi
  cat <<EOF
## 安装与更新

已安装的正式版会在一天内自动更新到此版本，无需任何操作。

首次安装：下载 \`RimeLingo-$VERSION.dmg\`，打开后双击里面的「灵译输入法」（系统的首选语言里有英文、且简体中文没有排在它前面时显示为 RimeLingo），点「安装」。不需要管理员密码，也不用注销。

\`RimeLingo-$VERSION.zip\` 是已安装的版本自动更新时下载的文件，首次安装不需要它。

已使用 Developer ID 签名并通过 Apple 公证。最低系统：macOS $MIN_MACOS。

## SHA-256

\`\`\`
$(sha256 "$DMG")  RimeLingo-$VERSION.dmg
$(sha256 "$ZIP")  RimeLingo-$VERSION.zip
\`\`\`
EOF
} > "$NOTES"

cat <<EOF

Publishing — this cannot be taken back once installed copies have seen it:
  repository  https://github.com/$REPO (public)
  tag         $TAG -> $COMMIT (pushed to origin)
  release     "RimeLingo $VERSION", marked as latest
EOF
for file in "$ZIP" "$OUT/latest.json" "$OUT/latest.json.sig" "$DMG"; do
  printf '  %-22s %10s bytes  sha256 %s\n' "$(basename "$file")" "$(size "$file")" "$(sha256 "$file")"
done
echo "  manifest key $SIGNING_KEY ($SIGNING_KEY_NAME)"
echo "Every installed release build updates itself to $VERSION within about 24 hours."

# ---------------------------------------------------------------- publish

step "publishing"
git tag "$TAG" "$COMMIT"
PUBLISH_STAGE=tagged
git push origin "refs/tags/$TAG"
PUBLISH_STAGE=pushed
# A draft first: the four assets become visible together when the draft is published,
# so no client can fetch a new latest.json next to an old latest.json.sig.
gh release create "$TAG" --repo "$REPO" --draft --verify-tag --title "RimeLingo $VERSION" --notes-file "$NOTES" \
  "$ZIP" "$OUT/latest.json" "$OUT/latest.json.sig" "$DMG" || { PUBLISH_STAGE=draft; false; }
PUBLISH_STAGE=draft
gh release edit "$TAG" --repo "$REPO" --draft=false --latest
PUBLISH_STAGE=published

step "checking what clients receive (GET, as the updater does)"
BASE="https://github.com/$REPO/releases"
PROBLEM=0
for name in latest.json latest.json.sig; do
  # "latest" can keep answering with the previous release for a few seconds after the
  # new one is published, so a file that differs is fetched again before it counts.
  MATCHED=0
  for attempt in 1 2 3 4 5 6; do
    if curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors "$BASE/latest/download/$name" -o "$WORK/$name" \
       && cmp -s "$WORK/$name" "$OUT/$name"; then
      MATCHED=1
      break
    fi
    [[ "$attempt" == 6 ]] || sleep 5
  done
  if [[ "$MATCHED" == 1 ]]; then
    echo "    ok  $name"
  else
    echo "    MISMATCH  $BASE/latest/download/$name is not the file just published" >&2
    PROBLEM=1
  fi
done
# The disk image first, so that REMOTE_HEADERS is left describing the zip for the check
# of the hosts below.
for file in "$DMG" "$ZIP"; do
  name="$(basename "$file")"
  probe_download "$BASE/download/$TAG/$name"
  if [[ "$REMOTE_SIZE" == "$(size "$file")" ]]; then
    echo "    ok  $name ($REMOTE_SIZE bytes)"
  else
    echo "    MISMATCH  the published $name reports ${REMOTE_SIZE:-no} bytes, expected $(size "$file")" >&2
    PROBLEM=1
  fi
done
# The updater follows redirects only to the hosts it knows.
for host in $(awk 'tolower($1) == "location:" || $1 == "effective-url:" { print $2 }' <<<"$REMOTE_HEADERS" | sed -E 's#^https?://([^/:]+).*#\1#' | sort -u); do
  case " $ALLOWED_HOSTS " in
    *" $host "*) ;;
    *) echo "    WARNING  the zip is served through $host, which UpdateConfiguration.allowedHosts does not allow:" >&2
       echo "             installed copies cannot download it. Add the host and publish a new release." >&2
       PROBLEM=1 ;;
  esac
done
[[ "$PROBLEM" == 0 ]] || die "published, but the checks above failed: look at https://github.com/$REPO/releases/tag/$TAG now"
step "released RimeLingo $VERSION: https://github.com/$REPO/releases/tag/$TAG"
