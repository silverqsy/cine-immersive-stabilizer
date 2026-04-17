#!/usr/bin/env bash
# Build the Swift Cine Immersive Stabilizer .app, signed + notarized.
#
# Steps:
#   1. swift build -c release  (arm64 executable)
#   2. Assemble .app bundle
#   3. Copy braw_helper → Contents/Resources
#   4. Copy BlackmagicRawAPI.framework → Contents/Frameworks
#   5. Rewrite braw_helper's dylib reference to @loader_path/../Frameworks
#   6. codesign (deep, hardened, timestamped)
#   7. ditto a zip, notarize via keychain profile DEV, staple

set -euo pipefail
cd "$(dirname "$0")"

# --- inputs ---------------------------------------------------------
APP_NAME="Cine Immersive Stabilizer"
BUNDLE_ID="com.siyangqi.cineimmersivestabilizer"
VERSION="2.0.0"
SIGN_IDENTITY="Developer ID Application: Yuanming Ni (655S25MMH5)"
KEYCHAIN_PROFILE="DEV"

BRAW_HELPER="../braw_helper"
FRAMEWORK_SRC="/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Libraries/BlackmagicRawAPI.framework"

if [ ! -f "$BRAW_HELPER" ]; then
    echo "❌ braw_helper not found at $BRAW_HELPER"; exit 1
fi
if [ ! -d "$FRAMEWORK_SRC" ]; then
    # Fall back to the PyInstaller bundle's copy if present
    FRAMEWORK_SRC="../dist/Cine Immersive Stabilizer.app/Contents/Frameworks/BlackmagicRawAPI.framework"
fi
if [ ! -d "$FRAMEWORK_SRC" ]; then
    echo "❌ BlackmagicRawAPI.framework not found (install the BMD RAW SDK)"; exit 1
fi

# --- compile --------------------------------------------------------
echo "▸ swift build -c release"
swift build -c release >/dev/null
BIN=".build/release/CineImmersiveStabilizer"

# --- assemble .app --------------------------------------------------
OUT="dist/$APP_NAME.app"
rm -rf "dist"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources" "$OUT/Contents/Frameworks"

cp "$BIN" "$OUT/Contents/MacOS/$APP_NAME"
# Preserve framework symlinks (ditto is symlink-aware)
ditto "$FRAMEWORK_SRC" "$OUT/Contents/Frameworks/BlackmagicRawAPI.framework"
# braw_helper lives next to the framework so BlackmagicRawAPI's internal
# dladdr-based support-library lookup finds Libraries/ alongside the
# loaded dylib. That's also what PyInstaller does.
cp "$BRAW_HELPER" "$OUT/Contents/Frameworks/braw_helper"
# Provide a bare-name symlink the dylib ref below points at.
ln -sf "BlackmagicRawAPI.framework/Versions/A/BlackmagicRawAPI" \
    "$OUT/Contents/Frameworks/BlackmagicRawAPI"

# Minimal Info.plist
cat > "$OUT/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>           <string>$APP_NAME</string>
    <key>CFBundleName</key>                 <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>           <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>              <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>   <string>$VERSION</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleSupportedPlatforms</key>   <array><string>MacOSX</string></array>
    <key>LSMinimumSystemVersion</key>       <string>13.0</string>
    <key>NSHighResolutionCapable</key>      <true/>
</dict>
</plist>
EOF

# --- fix braw_helper dylib reference + rpaths -----------------------
# Shortest reliable path for bundled loading, matching what PyInstaller
# produced (which is known-good on this machine):
#   • dylib reference:  @rpath/BlackmagicRawAPI
#   • LC_RPATH:         @loader_path
#   • braw_helper sits in Contents/Frameworks next to the symlink.
# BlackmagicRawAPI's internal support-library lookup uses dladdr on the
# loaded dylib, so placing braw_helper in Frameworks/ lets that lookup
# find Libraries/ inside the .framework without the absolute /Applications
# rpath the original binary had.
HELPER="$OUT/Contents/Frameworks/braw_helper"
install_name_tool -delete_rpath "/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Libraries" "$HELPER" 2>/dev/null || true
install_name_tool -add_rpath "@loader_path" "$HELPER"
install_name_tool -change \
    "@rpath/BlackmagicRawAPI.framework/Versions/A/BlackmagicRawAPI" \
    "@rpath/BlackmagicRawAPI" \
    "$HELPER"

# --- sign -----------------------------------------------------------
echo "▸ codesign"
ENTITLEMENTS=../entitlements.plist
# Sign the framework + helper first (inside-out), then the .app.
codesign --force --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" \
    "$OUT/Contents/Frameworks/BlackmagicRawAPI.framework" >/dev/null
# Helper needs the same entitlements as the main app so that the hardened
# runtime allows it to load the Blackmagic-signed framework. Without
# `disable-library-validation` the loader refuses the cross-team dylib.
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$HELPER" >/dev/null
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$OUT" >/dev/null
codesign --verify --strict --deep "$OUT" && echo "  signature valid"

# --- zip + notarize + staple ---------------------------------------
ZIP="dist/CineImmersiveStabilizer.zip"
echo "▸ zip + notarize (this takes 1–5 min)"
ditto -c -k --sequesterRsrc --keepParent "$OUT" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$OUT"
spctl -a -vvv -t execute "$OUT"

# Re-zip the stapled version for distribution
rm "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$OUT" "$ZIP"
ls -lh "$OUT" "$ZIP"
echo "✅ built: $OUT"
