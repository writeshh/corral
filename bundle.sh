#!/bin/sh
# Builds Corral.app (menu bar agent, no Dock icon) with nginx and dnsmasq inside.
# The same binary is the CLI. Corral links it as bin/corral in its state folder.
set -e
cd "$(dirname "$0")"
[ -x .deps/bin/nginx ] && [ -x .deps/bin/dnsmasq ] || ./scripts/build-deps.sh
swift build -c release
rm -rf Corral.app
mkdir -p Corral.app/Contents/MacOS Corral.app/Contents/Resources
cp .build/release/Corral Corral.app/Contents/MacOS/Corral
cp -R .deps/bin .deps/licenses Corral.app/Contents/Resources/
cp Resources/AppIcon.icns Resources/AppIcon-Dark.icns Corral.app/Contents/Resources/ # rebuild with: swift scripts/build-icon.swift
cat > Corral.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.corral.app</string>
    <key>CFBundleName</key><string>Corral</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleExecutable</key><string>Corral</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
# Sign nested executables first, then the app.
codesign --force --sign - Corral.app/Contents/Resources/bin/*
codesign --force --sign - Corral.app
echo "Built $(pwd)/Corral.app"
