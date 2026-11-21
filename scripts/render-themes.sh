#!/usr/bin/env bash
# Renders the built-in themes with the real candidate panel (ThemeRenderProbe), horizontal
# and vertical, for the website: <out>/<id>-linear.png and <id>-stacked.png (@2x).
#   bash scripts/render-themes.sh [<out-dir>]     default: ../rimelingo-web/public/themes/renders
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/../rimelingo-web/public/themes/renders}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
SCHEMES="$(python3 -c 'import json,sys; print(",".join(t["id"] for t in json.load(open(sys.argv[1]))))' \
  "$ROOT/Packages/RimeLingoKit/Tests/RimeLingoCoreTests/Fixtures/theme-v1/valid.json" | tr ',' '\n' | grep -v -e sakura_test -e low_contrast | paste -sd, -)"
RIMELINGO_RENDER_FRONTEND="$ROOT/SharedSupport/rimelingo.yaml" RIMELINGO_RENDER_OUT="$OUT" RIMELINGO_RENDER_PREEDIT=1 RIMELINGO_RENDER_SCHEMES="$SCHEMES" \
  swift test --package-path "$ROOT/Packages/RimeLingoKit" --filter ThemeRenderProbe >/dev/null
echo "rendered images: $(find "$OUT" -name "*.png" | wc -l | tr -d " ")"
