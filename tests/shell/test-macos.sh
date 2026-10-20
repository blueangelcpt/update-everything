#!/usr/bin/env bash

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
FIXTURE="$REPO_ROOT/tests/fixtures/macos/softwareupdate-list.txt"

# shellcheck source=tests/shell/assertions.sh
. "$TEST_DIR/assertions.sh"
UPDATE_EVERYTHING_TESTING=1
export UPDATE_EVERYTHING_TESTING
# shellcheck source=macos/update-everything.sh
. "$REPO_ROOT/macos/update-everything.sh"

test_help_version_and_invalid_options() {
    local output status
    output="$(main --help 2>&1)"; status=$?
    assert_status 0 "$status" || return 1
    assert_contains "$output" '--dry-run' || return 1
    output="$(main --version 2>&1)"; status=$?
    assert_status 0 "$status" || return 1
    assert_contains "$output" '2.0.0' || return 1
    output="$(main --max-macos-major 0 2>&1)"; status=$?
    assert_status 2 "$status" || return 1
    output="$(main --system-only --skip-system-update 2>&1)"; status=$?
    assert_status 2 "$status" || return 1
    assert_contains "$output" 'cannot be used together'
}

test_platform_and_root_guards() {
    local output status
    run_system_command() { printf 'Linux\n'; }
    is_root() { return 1; }
    output="$(main --system-only 2>&1)"; status=$?
    assert_status 2 "$status" || return 1
    assert_contains "$output" 'supports macOS only' || return 1

    run_system_command() { printf 'Darwin\n'; }
    is_root() { return 0; }
    output="$(main --system-only 2>&1)"; status=$?
    assert_status 2 "$status" || return 1
    assert_contains "$output" 'normal user'
}

expect_decision() {
    local expected="$1" current="$2" target="$3" maximum="$4" allow="$5" oclp="$6"
    local status
    MACOS_MAJOR="$current"; MAX_MACOS_MAJOR="$maximum"
    ALLOW_MAJOR_UPGRADE="$allow"; OCLP_DETECTED="$oclp"
    should_install_update 'macOS Test' "$target" 'macOS Test label' >/dev/null
    status=$?
    assert_status "$expected" "$status"
}

test_release_decision_matrix() {
    expect_decision 0 15 15.7.1 25 0 0 || return 1
    expect_decision 0 26 26.1 25 0 0 || return 1
    expect_decision 1 15 26.0 25 1 0 || return 1
    expect_decision 1 15 16.0 25 0 0 || return 1
    expect_decision 0 15 16.0 25 1 0 || return 1
    expect_decision 1 15 16.0 25 1 1 || return 1
    expect_decision 1 15 14.7 25 1 0 || return 1

    MACOS_MAJOR=15; MAX_MACOS_MAJOR=25; ALLOW_MAJOR_UPGRADE=0; OCLP_DETECTED=1
    should_install_update 'Safari' '99.0' 'Safari label' >/dev/null || return 1
    should_install_update '' '' 'macOS malformed label' >/dev/null 2>&1
    assert_status 1 "$?"
}

test_oclp_detection_evidence() {
    oclp_path_exists() { [[ "$1" == '/Library/Application Support/Dortania' ]]; }
    oclp_nvram_present() { return 0; }
    oclp_device_tree_present() { return 0; }
    OCLP_DETECTED=0; OCLP_EVIDENCE=
    detect_oclp || return 1
    assert_equal 1 "$OCLP_DETECTED" || return 1
    assert_contains "$OCLP_EVIDENCE" '/Library/Application Support/Dortania' || return 1
    assert_contains "$OCLP_EVIDENCE" 'OCLP-Version NVRAM variable' || return 1
    assert_contains "$OCLP_EVIDENCE" 'OpenCore device tree entry'
}

test_softwareupdate_parser() {
    local records label title version action count
    records="$(parse_software_updates < "$FIXTURE")"
    count=0
    while IFS=$'\034' read -r label title version action; do
        count=$((count + 1))
        if (( count == 1 )); then
            assert_equal 'macOS Sequoia 15.7.1-24G231' "$label" || return 1
            assert_equal 'macOS Sequoia 15.7.1' "$title" || return 1
            assert_equal restart "$action" || return 1
        elif (( count == 2 )); then
            assert_equal 'Safari 18.6-18.6' "$label" || return 1
            assert_equal '' "$action" || return 1
        fi
    done <<EOF
$records
EOF
    assert_equal 3 "$count"
}

