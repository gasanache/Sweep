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

echo "▸ building Sweep ($CONFIGURATION)"
rm -rf build
xcodebuild \
    -project Sweep.xcodeproj \
    -scheme Sweep \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS' \
    CONFIGURATION_BUILD_DIR="$PWD/build" \
    build | grep -E '(error|warning):|BUILD' || true

APP="$PWD/build/Sweep.app"
if [ ! -d "$APP" ]; then
    echo "✗ build produced no app bundle" >&2
    exit 1
fi

echo "▸ signature"
codesign -dv "$APP" 2>&1 | grep -E 'Authority|Signature|Identifier' | sed 's/^/    /' || true

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
