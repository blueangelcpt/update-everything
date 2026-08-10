#!/usr/bin/env bash
#
# Fail if the repository-wide version drifts apart. Every script embeds the
# same Semantic Version, and the documents that quote it must agree.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"

status=0

report() {
    printf 'not ok - %s\n' "$*" >&2
    status=1
}

extract() {
    sed -n "$2" "$REPO_ROOT/$1" | head -n 1
}

linux_version="$(extract linux/update-everything.sh 's/^readonly SCRIPT_VERSION="\(.*\)"$/\1/p')"
macos_version="$(extract macos/update-everything.sh 's/^readonly SCRIPT_VERSION="\(.*\)"$/\1/p')"
windows_version="$(extract windows/update-everything.ps1 "s/^\\\$ScriptVersion = '\\(.*\\)'\$/\\1/p")"

if [[ ! "$linux_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    report "the Linux script has no readable Semantic Version (found '$linux_version')"
fi

for pair in "macOS:$macos_version" "Windows:$windows_version"; do
    if [[ "${pair#*:}" != "$linux_version" ]]; then
        report "${pair%%:*} version '${pair#*:}' does not match the Linux version '$linux_version'"
    fi
done

if [[ "$status" == 0 ]]; then
    for document in README.md CHANGELOG.md linux/README.md macos/README.md windows/README.md; do
        if ! grep -qF "$linux_version" "$REPO_ROOT/$document"; then
            report "$document does not mention version $linux_version"
        fi
    done
fi

if (( status )); then
    printf '1..1\nVersion consistency check failed.\n' >&2
    exit 1
fi

printf 'ok 1 - all scripts and documents use version %s\n1..1\n' "$linux_version"
