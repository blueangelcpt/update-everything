#!/usr/bin/env bash

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
status=0

bash "$TEST_DIR/shell/test-linux.sh" || status=1
bash "$TEST_DIR/shell/test-macos.sh" || status=1

exit "$status"
