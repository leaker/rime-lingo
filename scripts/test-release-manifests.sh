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

# The backup key: its own file, same rules, and a signature that only its public key accepts.
BACKUP=(--backup --ephemeral-key-file "$WORK/backup-key")
BACKUP_PUBLIC_KEY="$("${SIGN[@]}" keygen "${BACKUP[@]}")"
[[ "$BACKUP_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || fail "keygen --backup must print the public key and nothing else"
[[ "$BACKUP_PUBLIC_KEY" != "$PUBLIC_KEY" ]] || fail "the backup key is the everyday key"
! grep -qF "$(cat "$WORK/backup-key")" <<<"$BACKUP_PUBLIC_KEY" || fail "keygen --backup printed the private key"
[[ "$("${SIGN[@]}" pubkey "${BACKUP[@]}")" == "$BACKUP_PUBLIC_KEY" ]] || fail "pubkey --backup differs from keygen --backup"
[[ "$("${SIGN[@]}" pubkey "${KEY[@]}")" == "$PUBLIC_KEY" ]] || fail "keygen --backup changed the everyday key"
BACKUP_PRIVATE="$(cat "$WORK/backup-key")"
if "${SIGN[@]}" keygen "${BACKUP[@]}" > "$WORK/backup-second.log" 2>&1; then fail "keygen --backup replaced an existing key"; fi
[[ "$(cat "$WORK/backup-key")" == "$BACKUP_PRIVATE" ]] || fail "a refused keygen --backup rewrote the key"
"${SIGN[@]}" sign --backup "$WORK/latest.json" --ephemeral-key-file "$WORK/backup-key" > "$WORK/backup-sign.log"
! grep -qF "$BACKUP_PRIVATE" "$WORK/backup-sign.log" || fail "sign --backup printed the private key"
"${SIGN[@]}" verify "$WORK/latest.json" "$BACKUP_PUBLIC_KEY" >/dev/null
if "${SIGN[@]}" verify "$WORK/latest.json" "$PUBLIC_KEY" > "$WORK/backup-everyday.log" 2>&1; then
  fail "the everyday key accepted a signature made with the backup key"
fi
"${SIGN[@]}" sign "$WORK/latest.json" "${KEY[@]}" >/dev/null
if "${SIGN[@]}" verify "$WORK/latest.json" "$BACKUP_PUBLIC_KEY" > "$WORK/everyday-backup.log" 2>&1; then
  fail "the backup key accepted a signature made with the everyday key"
fi
if "${SIGN[@]}" pubkey --backup --ephemeral-key-file "$WORK/missing" > "$WORK/backup-missing.log" 2>&1; then
  fail "pubkey --backup without a key"
fi
if "${SIGN[@]}" verify --backup "$WORK/latest.json" "$PUBLIC_KEY" > "$WORK/backup-verify.log" 2>&1; then
  fail "verify took --backup"
fi

# Points of small order are not keys: under them a signature made without any private key
# verifies. The identity takes R = identity, S = 0 for every message.
cp "$WORK/latest.json.sig" "$WORK/real.sig"
python3 -c 'import base64; print(base64.b64encode(bytes([1] + [0] * 63)).decode())' > "$WORK/latest.json.sig"
for weak in AQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= AQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIA= \
            AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIA= \
            JuiVj8KyJ7BFw/SJ8u+Y8NXfrAXTxjM5sTgCiG1T/AU= JuiVj8KyJ7BFw/SJ8u+Y8NXfrAXTxjM5sTgCiG1T/IU= \
            xxdqcD1N2E+6PAt2DRBnDyogU/osOczGTsf9d5KsA3o= xxdqcD1N2E+6PAt2DRBnDyogU/osOczGTsf9d5KsA/o= \
            7P///////////////////////////////////////38= 7P////////////////////////////////////////8= \
            7f///////////////////////////////////////38= 7f////////////////////////////////////////8= \
            7v///////////////////////////////////////38= 7v////////////////////////////////////////8=; do
  if "${SIGN[@]}" verify "$WORK/latest.json" "$weak" > "$WORK/weak.log" 2>&1; then fail "small-order key accepted: $weak"; fi
  grep -q 'not a usable Ed25519 public key' "$WORK/weak.log" || fail "small-order key not named as the reason: $weak"
done
cp "$WORK/real.sig" "$WORK/latest.json.sig"
"${SIGN[@]}" verify "$WORK/latest.json" "$PUBLIC_KEY" >/dev/null

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
echo 'PASS: public-key-only keygen, manifest fields and checksum, signature, tampering, wrong key, missing key, backup key, small-order keys, refused input'
