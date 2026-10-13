#!/bin/sh
# Builds bin/PingGadget.app, a universal app for Intel Macs on macOS 10.13 (High Sierra) or later
# and Apple silicon Macs on macOS 11 or later (the first macOS they shipped with).
# Also writes bin/PingGadget-macOS.zip: copy that file, not the .app folder, to other Macs.
set -e
cd "$(dirname "$0")"

# The Swift back-deployment libraries for Intel ship with Xcode; the Command Line Tools on
# Apple silicon only have them for arm64. Use Xcode when it's installed.
if [ -z "$DEVELOPER_DIR" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
USR=$(dirname "$(dirname "$(xcrun --find swiftc)")")
if ! lipo -archs "$USR/lib/swift/macosx/libswiftCompatibility50.a" | grep -q x86_64; then
    echo "error: this Swift toolchain can't build for Intel Macs. Install Xcode from the App Store." >&2
    exit 1
fi

APP=bin/PingGadget.app
ZIP=bin/PingGadget-macOS.zip
OBJ=build
rm -rf "$APP" "$ZIP" "$OBJ"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OBJ"

xcrun swiftc -O -swift-version 5 -target arm64-apple-macos11.0 -o "$OBJ/PingGadget-arm64" src/*.swift
# macOS includes the Swift runtime from 10.14.4; older systems load the copy in Contents/Frameworks.
xcrun swiftc -O -swift-version 5 -target x86_64-apple-macos10.13 \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks -o "$OBJ/PingGadget-x86_64" src/*.swift
lipo -create "$OBJ/PingGadget-arm64" "$OBJ/PingGadget-x86_64" -output "$APP/Contents/MacOS/PingGadget"

xcrun swift-stdlib-tool --copy --platform macosx --scan-executable "$APP/Contents/MacOS/PingGadget" \
    --source-libraries "$USR/lib/swift-5.0/macosx" --destination "$APP/Contents/Frameworks"

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

# Ad-hoc signature (inside out): Apple silicon refuses to run unsigned code.
for lib in "$APP"/Contents/Frameworks/*.dylib; do
    [ -f "$lib" ] && codesign --force --sign - "$lib"
done
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

# ditto keeps the signature and permissions intact; zipping in Finder works too.
ditto -c -k --keepParent "$APP" "$ZIP"
rm -rf "$OBJ"
echo "Built $APP and $ZIP"
