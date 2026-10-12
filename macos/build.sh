#!/bin/sh
# Builds bin/PingGadget.app (universal: Apple silicon and Intel) with the Swift compiler from the
# Xcode Command Line Tools (xcode-select --install), so Xcode itself isn't needed.
set -e
cd "$(dirname "$0")"

APP=bin/PingGadget.app
OBJ=build
rm -rf "$APP" "$OBJ"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OBJ"

for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" -o "$OBJ/PingGadget-$arch" src/*.swift
done
lipo -create "$OBJ/PingGadget-arm64" "$OBJ/PingGadget-x86_64" -output "$APP/Contents/MacOS/PingGadget"

cp Info.plist "$APP/Contents/"
cp helper/pinggadget-helper helper/install-helper.sh "$APP/Contents/Resources/"
chmod 755 "$APP/Contents/Resources/pinggadget-helper" "$APP/Contents/Resources/install-helper.sh"

# App icon from the same artwork as the Windows build.
ICONSET="$OBJ/PingGadget.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256; do
    sips -z $size $size ../PingGadget.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double ../PingGadget.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/PingGadget.icns"

# Ad-hoc signature: required to run on Apple silicon.
codesign --force --sign - "$APP"
rm -rf "$OBJ"
echo "Built $APP"
