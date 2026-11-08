#!/usr/bin/env bash
set -euo pipefail

if root=$(command git rev-parse --show-toplevel 2>/dev/null); then
    cd "$root"
else
    cd "$(dirname "$0")/.."
fi

status=0
report() {
    printf 'personal-data check: %s\n' "$1" >&2
    status=1
}

# Generated Xcode state must never be committed.
if command git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if git ls-files | grep -E '(^|/)(xcuserdata|DerivedData)/|\.xcuserstate$'; then
        report 'tracked Xcode user state/DerivedData'
    fi

    # Scan tracked text for local paths, personal-mail domains and common
    # credential formats. The template itself uses only example.com names.
    if git grep -n -I -E \
        '/Users/|/home/|@gmail\.com|@icloud\.com|@me\.com|@yahoo\.com|ghp_|github_pat_|AKIA|-----BEGIN|DEVELOPMENT_TEAM[[:space:]]*[:=][[:space:]]*"?[A-Z0-9]{10}"?' \
        -- . ':(exclude)scripts/check-personal-data.sh'; then
        report 'suspicious personal/credential pattern in tracked files'
    fi

    if git ls-files | grep -E '\.(p12|pem|key|mobileprovision|provisionprofile|env)$|(^|/)\.env'; then
        report 'tracked credential/profile file'
    fi
else
    # A downloaded ZIP has no Git metadata and therefore no commits to leak.
    printf 'personal-data check: skipped (not a Git work tree)\n'
    exit 0
fi

if (( status == 0 )); then
    printf 'personal-data check: OK\n'
else
    printf 'personal-data check: remove the listed data before committing\n' >&2
fi
exit "$status"
