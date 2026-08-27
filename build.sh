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

for required_command in swiftc lipo codesign plutil ditto; do
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

if [ -f "assets/Assets.car" ]; then
    echo "Copying compiled AppIcon asset catalog..."
    cp assets/Assets.car "${APP_DIR}/Contents/Resources/Assets.car"
else
    echo "Error: Assets.car not found."
    exit 1
fi

# 4. Compile Swift code
echo "Compiling main.swift with swiftc..."
if [ -f "main.swift" ]; then
    swiftc -O \
        -target "arm64-apple-macosx${DEPLOYMENT_TARGET}" \
        -module-cache-path "${MODULE_CACHE_DIR}/arm64" \
        KeyboardPermissionFlow.swift main.swift -framework IOKit -o "${ARM64_BINARY}"
    swiftc -O \
        -target "x86_64-apple-macosx${DEPLOYMENT_TARGET}" \
        -module-cache-path "${MODULE_CACHE_DIR}/x86_64" \
        KeyboardPermissionFlow.swift main.swift -framework IOKit -o "${X86_64_BINARY}"

    lipo -create "${ARM64_BINARY}" "${X86_64_BINARY}" \
        -output "${APP_DIR}/Contents/MacOS/${APP_NAME}"
    echo "Built universal arm64 + x86_64 binary."
else
    echo "Error: main.swift not found!"
    exit 1
fi

# 5. Sign an isolated copy. Desktop, iCloud, and File Provider locations can
# reattach Finder metadata while codesign is reading the bundle.
SIGNING_ROOT=$(mktemp -d "/private/tmp/${APP_NAME}-sign.XXXXXX")
SIGNING_APP="${SIGNING_ROOT}/${APP_DIR}"
trap 'rm -rf "${SIGNING_ROOT}"' EXIT
ditto --norsrc "${APP_DIR}" "${SIGNING_APP}"
xattr -cr "${SIGNING_APP}"

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    # Distribution builds use the hardened runtime and a trusted timestamp.
    codesign --force --deep --options runtime --timestamp \
        --sign "${CODESIGN_IDENTITY}" "${SIGNING_APP}"
else
    # Give local ad-hoc builds a stable designated requirement. Without this,
    # each rebuild is identified only by a new CDHash and macOS TCC permissions
    # appear enabled for the old binary while being unavailable to the new one.
    AD_HOC_REQUIREMENT='=designated => identifier "com.khalil.keepawake"'
    codesign --force --deep --sign - \
        --requirements "${AD_HOC_REQUIREMENT}" "${SIGNING_APP}"
fi

# Copy the signed bundle back without resource forks, then verify the exact
# artifact that install.sh will place in /Applications.
codesign --verify --deep --strict "${SIGNING_APP}"
rm -rf "${APP_DIR}"
ditto --norsrc "${SIGNING_APP}" "${APP_DIR}"
xattr -cr "${APP_DIR}"
rm -rf "${SIGNING_ROOT}"
trap - EXIT

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
