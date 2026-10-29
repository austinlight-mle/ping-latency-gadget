#!/bin/sh
# Prints the two GitHub secrets that let CI sign the app with the same certificate as this Mac,
# so a Mac that granted Ping Gadget Accessibility keeps the grant when it installs a new release.
#
#   sh macos/export-signing-identity.sh
#
# Then in GitHub: Settings → Secrets and variables → Actions → New repository secret, twice:
#   MACOS_SIGNING_P12           the long base64 text (copied to the clipboard)
#   MACOS_SIGNING_P12_PASSWORD  the password printed below
#
# Run build.sh once first: it creates the certificate. Anyone with these two values can sign apps
# as "PingGadget Code Signing", so keep them in secrets only.
set -e
KEYCHAIN="$HOME/Library/Keychains/pinggadget-codesign.keychain-db"
KEYCHAIN_PASSWORD=pinggadget # as in build.sh

if [ ! -f "$KEYCHAIN" ]; then
    echo "error: $KEYCHAIN doesn't exist yet. Run macos/build.sh once to create the certificate." >&2
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASSWORD=$(/usr/bin/openssl rand -hex 16)
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
echo "macOS asks before it exports the private key: enter the keychain password \"$KEYCHAIN_PASSWORD\" and click Allow."
security export -k "$KEYCHAIN" -t identities -f pkcs12 -P "$PASSWORD" -o "$TMP/id.p12"
base64 -i "$TMP/id.p12" | tr -d '\n' | pbcopy

echo "MACOS_SIGNING_P12: copied to the clipboard ($(wc -c < "$TMP/id.p12" | tr -d ' ') bytes of .p12, base64-encoded)."
echo "MACOS_SIGNING_P12_PASSWORD: $PASSWORD"
