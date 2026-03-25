#!/bin/bash
set -e

# MacDJ build and package script
# Usage:
#   ./scripts/build.sh          — build only
#   ./scripts/build.sh dmg      — build + create .dmg
#   ./scripts/build.sh clean    — clean build artifacts

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="MacDJ"

cd "$PROJECT_DIR"

case "${1:-build}" in
    clean)
        echo "Cleaning build artifacts..."
        rm -rf "$BUILD_DIR"
        rm -f "$PROJECT_DIR/$APP_NAME.dmg"
        echo "Done."
        ;;

    build)
        echo "Building $APP_NAME (Release)..."
        xcodebuild -project "$APP_NAME.xcodeproj" \
            -scheme "$APP_NAME" \
            -configuration Release \
            -derivedDataPath "$BUILD_DIR" \
            -destination "platform=macOS" \
            build 2>&1 | grep -E "BUILD|error:" || true

        APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
        if [ -d "$APP_PATH" ]; then
            echo ""
            echo "Built: $APP_PATH"
            echo "Run:   open \"$APP_PATH\""
        else
            echo "Build failed."
            exit 1
        fi
        ;;

    dmg)
        # Build first
        "$0" build

        APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
        DMG_PATH="$PROJECT_DIR/$APP_NAME.dmg"

        # Ad-hoc sign
        echo ""
        echo "Signing (ad-hoc)..."
        codesign --force --deep --sign - "$APP_PATH"

        # Create DMG
        echo "Creating DMG..."
        rm -f "$DMG_PATH"

        if command -v create-dmg &> /dev/null; then
            create-dmg \
                --volname "$APP_NAME" \
                --window-size 600 400 \
                --icon-size 100 \
                --icon "$APP_NAME.app" 175 190 \
                --app-drop-link 425 190 \
                "$DMG_PATH" \
                "$APP_PATH" 2>&1 | tail -3
        else
            # Fallback: plain hdiutil
            echo "  (install create-dmg for a prettier DMG: brew install create-dmg)"
            TEMP_DMG=$(mktemp -t macdj).dmg
            hdiutil create -size 50m -fs HFS+ -volname "$APP_NAME" "$TEMP_DMG" > /dev/null
            MOUNT_DIR=$(hdiutil attach "$TEMP_DMG" | tail -1 | awk '{print $3}')
            cp -R "$APP_PATH" "$MOUNT_DIR/"
            ln -s /Applications "$MOUNT_DIR/Applications"
            hdiutil detach "$MOUNT_DIR" > /dev/null
            hdiutil convert "$TEMP_DMG" -format UDZO -o "$DMG_PATH" > /dev/null
            rm "$TEMP_DMG"
        fi

        echo ""
        echo "DMG: $DMG_PATH"
        echo ""
        echo "Share this file with friends. They should:"
        echo "  1. Open the DMG, drag MacDJ to Applications"
        echo "  2. Right-click MacDJ.app → Open (first launch only)"
        echo "  3. Install BlackHole 2ch if prompted"
        ;;

    *)
        echo "Usage: $0 [build|dmg|clean]"
        exit 1
        ;;
esac
