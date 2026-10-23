#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
set -eu
cd "$(dirname "$0")/.."
exec /usr/bin/xcodebuild -quiet -project NoctDesktop.xcodeproj -scheme NoctDesktop \
  -configuration "${CONFIGURATION:-Debug}" -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/Xcode -jobs 2 "$@" build
