#!/usr/bin/env bash
#
# Run every safe shell test. No test installs, removes, or refreshes a package;
# the scripts under test are sourced with UPDATE_EVERYTHING_TESTING=1 so that
# their main function never runs on its own, and every mutating command is
# either replaced by a shell function or routed through the dry-run printer.
#
# Each suite runs under the same interpreter as this script, so that
# `/bin/bash tests/run-shell-tests.sh` on macOS really does exercise Apple's
# GNU Bash 3.2 rather than a newer bash found earlier on PATH.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHELL_UNDER_TEST="${BASH:-bash}"
status=0

printf '# interpreter: %s (%s)\n' "$SHELL_UNDER_TEST" "${BASH_VERSION:-unknown}"

"$SHELL_UNDER_TEST" "$TEST_DIR/shell/test-bash32-compat.sh" || status=1
"$SHELL_UNDER_TEST" "$TEST_DIR/shell/test-linux.sh" || status=1
"$SHELL_UNDER_TEST" "$TEST_DIR/shell/test-macos.sh" || status=1

exit "$status"
