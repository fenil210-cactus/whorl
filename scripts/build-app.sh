#!/bin/sh
# Builds dist/Whorl.app (universal, ad-hoc signed) and dist/Whorl.zip.
# usage: scripts/build-app.sh [version]
set -eu
cd "$(dirname "$0")/.."

VERSION="${1:-$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/Whorl/Support/AppInfo.swift)}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "Building Whorl $VERSION (Apple silicon + Intel)…"
# One build per architecture, then lipo: this works with just the Command Line Tools (no Xcode).
swift build -c release --triple arm64-apple-macosx13.0 --product Whorl
swift build -c release --triple x86_64-apple-macosx13.0 --product Whorl
mkdir -p dist
BIN="dist/Whorl-universal"
lipo -create -output "$BIN" \
  ".build/arm64-apple-macosx/release/Whorl" \
  ".build/x86_64-apple-macosx/release/Whorl"

APP="dist/Whorl.app"
rm -rf "$APP" dist/Whorl.zip dist/Whorl.zip.sha256
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BIN" "$APP/Contents/MacOS/Whorl"
chmod +x "$APP/Contents/MacOS/Whorl"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" packaging/Info.plist > "$APP/Contents/Info.plist"

# App icon, drawn by the app itself.
ICONS="$(mktemp -d)/Whorl.iconset"
mkdir -p "$ICONS"
for size in 16 32 128 256 512; do
  "$APP/Contents/MacOS/Whorl" --make-icon "$size" "$ICONS/icon_${size}x${size}.png"
  "$APP/Contents/MacOS/Whorl" --make-icon "$((size * 2))" "$ICONS/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$ICONS" -o "$APP/Contents/Resources/Whorl.icns"
rm -rf "$(dirname "$ICONS")"

codesign --force --deep --sign - --identifier com.fenil210.whorl "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --keepParent "$APP" dist/Whorl.zip
( cd dist && shasum -a 256 Whorl.zip > Whorl.zip.sha256 )
lipo -archs "$APP/Contents/MacOS/Whorl" | sed 's/^/architectures: /'
echo "built $APP"
cat dist/Whorl.zip.sha256
