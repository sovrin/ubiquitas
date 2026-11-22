#!/bin/sh
# Builds ubiquitas.app (menu bar only, no Dock icon) next to this script, via the Xcode project.
# Not SwiftPM: a package build stamps the binary with SDK = deployment target,
# which makes macOS 26+ draw the old look (square menu bar panel).
set -e
cd "$(dirname "$0")"
xcodebuild -project ubiquitas.xcodeproj -scheme ubiquitas -configuration Release \
  -destination 'platform=macOS' -derivedDataPath .build/xcode -quiet build
rm -rf ubiquitas.app
cp -R .build/xcode/Build/Products/Release/ubiquitas.app .
echo "Built $(pwd)/ubiquitas.app"