test_failed_install_does_not_set_restart_or_oclp_notice() {
    local output status
    list_software_updates() { cat "$FIXTURE"; }
    as_root() {
        case "$*" in
            *'macOS Sequoia'*) return 9 ;;
            *) return 0 ;;
        esac
    }
    MACOS_MAJOR=15; MAX_MACOS_MAJOR=25; ALLOW_MAJOR_UPGRADE=0
    ARCHITECTURE=x86_64; OCLP_DETECTED=1; DRY_RUN=0
    RESTART_REQUIRED=0; MACOS_UPDATE_INSTALLED=0; HELD_BACK=()
    output="$(update_macos 2>&1)"; status=$?
    assert_status 1 "$status" || return 1
    assert_equal 0 "$RESTART_REQUIRED" || return 1
    assert_equal 0 "$MACOS_UPDATE_INSTALLED" || return 1
    assert_contains "$output" 'Failed to install update'
}

test_successful_macos_install_sets_restart_and_oclp_notice() {
    local output
    list_software_updates() { cat "$FIXTURE"; }
    as_root() { return 0; }
    MACOS_MAJOR=15; MAX_MACOS_MAJOR=25; ALLOW_MAJOR_UPGRADE=0
    ARCHITECTURE=arm64; OCLP_DETECTED=1; OCLP_EVIDENCE='test evidence'
    DRY_RUN=0; RESTART_REQUIRED=0; MACOS_UPDATE_INSTALLED=0
    update_macos >/dev/null 2>&1 || return 1
    assert_equal 1 "$RESTART_REQUIRED" || return 1
    assert_equal 1 "$MACOS_UPDATE_INSTALLED" || return 1
    MACOS_NAME=macOS; MACOS_VERSION=15.7; HARDWARE_MODEL='Test Mac'
    SUCCEEDED=('macOS updates'); FAILED=(); SKIPPED=(); HELD_BACK=(); PLANNED=()
    output="$(print_summary 2>&1)"
    assert_contains "$output" 're-apply' || return 1
    assert_contains "$output" 'restart is required'
}

test_dry_run_never_marks_update_installed() {
    local output
    list_software_updates() { cat "$FIXTURE"; }
    is_root() { return 1; }
    DRY_RUN=1; PRIVILEGE_TOOL=/usr/bin/sudo; MACOS_MAJOR=15; MAX_MACOS_MAJOR=25
    ALLOW_MAJOR_UPGRADE=0; OCLP_DETECTED=0; ARCHITECTURE=x86_64
    RESTART_REQUIRED=0; MACOS_UPDATE_INSTALLED=0
    output="$(update_macos 2>&1)" || return 1
    assert_contains "$output" '[DRY-RUN]' || return 1
    assert_contains "$output" 'macOS\ Sequoia\ 15.7.1-24G231' || return 1
    assert_equal 0 "$RESTART_REQUIRED" || return 1
    assert_equal 0 "$MACOS_UPDATE_INSTALLED"
}

test_malformed_softwareupdate_output_fails_closed() {
    local output status
    list_software_updates() {
        printf 'Software Update found something in an unknown format\n'
    }
    output="$(update_macos 2>&1)"; status=$?
    assert_status 1 "$status" || return 1
    assert_contains "$output" 'could not be parsed safely' || return 1

    list_software_updates() { printf 'No new software available.\n'; }
    output="$(update_macos 2>&1)"; status=$?
    assert_status 0 "$status" || return 1
    assert_contains "$output" 'No macOS updates are available'
}

