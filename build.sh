#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="TempMonitor"
BUNDLE_DIR="build/${APP_NAME}.app"
DMG_NAME="${APP_NAME}.dmg"
BUILD_DIR="build"

echo "=== TempMonitor Build ==="

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"

# Step 1: Compile
echo "[1/4] Compiling..."
swiftc -O \
    -framework IOKit \
    -framework Cocoa \
    TempMonitor.swift \
    -o "${BUNDLE_DIR}/Contents/MacOS/${APP_NAME}"

echo "      Binary size: $(du -h "${BUNDLE_DIR}/Contents/MacOS/${APP_NAME}" | cut -f1)"

# Step 2: Copy Info.plist
echo "[2/4] Creating app bundle..."
cp Info.plist "${BUNDLE_DIR}/Contents/Info.plist"

# Step 3: Code sign (ad-hoc)
echo "[3/4] Code signing..."
codesign --force --sign - "${BUNDLE_DIR}"

# Verify signature
codesign --verify --verbose "${BUNDLE_DIR}" 2>&1 | head -1

# Step 4: Create DMG
echo "[4/4] Creating DMG..."
rm -f "${BUILD_DIR}/${DMG_NAME}"
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${BUNDLE_DIR}" \
    -ov \
    -format UDZO \
    "${BUILD_DIR}/${DMG_NAME}" \
    -quiet

echo ""
echo "=== Build Complete ==="
echo "App bundle: ${BUNDLE_DIR}"
echo "DMG: ${BUILD_DIR}/${DMG_NAME}"
echo "DMG size: $(du -h "${BUILD_DIR}/${DMG_NAME}" | cut -f1)"
