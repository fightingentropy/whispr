#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${APP_NAME:-Whispr}"
BUNDLE_ID="${BUNDLE_ID:-com.erlinhoxha.whispr}"
VERSION="${VERSION:-0.1.7}"
VOL_NAME="${VOL_NAME:-Whispr}"
BUILD_CONFIG="${BUILD_CONFIG:-release}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/dist}"
LOGO_PATH="${LOGO_PATH:-$ROOT_DIR/assets/logo.png}"
ICON_PATH="${ICON_PATH:-$ROOT_DIR/assets/AppIcon.icns}"
MODEL_SOURCE_DIR="${MODEL_SOURCE_DIR:-$ROOT_DIR/models}"
BUNDLE_MODELS="${BUNDLE_MODELS:-1}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
CODESIGN_REQUIREMENTS="${CODESIGN_REQUIREMENTS:-}"

mkdir -p "$OUT_DIR"

"$ROOT_DIR/scripts/generate-icon.sh" "$LOGO_PATH" "$ICON_PATH"

pushd "$ROOT_DIR" >/dev/null
swift build -c "$BUILD_CONFIG"
popd >/dev/null

BINARY_PATH="$ROOT_DIR/.build/$BUILD_CONFIG/$APP_NAME"
if [[ ! -x "$BINARY_PATH" ]]; then
  echo "Built binary not found: $BINARY_PATH" >&2
  exit 1
fi

APP_BUNDLE="$OUT_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BINARY_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"
cp "$ICON_PATH" "$RESOURCES_DIR/AppIcon.icns"

if [[ "$BUNDLE_MODELS" == "1" && -d "$MODEL_SOURCE_DIR" ]]; then
  mkdir -p "$RESOURCES_DIR/models"
  rsync -a --exclude '_archived/' "$MODEL_SOURCE_DIR"/ "$RESOURCES_DIR/models/"
  echo "Bundled models from: $MODEL_SOURCE_DIR"
fi

WHISPER_CPP_CANDIDATES=(
  "$ROOT_DIR/whisper.cpp/build/bin/whisper-cli"
  "$ROOT_DIR/whisper-cli"
  "/opt/homebrew/bin/whisper-cli"
  "/usr/local/bin/whisper-cli"
)

COPIED_WHISPER_RUNTIME=0
for candidate in "${WHISPER_CPP_CANDIDATES[@]}"; do
  if [[ -x "$candidate" ]]; then
    cp "$candidate" "$MACOS_DIR/whisper-cli"
    chmod +x "$MACOS_DIR/whisper-cli"

    if [[ "$candidate" == "$ROOT_DIR/whisper.cpp/build/bin/whisper-cli" ]]; then
      WHISPER_BUILD_DIR="$ROOT_DIR/whisper.cpp/build"
      cp -a "$WHISPER_BUILD_DIR/src"/libwhisper*.dylib "$MACOS_DIR/" 2>/dev/null || true
      cp -a "$WHISPER_BUILD_DIR/ggml/src"/libggml*.dylib "$MACOS_DIR/" 2>/dev/null || true
      cp -a "$WHISPER_BUILD_DIR/ggml/src/ggml-blas"/libggml-blas*.dylib "$MACOS_DIR/" 2>/dev/null || true
      cp -a "$WHISPER_BUILD_DIR/ggml/src/ggml-metal"/libggml-metal*.dylib "$MACOS_DIR/" 2>/dev/null || true

      install_name_tool -add_rpath @executable_path "$MACOS_DIR/whisper-cli" 2>/dev/null || true
    fi

    COPIED_WHISPER_RUNTIME=1
    echo "Bundled whisper-cli: $candidate"
    break
  fi
done

if [[ "$COPIED_WHISPER_RUNTIME" -eq 0 ]]; then
  echo "Warning: whisper-cli not bundled. Set one of: ${WHISPER_CPP_CANDIDATES[*]}" >&2
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Whispr uses the microphone to capture your voice for transcription.</string>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  # Preserve nested runtime signatures first; then sign the app bundle itself.
  while IFS= read -r -d '' nested_binary; do
    codesign --force --sign "$CODESIGN_IDENTITY" "$nested_binary" >/dev/null
  done < <(find "$MACOS_DIR" -type f ! -name "$APP_NAME" -print0)

  # For ad-hoc signing, use a stable designated requirement to reduce TCC churn
  # (Accessibility entries) between app updates.
  if [[ "$CODESIGN_IDENTITY" == "-" && -z "$CODESIGN_REQUIREMENTS" ]]; then
    CODESIGN_REQUIREMENTS="designated => identifier \"$BUNDLE_ID\""
  fi

  if [[ -n "$CODESIGN_REQUIREMENTS" ]]; then
    codesign --force --sign "$CODESIGN_IDENTITY" --requirements "=$CODESIGN_REQUIREMENTS" "$APP_BUNDLE" >/dev/null
  else
    codesign --force --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE" >/dev/null
  fi

  codesign --verify --deep --strict "$APP_BUNDLE" >/dev/null
  echo "Signed app bundle with identity: $CODESIGN_IDENTITY"
else
  echo "Warning: codesign not found; app will be unsigned." >&2
fi

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/whispr-dmg-stage.XXXXXX")"
cleanup() {
  rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

cp -R "$APP_BUNDLE" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

DMG_PATH="$OUT_DIR/$APP_NAME.dmg"
rm -f "$DMG_PATH"
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG_PATH" >/dev/null

echo "App bundle: $APP_BUNDLE"
echo "DMG: $DMG_PATH"
