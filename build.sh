#!/bin/bash
# Build VideoScopes.app without Xcode (swiftc + clang). Shaders are compiled at
# runtime from the bundled Shaders.metal, so the Metal offline toolchain is not
# required. DeckLink capture is compiled in automatically when the SDK headers
# are found and the CaptureBridge sources are present; otherwise the app builds
# test-pattern-only.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/VideoScopes.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
BIN="$MACOS/VideoScopes"

rm -rf build
mkdir -p "$MACOS" "$RES"

SWIFT_FLAGS=(-swift-version 5 -O
  -framework Cocoa -framework Metal -framework MetalKit -framework QuartzCore)
EXTRA_OBJ=()

# --- locate the DeckLink SDK headers ---
SDK_HDR="$(find "$HOME/Downloads" -maxdepth 5 -path '*/Mac/include/DeckLinkAPI.h' 2>/dev/null | head -1 || true)"
if [ -z "$SDK_HDR" ]; then
  SDK_HDR="$(find /Library/Developer "$HOME" -maxdepth 6 -name DeckLinkAPI.h 2>/dev/null | grep -i mac | head -1 || true)"
fi

if [ -n "$SDK_HDR" ] && [ -f CaptureBridge/DLCapture.mm ]; then
  SDK_INC="$(dirname "$SDK_HDR")"
  echo ">> DeckLink: building real capture (SDK headers: $SDK_INC)"
  clang -c -ObjC++ -std=c++17 -fobjc-arc -mmacosx-version-min=13.0 \
    -I"$SDK_INC" CaptureBridge/DLCapture.mm -o build/DLCapture.o
  clang -c -ObjC++ -std=c++17 -mmacosx-version-min=13.0 \
    -I"$SDK_INC" "$SDK_INC/DeckLinkAPIDispatch.cpp" -o build/Dispatch.o
  EXTRA_OBJ=(build/DLCapture.o build/Dispatch.o)
  SWIFT_FLAGS+=(-D HAVE_DECKLINK
    -import-objc-header CaptureBridge/Bridging.h
    -Xlinker -lc++ -framework CoreFoundation -framework IOKit)
else
  echo ">> DeckLink: not built (SDK headers or CaptureBridge missing) — test pattern only"
fi

echo ">> Compiling Swift sources..."
swiftc "${SWIFT_FLAGS[@]}" Sources/*.swift ${EXTRA_OBJ[@]+"${EXTRA_OBJ[@]}"} -o "$BIN"

# generate the app icon (.icns) from Tools/make_icon.swift if it is not present
if [ ! -f AppIcon.icns ] && [ -f Tools/make_icon.swift ]; then
  echo ">> Generating app icon..."
  rm -rf /tmp/VideoScopes.iconset
  swift Tools/make_icon.swift /tmp/VideoScopes.iconset >/dev/null 2>&1 \
    && iconutil -c icns /tmp/VideoScopes.iconset -o AppIcon.icns 2>/dev/null || true
fi

echo ">> Assembling app bundle..."
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/Shaders.metal "$RES/Shaders.metal"
[ -f AppIcon.icns ] && cp AppIcon.icns "$RES/AppIcon.icns"

echo ">> Ad-hoc code signing..."
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo ">> Done: $APP"
