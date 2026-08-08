#!/bin/bash
set -euo pipefail

# Configuration
APP_NAME="KeepAwake"
APP_DIR="${APP_NAME}.app"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
MODULE_CACHE_DIR="build_cache/modules"
ARM64_BINARY="build_cache/${APP_NAME}-arm64"
X86_64_BINARY="build_cache/${APP_NAME}-x86_64"

echo "=== Building ${APP_NAME} macOS native app ==="

for required_command in swiftc lipo codesign plutil; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        echo "Error: ${required_command} is required to build ${APP_NAME}.app."
        exit 1
    fi
done

if ! plutil -lint Info.plist >/dev/null; then
    echo "Error: Info.plist is invalid."
    exit 1
fi

# 1. Clean previous build
if [ -d "$APP_DIR" ]; then
    echo "Cleaning previous build..."
    rm -rf "$APP_DIR"
fi

# 2. Create the App bundle structure
echo "Creating application bundle structure..."
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources" "${MODULE_CACHE_DIR}"

# 3. Copy Plist configuration
echo "Copying Info.plist..."
if [ -f "Info.plist" ]; then
    cp Info.plist "${APP_DIR}/Contents/Info.plist"
else
    echo "Error: Info.plist not found!"
    exit 1
fi

if [ -f "assets/AppIcon.icns" ]; then
    echo "Copying AppIcon.icns..."
    cp assets/AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"
else
    echo "Error: AppIcon.icns not found."
    exit 1
fi

# 4. Compile Swift code
echo "Compiling main.swift with swiftc..."
if [ -f "main.swift" ]; then
    swiftc -O \
        -target "arm64-apple-macosx${DEPLOYMENT_TARGET}" \
        -module-cache-path "${MODULE_CACHE_DIR}/arm64" \
        main.swift -framework IOKit -o "${ARM64_BINARY}"
    swiftc -O \
        -target "x86_64-apple-macosx${DEPLOYMENT_TARGET}" \
        -module-cache-path "${MODULE_CACHE_DIR}/x86_64" \
        main.swift -framework IOKit -o "${X86_64_BINARY}"

    lipo -create "${ARM64_BINARY}" "${X86_64_BINARY}" \
        -output "${APP_DIR}/Contents/MacOS/${APP_NAME}"
    echo "Built universal arm64 + x86_64 binary."
else
    echo "Error: main.swift not found!"
    exit 1
fi

# 5. Apply an ad-hoc signature for local execution. Set CODESIGN_IDENTITY to
# use a Developer ID or Mac Development certificate for distribution builds.
if command -v xattr >/dev/null 2>&1; then
    # Finder provenance/resource-fork metadata can make codesign reject a
    # locally copied bundle, especially when assets came from Downloads/AirDrop.
    xattr -cr "${APP_DIR}"
fi

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    # Distribution builds use the hardened runtime and a trusted timestamp.
    codesign --force --deep --options runtime --timestamp \
        --sign "${CODESIGN_IDENTITY}" "${APP_DIR}"
else
    # Ad-hoc signing keeps source builds runnable without a local certificate.
    codesign --force --deep --sign - "${APP_DIR}"
fi

# codesign may recreate Finder metadata on the outer .app directory. Remove it
# after signing as well so a strict verification works on a local checkout.
if command -v xattr >/dev/null 2>&1; then
    xattr -cr "${APP_DIR}"
    # Finder/File Provider can reattach these outer-bundle attributes while
    # codesign is finishing. Remove the known verification blockers explicitly.
    xattr -d com.apple.FinderInfo "${APP_DIR}" 2>/dev/null || true
    xattr -d 'com.apple.fileprovider.fpfs#P' "${APP_DIR}" 2>/dev/null || true
fi

codesign --verify --deep --strict "${APP_DIR}"

echo "=== Build Successful! ==="
echo "Application built at: $(pwd)/${APP_DIR}"
echo ""
echo "To run the app in the background, you can double-click it in Finder or run:"
echo "  open ${APP_DIR}"
echo ""
echo "To test execution in terminal (logs will print to screen):"
echo "  ./${APP_DIR}/Contents/MacOS/${APP_NAME}"
echo ""
