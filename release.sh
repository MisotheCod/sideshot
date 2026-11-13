#!/usr/bin/env bash
#
# Build Sideshot, sign the archive with Sparkle's EdDSA key, and publish a
# GitHub release that includes the appcast.xml the app actually polls.
#
#   ./release.sh "Release notes here"
#
# Requirements:
#   - gh authenticated for MisotheCod/sideshot
#   - the Sparkle EdDSA private key in your login keychain
#     (regenerate once with: sparkle/bin/generate_keys)
#   - the Sparkle release tools; this script downloads them if missing
#
set -euo pipefail

REPO="MisotheCod/sideshot"
SPARKLE_VER="2.10.1"
SPARKLE_DIR="${SPARKLE_DIR:-/tmp/sparkle}"

cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sideshot/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Sideshot/Info.plist)
TAG="v${VERSION}"
NOTES="${1:-Sideshot ${TAG}}"

echo "==> Releasing Sideshot ${VERSION} (build ${BUILD})"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "!! Working tree is dirty. Commit first." >&2
  exit 1
fi

if [[ ! -x "${SPARKLE_DIR}/bin/generate_appcast" ]]; then
  echo "==> Fetching Sparkle ${SPARKLE_VER} tools"
  mkdir -p "${SPARKLE_DIR}"
  curl -sL -o "${SPARKLE_DIR}/sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VER}/Sparkle-${SPARKLE_VER}.tar.xz"
  tar -xf "${SPARKLE_DIR}/sparkle.tar.xz" -C "${SPARKLE_DIR}"
fi

echo "==> Generating project"
xcodegen generate >/dev/null

echo "==> Building (universal, Release)"
xcodebuild -project Sideshot.xcodeproj -scheme Sideshot -configuration Release \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build >/dev/null

APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/Sideshot-*/Build/Products/Release/Sideshot.app | head -1)

STAGE=$(mktemp -d)
ZIP_NAME="Sideshot-${TAG}.zip"
echo "==> Archiving ${ZIP_NAME}"
ditto -c -k --sequesterRsrc --keepParent "${APP}" "${STAGE}/${ZIP_NAME}"
printf '## Sideshot %s\n\n%s\n' "${TAG}" "${NOTES}" > "${STAGE}/Sideshot-${TAG}.md"

echo "==> Signing archive and writing appcast.xml"
"${SPARKLE_DIR}/bin/generate_appcast" "${STAGE}" \
  --download-url-prefix "https://github.com/${REPO}/releases/download/${TAG}/"

# The app polls releases/latest/download/appcast.xml, so every release MUST
# carry appcast.xml as an asset or every installed copy gets a 404.
echo "==> Publishing ${TAG}"
git tag -f "${TAG}" >/dev/null
git push -q origin "${TAG}" --force
gh release create "${TAG}" -R "${REPO}" \
  "${STAGE}/${ZIP_NAME}" "${STAGE}/appcast.xml" "${STAGE}/Sideshot-${TAG}.md" \
  --title "Sideshot ${TAG}" --notes "${NOTES}"

echo "==> Done. Installed copies will offer ${TAG} within a day, or immediately"
echo "    from the menu bar: Check for Updates…"
echo "    Feed: https://github.com/${REPO}/releases/latest/download/appcast.xml"
