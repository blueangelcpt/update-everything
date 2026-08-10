#!/usr/bin/env bash
#
# Static check that the macOS script stays within the GNU Bash 3.2 that Apple
# ships at /bin/bash. CI also runs the whole suite under that interpreter on a
# macOS runner, but this check gives the same protection on a machine that has
# no Bash 3.2 available, which is every Linux developer machine.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"

# shellcheck source=tests/shell/assertions.sh
. "$TEST_DIR/assertions.sh"

MACOS_SCRIPT="$REPO_ROOT/macos/update-everything.sh"

# Constructs that GNU Bash 3.2 does not understand. Each entry is a
# description, an extended regular expression, and the files it applies to.
assert_absent() {
    local description="$1"
    local pattern="$2"
    local file="$3"
    local matches

    matches="$(grep -nE "$pattern" "$file" || true)"
    if [[ -n "$matches" ]]; then
        fail "$description found in ${file##*/}:"
        printf '      %s\n' "$matches" >&2
        return 1
    fi
}

test_macos_script_avoids_post_32_features() {
    assert_absent 'associative array declaration' '(^|[[:space:]])(declare|local|typeset)[[:space:]]+-[A-Za-z]*A' "$MACOS_SCRIPT" || return 1
    assert_absent 'mapfile or readarray' '(^|[^[:alnum:]_])(mapfile|readarray)([^[:alnum:]_]|$)' "$MACOS_SCRIPT" || return 1
    assert_absent 'case conversion expansion' '\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(\^\^|,,|\^|,)' "$MACOS_SCRIPT" || return 1
    assert_absent 'nameref declaration' '(^|[[:space:]])(declare|local|typeset)[[:space:]]+-[A-Za-z]*n([[:space:]]|$)' "$MACOS_SCRIPT" || return 1
    assert_absent '[[ -v ]] test' '\[\[[^]]*-v[[:space:]]' "$MACOS_SCRIPT" || return 1
    assert_absent ';;& case terminator' ';;&' "$MACOS_SCRIPT" || return 1
    assert_absent '&>> redirection' '&>>' "$MACOS_SCRIPT" || return 1
    assert_absent 'globstar option' 'shopt[[:space:]]+-[su][[:space:]]+globstar' "$MACOS_SCRIPT" || return 1
    assert_absent 'coproc keyword' '(^|[[:space:]])coproc([[:space:]]|$)' "$MACOS_SCRIPT" || return 1
    assert_absent 'EPOCHSECONDS or BASH_ARGV0' '(EPOCHSECONDS|EPOCHREALTIME|BASH_ARGV0)' "$MACOS_SCRIPT"
}

# Bash before 4.4 treats "${array[@]}" as an unbound variable under `set -u`
# when the array is empty, so every such expansion has to sit behind an
# element-count guard. This catches the expansions that are not guarded on the
# same line or by an enclosing `if ((${#name[@]}))`.
test_empty_array_expansions_are_guarded() {
    local script line_number line name guard_found
    local unguarded=""

    for script in "$MACOS_SCRIPT" "$REPO_ROOT/linux/update-everything.sh"; do
        while IFS=: read -r line_number line; do
            [[ -n "$line_number" ]] || continue
            name="$(printf '%s\n' "$line" | sed -n 's/.*"\${\([A-Za-z_][A-Za-z0-9_]*\)\[@\]}".*/\1/p')"
            [[ -n "$name" ]] || continue

            # Accept the expansion when the same function guards it with a
            # count test somewhere in the preceding twenty lines.
            guard_found="$(sed -n "$(( line_number > 20 ? line_number - 20 : 1 )),${line_number}p" "$script" |
                grep -cE "#\{$name\[@\]\}|\\\$\{#$name\[@\]\}" || true)"
            if [[ "$guard_found" == "0" ]]; then
                unguarded="$unguarded${script##*/}:$line_number: $line"$'\n'
            fi
        done < <(grep -nE '"\$\{[A-Za-z_][A-Za-z0-9_]*\[@\]\}"' "$script" || true)
    done

    if [[ -n "$unguarded" ]]; then
        fail "unguarded empty-array expansion (breaks under set -u before Bash 4.4):"
        printf '      %s\n' "$unguarded" >&2
        return 1
    fi
}

test_macos_script_declares_the_apple_interpreter() {
    local first_line
    IFS= read -r first_line < "$MACOS_SCRIPT"
    assert_equal '#!/usr/bin/env bash' "$first_line"
}

run_test 'macOS script avoids post-3.2 Bash features' test_macos_script_avoids_post_32_features
run_test 'empty array expansions are guarded for Bash 3.2 set -u' test_empty_array_expansions_are_guarded
run_test 'macOS script keeps a portable interpreter line' test_macos_script_declares_the_apple_interpreter

finish_tests
