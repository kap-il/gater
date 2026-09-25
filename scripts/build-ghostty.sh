#!/bin/sh
# Builds libghostty-vt from the pinned Vendor/ghostty/src submodule and
# packages it as Vendor/ghostty/GhosttyVT.xcframework, which Package.swift
# consumes as a binaryTarget.
#
# The xcframework is assembled by hand (it's just a directory + Info.plist)
# rather than via `xcodebuild -create-xcframework`, so the build doesn't
# depend on a healthy Xcode plug-in install — only on Zig 0.16.x.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/Vendor/ghostty/src"
prefix="$root/Vendor/ghostty/build"
xcf="$root/Vendor/ghostty/GhosttyVT.xcframework"
slice="macos-arm64"

if [ ! -f "$src/build.zig" ]; then
  git -C "$root" submodule update --init --depth 1 Vendor/ghostty/src
fi

(cd "$src" && zig build \
  -Demit-lib-vt=true \
  -Demit-xcframework=false \
  -Doptimize=ReleaseFast \
  --prefix "$prefix")

rm -rf "$xcf"
mkdir -p "$xcf/$slice/Headers"
cp "$prefix/lib/libghostty-vt.a" "$xcf/$slice/libghostty-vt.a"
cp -R "$prefix/include/ghostty" "$xcf/$slice/Headers/"
cat > "$xcf/$slice/Headers/module.modulemap" <<'EOF'
module GhosttyVT {
    header "ghostty/vt.h"
    link "ghostty-vt"
    export *
}
EOF

cat > "$xcf/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>HeadersPath</key>
			<string>Headers</string>
			<key>LibraryIdentifier</key>
			<string>$slice</string>
			<key>LibraryPath</key>
			<string>libghostty-vt.a</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>macos</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
EOF

echo "Built $xcf"
