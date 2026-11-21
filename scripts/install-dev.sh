#!/usr/bin/env bash
# Builds RimeLingo and installs it for the current user into ~/Library/Input Methods,
# then registers and enables the input source. For a system-wide install use the
# package from scripts/package.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/Library/Input Methods"

bash "$ROOT/scripts/build-app.sh"

echo "==> installing to $DEST"
pkill -f "Input Methods/RimeLingo.app/Contents/MacOS/RimeLingo" 2>/dev/null || true
mkdir -p "$DEST"
rm -rf "$DEST/RimeLingo.app"
ditto "$ROOT/build/Release/RimeLingo.app" "$DEST/RimeLingo.app"
"$DEST/RimeLingo.app/Contents/MacOS/RimeLingo" --install || true
# A copy installed by the .pkg (/Library) has the same bundle id: macOS may launch
# either one and keeps showing cached icons. Development wants exactly one.
if [[ -d "/Library/Input Methods/RimeLingo.app" ]]; then
  echo "warning: /Library/Input Methods/RimeLingo.app (installed by the .pkg) also exists." >&2
  echo "         Two copies share one bundle id; remove one, e.g.:" >&2
  echo "         sudo rm -rf '/Library/Input Methods/RimeLingo.app' '/Applications/RimeLingo Settings.app'" >&2
fi
echo "note: installing an RimeLingo .pkg later moves this per-user copy to the Trash (#32)." >&2
echo "==> done. If RimeLingo is not selectable yet, add it in System Settings › Keyboard ›"
echo "    Input Sources (log out and back in once after the first install)."
echo "    CLI: \"$DEST/RimeLingo.app/Contents/Helpers/rimelingo\" doctor"
