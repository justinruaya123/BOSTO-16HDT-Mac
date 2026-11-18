#!/bin/bash
set -euo pipefail
# Arguments: isolated scratch directory, final .icns path. Nothing else is packaged.
SOURCE="$(cd "$(dirname "$0")" && pwd)"
SCRATCH="$1"
OUTPUT="$2"
mkdir -p "$SCRATCH"
rm -rf "$SCRATCH/BostoTablet.iconset"
mkdir -p "$SCRATCH/BostoTablet.iconset"
xcrun clang -fobjc-arc -Wall -Wextra -Werror "$SOURCE/GenerateIcon.m" -framework Foundation -framework CoreGraphics -framework ImageIO -o "$SCRATCH/generate-icon"
"$SCRATCH/generate-icon" "$SCRATCH/BostoTablet.iconset"
/usr/bin/iconutil -c icns "$SCRATCH/BostoTablet.iconset" -o "$OUTPUT"
