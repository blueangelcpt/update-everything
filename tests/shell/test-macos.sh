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
    assert_contains "$output" '2.1.0' || return 1
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
    local expected="$1" current="$2" target="$3" ceiling="$4" allow="$5" oclp="$6"
    local version="${7:-}" explicit="${8:-0}"
    local status
    MACOS_MAJOR="$current"; MAX_MACOS_MAJOR="$ceiling"
    ALLOW_MAJOR_UPGRADE="$allow"; OCLP_DETECTED="$oclp"
    OCLP_VERSION="$version"; MAX_MACOS_MAJOR_EXPLICIT="$explicit"
    should_install_update 'macOS Test' "$target" 'macOS Test label' >/dev/null
    status=$?
    assert_status "$expected" "$status"
}

test_release_decision_matrix() {
    # A Mac without OpenCore Legacy Patcher has no ceiling of any kind, so
    # only the major-upgrade switch and the downgrade guard apply.
    expect_decision 0 15 15.7.1 '' 0 0 || return 1
    expect_decision 0 26 26.1 '' 0 0 || return 1
    expect_decision 1 15 14.7 '' 1 0 || return 1
    expect_decision 1 15 26.0 '' 0 0 || return 1
    expect_decision 0 15 26.0 '' 1 0 || return 1
    expect_decision 0 15 27.0 '' 1 0 || return 1

    # OCLP 3.x supports macOS 26 Tahoe, but nothing newer.
    expect_decision 0 15 15.7.1 26 0 1 3.0.0 || return 1
    expect_decision 1 15 26.0 26 0 1 3.0.0 || return 1
    expect_decision 0 15 26.0 26 1 1 3.0.0 || return 1
    expect_decision 1 15 27.0 26 1 1 3.0.0 || return 1

    # OCLP 2.5.x and older stop at macOS 15 Sequoia.
    expect_decision 0 15 15.7.1 15 1 1 2.5.1 || return 1
    expect_decision 1 15 26.0 15 1 1 2.5.1 || return 1

    # An explicit --max-macos-major overrides what OCLP is known to support.
    expect_decision 1 15 27.0 26 1 1 3.0.0 1 || return 1
    expect_decision 0 15 27.0 27 1 1 3.0.0 1 || return 1

    MACOS_MAJOR=15; MAX_MACOS_MAJOR=26; ALLOW_MAJOR_UPGRADE=0; OCLP_DETECTED=1
    OCLP_VERSION=3.0.0; MAX_MACOS_MAJOR_EXPLICIT=0
    should_install_update 'Safari' '99.0' 'Safari label' >/dev/null || return 1
    should_install_update '' '' 'macOS malformed label' >/dev/null 2>&1
    assert_status 1 "$?"
}

test_held_back_reasons_name_the_real_limit() {
    local reason
    MACOS_MAJOR=15; MAX_MACOS_MAJOR=26; ALLOW_MAJOR_UPGRADE=1
    OCLP_DETECTED=1; OCLP_VERSION=3.0.0; MAX_MACOS_MAJOR_EXPLICIT=0
    reason="$(should_install_update 'macOS Next' 27.0 'macOS Next label')"
    assert_contains "$reason" 'OpenCore Legacy Patcher 3.0.0 supports macOS up to 26' || return 1

    OCLP_VERSION=
    reason="$(should_install_update 'macOS Next' 27.0 'macOS Next label')"
    assert_contains "$reason" 'version is unknown' || return 1

    MAX_MACOS_MAJOR_EXPLICIT=1
    reason="$(should_install_update 'macOS Next' 27.0 'macOS Next label')"
    assert_contains "$reason" 'configured maximum' || return 1

    # Without OCLP the reason never mentions it.
    OCLP_DETECTED=0; MAX_MACOS_MAJOR=; MAX_MACOS_MAJOR_EXPLICIT=0; ALLOW_MAJOR_UPGRADE=0
    reason="$(should_install_update 'macOS Next' 27.0 'macOS Next label')"
    assert_contains "$reason" 'needs --allow-major-upgrade' || return 1
    assert_not_contains "$reason" 'OpenCore'
}

