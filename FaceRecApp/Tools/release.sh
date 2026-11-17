#!/usr/bin/env bash
# Publishes the version in the Xcode project (MARKETING_VERSION) as a GitHub release.
# Installed copies of FaceRec pick it up automatically (see FaceRec/Updater.swift).
#
#   1. Raise MARKETING_VERSION in FaceRec.xcodeproj, commit and push.
#      If the models changed, also raise ModelStore.bundledVersion.
#   2. Tools/release.sh ["Release notes"]
#
# Needs the GitHub CLI (gh) and the update signing key (swift Tools/sign_update.swift keygen).
# The key lives in ~/.config/facerec/update_signing_key. Keep a backup: without it,
# installed copies will refuse future updates.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' FaceRec.xcodeproj/project.pbxproj | head -1)"
MODELS="$(sed -n 's/.*static let bundledVersion = \([0-9]*\).*/\1/p' FaceRec/ModelStore.swift)"
TAG="v$VERSION"

if [ "${1:-}" != "--package-only" ] && [ -n "$(git status --porcelain)" ]; then
    echo "Commit your changes first, so the release matches the repository." >&2; exit 1
fi
if [ "${1:-}" != "--package-only" ] && [ "$(gh release view "$TAG" --json isDraft -q .isDraft 2>/dev/null)" = "false" ]; then
    echo "$TAG is already released. Raise MARKETING_VERSION first." >&2; exit 1
fi

Tools/make_dmg.sh
APP="build/release/Build/Products/Release/FaceRec.app"

echo "Packaging..."
ASSETS=("build/FaceRec-$VERSION.dmg" build/FaceRec.zip build/FaceRec.zip.sig "build/Models-$MODELS.zip" "build/Models-$MODELS.zip.sig")
rm -f build/FaceRec.zip build/FaceRec.zip.sig build/Models-*.zip build/Models-*.zip.sig
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# Package from a copy without extended attributes (see make_dmg.sh).
ditto --noextattr --norsrc "$APP" "$STAGE/app/FaceRec.app"
codesign --verify --deep --strict "$STAGE/app/FaceRec.app"
ditto -c -k --keepParent "$STAGE/app/FaceRec.app" build/FaceRec.zip
swift Tools/sign_update.swift sign build/FaceRec.zip > build/FaceRec.zip.sig
# The compiled models on their own, for copies built without them and for model-only updates.
mkdir "$STAGE/models"
ditto --noextattr --norsrc "$APP/Contents/Resources/FaceNet.mlmodelc" "$STAGE/models/FaceNet.mlmodelc"
ditto --noextattr --norsrc "$APP/Contents/Resources/YOLOv8n.mlmodelc" "$STAGE/models/YOLOv8n.mlmodelc"
ditto -c -k "$STAGE/models" "build/Models-$MODELS.zip"
swift Tools/sign_update.swift sign "build/Models-$MODELS.zip" > "build/Models-$MODELS.zip.sig"

if [ "${1:-}" = "--package-only" ]; then
    printf '%s\n' "${ASSETS[@]}"; exit 0
fi

echo "Publishing $TAG..."
git push origin HEAD
# Create a draft, upload each file with retries (a dropped connection must not
# leave a half-published release), then publish.
if ! gh release view "$TAG" >/dev/null 2>&1; then
    if [ $# -gt 0 ]; then
        gh release create "$TAG" --draft --title "FaceRec $VERSION" --notes "$1"
    else
        gh release create "$TAG" --draft --title "FaceRec $VERSION" --generate-notes
    fi
fi
for asset in "${ASSETS[@]}"; do
    for attempt in 1 2 3 4 5; do
        if gh release upload "$TAG" "$asset" --clobber \
            && gh release view "$TAG" --json assets -q '.assets[].name' | grep -qx "$(basename "$asset")"; then
            continue 2
        fi
        echo "Upload of $asset failed (attempt $attempt), retrying..." >&2
        sleep 5
    done
    echo "Could not upload $asset. The release is still a draft; run Tools/release.sh again to resume." >&2
    exit 1
done
gh release edit "$TAG" --draft=false --latest
echo "Released $TAG"
