#!/bin/sh
# Lays out build/pi-desk.app around the binary build.sh just linked
# (docs/BROWSER.md §1.5) and writes the build/pi-desk wrapper.
#   Contents/MacOS/pi-desk                         the Odin binary (already there)
#   Contents/Frameworks/Chromium Embedded Framework.framework   APFS clone of the pinned one
#   Contents/Frameworks/pi-desk Helper[ (GPU|Renderer|Plugin|Alerts)].app   one C binary
# Signed ad hoc, inside out: helpers, framework, app. No --deep, no hardened
# runtime. The framework is copied and signed only when the pin changed;
# later builds re-sign the helpers (tiny) and the app.
# Usage: scripts/bundle-app.sh CEF_DIR MACOS_MIN   (called by build.sh)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
CEF=$1
MIN=$2
APP=build/pi-desk.app
C=$APP/Contents
FW_NAME="Chromium Embedded Framework.framework"
VERSION=$(sed -n 's/^CEF_VERSION=//p' vendor/cef/VERSION)
ID=dev.pi-desk.app

plist() { # PATH EXECUTABLE ID NAME [LSUIElement]
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    echo "  <key>CFBundleExecutable</key><string>$2</string>"
    echo "  <key>CFBundleIdentifier</key><string>$3</string>"
    echo "  <key>CFBundleName</key><string>$4</string>"
    echo '  <key>CFBundlePackageType</key><string>APPL</string>'
    echo '  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>'
    echo '  <key>CFBundleShortVersionString</key><string>0.1</string>'
    echo '  <key>CFBundleVersion</key><string>1</string>'
    echo "  <key>LSMinimumSystemVersion</key><string>$MIN</string>"
    echo '  <key>NSHighResolutionCapable</key><true/>'
    echo '  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>'
    # the app's icon (assets/icon/pi-desk.icns, from pi-desk.svg); helpers have none
    [ "${5:-}" = ui_element ] || echo '  <key>CFBundleIconFile</key><string>pi-desk</string>'
    [ "${5:-}" = ui_element ] && echo '  <key>LSUIElement</key><true/>'
    # KSBrandID "": Chromium takes the app's brand code (none, organic) and never
    # reads ~/Library/Google/Google Chrome Brand.plist, which Google Chrome shares
    # (docs/BROWSER.md §2.3; cef_start refuses to start CEF without it)
    [ "${5:-}" = ui_element ] || echo '  <key>KSBrandID</key><string></string>'
    # a web page may ask for the camera, the microphone or the location (after the user's Allow in
    # its bar, docs/BROWSER.md "Step 3 results"): macOS asks the user once more with these words,
    # and without them it would end pi-desk instead
    if [ "${5:-}" != ui_element ]; then
      echo '  <key>NSCameraUsageDescription</key><string>A web page in a browser tab asked to use the camera.</string>'
      echo '  <key>NSMicrophoneUsageDescription</key><string>A web page in a browser tab asked to use the microphone.</string>'
      echo '  <key>NSLocationUsageDescription</key><string>A web page in a browser tab asked for your location.</string>'
      echo '  <key>NSLocationWhenInUseUsageDescription</key><string>A web page in a browser tab asked for your location.</string>'
    fi
    echo '</dict></plist>'
  } > "$1"
}

mkdir -p "$C/MacOS" "$C/Frameworks" "$C/Resources"
plist "$C/Info.plist" pi-desk "$ID" pi-desk
cp assets/icon/pi-desk.icns "$C/Resources/pi-desk.icns"

# licences (THIRD_PARTY_NOTICES.md): pi-desk's, the notices, CEF's and Chromium's credits
L="$C/Resources/licenses"
mkdir -p "$L"
cp LICENSE "$L/LICENSE"
cp THIRD_PARTY_NOTICES.md "$L/THIRD_PARTY_NOTICES.md"
cp "$CEF/LICENSE.txt" "$L/CEF-LICENSE.txt"
cp "$CEF/CREDITS.html" "$L/CHROMIUM-CREDITS.html"

# the framework: an APFS clone (cp -c), only when the pinned version changed
if [ "$(cat build/.cef-bundled-version 2>/dev/null)" != "$VERSION" ] || [ ! -d "$C/Frameworks/$FW_NAME" ]; then
  echo "bundling CEF $VERSION"
  rm -rf "$C/Frameworks/$FW_NAME"
  cp -cR "$CEF/Release/$FW_NAME" "$C/Frameworks/$FW_NAME"
  codesign --force --sign - "$C/Frameworks/$FW_NAME/Libraries/"*.dylib
  codesign --force --sign - "$C/Frameworks/$FW_NAME"
  echo "$VERSION" > build/.cef-bundled-version
fi

# helpers: one binary, five bundles (Chromium picks them by name)
for kind in "" " (GPU)" " (Renderer)" " (Plugin)" " (Alerts)"; do
  name="pi-desk Helper$kind"
  suffix=$(printf %s "$kind" | tr -d ' ()' | tr '[:upper:]' '[:lower:]')
  h="$C/Frameworks/$name.app"
  mkdir -p "$h/Contents/MacOS"
  if ! cmp -s build/cef_helper "$h/Contents/MacOS/$name"; then
    cp build/cef_helper "$h/Contents/MacOS/$name"
  fi
  plist "$h/Contents/Info.plist" "$name" "$ID.helper${suffix:+.$suffix}" "$name" ui_element
  codesign --force --sign - "$h" 2>/dev/null
done

codesign --force --sign - "$APP"

# build/pi-desk: the command scripts and the relaunch use, environment intact
cat > build/pi-desk <<'EOF'
#!/bin/sh
# pi-desk is an app bundle (CEF needs one); this runs its binary directly so
# arguments, the environment and stdio pass through (`open` would drop them).
exec "$(dirname "$0")/pi-desk.app/Contents/MacOS/pi-desk" "$@"
EOF
chmod +x build/pi-desk
