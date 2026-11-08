#!/bin/bash
# Compile KyNEDIT, assemble l'.app, la signe (sign_app.sh) et l'installe dans Applications Personnelles.
set -euo pipefail
cd "$(dirname "$0")"
NAME=kYNEDIT; TARGET=KyNEDIT; BUNDLE_ID=com.starbudweiser.kynedit; VERSION="${1:-0.1.0}"
DEST="${DEST:-$HOME/Applications/Applications Personnelles}"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/$TARGET"
APP="$DEST/$NAME.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
# SDK Blackmagic RAW : framework embarqué (vendor/, hors dépôt) pour lire et exporter le BRAW.
# SDK RED : bibliothèques dynamiques à côté de l'exécutable (Redistributable, copiées telles quelles).
if [ -d vendor/R3DSDK/Redistributable/mac ]; then mkdir -p "$APP/Contents/Frameworks"; cp vendor/R3DSDK/Redistributable/mac/*.dylib "$APP/Contents/Frameworks/"; fi
if [ -d vendor/BlackmagicRawAPI.framework ]; then mkdir -p "$APP/Contents/Frameworks"; ditto vendor/BlackmagicRawAPI.framework "$APP/Contents/Frameworks/BlackmagicRawAPI.framework"; fi
ICON=""; for f in assets/*.icns; do [ -f "$f" ] && { cp "$f" "$APP/Contents/Resources/AppIcon.icns"; ICON="AppIcon"; }; done
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$NAME</string>
<key>CFBundleDisplayName</key><string>$NAME</string>
<key>CFBundleExecutable</key><string>$NAME</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleIconFile</key><string>$ICON</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleLocalizations</key><array><string>fr</string><string>en</string><string>es</string><string>it</string></array>
</dict></plist>
PL
/Volumes/SKYRIM/TOOLS/MAC/_tools/sign_app.sh "$APP" "$VERSION"
echo "Installé : $APP"
