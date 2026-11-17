#!/usr/bin/env bash
# Builds a distributable build/FaceRec-<version>.dmg (Apple Silicon).
# With --no-build it repackages the app already built in build/release.
# The app is signed to run locally, not with a personal certificate, and is
# not notarised: people who download it must allow it once in System Settings.
set -euo pipefail
cd "$(dirname "$0")/.."
for model in FaceNet YOLOv8n; do
    [ -d "FaceRec/Models/$model.mlpackage" ] || { echo "Missing $model: run Tools/setup_models.sh first." >&2; exit 1; }
done
VERSION="$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' FaceRec.xcodeproj/project.pbxproj | head -1)"
if [ "${1:-}" != "--no-build" ]; then
xcodebuild -project FaceRec.xcodeproj -scheme FaceRec -configuration Release \
    -derivedDataPath build/release ARCHS=arm64 CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
    DEBUG_INFORMATION_FORMAT=dwarf-with-dsym build | grep -E "error|BUILD" || true
fi
APP="build/release/Build/Products/Release/FaceRec.app"
[ -d "$APP" ] || { echo "Build failed." >&2; exit 1; }
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# Copy without extended attributes: Finder and cloud-sync attributes picked up
# in the build folder would invalidate the app's signature for other people.
ditto --noextattr --norsrc "$APP" "$STAGE/FaceRec.app"
codesign --verify --deep --strict "$STAGE/FaceRec.app" || { echo "The app's signature does not verify." >&2; exit 1; }
ln -s /Applications "$STAGE/Applications"
DMG="build/FaceRec-$VERSION.dmg"
hdiutil create -volname "FaceRec" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "Disk image: $(pwd)/$DMG"
