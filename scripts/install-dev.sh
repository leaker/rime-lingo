#!/usr/bin/env bash
# Builds RimeLingo and installs it for the current user into ~/Library/Input Methods,
# then registers and enables the input source. Development builds never update themselves.
#
# Users do not need this script: opening RimeLingo.app from anywhere else (the release's
# disk image, or build/Release after scripts/build-app.sh) shows a window that installs it
# and restarts the system's input method launcher by itself. That is also the way to try
# the installer window during development.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/Library/Input Methods"

bash "$ROOT/scripts/build-app.sh"

echo "==> installing to $DEST"
# Update the bundle in place. Deleting and recreating it makes macOS drop the input
# source from the menu until the next login.
# A reinstall only re-enables the input source; it must not change which one is selected.
MODE=--enable; [[ -d "$DEST/RimeLingo.app" ]] || MODE=--install
mkdir -p "$DEST/RimeLingo.app"
rsync -a --delete "$ROOT/build/Release/RimeLingo.app/" "$DEST/RimeLingo.app/"
# Make the installed copy the one LaunchServices resolves for the bundle id, so the
# system can start it on demand (see the note at the end of build-app.sh).
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$DEST/RimeLingo.app" >/dev/null 2>&1 || true
# A failure here must not stop the script: the running input method still has to be
# restarted below. It is reported at the end and decides the exit code.
ENABLE_STATUS=0
"$DEST/RimeLingo.app/Contents/MacOS/RimeLingo" "$MODE" || ENABLE_STATUS=$?
# Restart the running input method only now that the new files are in place, and bring
# it straight back: applications with an open text field must not be left without one.
RUNNING="Input Methods/RimeLingo.app/Contents/MacOS/RimeLingo"
if pkill -f "$RUNNING" 2>/dev/null; then
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$RUNNING" >/dev/null || break; /bin/sleep 0.1; done
fi
pgrep -f "$RUNNING" >/dev/null || open -g "$DEST/RimeLingo.app"
# A system-wide copy (/Library) has the same bundle id: macOS may launch either one and
# keeps showing cached icons. Exactly one copy should exist.
if [[ -d "/Library/Input Methods/RimeLingo.app" ]]; then
  echo "warning: /Library/Input Methods/RimeLingo.app also exists." >&2
  echo "         Two copies share one bundle id; remove one, e.g.:" >&2
  echo "         sudo rm -rf '/Library/Input Methods/RimeLingo.app'" >&2
fi
echo "==> done. After the FIRST install the system's input method launcher, which has been"
echo "    running since login, cannot start RimeLingo on demand (LaunchInputMethod() status"
echo "    -50): typing does nothing and applications may misbehave. Do one of these once:"
echo "      killall imklaunchagent TextInputMenuAgent TextInputSwitcher"
echo "    or log out and back in. If RimeLingo is still missing from the input menu, remove"
echo "    and re-add it in System Settings › Keyboard › Input Sources."
echo "    CLI: \"$DEST/RimeLingo.app/Contents/Helpers/rimelingo\" doctor"
if [[ "$ENABLE_STATUS" -ne 0 ]]; then
  echo "error: the input source was installed but could not be enabled (see the lines above)." >&2
  echo "       Add it by hand in System Settings › Keyboard › Input Sources." >&2
  exit 1
fi
