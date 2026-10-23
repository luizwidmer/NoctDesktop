#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
set -eu
guest_source="${NOCTBSD_SOURCE:-$SRCROOT/../NoctBSD/overlay/opt/noct}"
test -f "$guest_source/native/desktop.cpp" || { echo 'NoctBSD sibling checkout is required.' >&2; exit 1; }
resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
helpers="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
mkdir -p "$resources/Guest" "$helpers"
/usr/bin/rsync -a --delete --exclude '*.py' --exclude '__pycache__' --exclude bin "$guest_source/" "$resources/Guest/"
/bin/cp "$SRCROOT/tools/gpu-helper.sb" "$resources/gpu-helper.sb"
/bin/cp "$BUILT_PRODUCTS_DIR/NoctGPUBroker" "$helpers/NoctGPUBroker"
/bin/cp "$SRCROOT/README.md" "$resources/README.md"
# The GPU and Homebrew QEMU dependencies remain an explicit development runtime.
# Do not put an absolute developer path into the application's Info.plist.