test_ceiling_comes_from_the_oclp_version() {
    # No OCLP means no ceiling, whatever was there before.
    OCLP_DETECTED=0; OCLP_VERSION=; MAX_MACOS_MAJOR=99; MAX_MACOS_MAJOR_EXPLICIT=0
    resolve_macos_ceiling
    assert_equal '' "$MAX_MACOS_MAJOR" || return 1

    OCLP_DETECTED=1; OCLP_VERSION=3.0.0; MAX_MACOS_MAJOR=
    resolve_macos_ceiling
    assert_equal 26 "$MAX_MACOS_MAJOR" || return 1

    # An OCLP generation newer than the one verified here stays conservative.
    OCLP_VERSION=4.1.0; MAX_MACOS_MAJOR=
    resolve_macos_ceiling
    assert_equal 26 "$MAX_MACOS_MAJOR" || return 1

    OCLP_VERSION=2.5.1; MAX_MACOS_MAJOR=
    resolve_macos_ceiling
    assert_equal 15 "$MAX_MACOS_MAJOR" || return 1

    # An unreadable version is treated as an old one.
    OCLP_VERSION=; MAX_MACOS_MAJOR=
    resolve_macos_ceiling
    assert_equal 15 "$MAX_MACOS_MAJOR" || return 1

    OCLP_VERSION=2.5.1; MAX_MACOS_MAJOR=27; MAX_MACOS_MAJOR_EXPLICIT=1
    resolve_macos_ceiling
    assert_equal 27 "$MAX_MACOS_MAJOR"
}

test_oclp_version_is_read_from_the_best_source() {
    oclp_bundle_version() {
        [[ "$1" == '/Applications/OpenCore-Patcher.app' ]] || return 1
        printf '3.0.1\n'
    }
    OCLP_VERSION=; OCLP_VERSION_SOURCE=
    detect_oclp_version || return 1
    assert_equal 3.0.1 "$OCLP_VERSION" || return 1
    assert_equal '/Applications/OpenCore-Patcher.app' "$OCLP_VERSION_SOURCE" || return 1

    oclp_bundle_version() { return 1; }
    oclp_root_patch_version() { printf '  "OpenCore Legacy Patcher" => "2.5.1"\n'; }
    OCLP_VERSION=; OCLP_VERSION_SOURCE=
    detect_oclp_version || return 1
    assert_equal 2.5.1 "$OCLP_VERSION" || return 1

    oclp_root_patch_version() { return 1; }
    oclp_nvram_version() {
        printf '4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:OCLP-Version\t2.1.2\n'
    }
    OCLP_VERSION=; OCLP_VERSION_SOURCE=
    detect_oclp_version || return 1
    assert_equal 2.1.2 "$OCLP_VERSION" || return 1
    assert_contains "$OCLP_VERSION_SOURCE" 'NVRAM' || return 1

    oclp_nvram_version() { return 1; }
    OCLP_VERSION=; OCLP_VERSION_SOURCE=
    detect_oclp_version && return 1
    assert_equal '' "$OCLP_VERSION"
}

test_apple_silicon_never_looks_for_oclp() {
    # OCLP only ever runs on Intel, so every trace is ignored on arm64.
    oclp_path_exists() { return 0; }
    oclp_nvram_present() { return 0; }
    oclp_device_tree_present() { return 0; }
    ARCHITECTURE=arm64; OCLP_DETECTED=0; OCLP_EVIDENCE=
    detect_oclp && return 1
    assert_equal 0 "$OCLP_DETECTED" || return 1
    assert_equal '' "$OCLP_EVIDENCE"
}

