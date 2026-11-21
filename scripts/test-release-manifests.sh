#!/usr/bin/env bash
# Checks manifest writing and signing with fixture files and a throw-away key in a
# temporary file. No Keychain, no network, nothing built or published.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d -t rimelingo-manifest-test)"
trap 'rm -rf "$WORK"' EXIT
umask 077
SIGN=(swift "$ROOT/scripts/sign-manifest.swift")
KEY=(--ephemeral-key-file "$WORK/key")
fail() { echo "FAIL: $*" >&2; exit 1; }

PUBLIC_KEY="$("${SIGN[@]}" keygen "${KEY[@]}")"
[[ "$PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || fail "keygen must print the public key and nothing else"
! grep -qF "$(cat "$WORK/key")" <<<"$PUBLIC_KEY" || fail "keygen printed the private key"
[[ "$("${SIGN[@]}" pubkey "${KEY[@]}")" == "$PUBLIC_KEY" ]] || fail "pubkey differs from keygen"
if "${SIGN[@]}" keygen "${KEY[@]}" > "$WORK/second.log" 2>&1; then fail "keygen replaced an existing key"; fi

printf 'fixture archive\n' > "$WORK/RimeLingo-0.3.0.zip"
python3 "$ROOT/scripts/write-release-manifest.py" "$WORK/RimeLingo-0.3.0.zip" 0.3.0 21 15.0 "$WORK"
"${SIGN[@]}" sign "$WORK/latest.json" "${KEY[@]}" >/dev/null
"${SIGN[@]}" verify "$WORK/latest.json" "$PUBLIC_KEY" >/dev/null
python3 - "$WORK" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
manifest = json.loads((root / "latest.json").read_text())
data = (root / "RimeLingo-0.3.0.zip").read_bytes()
assert manifest["product"] == "rimelingo" and manifest["version"] == "0.3.0" and manifest["build"] == 21
assert manifest["minimumSystemVersion"] == "15.0"
assert manifest["files"] == {"zip": {"name": "RimeLingo-0.3.0.zip", "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}}
assert set(manifest) == {"product", "version", "build", "date", "minimumSystemVersion", "files"}, set(manifest)
PY

# A changed manifest, another key and a missing key must all fail.
cp "$WORK/latest.json" "$WORK/original.json"
printf ' ' >> "$WORK/latest.json"
if "${SIGN[@]}" verify "$WORK/latest.json" "$PUBLIC_KEY" > "$WORK/tampered.log" 2>&1; then fail "tampered manifest accepted"; fi
cp "$WORK/original.json" "$WORK/latest.json"
OTHER="$("${SIGN[@]}" keygen --ephemeral-key-file "$WORK/other")"
if "${SIGN[@]}" verify "$WORK/latest.json" "$OTHER" > "$WORK/other.log" 2>&1; then fail "another key accepted"; fi
if "${SIGN[@]}" sign "$WORK/latest.json" --ephemeral-key-file "$WORK/missing" > "$WORK/missing.log" 2>&1; then
  fail "signed without a key"
fi

# Pre-release versions, wrong archive names and bad numbers are refused.
mkdir "$WORK/bad"
for arguments in "RimeLingo-0.3.0.zip 0.3.0-beta.1 21 15.0" "RimeLingo-0.3.0.zip 0.3.1 21 15.0" \
                 "RimeLingo-0.3.0.zip 0.3.0 0 15.0" "RimeLingo-0.3.0.zip 0.3.0 21 sequoia"; do
  read -r name version build minimum <<<"$arguments"
  if python3 "$ROOT/scripts/write-release-manifest.py" "$WORK/$name" "$version" "$build" "$minimum" "$WORK/bad" 2>/dev/null; then
    fail "accepted: $arguments"
  fi
  [[ ! -e "$WORK/bad/latest.json" ]] || fail "wrote a manifest for: $arguments"
done
echo 'PASS: public-key-only keygen, manifest fields and checksum, signature, tampering, wrong key, missing key, refused input'
