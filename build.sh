#!/bin/bash
# Build OrdCat.app (universal: Apple Silicon + Intel). Requires Xcode Command Line Tools on macOS.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"
rm -rf build && mkdir -p build
for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -target ${ARCH}-apple-macos13.0 Sources/main.swift -o build/OrdCat-${ARCH}
done
APP=build/OrdCat.app
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
lipo -create build/OrdCat-arm64 build/OrdCat-x86_64 -output $APP/Contents/MacOS/OrdCat
sed -e "s/__VERSION__/${VERSION}/" -e "s/__BUILD__/${BUILD}/" Resources/Info.plist > $APP/Contents/Info.plist
# App icon
ICONSET=build/AppIcon.iconset; mkdir -p $ICONSET
for S in 16 32 128 256 512; do
  sips -z $S $S Resources/icon_1024.png --out $ICONSET/icon_${S}x${S}.png >/dev/null
  D=$((S*2)); sips -z $D $D Resources/icon_1024.png --out $ICONSET/icon_${S}x${S}@2x.png >/dev/null
done
iconutil -c icns $ICONSET -o $APP/Contents/Resources/AppIcon.icns
codesign --force --deep --sign - $APP
ditto -c -k --keepParent $APP build/OrdCat-macOS.zip
echo "Built $APP"
