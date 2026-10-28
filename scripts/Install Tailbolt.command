#!/bin/zsh
# Double-click installer: expects Tailbolt.zip next to this script (or in ~/Downloads).
set -e
cd "$(dirname "$0")"
ZIP="Tailbolt.zip"
[[ -f "$ZIP" ]] || ZIP="$HOME/Downloads/Tailbolt.zip"
if [[ ! -f "$ZIP" ]]; then
  echo "Tailbolt.zip nicht gefunden (neben diesem Script oder in ~/Downloads)."; read -k1; exit 1
fi
echo "Installiere Tailbolt…"
pkill -x Tailbolt 2>/dev/null || true
# Tailbolt was called Tailbeam until 2.0 – the old app would fight for the same port, so it goes.
if [[ -d /Applications/Tailbeam.app ]]; then
  echo "Entferne das alte Tailbeam…"
  pkill -x Tailbeam 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/Tailbeam.app
  rm -rf "$HOME/Library/Services/Mit Tailbeam senden.workflow"
  rm -f /usr/local/bin/tailbeam 2>/dev/null || true
fi
TMP="$(mktemp -d)"
ditto -x -k "$ZIP" "$TMP"
rm -rf /Applications/Tailbolt.app
mv "$TMP/Tailbolt.app" /Applications/Tailbolt.app
xattr -dr com.apple.quarantine /Applications/Tailbolt.app 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Tailbolt.app
pluginkit -a /Applications/Tailbolt.app/Contents/PlugIns/TailboltShare.appex 2>/dev/null || true
open /Applications/Tailbolt.app
echo "Fertig – Tailbolt läuft in der Menüleiste. Dieses Fenster kannst du schliessen."
sleep 2
osascript -e 'tell application "Terminal" to close (every window whose name contains "Install Tailbolt")' 2>/dev/null || true
