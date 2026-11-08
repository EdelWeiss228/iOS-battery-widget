#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

echo "================================================"
echo "  BatteryWidget — Setup Script"
echo "================================================"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode is not selected. Install Xcode and run:"
  echo "  sudo xcode-select -s /Applications/Xcode.app"
  exit 1
fi

# 1. Install XcodeGen if not present
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "[1/4] Installing XcodeGen..."
  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew is required to install XcodeGen: https://brew.sh" >&2
    exit 1
  fi
  brew install xcodegen
else
  echo "[1/4] XcodeGen already installed"
fi

# 2. Optional one-place bundle prefix configuration.
if [[ -n "${BUNDLE_ID_PREFIX:-}" ]]; then
  echo "[2/4] Applying BUNDLE_ID_PREFIX=$BUNDLE_ID_PREFIX"
  ./scripts/configure.sh "$BUNDLE_ID_PREFIX"
else
  echo "[2/4] Using BUNDLE_ID_PREFIX from project.yml (default: com.example)"
  echo "      Set your own prefix with: ./scripts/configure.sh com.yourprefix"
fi

# 3. Safety check and Xcode project generation.
echo "[3/4] Checking for accidental personal data..."
./scripts/check-personal-data.sh

echo "[3/4] Generating Xcode project..."
xcodegen generate

if [[ -d .git && -d .githooks ]]; then
  git config core.hooksPath .githooks
fi

# 4. Open Xcode.
echo "[4/4] Opening in Xcode..."
open BatteryWidget.xcodeproj

echo ""
echo "Done."
echo ""
echo "Next steps in Xcode:"
echo " 1. Select your Team in Signing & Capabilities for all 4 targets"
echo " 2. Keychain Sharing group: \$(AppIdentifierPrefix)<your-prefix>.batterywidget.shared"
echo " 3. App Group: group.<your-prefix>.batterywidget"
echo " 4. Turn on iCloud Keychain on both Mac and iPhone and sign into the same Apple ID"
echo " 5. Build & Run BatteryWidgetApp on iPhone and BatteryMacApp on Mac"
echo ""
echo "Note: with a free Personal Team the macOS App Group container may not be"
echo "writable; BatteryWidget falls back to a local Keychain snapshot automatically."
