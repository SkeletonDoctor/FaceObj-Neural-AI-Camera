#!/usr/bin/env bash
# Builds FaceRec.app (Release) into build/.
# If an "Apple Development" certificate is in the keychain it is used, so macOS
# remembers the camera permission between builds. Without one the app is signed
# to run locally and macOS asks for the camera again after every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')"
SIGNING=()
if [ -n "$IDENTITY" ]; then
    SIGNING=(CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual)
fi
xcodebuild -project FaceRec.xcodeproj -scheme FaceRec -configuration Release \
    -derivedDataPath build "${SIGNING[@]}" build | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
echo "App: $(pwd)/build/Build/Products/Release/FaceRec.app"
