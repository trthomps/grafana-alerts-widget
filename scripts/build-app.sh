#!/usr/bin/env bash
# Builds "Grafana Alerts.app" into ./build. Needs only the Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Grafana Alerts"
EXECUTABLE="GrafanaAlerts"
BUNDLE_ID="${BUNDLE_ID:-io.github.trthomps.grafana-alerts}"
VERSION="${VERSION:-0.1.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # "-" = ad-hoc; set to a Developer ID to sign properly

swift build -c release
BIN="$(swift build -c release --show-bin-path)/$EXECUTABLE"

APP="build/$APP_NAME.app"
rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXECUTABLE"

"$BIN" --render-icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP" >/dev/null
echo "Built $APP"
