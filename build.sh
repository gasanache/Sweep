#!/bin/sh
#
#  build.sh — build Sweep.app into ./build and optionally launch it.
#
#  Usage:
#     ./build.sh              Release build, signed with your Developer ID
#     ./build.sh --run        …and launch it when it succeeds
#     ./build.sh --debug      Debug configuration instead
#     ./build.sh --icon       regenerate the app icon first
#     ./build.sh --install    copy the result to /Applications
#
set -e

cd "$(dirname "$0")"

CONFIGURATION="Release"
RUN=0
INSTALL=0
ICON=0

for argument in "$@"; do
    case "$argument" in
        --run)     RUN=1 ;;
        --debug)   CONFIGURATION="Debug" ;;
        --install) INSTALL=1 ;;
        --icon)    ICON=1 ;;
        *) echo "unknown option: $argument" >&2; exit 2 ;;
    esac
done

if [ "$ICON" -eq 1 ]; then
    echo "▸ rendering app icon"
    swift Scripts/make_icon.swift
fi

mkdir -p build
WORK="$(mktemp -d "$PWD/build/.sweep-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Preserve versioned release artifacts; never launch a stale app after failure.
set --
if [ "$CONFIGURATION" = "Release" ]; then
    set -- CODE_SIGN_STYLE=Manual \
        "CODE_SIGN_IDENTITY=Developer ID Application" \
        OTHER_CODE_SIGN_FLAGS=--timestamp \
        "ARCHS=arm64 x86_64" ONLY_ACTIVE_ARCH=NO
fi

echo "Building Sweep ($CONFIGURATION)"
xcodebuild -quiet \
    -project Sweep.xcodeproj \
    -scheme Sweep \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$WORK/DerivedData" \
    CONFIGURATION_BUILD_DIR="$WORK/Products" \
    "$@" build

STAGED_APP="$WORK/Products/Sweep.app"
if [ ! -d "$STAGED_APP" ]; then
    echo "✗ build produced no app bundle" >&2
    exit 1
fi

codesign --verify --deep --strict "$STAGED_APP"
APP="$PWD/build/Sweep.app"
rm -rf "$APP"
mv "$STAGED_APP" "$APP"
# Keep the symbols next to the app; the EXIT trap deletes everything in $WORK.
if [ -d "$STAGED_APP.dSYM" ]; then
    rm -rf "$APP.dSYM"
    mv "$STAGED_APP.dSYM" "$APP.dSYM"
fi
echo "Signature"
codesign -dv "$APP"

if [ "$INSTALL" -eq 1 ]; then
    echo "▸ installing to /Applications"
    rm -rf "/Applications/Sweep.app"
    cp -R "$APP" /Applications/
    APP="/Applications/Sweep.app"
fi

echo "✓ $APP"

if [ "$RUN" -eq 1 ]; then
    # Relaunch cleanly: a stale copy from a previous build would otherwise keep
    # running and make it look as though changes had not taken effect.
    pkill -x Sweep 2>/dev/null || true
    open "$APP"
fi
