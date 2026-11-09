#!/bin/sh
# Lays out build/Deckhand.app around the binary build.sh just linked
# (docs/BROWSER.md §1.5) and writes the build/deckhand wrapper (and build/pi-desk, the same).
#   Contents/MacOS/Deckhand                        the Odin binary (already there)
#   Contents/Frameworks/Chromium Embedded Framework.framework   APFS clone of the pinned one
#   Contents/Frameworks/Deckhand Helper[ (GPU|Renderer|Plugin|Alerts)].app   one C binary
#     (CEF finds them by the main executable's name: "<CFBundleExecutable> Helper (...).app")
#   Contents/Helpers/Deckhand Core.app             dev.deckhand.core (docs/plans/background-core.md §7.1)
#     Contents/MacOS/deckhand-core                 the session holder (build/deckhand-core)
#     Contents/MacOS/deckhand                      the CLI (build/deckhand-cli)
#     Contents/Resources/integrations/{pi,claude-code}
# Signed with DECKHAND_SIGN_IDENTITY (scripts/sign.sh: the self-signed identity, else ad hoc
# with a warning), inside out: framework, helpers, CLI, Core.app (its CLI, then the bundle), app.
# No --deep, no hardened runtime (until the Developer ID: §5.4). The framework is copied only when the pin changed, and signed again only then or
# when the identity changed; later builds re-sign the helpers (tiny) and the app.
# Usage: scripts/bundle-app.sh CEF_DIR MACOS_MIN   (called by build.sh)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
. scripts/sign.sh
sign_resolve
CEF=$1
MIN=$2
APP=build/Deckhand.app
C=$APP/Contents
FW_NAME="Chromium Embedded Framework.framework"
VERSION=$(sed -n 's/^CEF_VERSION=//p' vendor/cef/VERSION)
# the bundle id stays Deckhand's (docs/DEVELOPING.md): macOS keeps notification settings by it.
# Privacy permissions (camera, microphone, location, folders) also depend on the code signature:
# kept across rebuilds and updates when signed with the same certificate (scripts/sign.sh), asked
# for again after each one when signed ad hoc.
ID=dev.pi-desk.app
NAME=Deckhand

plist() { # PATH EXECUTABLE ID NAME [LSUIElement]
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    echo "  <key>CFBundleExecutable</key><string>$2</string>"
    echo "  <key>CFBundleIdentifier</key><string>$3</string>"
    echo "  <key>CFBundleName</key><string>$4</string>"
    echo "  <key>CFBundleDisplayName</key><string>$4</string>"
    echo '  <key>CFBundlePackageType</key><string>APPL</string>'
    echo '  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>'
    echo '  <key>CFBundleShortVersionString</key><string>0.1</string>'
    echo '  <key>CFBundleVersion</key><string>1</string>'
    echo "  <key>LSMinimumSystemVersion</key><string>$MIN</string>"
    echo '  <key>NSHighResolutionCapable</key><true/>'
    echo '  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>'
    # the app's icon (assets/icon/Deckhand.icns, from deckhand.svg); helpers have none
    [ "${5:-}" = ui_element ] || echo '  <key>CFBundleIconFile</key><string>Deckhand</string>'
    [ "${5:-}" = ui_element ] && echo '  <key>LSUIElement</key><true/>'
    # KSBrandID "": Chromium takes the app's brand code (none, organic) and never
    # reads ~/Library/Google/Google Chrome Brand.plist, which Google Chrome shares
    # (docs/BROWSER.md §2.3; cef_start refuses to start CEF without it)
    [ "${5:-}" = ui_element ] || echo '  <key>KSBrandID</key><string></string>'
    # a web page may ask for the camera, the microphone or the location (after the user's Allow in
    # its bar, docs/BROWSER.md "Step 3 results"): macOS asks the user once more with these words,
    # and without them it would end Deckhand instead
    if [ "${5:-}" != ui_element ]; then
      echo '  <key>NSCameraUsageDescription</key><string>A web page in a browser tab asked to use the camera.</string>'
      echo '  <key>NSMicrophoneUsageDescription</key><string>A web page in a browser tab asked to use the microphone.</string>'
      echo '  <key>NSLocationUsageDescription</key><string>A web page in a browser tab asked for your location.</string>'
      echo '  <key>NSLocationWhenInUseUsageDescription</key><string>A web page in a browser tab asked for your location.</string>'
      # the Files tab and the editor list and open folders macOS protects: it asks the user with
      # these words (docs/GUIDE.md "The Files tab"); an ad-hoc build asks again after each update
      echo '  <key>NSDesktopFolderUsageDescription</key><string>Deckhand shows and edits files in your Desktop folder for your projects.</string>'
      echo '  <key>NSDocumentsFolderUsageDescription</key><string>Deckhand shows and edits files in your Documents folder for your projects.</string>'
      echo '  <key>NSDownloadsFolderUsageDescription</key><string>Deckhand shows and edits files in your Downloads folder for your projects.</string>'
      echo '  <key>NSRemovableVolumesUsageDescription</key><string>Deckhand shows and edits project files on a removable drive.</string>'
      echo '  <key>NSNetworkVolumesUsageDescription</key><string>Deckhand shows and edits project files on a network volume.</string>'
    fi
    echo '</dict></plist>'
  } > "$1"
}

