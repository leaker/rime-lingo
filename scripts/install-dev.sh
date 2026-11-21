#!/usr/bin/env bash
# Builds RimeLingo and installs it for the current user into ~/Library/Input Methods,
# then registers and enables the input source. For a system-wide install use the
# package from scripts/package.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/Library/Input Methods"

bash "$ROOT/scripts/build-app.sh"

echo "==> installing to $DEST"
# Update the bundle in place. Deleting and recreating it makes macOS drop the input
# source from the menu until the next login.
mkdir -p "$DEST/RimeLingo.app"
rsync -a --delete "$ROOT/build/Release/RimeLingo.app/" "$DEST/RimeLingo.app/"
# Make the installed copy the one LaunchServices resolves for the bundle id, so the
# system can start it on demand (see the note at the end of build-app.sh).
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$DEST/RimeLingo.app" >/dev/null 2>&1 || true
"$DEST/RimeLingo.app/Contents/MacOS/RimeLingo" --install || true
# Restart the running input method only now that the new files are in place, and bring
# it straight back: applications with an open text field must not be left without one.
RUNNING="Input Methods/RimeLingo.app/Contents/MacOS/RimeLingo"
if pkill -f "$RUNNING" 2>/dev/null; then
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$RUNNING" >/dev/null || break; /bin/sleep 0.1; done
fi
pgrep -f "$RUNNING" >/dev/null || open -g "$DEST/RimeLingo.app"
# A copy installed by the .pkg (/Library) has the same bundle id: macOS may launch
# either one and keeps showing cached icons. Development wants exactly one.
if [[ -d "/Library/Input Methods/RimeLingo.app" ]]; then
  echo "warning: /Library/Input Methods/RimeLingo.app (installed by the .pkg) also exists." >&2
  echo "         Two copies share one bundle id; remove one, e.g.:" >&2
  echo "         sudo rm -rf '/Library/Input Methods/RimeLingo.app' '/Applications/RimeLingo Settings.app'" >&2
fi
echo "note: installing an RimeLingo .pkg later moves this per-user copy to the Trash (#32)." >&2
echo "==> done. After the FIRST install the system's input method launcher, which has been"
echo "    running since login, cannot start RimeLingo on demand (LaunchInputMethod() status"
echo "    -50): typing does nothing and applications may misbehave. Do one of these once:"
echo "      killall imklaunchagent TextInputMenuAgent TextInputSwitcher"
echo "    or log out and back in. If RimeLingo is still missing from the input menu, remove"
echo "    and re-add it in System Settings › Keyboard › Input Sources."
echo "    CLI: \"$DEST/RimeLingo.app/Contents/Helpers/rimelingo\" doctor"
