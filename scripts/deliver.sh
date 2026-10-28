#!/bin/zsh
# Build, install locally and ship the zip + installer to another of your devices via Taildrop.
# Usage: scripts/deliver.sh <tailnet-device-name>
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="${1:?usage: scripts/deliver.sh <tailnet-device-name>}"
scripts/build-app.sh --install
cp "scripts/Install Tailbolt.command" dist/
TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
export TAILSCALE_BE_CLI=1
"$TS" file cp dist/Tailbolt.zip "dist/Install Tailbolt.command" "$TARGET:"
echo "Delivered dist/Tailbolt.zip + installer to $TARGET"