mkdir -p "$C/MacOS" "$C/Frameworks" "$C/Resources"
plist "$C/Info.plist" "$NAME" "$ID" "$NAME"
cp assets/icon/Deckhand.icns "$C/Resources/Deckhand.icns"

# licences (THIRD_PARTY_NOTICES.md): Deckhand's, the notices, CEF's and Chromium's credits
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
  rm -f build/.cef-signed-as
  echo "$VERSION" > build/.cef-bundled-version
fi
# signed again when the identity changed (build/.cef-signed-as: which one signed it)
if [ "$(cat build/.cef-signed-as 2>/dev/null)" != "$SIGN_AS" ]; then
  sign_code "$C/Frameworks/$FW_NAME/Libraries/"*.dylib
  sign_code "$C/Frameworks/$FW_NAME"
  printf '%s\n' "$SIGN_AS" > build/.cef-signed-as
fi

# helpers: one binary, five bundles (Chromium picks them by name)
for kind in "" " (GPU)" " (Renderer)" " (Plugin)" " (Alerts)"; do
  name="$NAME Helper$kind"
  suffix=$(printf %s "$kind" | tr -d ' ()' | tr '[:upper:]' '[:lower:]')
  h="$C/Frameworks/$name.app"
  mkdir -p "$h/Contents/MacOS"
  if ! cmp -s build/cef_helper "$h/Contents/MacOS/$name"; then
    cp build/cef_helper "$h/Contents/MacOS/$name"
  fi
  plist "$h/Contents/Info.plist" "$name" "$ID.helper${suffix:+.$suffix}" "$name" ui_element
  sign_code "$h"
done

# Claude Code tabs (src/core/claude.odin): the CLI next to the binary (signed before the app: nested
# code is signed inside out) and the plugin in Resources (sealed with the app's resources)
if [ -f build/deckhand-cli ] && [ -d build/claude-code ]; then
  cp build/deckhand-cli "$C/MacOS/deckhand-cli"
  sign_code "$C/MacOS/deckhand-cli"
  # its old name, a relative link sealed with the app: Claude tabs started before 0.1.7 (and held
  # across the update) run …/MacOS/pi-desk-cli by its absolute path (PI_DESK_CLI, a read-only
  # tab's guard hook). Kept until 0.2.0 at least (docs/DEVELOPING.md, "The rename").
  ln -sfn deckhand-cli "$C/MacOS/pi-desk-cli"
  rm -rf "$C/Resources/claude-code"
  cp -R build/claude-code "$C/Resources/claude-code"
fi
# Deckhand Core.app (docs/plans/background-core.md §7.1, §10.3 M4-A): the session holder as its
# main executable, the CLI and the integrations, identifier dev.deckhand.core, which holder_install
# checks on its copy with the app's own designated requirement (src/core/holder_install.odin,
# src/trust). A bundle in Contents/Helpers (a bare data file there would break the app's seal);
# signed before the app. Never written in place: a holder may run this very bundle's binary (a
# scene's, in test mode), and a signed binary changed under it is killed at its next page-in. Laid
# out and signed beside (build/.core-app.new), then renamed in; the old one is removed after (its
# running binary keeps its file until it exits).
CORE_APP="$C/Helpers/Deckhand Core.app"
if [ -f build/deckhand-core ]; then
  mkdir -p "$C/Helpers"
  N="build/.core-app.new/Deckhand Core.app"
  rm -rf build/.core-app.new
  mkdir -p "$N/Contents/MacOS" "$N/Contents/Resources/integrations"
  plist "$N/Contents/Info.plist" deckhand-core dev.deckhand.core "Deckhand Core" ui_element
  cp build/deckhand-core "$N/Contents/MacOS/deckhand-core"
  [ -f build/deckhand-cli ] && cp build/deckhand-cli "$N/Contents/MacOS/deckhand"
  [ -d build/pi ] && cp -R build/pi "$N/Contents/Resources/integrations/pi"
  [ -d build/claude-code ] && cp -R build/claude-code "$N/Contents/Resources/integrations/claude-code"
  # inside out: the CLI, then the bundle (which signs its main executable, deckhand-core)
  [ -f "$N/Contents/MacOS/deckhand" ] && sign_code --identifier dev.deckhand.cli "$N/Contents/MacOS/deckhand"
  sign_code "$N"
  rm -rf "$CORE_APP.old"
  [ -d "$CORE_APP" ] && mv "$CORE_APP" "$CORE_APP.old"
  mv "$N" "$CORE_APP"
  rm -rf "$CORE_APP.old" build/.core-app.new
fi
# the bare holder of builds before Deckhand Core.app (removing it is safe while one runs)
rm -f "$C/Helpers/deckhand-core"
# pi tabs (src/core/pi_integration.odin): the pi integration in Resources, loaded with `pi -e`
if [ -d build/pi ]; then
  rm -rf "$C/Resources/pi"
  cp -R build/pi "$C/Resources/pi"
fi

sign_code "$APP"

# build/deckhand: the command scripts and the relaunch use, environment intact; build/pi-desk is
# the same (older scripts and pi-kit's development setups run that name)
for w in build/deckhand build/pi-desk; do
  rm -f "$w"
  cat > "$w" <<'EOF'
#!/bin/sh
# Deckhand is an app bundle (CEF needs one); this runs its binary directly so
# arguments, the environment and stdio pass through (`open` would drop them).
exec "$(dirname "$0")/Deckhand.app/Contents/MacOS/Deckhand" "$@"
EOF
  chmod +x "$w"
done
