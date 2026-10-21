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
