#!/bin/zsh
# Builds dist/Tailbolt.app (+ Share extension), ad-hoc signed, and dist/Tailbolt.zip.
# Usage: scripts/build-app.sh [--install]   (--install copies to /Applications and relaunches)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="2.3"
BUILD="$(date +%Y%m%d%H%M)"
# The macOS 27 SDK needs Xcode's SwiftUI macro plugin; the 26.5 SDK builds fine with the CLT alone.
SDK="${TAILBOLT_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
[[ -d "$SDK" ]] || SDK="$(xcrun --show-sdk-path)"
export SDKROOT="$SDK"

# Universal binary: each architecture gets its own scratch path, lipo merges them.
ARCHS=(${=TAILBOLT_ARCHS:-arm64 x86_64})
typeset -A BINS
for arch in $ARCHS; do
  SCRATCH=".build/$arch"
  swift build -c release --scratch-path "$SCRATCH" --triple "$arch-apple-macosx14.0" --product Tailbolt
  swift build -c release --scratch-path "$SCRATCH" --triple "$arch-apple-macosx14.0" --product tailbolt-cli
  BINS[$arch]="$(swift build -c release --scratch-path "$SCRATCH" --triple "$arch-apple-macosx14.0" --show-bin-path)"
done
BIN="$(mktemp -d)"
for product in Tailbolt tailbolt-cli; do
  lipo -create $(for arch in $ARCHS; do echo "${BINS[$arch]}/$product"; done) -output "$BIN/$product"
done

APP=dist/Tailbolt.app
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/PlugIns"
cp "$BIN/Tailbolt" "$APP/Contents/MacOS/Tailbolt"
cp "$BIN/tailbolt-cli" "$APP/Contents/Resources/tailbolt-cli"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"

# Icon (rendered per size by the script) + menu-bar template glyphs (pre-rendered in Resources/,
# regenerate with: swift scripts/make-icon.swift --menubar Resources)
ICONSET="$(mktemp -d)/AppIcon.iconset"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp Resources/menubar*.png "$APP/Contents/Resources/"
# Localizations: English is the source language, German comes from de.lproj
cp -R Resources/en.lproj Resources/de.lproj "$APP/Contents/Resources/"
plutil -lint "$APP/Contents/Resources/de.lproj/Localizable.strings" >/dev/null

# Share extension (Finder → Teilen → Tailbolt)
APPEX="$APP/Contents/PlugIns/TailboltShare.appex"
mkdir -p "$APPEX/Contents/MacOS"
SHARE_SLICES=()
for arch in $ARCHS; do
  swiftc -O -sdk "$SDK" -target "$arch-apple-macos14.0" -parse-as-library -module-name TailboltShare \
    ShareExtension/ShareViewController.swift -Xlinker -e -Xlinker _NSExtensionMain -framework AppKit \
    -o "$BIN/TailboltShare-$arch"
  SHARE_SLICES+=("$BIN/TailboltShare-$arch")
done
lipo -create $SHARE_SLICES -output "$APPEX/Contents/MacOS/TailboltShare"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" ShareExtension/Info.plist > "$APPEX/Contents/Info.plist"

codesign --force --sign - --entitlements ShareExtension/Share.entitlements "$APPEX"
codesign --force --sign - "$APP/Contents/Resources/tailbolt-cli"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

ditto -c -k --keepParent "$APP" dist/Tailbolt.zip
echo "Built $APP ($BUILD)"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Tailbolt || true
  pkill -x Tailbeam || true          # pre-2.0 name; same port, so the old app must go
  sleep 0.5
  rm -rf /Applications/Tailbolt.app /Applications/Tailbeam.app "$HOME/Library/Services/Mit Tailbeam senden.workflow"
  cp -R "$APP" /Applications/Tailbolt.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Tailbolt.app
  pluginkit -a /Applications/Tailbolt.app/Contents/PlugIns/TailboltShare.appex || true
  /System/Library/CoreServices/pbs -update || true
  open /Applications/Tailbolt.app
  echo "Installed and launched /Applications/Tailbolt.app"
fi
