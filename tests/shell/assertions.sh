#!/usr/bin/env bash

TESTS_RUN=0
TESTS_FAILED=0

fail() {
    printf '    %s\n' "$*" >&2
    return 1
}

assert_status() {
    local expected="$1"
    local actual="$2"
    [[ "$actual" == "$expected" ]] || fail "expected status $expected, got $actual"
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    [[ "$actual" == "$expected" ]] || fail "expected '$expected', got '$actual'"
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    [[ "$haystack" != *"$needle"* ]] || fail "expected output not to contain: $needle"
}

# Send a signal to the shell that is running main. That shell is a command
# substitution, so $$ would name the test runner instead; the parent of an
# exec'd child is the current shell even under Bash 3.2, which has no BASHPID.
signal_current_shell() {
    kill "-$1" "$(exec sh -c 'printf "%s" "$PPID"')"
}

run_test() {
    local name="$1"
    local test_function="$2"
    TESTS_RUN=$((TESTS_RUN + 1))

    if ( "$test_function" ); then
        printf 'ok %d - %s\n' "$TESTS_RUN" "$name"
    else
        printf 'not ok %d - %s\n' "$TESTS_RUN" "$name"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

finish_tests() {
    printf '1..%d\n' "$TESTS_RUN"
    if (( TESTS_FAILED )); then
        printf '%d test(s) failed.\n' "$TESTS_FAILED" >&2
        return 1
    fi
    printf 'All %d tests passed.\n' "$TESTS_RUN"
}

# Replace each non-ASCII banner character with one ASCII character, so that
# column positions and line lengths can be compared byte for byte whatever the
# locale of the test run.
banner_layout() {
    sed -e 's/│/|/g' -e 's/●/o/g' -e 's/·/./g'
}

# Count the bytes outside 7-bit ASCII.
non_ascii_bytes() {
    printf '%s' "$1" | LC_ALL=C tr -d '\000-\177' | wc -c | tr -d ' '
}

# Shared by the Linux and macOS suites: both scripts embed the same banner.
# Run inside run_test's subshell, so the stubs do not leak.
check_start_up_banner() {
    local subtitle="$1"
    local output plain columns long_lines

    # shellcheck disable=SC2317
    banner_locale_is_utf8() { return 0; }

    output="$(COLUMNS=100 print_banner "$subtitle" 'dry run')"
    assert_contains "$output" "│ Update Everything $SCRIPT_VERSION" || return 1
    assert_contains "$output" '│ Everything, carefully.' || return 1
    assert_contains "$output" "│ $subtitle · dry run" || return 1
    assert_contains "$output" '      @@@@%%%%@@@@@@=@@@@@@@@@@@@@' || return 1
    assert_not_contains "$output" $'\033' || return 1
    assert_equal 22 "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" || return 1
    columns="$(printf '%s\n' "$output" | banner_layout | awk 'index($0, "|") { print index($0, "|") }' | sort -u)"
    assert_equal 44 "$columns" || return 1
    plain="$output"

    # shellcheck disable=SC2317
    banner_uses_color() { return 0; }
    output="$(COLUMNS=100 print_banner "$subtitle" 'dry run')"
    assert_contains "$output" $'\033[0m' || return 1
    assert_equal "$plain" "$(printf '%s\n' "$output" | sed $'s/\033\\[[0-9;]*m//g')" || return 1
    # shellcheck disable=SC2317
    banner_uses_color() { return 1; }

    output="$(COLUMNS=72 print_banner "$subtitle with a name long enough to need shortening" 'dry run')"
    assert_contains "$output" '...' || return 1
    long_lines="$(printf '%s\n' "$output" | banner_layout | awk 'length > 71')"
    assert_equal '' "$long_lines" || return 1

    output="$(COLUMNS=71 print_banner "$subtitle")"
    assert_contains "$output" "● Update Everything $SCRIPT_VERSION" || return 1
    assert_contains "$output" "  $subtitle" || return 1
    assert_not_contains "$output" '│' || return 1

    output="$(COLUMNS=40 print_banner "$subtitle with a name long enough to need shortening" 'dry run')"
    assert_equal '...' "$(printf '%s\n' "$output" | tail -n 1 | tail -c 4)" || return 1
    assert_equal 39 "$(printf '%s\n' "$output" | tail -n 1 | banner_layout | awk '{ print length }')" || return 1

    # shellcheck disable=SC2317
    banner_locale_is_utf8() { return 1; }
    output="$(COLUMNS=100 print_banner "$subtitle" 'dry run')"
    assert_contains "$output" "| Update Everything $SCRIPT_VERSION" || return 1
    assert_contains "$output" "| $subtitle - dry run" || return 1
    assert_equal 0 "$(non_ascii_bytes "$output")" || return 1

    output="$(COLUMNS=71 print_banner "$subtitle" 'dry run')"
    assert_equal "[ok] Update Everything $SCRIPT_VERSION - Everything, carefully.
     $subtitle - dry run" "$output" || return 1

    output="$(COLUMNS=40 print_banner "$subtitle with a name long enough to need shortening" 'dry run')"
    assert_equal '...' "$(printf '%s\n' "$output" | tail -n 1 | tail -c 4)" || return 1
    assert_equal 39 "$(printf '%s\n' "$output" | tail -n 1 | awk '{ print length }')" || return 1
}
