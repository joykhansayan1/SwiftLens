#!/usr/bin/env bash
# Builds SwiftLens.app (menu-bar app, no Xcode project needed) and the `swiftlens` CLI into ./dist.
#
#   scripts/build-app.sh            # release build, ad-hoc signed
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#
# The Xcode Source Editor Extension needs an Xcode project (see project.yml / README).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${CONFIGURATION:-release}"
DIST="dist"
APP="$DIST/SwiftLens.app"

swift build -c "$CONFIGURATION" --product SwiftLensApp
swift build -c "$CONFIGURATION" --product swiftlens
BIN="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SwiftLensApp" "$APP/Contents/MacOS/SwiftLens"
cp App/Info.plist "$APP/Contents/Info.plist"
# SwiftPM resource bundles (if any) live next to the binary.
for bundle in "$BIN"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
cp "$BIN/swiftlens" "$DIST/swiftlens"

IDENTITY="${SIGN_IDENTITY:--}"
ENTITLEMENTS="App/SwiftLens.entitlements"
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP/Contents/MacOS/SwiftLens"
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$DIST/swiftlens"

echo "Built $APP and $DIST/swiftlens"
echo "Run:   open $APP"
echo "CLI:   $DIST/swiftlens --help"
