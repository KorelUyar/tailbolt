#!/bin/zsh
# One-line install of the latest release:
#   curl -fsSL https://raw.githubusercontent.com/KorelUyar/tailbolt/main/scripts/install.sh | zsh
set -euo pipefail

# Everything lives in a function that is called on the last line: if the download of this script is
# cut off, zsh has nothing complete to run.
main() {
  local URL="https://github.com/KorelUyar/tailbolt/releases/latest/download/Tailbolt.zip"
  local TMP
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  echo "Downloading Tailbolt…"
  curl -fL --progress-bar "$URL" -o "$TMP/Tailbolt.zip"
  ditto -x -k "$TMP/Tailbolt.zip" "$TMP/x"
  if [[ ! -d "$TMP/x/Tailbolt.app" ]]; then
    echo "The download does not contain Tailbolt.app." >&2
    exit 1
  fi
  pkill -x Tailbolt 2>/dev/null || true
  # Tailbolt was called Tailbeam until 2.0 – an old copy would fight for the same port.
  if [[ -d /Applications/Tailbeam.app ]]; then
    pkill -x Tailbeam 2>/dev/null || true
    sleep 0.5
    rm -rf /Applications/Tailbeam.app "$HOME/Library/Services/Mit Tailbeam senden.workflow"
  fi
  # The old app is only removed now that the new one is unpacked and complete.
  rm -rf /Applications/Tailbolt.app
  mv "$TMP/x/Tailbolt.app" /Applications/Tailbolt.app
  xattr -dr com.apple.quarantine /Applications/Tailbolt.app 2>/dev/null || true
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Tailbolt.app
  pluginkit -a /Applications/Tailbolt.app/Contents/PlugIns/TailboltShare.appex 2>/dev/null || true
  open /Applications/Tailbolt.app
  echo "Done – Tailbolt is running in the menu bar."
}

main "$@"
