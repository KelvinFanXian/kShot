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

KSHOT_SIGNING_IDENTITY="${KSHOT_SIGNING_IDENTITY:-}"
if [[ -z "$KSHOT_SIGNING_IDENTITY" ]]; then
    KSHOT_SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' \
        | head -n 1)"
fi
if [[ -z "$KSHOT_SIGNING_IDENTITY" ]]; then
    KSHOT_SIGNING_IDENTITY="-"
fi

codesign --force --deep --sign "$KSHOT_SIGNING_IDENTITY" "$APP_DIR"
echo "签名：$KSHOT_SIGNING_IDENTITY"
echo "$APP_DIR"
