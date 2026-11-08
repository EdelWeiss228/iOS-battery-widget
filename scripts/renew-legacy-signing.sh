#!/usr/bin/env bash
set -euo pipefail

# Renew the development signature of an app that must keep its old bundle ID,
# App Group and Keychain data. The actual legacy values are intentionally kept
# in an ignored local file (.local/legacy.env by default), never in Git.

if root=$(command git rev-parse --show-toplevel 2>/dev/null); then
    cd "$root"
else
    cd "$(dirname "$0")/.."
fi

config="${LEGACY_CONFIG:-$PWD/.local/legacy.env}"
if [[ -f "$config" ]]; then
    # shellcheck disable=SC1090
    source "$config"
fi

: "${LEGACY_BUNDLE_PREFIX:?Set LEGACY_BUNDLE_PREFIX in $config or the environment}"
: "${LEGACY_TEAM_ID:?Set LEGACY_TEAM_ID in $config or the environment}"
: "${LEGACY_DEVICE_UDID:?Set LEGACY_DEVICE_UDID in $config or the environment}"

scheme="${LEGACY_SCHEME:-BatteryWidgetApp}"
expected_app_id="${LEGACY_BUNDLE_PREFIX}.batterywidget"
launch_id="${LEGACY_LAUNCH_BUNDLE_ID:-$expected_app_id}"

if [[ ! "$LEGACY_BUNDLE_PREFIX" =~ ^[A-Za-z][A-Za-z0-9.-]*$ ]] || [[ "$LEGACY_BUNDLE_PREFIX" == *..* ]]; then
    echo "renew-legacy-signing: invalid legacy reverse-DNS prefix: $LEGACY_BUNDLE_PREFIX" >&2
    exit 2
fi
if [[ ! "$LEGACY_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "renew-legacy-signing: LEGACY_TEAM_ID must be a 10-character Team ID" >&2
    exit 2
fi

for tool in xcodebuild xcrun rsync perl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "renew-legacy-signing: required tool not found: $tool" >&2
        exit 2
    fi
done

if [[ ! -d BatteryWidget.xcodeproj ]]; then
    echo "renew-legacy-signing: BatteryWidget.xcodeproj is missing; run xcodegen generate first" >&2
    exit 2
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/batterywidget-renew.XXXXXX")
cleanup() {
    rm -rf "$tmp"
}
trap cleanup EXIT

echo "Copying project to a temporary directory..."
rsync -a \
    --exclude='.git' \
    --exclude='.local' \
    --exclude='DerivedData' \
    --exclude='build' \
    --exclude='.build' \
    --exclude='xcuserdata' \
    --exclude='*.xcuserstate' \
    --exclude='.DS_Store' \
    ./ "$tmp/"

# Hardcoded generic strings in Swift are the keychain service names, local
# snapshot service and widget kind. Replace them only in the throwaway copy so
# the existing legacy app keeps reading its old data.
find "$tmp/Shared" "$tmp/iOSWidget" "$tmp/macOSWidget" \
    -type f -name '*.swift' \
    -exec perl -pi -e "s/com\\.example/${LEGACY_BUNDLE_PREFIX}/g" {} +

echo "Building with legacy identifiers (developer data stays local)..."
build_log="$tmp/build.log"
if ! xcodebuild \
    -project "$tmp/BatteryWidget.xcodeproj" \
    -scheme "$scheme" \
    -configuration Debug \
    -destination "id=$LEGACY_DEVICE_UDID" \
    -derivedDataPath "$tmp/.derived" \
    DEVELOPMENT_TEAM="$LEGACY_TEAM_ID" \
    BUNDLE_ID_PREFIX="$LEGACY_BUNDLE_PREFIX" \
    CODE_SIGN_STYLE=Automatic \
    -allowProvisioningUpdates \
    build >"$build_log" 2>&1; then
    tail -n 100 "$build_log" >&2
    echo "renew-legacy-signing: build failed; log: $build_log" >&2
    exit 1
fi

app="$tmp/.derived/Build/Products/Debug-iphoneos/BatteryWidgetApp.app"
if [[ ! -d "$app" ]]; then
    echo "renew-legacy-signing: built app not found at $app" >&2
    exit 1
fi

actual_app_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
if [[ "$actual_app_id" != "$expected_app_id" ]]; then
    echo "renew-legacy-signing: unexpected app ID: $actual_app_id (expected $expected_app_id)" >&2
    exit 1
fi

echo "Installing $actual_app_id on the connected iPhone..."
xcrun devicectl device install app --device "$LEGACY_DEVICE_UDID" "$app"

if ! xcrun devicectl device process launch --device "$LEGACY_DEVICE_UDID" "$launch_id"; then
    echo "renew-legacy-signing: installed, but launch failed. Unlock the iPhone and check Developer Mode/trust." >&2
    exit 1
fi

if [[ -f "$app/embedded.mobileprovision" ]]; then
    security cms -D -i "$app/embedded.mobileprovision" > "$tmp/profile.plist" 2>/dev/null || true
    expires=$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$tmp/profile.plist" 2>/dev/null || true)
    if [[ -n "$expires" ]]; then
        echo "Provisioning profile expires: $expires"
    fi
fi

echo "Done: $actual_app_id installed and launched without changing the repository."
