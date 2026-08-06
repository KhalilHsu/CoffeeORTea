#!/bin/bash
set -e

# Configuration
APP_NAME="KeepAwake"
APP_DIR="${APP_NAME}.app"

echo "=== Building ${APP_NAME} macOS native app ==="

# 1. Clean previous build
if [ -d "$APP_DIR" ]; then
    echo "Cleaning previous build..."
    rm -rf "$APP_DIR"
fi

# 2. Create the App bundle structure
echo "Creating application bundle structure..."
mkdir -p "${APP_DIR}/Contents/MacOS"

# 3. Copy Plist configuration
echo "Copying Info.plist..."
if [ -f "Info.plist" ]; then
    cp Info.plist "${APP_DIR}/Contents/Info.plist"
else
    echo "Error: Info.plist not found!"
    exit 1
fi

# 4. Compile Swift code
echo "Compiling main.swift with swiftc..."
if [ -f "main.swift" ]; then
    swiftc -O main.swift -o "${APP_DIR}/Contents/MacOS/${APP_NAME}"
else
    echo "Error: main.swift not found!"
    exit 1
fi

echo "=== Build Successful! ==="
echo "Application built at: $(pwd)/${APP_DIR}"
echo ""
echo "To run the app in the background, you can double-click it in Finder or run:"
echo "  open ${APP_DIR}"
echo ""
echo "To test execution in terminal (logs will print to screen):"
echo "  ./${APP_DIR}/Contents/MacOS/${APP_NAME}"
echo ""