test_held_back_summary_and_failure_isolation() {
    local output
    # Invoked indirectly through run_task.
    # shellcheck disable=SC2317
    fail_manager() { return 4; }
    # Invoked indirectly through run_task.
    # shellcheck disable=SC2317
    pass_manager() { return 0; }
    DRY_RUN=0; FAILED=(); SUCCEEDED=(); SKIPPED=(); PLANNED=()
    HELD_BACK=('macOS update: future release (above maximum)')
    run_task 'first manager' fail_manager
    run_task 'second manager' pass_manager
    assert_equal 1 "${#FAILED[@]}" || return 1
    assert_equal 1 "${#SUCCEEDED[@]}" || return 1
    MACOS_NAME=macOS; MACOS_VERSION=15.7; HARDWARE_MODEL=; ARCHITECTURE=x86_64
    OCLP_DETECTED=0; RESTART_REQUIRED=0
    output="$(print_summary 2>&1)"
    assert_contains "$output" 'Held back:' || return 1
    assert_contains "$output" 'future release'
}

expect_interrupted_run() {
    local signal="$1" expected_status="$2"
    local output status
    INTERRUPT_SIGNAL="$signal"
    run_system_command() { printf 'Darwin\n'; }
    is_root() { return 1; }
    load_system_information() {
        MACOS_NAME=macOS; MACOS_VERSION=15.7; MACOS_MAJOR=15
        HARDWARE_MODEL='Test Mac'; ARCHITECTURE=arm64
    }
    select_privilege_tool() { PRIVILEGE_TOOL=/usr/bin/sudo; }
    detect_oclp() { return 1; }
    validate_privileges() { return 0; }
    # Invoked indirectly through main/run_task.
    # shellcheck disable=SC2317
    update_macos() { return 0; }
    have_command() { [[ "$1" == brew || "$1" == port ]]; }
    # shellcheck disable=SC2317
    update_homebrew() { signal_current_shell "$INTERRUPT_SIGNAL"; printf 'HOMEBREW-CONTINUED\n'; }
    # shellcheck disable=SC2317
    update_macports() { printf 'MACPORTS-STARTED\n'; }
    MAX_MACOS_MAJOR=25; OCLP_DETECTED=0; RESTART_REQUIRED=0; DRY_RUN=0
    SUCCEEDED=(); FAILED=(); SKIPPED=(); HELD_BACK=(); PLANNED=()

    output="$(main 2>&1)"; status=$?
    assert_status "$expected_status" "$status" || return 1
    assert_contains "$output" "Received SIG$signal" || return 1
    assert_contains "$output" '==> Summary' || return 1
    assert_contains "$output" '- macOS updates' || return 1
    assert_contains "$output" "Interrupted by SIG$signal:" || return 1
    assert_contains "$output" '- Homebrew formulae and casks (stopped while running' || return 1
    assert_not_contains "$output" 'HOMEBREW-CONTINUED' || return 1
    assert_not_contains "$output" 'MACPORTS-STARTED' || return 1
    assert_not_contains "$output" 'All detected package managers completed'
}

test_sigint_prints_summary_and_exits_130() {
    expect_interrupted_run INT 130
}

test_sigterm_prints_summary_and_exits_143() {
    expect_interrupted_run TERM 143
}

run_test 'help, version, invalid and conflicting options' test_help_version_and_invalid_options
run_test 'supported platform and root guards' test_platform_and_root_guards
run_test 'complete macOS/OCLP release decision matrix' test_release_decision_matrix
run_test 'OCLP filesystem, NVRAM, and device-tree evidence' test_oclp_detection_evidence
run_test 'softwareupdate parsing including empty fields' test_softwareupdate_parser
run_test 'failed installs do not set restart or OCLP state' test_failed_install_does_not_set_restart_or_oclp_notice
run_test 'successful macOS update sets restart and OCLP notice' test_successful_macos_install_sets_restart_and_oclp_notice
run_test 'dry run makes no installed/restart claims' test_dry_run_never_marks_update_installed
run_test 'malformed softwareupdate output fails closed' test_malformed_softwareupdate_output_fails_closed
run_test 'held-back summary and manager failure isolation' test_held_back_summary_and_failure_isolation
run_test 'SIGINT prints the summary and exits 130' test_sigint_prints_summary_and_exits_130
run_test 'SIGTERM prints the summary and exits 143' test_sigterm_prints_summary_and_exits_143

finish_tests
