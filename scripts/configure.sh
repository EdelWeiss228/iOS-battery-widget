#!/usr/bin/env bash
set -euo pipefail

if root=$(command git rev-parse --show-toplevel 2>/dev/null); then
    cd "$root"
else
    cd "$(dirname "$0")/.."
fi
prefix="${1:-${BUNDLE_ID_PREFIX:-}}"

if [[ -z "$prefix" ]]; then
    cat >&2 <<'USAGE'
Usage:
  ./scripts/configure.sh com.yourname
  BUNDLE_ID_PREFIX=com.yourname ./scripts/configure.sh

The prefix is used for bundle IDs, the App Group and the Keychain group.
Use a reverse-DNS prefix that you own. Do not put your Team ID or email in
project.yml; select your Team in Xcode instead.
USAGE
    exit 2
fi

if [[ ! "$prefix" =~ ^[A-Za-z][A-Za-z0-9.-]*$ ]] || [[ "$prefix" == *..* ]]; then
    echo "configure: invalid reverse-DNS prefix: $prefix" >&2
    exit 2
fi
if [[ "$prefix" == "com.example" ]]; then
    echo "configure: replace com.example with your own prefix" >&2
    exit 2
fi

perl -pi -e 's/^(\s*BUNDLE_ID_PREFIX:\s*).*$/${1}'"$prefix"'/' project.yml
echo "BUNDLE_ID_PREFIX set to: $prefix"
if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate
    echo "Xcode project regenerated."
else
    echo "xcodegen not found; run ./setup.sh after installing it."
fi
