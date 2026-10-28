#!/bin/zsh
# One-line install of the latest release:
#   curl -fsSL https://raw.githubusercontent.com/KorelUyar/tailbolt/main/scripts/install.sh | zsh
set -euo pipefail
URL="https://github.com/KorelUyar/tailbolt/releases/latest/download/Tailbolt.zip"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Downloading Tailbolt…"
curl -fL --progress-bar "$URL" -o "$TMP/Tailbolt.zip"
pkill -x Tailbolt 2>/dev/null || true
# Tailbolt was called Tailbeam until 2.0 – an old copy would fight for the same port.
if [[ -d /Applications/Tailbeam.app ]]; then
  pkill -x Tailbeam 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/Tailbeam.app "$HOME/Library/Services/Mit Tailbeam senden.workflow"
fi
ditto -x -k "$TMP/Tailbolt.zip" "$TMP/x"
rm -rf /Applications/Tailbolt.app
mv "$TMP/x/Tailbolt.app" /Applications/Tailbolt.app
xattr -dr com.apple.quarantine /Applications/Tailbolt.app 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Tailbolt.app
pluginkit -a /Applications/Tailbolt.app/Contents/PlugIns/TailboltShare.appex 2>/dev/null || true
open /Applications/Tailbolt.app
echo "Done – Tailbolt is running in the menu bar."
