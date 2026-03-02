#!/bin/bash
set -euo pipefail

APP_NAME="ClaudeUsageBar"
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"

echo "Building ${APP_NAME}..."

# Clean previous build
rm -rf "${APP_BUNDLE}"

# Compile
swiftc \
    -o "${BUILD_DIR}/${APP_NAME}" \
    -parse-as-library \
    "${BUILD_DIR}/${APP_NAME}.swift" \
    -framework SwiftUI \
    -framework AppKit

# Create .app bundle structure
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
mv "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# Create Info.plist (LSUIElement hides dock icon)
cat > "${APP_BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.${APP_NAME}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
</dict>
</plist>
PLIST

echo "Built ${APP_BUNDLE}"
echo "Run with: open ${APP_BUNDLE}"
