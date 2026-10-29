#!/bin/sh
# Builds bin/PingGadget.app, a universal app for Intel Macs on macOS 10.13 (High Sierra) or later
# and Apple silicon Macs on macOS 11 or later (the first macOS they shipped with).
# Also writes bin/PingGadget-macOS.zip: copy that file, not the .app folder, to other Macs.
set -e
cd "$(dirname "$0")"

# The version comes from the VERSION file at the repository root (shared with the Windows build).
VERSION=$(tr -d ' \t\r\n' < ../VERSION)
if [ -z "$VERSION" ]; then
    echo "error: ../VERSION is empty." >&2
    exit 1
fi

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
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
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

# Sign with a stable, self-signed certificate rather than ad hoc. macOS remembers privacy
# permissions (Accessibility) by the app's designated requirement: for an ad-hoc signature that is
# the binary's hash, which changes with every build and isn't reliably kept across restarts; with a
# certificate it is "this bundle ID signed by this certificate", which stays the same. The
# certificate is made once and kept in its own keychain; keep that file to keep the identity.
IDENTITY="PingGadget Code Signing"
KEYCHAIN="$HOME/Library/Keychains/pinggadget-codesign.keychain-db"
KEYCHAIN_PASSWORD=pinggadget # protects only this self-signed signing key
if [ ! -f "$KEYCHAIN" ]; then
    echo "Creating the code signing certificate \"$IDENTITY\" in $KEYCHAIN"
    CERT="$OBJ/cert"
    mkdir -p "$CERT"
    openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -subj "/CN=$IDENTITY" \
        -keyout "$CERT/key.pem" -out "$CERT/cert.pem" \
        -addext "basicConstraints=critical,CA:false" -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
    openssl pkcs12 -export -name "$IDENTITY" -inkey "$CERT/key.pem" -in "$CERT/cert.pem" \
        -out "$CERT/id.p12" -passout "pass:$KEYCHAIN_PASSWORD"
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN" # don't lock after a timeout
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    security import "$CERT/id.p12" -k "$KEYCHAIN" -P "$KEYCHAIN_PASSWORD" -T /usr/bin/codesign >/dev/null
    # Let codesign use the key without a password dialog.
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
    rm -rf "$CERT"
fi
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"

# codesign only finds identities in keychains on the search list, so add ours while signing and
# put the user's list back afterwards (also if signing fails).
eval "set -- $(security list-keychains -d user | tr '\n' ' ')"
restore_keychains() { security list-keychains -d user -s "$@"; }
trap 'restore_keychains "$@"' EXIT
security list-keychains -d user -s "$@" "$KEYCHAIN"

# Inside out: the embedded Swift libraries first, then the app.
for lib in "$APP"/Contents/Frameworks/*.dylib; do
    [ -f "$lib" ] && codesign --force --keychain "$KEYCHAIN" --sign "$IDENTITY" "$lib"
done
codesign --force --keychain "$KEYCHAIN" --sign "$IDENTITY" "$APP"
restore_keychains "$@"
trap - EXIT
codesign --verify --strict "$APP"

# ditto keeps the signature and permissions intact; zipping in Finder works too.
ditto -c -k --keepParent "$APP" "$ZIP"
rm -rf "$OBJ"
echo "Built $APP and $ZIP (version $VERSION)"
