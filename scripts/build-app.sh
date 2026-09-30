#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"
mkdir -p "$ROOT_DIR/.build/module-cache"
SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.build/module-cache" \
CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/module-cache" \
swift build -c release --disable-sandbox -debug-info-format none

APP_DIR="$ROOT_DIR/.build/app/KShot.app"
CONTENTS_DIR="$APP_DIR/Contents"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$ROOT_DIR/.build/release/KShot" "$CONTENTS_DIR/MacOS/KShot"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
codesign --force --deep --sign - "$APP_DIR"
echo "$APP_DIR"
