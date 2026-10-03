#!/bin/bash
# Builds build/Ap.app: the menu bar app plus the ap CLI, signed with a stable identity when one is available.
# Requires Swift 6 (Xcode or the Command Line Tools). No other dependencies.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product ApApp
swift build -c release --product ap
BIN="$(swift build -c release --show-bin-path)"

# Single source of the version (the release workflow rewrites Version.swift from the tag)
VERSION="$(sed -n 's/^let apVersion = "\(.*\)"$/\1/p' Sources/ap/Version.swift)"
SHORT_VERSION="${VERSION%%-*}"

APP="build/Ap.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
sed -e "s/__SHORT_VERSION__/$SHORT_VERSION/" -e "s/__VERSION__/$VERSION/" packaging/Info.plist > "$APP/Contents/Info.plist"
# The app executable is ApApp, not Ap: on a case-insensitive volume "Ap" and the bundled "ap" CLI would be the same file
cp "$BIN/ApApp" "$APP/Contents/MacOS/ApApp"
cp "$BIN/ap" "$APP/Contents/MacOS/ap"
# UI strings (en, ja). Copied by hand rather than as SwiftPM resources: Bundle.module looks for a resource bundle next
# to the executable's build directory, which a hand-assembled .app doesn't have. Bundle.main finds these
cp -R packaging/Resources/*.lproj "$APP/Contents/Resources/"

# macOS keys the Accessibility grant on the code signature's designated requirement. An ad-hoc signature's
# requirement is the cdhash, so every rebuild is a new app and the grant is lost. A stable signing identity (even an
# untrusted self-signed one) keeps the requirement, and the grant, across rebuilds. Try AP_SIGN_IDENTITY, then
# "ap-dev", then "shepherd-dev", and fall back to ad hoc. codesign is tried directly instead of checking
# `security find-identity -v`, which hides untrusted self-signed certificates that codesign can still use.
# AP_SIGN_IDENTITY=- forces ad hoc (e.g. on CI, where there is no certificate)
SIGNED_WITH=""
for IDENTITY in ${AP_SIGN_IDENTITY:+"$AP_SIGN_IDENTITY"} ap-dev shepherd-dev; do
  [ "$IDENTITY" = "-" ] && break
  # Inner binary first, then the bundle
  if codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/ap" 2>/dev/null \
    && codesign --force --sign "$IDENTITY" "$APP" 2>/dev/null; then
    SIGNED_WITH="$IDENTITY"
    break
  fi
done
if [ -n "$SIGNED_WITH" ]; then
  echo "signed: $SIGNED_WITH"
else
  codesign --force --sign - "$APP/Contents/MacOS/ap"
  codesign --force --sign - "$APP"
  echo "signed: ad hoc. The Accessibility grant will not survive a rebuild. To keep it, create a code signing"
  echo "  certificate named ap-dev once (Keychain Access > Certificate Assistant > Create a Certificate:"
  echo "  Self Signed Root, type Code Signing) or set AP_SIGN_IDENTITY to an existing identity"
fi
echo "built: $(pwd)/$APP ($VERSION)"
