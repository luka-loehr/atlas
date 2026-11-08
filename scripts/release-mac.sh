#!/usr/bin/env bash
# release-mac.sh — publish the Mac app of a release, for its Sparkle updates.
#
#   scripts/release-mac.sh v0.6.0
#
# Archives the Mac app, signs it with the team's Developer ID, has Apple
# notarize it, staples the ticket, zips it, signs the zip with the Sparkle
# key and uploads the zip and a fresh appcast.xml to the GitHub release of
# that tag. The app's SUFeedURL points at the latest release's appcast.xml,
# so every installed copy finds the update within a day.
#
# Needs, once per Mac:
#   - a "Developer ID Application" certificate of the team in the keychain
#     (Xcode > Settings > Accounts > Manage Certificates)
#   - notarization credentials: xcrun notarytool store-credentials atlas-notary
#   - the Sparkle EdDSA private key in the keychain (generate_keys, run once;
#     its public half is SUPublicEDKey in app/Mac/Info.plist)
#   - gh, logged in; the release (the tag) must exist
#
# Environment: DEVELOPMENT_TEAM (required), NOTARY_PROFILE (atlas-notary).
set -euo pipefail

TAG=${1:?usage: release-mac.sh <tag, e.g. v0.6.0>}
TEAM=${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to your Apple team ID}
PROFILE=${NOTARY_PROFILE:-atlas-notary}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cd "$ROOT"
(cd app && xcodegen generate -q)

echo "› archive"
xcodebuild -project app/Atlas.xcodeproj -scheme Atlas -destination 'generic/platform=macOS' \
  -derivedDataPath build-mac -configuration Release -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" archive -archivePath "$WORK/Atlas.xcarchive" -quiet

echo "› sign with Developer ID"
cat > "$WORK/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$WORK/Atlas.xcarchive" -exportOptionsPlist "$WORK/export.plist" \
  -exportPath "$WORK/export" -allowProvisioningUpdates -quiet
APP="$WORK/export/Atlas.app"

echo "› notarize (a few minutes)"
ditto -c -k --keepParent "$APP" "$WORK/notarize.zip"
xcrun notarytool submit "$WORK/notarize.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"

VERSION=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)
mkdir -p "$WORK/updates"
ZIP="$WORK/updates/Atlas-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "› appcast"
BIN=build-mac/SourcePackages/artifacts/sparkle/Sparkle/bin
[ -x "$BIN/generate_appcast" ] || { echo "Sparkle's tools are missing: build the app once" >&2; exit 1; }
# the download links point at this release's assets
"$BIN/generate_appcast" --download-url-prefix "https://github.com/luka-loehr/atlas/releases/download/$TAG/" \
  --link "https://github.com/luka-loehr/atlas/releases/tag/$TAG" "$WORK/updates"

gh release upload "$TAG" "$ZIP" "$WORK/updates/appcast.xml" --clobber
echo "✓ Atlas $VERSION for Mac is on $TAG; installed copies update within a day"