test_without_oclp_nothing_mentions_it() {
    local output
    MACOS_NAME=macOS; MACOS_VERSION=27.0.1; HARDWARE_MODEL='Test Mac'
    ARCHITECTURE=arm64; OCLP_DETECTED=0; OCLP_VERSION=; OCLP_EVIDENCE=
    MAX_MACOS_MAJOR=; MAX_MACOS_MAJOR_EXPLICIT=0
    RESTART_REQUIRED=0; MACOS_UPDATE_INSTALLED=0
    SUCCEEDED=('macOS updates'); FAILED=(); SKIPPED=(); HELD_BACK=(); PLANNED=()
    output="$(print_summary 2>&1)"
    assert_not_contains "$output" 'OpenCore' || return 1
    assert_not_contains "$output" 'OCLP' || return 1
    assert_not_contains "$output" 'Ceiling' || return 1

    output="$(main --help 2>&1)"
    assert_not_contains "$output" 'OpenCore' || return 1
    assert_not_contains "$output" 'max-macos-major' || return 1

    # The ceiling is reported again as soon as one applies.
    OCLP_DETECTED=1; OCLP_VERSION=3.0.0; OCLP_EVIDENCE='test evidence'
    MAX_MACOS_MAJOR=26
    output="$(print_summary 2>&1)"
    assert_contains "$output" 'OpenCore Legacy Patcher: 3.0.0' || return 1
    assert_contains "$output" 'Ceiling for major upgrades: macOS 26' || return 1
    output="$(usage 2>&1)"
    assert_contains "$output" '--max-macos-major'
}

test_oclp_detection_evidence() {
    oclp_path_exists() { [[ "$1" == '/Library/Application Support/Dortania' ]]; }
    oclp_nvram_present() { return 0; }
    oclp_device_tree_present() { return 0; }
    ARCHITECTURE=x86_64; OCLP_DETECTED=0; OCLP_EVIDENCE=
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
    MACOS_MAJOR=15; MAX_MACOS_MAJOR=26; ALLOW_MAJOR_UPGRADE=0
    MAX_MACOS_MAJOR_EXPLICIT=0; ARCHITECTURE=x86_64
    OCLP_DETECTED=1; OCLP_VERSION=3.0.0; DRY_RUN=0
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
    MACOS_MAJOR=15; MAX_MACOS_MAJOR=26; ALLOW_MAJOR_UPGRADE=0
    MAX_MACOS_MAJOR_EXPLICIT=0; ARCHITECTURE=arm64
    OCLP_DETECTED=1; OCLP_VERSION=3.0.0; OCLP_EVIDENCE='test evidence'
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
    DRY_RUN=1; PRIVILEGE_TOOL=/usr/bin/sudo; MACOS_MAJOR=15; MAX_MACOS_MAJOR=
    MAX_MACOS_MAJOR_EXPLICIT=0; ALLOW_MAJOR_UPGRADE=0
    OCLP_DETECTED=0; OCLP_VERSION=; ARCHITECTURE=x86_64
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
    OCLP_DETECTED=0; OCLP_VERSION=; MAX_MACOS_MAJOR=; RESTART_REQUIRED=0
    output="$(print_summary 2>&1)"
    assert_contains "$output" 'Held back:' || return 1
    assert_contains "$output" 'future release'
}

run_test 'help, version, invalid and conflicting options' test_help_version_and_invalid_options
run_test 'supported platform and root guards' test_platform_and_root_guards
run_test 'complete macOS/OCLP release decision matrix' test_release_decision_matrix
run_test 'held-back reasons name the real limit' test_held_back_reasons_name_the_real_limit
run_test 'ceiling comes from the installed OCLP version' test_ceiling_comes_from_the_oclp_version
run_test 'OCLP version read from the best available source' test_oclp_version_is_read_from_the_best_source
run_test 'Apple silicon never looks for OCLP' test_apple_silicon_never_looks_for_oclp
run_test 'no OCLP means no OCLP or ceiling in the output' test_without_oclp_nothing_mentions_it
run_test 'OCLP filesystem, NVRAM, and device-tree evidence' test_oclp_detection_evidence
run_test 'softwareupdate parsing including empty fields' test_softwareupdate_parser
run_test 'failed installs do not set restart or OCLP state' test_failed_install_does_not_set_restart_or_oclp_notice
run_test 'successful macOS update sets restart and OCLP notice' test_successful_macos_install_sets_restart_and_oclp_notice
run_test 'dry run makes no installed/restart claims' test_dry_run_never_marks_update_installed
run_test 'malformed softwareupdate output fails closed' test_malformed_softwareupdate_output_fails_closed
run_test 'held-back summary and manager failure isolation' test_held_back_summary_and_failure_isolation

finish_tests
