#!/bin/sh
# Packages g8r as a double-clickable macOS app: dist/G8r.app, plus a zip
# of it. Builds in release mode, puts the g8r-hook binary next to the app's
# own (where PaneManager looks for it), copies SwiftPM's resource bundles
# into Contents/Resources (where Bundle.module looks inside an app), and
# signs the result ad hoc so macOS will run it on this machine.
#
# Needs Vendor/ghostty/GhosttyVT.xcframework (scripts/build-ghostty.sh).
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
dist="$root/dist"
app="$dist/G8r.app"
version="${G8R_VERSION:-0.1.0}"

cd "$root"
swift build -c release --product G8r
swift build -c release --product g8r-hook
bin="$(swift build -c release --show-bin-path)"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/G8r" "$bin/g8r-hook" "$app/Contents/MacOS/"
for bundle in "$bin"/*.bundle; do
  cp -R "$bundle" "$app/Contents/Resources/"
done
cp "$root/THIRD_PARTY_NOTICES.md" "$app/Contents/Resources/"
cp "$root/Resources/AppIcon/AppIcon.icns" "$app/Contents/Resources/"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>G8r</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>local.g8r.G8r</string>
	<key>CFBundleName</key>
	<string>G8r</string>
	<key>CFBundleDisplayName</key>
	<string>g8r</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$version</string>
	<key>CFBundleVersion</key>
	<string>$version</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$app"
(cd "$dist" && rm -f G8r.zip && ditto -c -k --keepParent G8r.app G8r.zip)
echo "Built $app and $dist/G8r.zip"
