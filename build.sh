#!/bin/bash
# Builds "Zomboid Workshop Manager.app" and installs it in /Applications.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NAME="Zomboid Workshop Manager"
BUILD="$HERE/build"
APP="$BUILD/$NAME.app"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -o "$APP/Contents/MacOS/$NAME" "$HERE"/Sources/*.swift

swiftc -o "$BUILD/makeicon" "$HERE/MakeIcon.swift"
"$BUILD/makeicon" "$BUILD/AppIcon.iconset"
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$BUILD/AppIcon.iconset"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>io.github.lilpzmods.zomboid-workshop-manager</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Workshop item</string>
      <key>CFBundleURLSchemes</key><array><string>zomboid-workshop-manager</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
rm -rf "/Applications/$NAME.app"
cp -R "$APP" /Applications/
echo "Installed /Applications/$NAME.app"
