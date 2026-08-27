#!/bin/bash
set -euo pipefail

APP_NAME="KeepAwake"
APP_DIR="${APP_NAME}.app"
DEST_DIR="/Applications"

echo "Building ${APP_NAME}..."
./build.sh

STAGING_ROOT=$(mktemp -d "/private/tmp/${APP_NAME}-install.XXXXXX")
STAGING_APP="${STAGING_ROOT}/${APP_DIR}"
trap 'rm -rf "${STAGING_ROOT}"' EXIT
ditto --norsrc "${APP_DIR}" "${STAGING_APP}"
xattr -cr "${STAGING_APP}"
codesign --verify --deep --strict "${STAGING_APP}"

echo "Installing ${APP_NAME} to ${DEST_DIR}..."
pkill -x "${APP_NAME}" 2>/dev/null || true
if [ -d "${DEST_DIR}/${APP_DIR}" ]; then
    rm -rf "${DEST_DIR}/${APP_DIR}"
fi

ditto --norsrc "${STAGING_APP}" "${DEST_DIR}/${APP_DIR}"
xattr -cr "${DEST_DIR}/${APP_DIR}"
codesign --verify --deep --strict "${DEST_DIR}/${APP_DIR}"

rm -rf "${STAGING_ROOT}"
trap - EXIT

echo "Installation complete."
echo "You can launch the app from Launchpad or run:"
echo "open ${DEST_DIR}/${APP_DIR}"
