#!/bin/bash
set -euo pipefail

# Usage: ./scripts/build.sh [build|dmg|clean]
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="Mic Relay"
APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
DMG_PATH="$PROJECT_DIR/$APP_NAME.dmg"
LOG_FILE="$BUILD_DIR/logs/xcodebuild.log"
ACTION="${1:-build}"

case "$ACTION" in
    clean)
        rm -rf "$BUILD_DIR"
        rm -f "$DMG_PATH"
        exit 0
        ;;
    build|dmg) ;;
    *)
        echo "Usage: $0 [build|dmg|clean]" >&2
        exit 1
        ;;
esac

cd "$PROJECT_DIR"
xcodegen generate
mkdir -p "$BUILD_DIR/logs" "$BUILD_DIR/ModuleCache"
echo "Building $APP_NAME (Release)..."
if ! env CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache" \
    xcodebuild -project MicRelay.xcodeproj \
    -scheme MicRelay \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    -destination "platform=macOS" \
    build > "$LOG_FILE" 2>&1; then
    grep -E "error:|warning:" "$LOG_FILE" || tail -20 "$LOG_FILE"
    echo "Build failed. Full log: $LOG_FILE" >&2
    echo "For a missing local signing certificate, run ./scripts/setup-signing.sh once." >&2
    exit 1
fi

grep -E "BUILD|warning:" "$LOG_FILE" || true
codesign --verify --strict "$APP_PATH"
echo "Built: $APP_PATH"

if [ "$ACTION" = dmg ]; then
    STAGING_DIR="$(mktemp -d "$BUILD_DIR/dmg.XXXXXX")"
    trap 'rm -rf "$STAGING_DIR"' EXIT
    ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
    ln -s /Applications "$STAGING_DIR/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" \
        -format UDZO -ov "$DMG_PATH"
    echo "DMG: $DMG_PATH"
fi
