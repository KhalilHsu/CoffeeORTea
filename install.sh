#!/bin/bash
set -euo pipefail

APP_NAME="KeepAwake"
APP_DIR="${APP_NAME}.app"
DEST_DIR="/Applications"

echo "Building ${APP_NAME}..."
./build.sh

echo "Installing ${APP_NAME} to ${DEST_DIR}..."
# Remove existing app if any
if [ -d "${DEST_DIR}/${APP_DIR}" ]; then
    rm -rf "${DEST_DIR}/${APP_DIR}"
fi

# Copy the new app bundle
cp -R "${APP_DIR}" "${DEST_DIR}/"

echo "Installation complete."
echo "You can launch the app from Launchpad or run:"
echo "open ${DEST_DIR}/${APP_DIR}"
