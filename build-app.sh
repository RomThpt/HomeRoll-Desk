#!/bin/bash
# Build the reviewed local fork. No download, deployment or recursive cleanup.
set -euo pipefail
cd "$(dirname "$0")"
xcodegen generate
xcodebuild -project HomeRollDesktop.xcodeproj -scheme HomeRollDesktop -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build-app -disableAutomaticPackageResolution \
  CODE_SIGN_IDENTITY="${HOMEROLL_SIGNING_IDENTITY:--}" build
APP="build-app/Build/Products/Release/HomeRoll Desktop Local.app"
[ -d "$APP" ] || { echo "Application missing"; exit 1; }
codesign --verify --deep --strict "$APP"
V=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
ditto -c -k --keepParent "$APP" "build-app/HomeRoll-Desktop-Local-$V.zip"
