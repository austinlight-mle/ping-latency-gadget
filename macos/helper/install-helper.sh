#!/bin/sh
# Run as root (Ping Gadget asks for an administrator password once):
#   install-helper.sh <uid> <path to pinggadget-helper>
# Copies the helper to a root-owned location and lets that user run it through sudo without a password.
set -e
uid=$1
src=$2
dst=/Library/PrivilegedHelperTools/com.pinggadget.helper
rule=/etc/sudoers.d/pinggadget

echo "$uid" | grep -Eq '^[0-9]+$' || { echo "invalid uid: $uid" >&2; exit 2; }
[ -f "$src" ] || { echo "helper not found: $src" >&2; exit 2; }

install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
install -o root -g wheel -m 755 "$src" "$dst"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
echo "#$uid ALL=(root) NOPASSWD: $dst" > "$tmp"
visudo -cqf "$tmp"
install -d -o root -g wheel -m 755 /etc/sudoers.d
install -o root -g wheel -m 440 "$tmp" "$rule"
