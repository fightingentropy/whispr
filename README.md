# Whispr (Native macOS Voice-to-Text)

Native menu bar dictation app scaffold with:
- Global push-to-talk hotkey (`Option + Space`).
- Live microphone capture.
- Local Parakeet transcription via `sherpa-onnx-offline`.
- Model auto-discovery and active model selection.
- Auto-paste into the focused app (Accessibility permission required).

## Project Layout
- App source: `Sources/Whispr`
- Plan: `mac-native-vtt-plan.md`

## Prerequisites
- macOS 14+
- Xcode 15+ / Swift 5.10+
- `curl`, `tar` (for downloading prebuilt `sherpa-onnx`)

## 1) Install sherpa-onnx runtime
Run:

```bash
cd /Users/erlinhoxha/Developer/whispr/tools
curl -L -o sherpa-onnx-v1.12.24-osx-universal2-shared-no-tts.tar.bz2 \
  https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.12.24/sherpa-onnx-v1.12.24-osx-universal2-shared-no-tts.tar.bz2
mkdir -p sherpa-onnx
tar -xjf sherpa-onnx-v1.12.24-osx-universal2-shared-no-tts.tar.bz2 -C sherpa-onnx --strip-components=1
```

This installs a local binary at:
- `/Users/erlinhoxha/Developer/whispr/tools/sherpa-onnx/bin/sherpa-onnx-offline`

The app auto-detects this path.

## 2) Run app
Terminal:

```bash
cd /Users/erlinhoxha/whispr
swift run
```

Or open the folder in Xcode/Cursor and run target `Whispr`.

## Build `.app` + `.dmg`
To package a distributable app bundle and installer disk image:

```bash
cd /Users/erlinhoxha/whispr
./scripts/build-dmg.sh
```

Outputs:
- `/Users/erlinhoxha/whispr/dist/Whispr.app`
- `/Users/erlinhoxha/whispr/dist/Whispr.dmg`

Icon source defaults to:
- `/Users/erlinhoxha/whispr/assets/logo.png`

The packaging script auto-generates `AppIcon.icns` and bundles `sherpa-onnx-offline` if found.
By default it also bundles files from `models/` into `Whispr.app/Contents/Resources/models`.

Options:

```bash
# Skip bundling models into the app
BUNDLE_MODELS=0 ./scripts/build-dmg.sh

# Bundle models from a custom folder
MODEL_SOURCE_DIR=/path/to/models ./scripts/build-dmg.sh
```

## 3) Permissions
In app Settings, grant:
- Microphone (capture audio)
- Accessibility (auto-paste transcript into focused input)

If you run via `swift run`, macOS may ask permissions for your host app (Terminal/Cursor) instead of a standalone `Whispr` app bundle.

## Model Discovery
The app scans:
- Current working directory
- `./models` (project models folder)
- `~/whispr`
- `~/Library/Application Support/Whispr/Models`

Supported model files:
- `.onnx`

## Notes
- The selected model path should point to `encoder.onnx` inside a Parakeet bundle directory containing:
  `tokens.txt`, `encoder.onnx`, `encoder.weights`, `decoder.onnx`, and `joiner.onnx`.
