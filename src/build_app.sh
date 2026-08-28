#!/bin/bash
# Ricostruisce "Estrai Allegati.app" e "Estrai Allegati.dmg" nella cartella superiore.
set -e
cd "$(dirname "$0")"
OUT="$(cd .. && pwd)"
APP="$OUT/Estrai Allegati.app"
DMG="$OUT/Estrai Allegati.dmg"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Estrai Allegati</string>
  <key>CFBundleDisplayName</key><string>Estrai Allegati</string>
  <key>CFBundleIdentifier</key><string>com.lucatomei.estrai-allegati</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>EstraiAllegati</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Documento Office</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array>
      <string>org.openxmlformats.wordprocessingml.document</string>
      <string>org.openxmlformats.spreadsheetml.sheet</string>
      <string>org.openxmlformats.presentationml.presentation</string>
      <string>com.microsoft.word.doc</string>
      <string>com.microsoft.excel.xls</string>
      <string>com.microsoft.powerpoint.ppt</string>
    </array>
  </dict></array>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

echo "compilo EstraiAllegati.swift…"
swiftc -O -parse-as-library -target arm64-apple-macos12.0 -o "$APP/Contents/MacOS/EstraiAllegati.arm64" EstraiAllegati.swift Extractor.swift
swiftc -O -parse-as-library -target x86_64-apple-macos12.0 -o "$APP/Contents/MacOS/EstraiAllegati.x86_64" EstraiAllegati.swift Extractor.swift
lipo -create "$APP/Contents/MacOS/EstraiAllegati.arm64" "$APP/Contents/MacOS/EstraiAllegati.x86_64" -output "$APP/Contents/MacOS/EstraiAllegati"
rm "$APP/Contents/MacOS/EstraiAllegati.arm64" "$APP/Contents/MacOS/EstraiAllegati.x86_64"

# Icona
TMP="$(mktemp -d)"; ICONSET="$TMP/AppIcon.iconset"; mkdir -p "$ICONSET"
swiftc -O -o "$TMP/mkicon" make_icon.swift 2>/dev/null && "$TMP/mkicon" "$TMP/base.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/base.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/base.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" && echo "icona ok"
cp "$TMP/base.png" "$OUT/icon.png"
rm -rf "$TMP"
xattr -cr "$APP" 2>/dev/null
# Nessuna firma con certificato: resta solo la firma ad-hoc apposta dal linker (obbligatoria su Apple Silicon).
echo "creata: $APP"

# DMG
rm -f "$DMG"; STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Estrai Allegati" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
echo "creato: $DMG"
