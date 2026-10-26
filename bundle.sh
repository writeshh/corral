#!/bin/sh
# Builds Corral.app (menu bar agent, no Dock icon). The same binary is the CLI:
#   ln -s "$PWD/Corral.app/Contents/MacOS/Corral" /opt/homebrew/bin/corral
set -e
cd "$(dirname "$0")"
swift build -c release
rm -rf Corral.app
mkdir -p Corral.app/Contents/MacOS
cp .build/release/Corral Corral.app/Contents/MacOS/Corral
cat > Corral.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.corral.app</string>
    <key>CFBundleName</key><string>Corral</string>
    <key>CFBundleExecutable</key><string>Corral</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - Corral.app
echo "Built $(pwd)/Corral.app"
