#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_PNG="${1:-$ROOT_DIR/assets/logo.png}"
OUTPUT_ICNS="${2:-$ROOT_DIR/assets/AppIcon.icns}"

if [[ ! -f "$SOURCE_PNG" ]]; then
  echo "Icon source not found: $SOURCE_PNG" >&2
  exit 1
fi

ICONSET_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/whispr-iconset.XXXXXX")"
ICONSET_DIR="$ICONSET_ROOT/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"

cleanup() {
  rm -rf "$ICONSET_ROOT"
}
trap cleanup EXIT

resize_icon() {
  local size="$1"
  local name="$2"
  sips -z "$size" "$size" "$SOURCE_PNG" --out "$ICONSET_DIR/$name" >/dev/null
}

resize_icon 16 icon_16x16.png
resize_icon 32 icon_16x16@2x.png
resize_icon 32 icon_32x32.png
resize_icon 64 icon_32x32@2x.png
resize_icon 128 icon_128x128.png
resize_icon 256 icon_128x128@2x.png
resize_icon 256 icon_256x256.png
resize_icon 512 icon_256x256@2x.png
resize_icon 512 icon_512x512.png
resize_icon 1024 icon_512x512@2x.png

mkdir -p "$(dirname "$OUTPUT_ICNS")"
iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT_ICNS"
echo "Generated icon: $OUTPUT_ICNS"
