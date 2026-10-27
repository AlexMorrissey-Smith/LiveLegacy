#!/bin/bash
# Builds LiveLegacy without xcodebuild, because current Xcode refuses deployment targets below iOS 15
# while the Swift compiler and linker still produce working iOS 12 binaries.
#
#   ./build.sh            device build (arm64, iOS 12.0), signed, plus build/LiveLegacy.ipa
#   ./build.sh sim        simulator build (iOS 15 target, for testing on a current simulator)
#   ./build.sh unsigned   device build with no signature, as build/LiveLegacy-unsigned.ipa for Sideloadly/AltStore
#
# Env: SIGN_ID (codesigning identity), PROFILE (path to a .mobileprovision covering the bundle ID and the iPad).
set -euo pipefail
cd "$(dirname "$0")"

MODE=${1:-device}
BUNDLE_ID=com.alexms.livelegacy
if [ "$MODE" = sim ]; then
  SDK=iphonesimulator; TARGET=arm64-apple-ios15.0-simulator; MIN=15.0; PLATFORM=iPhoneSimulator
else
  SDK=iphoneos; TARGET=arm64-apple-ios12.0; MIN=12.0; PLATFORM=iPhoneOS
fi
SDK_PATH=$(xcrun -sdk $SDK --show-sdk-path)
OUT=build/$MODE
APP=$OUT/LiveLegacy.app
rm -rf "$OUT"; mkdir -p "$APP"

xcrun -sdk $SDK swiftc -target $TARGET -sdk "$SDK_PATH" -O -swift-version 5 \
  -module-name LiveLegacy -parse-as-library LiveLegacy/*.swift -o "$APP/LiveLegacy"

xcrun ibtool --compile "$APP/LaunchScreen.storyboardc" LiveLegacy/LaunchScreen.storyboard \
  --minimum-deployment-target $MIN --target-device ipad

sed -e 's/$(EXECUTABLE_NAME)/LiveLegacy/; s/$(PRODUCT_NAME)/LiveLegacy/' \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/" LiveLegacy/Info.plist > "$APP/Info.plist"
P() { /usr/libexec/PlistBuddy -c "$1" "$APP/Info.plist"; }
P "Add :MinimumOSVersion string $MIN"
P "Add :UIDeviceFamily array"; P "Add :UIDeviceFamily:0 integer 2"
P "Add :CFBundleSupportedPlatforms array"; P "Add :CFBundleSupportedPlatforms:0 string $PLATFORM"
P "Add :DTPlatformName string $SDK"
P "Add :UIRequiredDeviceCapabilities array"; P "Add :UIRequiredDeviceCapabilities:0 string arm64"
plutil -convert binary1 "$APP/Info.plist"
printf 'APPL????' > "$APP/PkgInfo"

if [ "$MODE" = sim ]; then
  codesign -s - "$APP"
  echo "Built $APP"
  exit 0
fi

if [ "$MODE" = unsigned ]; then
  (cd "$OUT" && rm -rf Payload && mkdir Payload && cp -R LiveLegacy.app Payload/ \
    && rm -f ../LiveLegacy-unsigned.ipa && zip -qr ../LiveLegacy-unsigned.ipa Payload && rm -rf Payload)
  echo "Built build/LiveLegacy-unsigned.ipa"
  exit 0
fi

SIGN_ID=${SIGN_ID:-"Apple Development"}
PROFILE=${PROFILE:?Set PROFILE to a .mobileprovision that covers $BUNDLE_ID and the iPad}
cp "$PROFILE" "$APP/embedded.mobileprovision"
security cms -D -i "$PROFILE" > "$OUT/profile.plist"
TEAM=$(/usr/libexec/PlistBuddy -c "Print :TeamIdentifier:0" "$OUT/profile.plist")
cat > "$OUT/ent.plist" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>application-identifier</key><string>$TEAM.$BUNDLE_ID</string>
  <key>com.apple.developer.team-identifier</key><string>$TEAM</string>
  <key>get-task-allow</key><true/>
</dict></plist>
ENT
codesign -f -s "$SIGN_ID" --entitlements "$OUT/ent.plist" "$APP"
(cd "$OUT" && rm -rf Payload && mkdir Payload && cp -R LiveLegacy.app Payload/ && rm -f ../LiveLegacy.ipa && zip -qr ../LiveLegacy.ipa Payload && rm -rf Payload)
echo "Built $APP and build/LiveLegacy.ipa"
