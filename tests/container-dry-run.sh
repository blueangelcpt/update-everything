#!/usr/bin/env bash
#
# Run linux/update-everything.sh --dry-run inside a disposable container of a
# real distribution and check that it detects the expected native manager.
#
# Usage: tests/container-dry-run.sh IMAGE EXPECTED_MANAGER [SETUP_COMMAND]
#
# The unit suites mock command discovery; this check exercises the genuine
# /etc/os-release and binary locations that a distribution image ships. It
# never performs a live update: the script runs only with --dry-run, and the
# container is disconnected from every network before the script starts.
#
# Test setup happens as root inside the throwaway container and never on the
# host: SETUP_COMMAND (for example, installing bash on an image without it) and
# the creation of an unprivileged user, because the script refuses to run as
# root. This is not a change to the project rule that the scripts never
# install package managers or change repositories on the user's machine.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
TEST_USER="updater"

if (( $# < 2 || $# > 3 )); then
    printf 'Usage: %s IMAGE EXPECTED_MANAGER [SETUP_COMMAND]\n' "${0##*/}" >&2
    exit 2
fi

image="$1"
expected_manager="$2"
setup_command="${3:-}"
container=""

fail() {
    printf 'not ok - %s: %s\n' "$image" "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$container" ]]; then
        docker rm --force "$container" >/dev/null 2>&1
    fi
}
trap cleanup EXIT

# `tail -f /dev/null` keeps the container alive on GNU and BusyBox userlands
# alike, so that setup and the dry run share one filesystem.
container="$(docker run --detach --volume "$REPO_ROOT:/src:ro" \
    "$image" tail -f /dev/null)" || fail "the container did not start"

if [[ -n "$setup_command" ]]; then
    printf '# setup: %s\n' "$setup_command"
    docker exec "$container" sh -c "$setup_command" ||
        fail "the setup command failed"
fi

# shellcheck disable=SC2016 # Expanded by the container's shell, not this one.
docker exec "$container" sh -c '
    if command -v useradd >/dev/null 2>&1; then
        useradd --create-home "$1"
    else
        adduser -D "$1"
    fi
' sh "$TEST_USER" || fail "the unprivileged user could not be created"

# From here on nothing can be downloaded, let alone installed.
docker network disconnect bridge "$container" ||
    fail "the container could not be disconnected from the network"

status=0
output="$(docker exec --user "$TEST_USER" --workdir "/home/$TEST_USER" \
    "$container" /src/linux/update-everything.sh --dry-run 2>&1)" || status=$?
printf '%s\n' "$output"

if (( status != 0 )); then
    fail "the dry run exited with status $status, expected 0"
fi

if ! grep -qxF "[INFO] Detected native system manager: $expected_manager" <<<"$output"; then
    fail "the native system manager was not detected as '$expected_manager'"
fi

if grep -qxF '[INFO] Detected distribution: Linux' <<<"$output"; then
    fail "/etc/os-release was not read; the distribution name fell back to 'Linux'"
fi

if ! grep -q '^\[DRY-RUN\] ' <<<"$output"; then
    fail "the dry run printed no planned command"
fi

if ! grep -qxF '[INFO] Dry run completed without executing mutating commands.' <<<"$output"; then
    fail "the dry run did not report completion"
fi

printf 'ok - %s: detected %s\n' "$image" "$expected_manager"
