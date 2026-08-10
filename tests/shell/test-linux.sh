#!/usr/bin/env bash

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"

# shellcheck source=tests/shell/assertions.sh
. "$TEST_DIR/assertions.sh"
UPDATE_EVERYTHING_TESTING=1
export UPDATE_EVERYTHING_TESTING
# shellcheck source=linux/update-everything.sh
. "$REPO_ROOT/linux/update-everything.sh"

test_help_and_version() {
    local output status
    output="$(main --help 2>&1)"; status=$?
    assert_status 0 "$status" || return 1
    assert_contains "$output" 'Usage:' || return 1
    assert_contains "$output" '--dry-run' || return 1

    output="$(main --version 2>&1)"; status=$?
    assert_status 0 "$status" || return 1
    assert_contains "$output" '2.0.0'
}

test_invalid_option_and_platform() {
    local output status
    output="$(main --not-an-option 2>&1)"; status=$?
    assert_status 2 "$status" || return 1
    assert_contains "$output" 'Unknown option' || return 1

    uname() { printf 'Darwin\n'; }
    is_root() { return 1; }
    output="$(main --system-only 2>&1)"; status=$?
    assert_status 2 "$status" || return 1
    assert_contains "$output" 'supports Linux only'
}

test_root_execution_is_refused() {
    local output status
    uname() { printf 'Linux\n'; }
    is_root() { return 0; }
    output="$(main --system-only 2>&1)"; status=$?
    assert_status 2 "$status" || return 1
    assert_contains "$output" 'normal user'
}

test_distribution_mapping_and_fallback() {
    local AVAILABLE id like command expected
    have_system_command() { [[ ":$AVAILABLE:" == *":$1:"* ]]; }
    is_ostree_system() { return 1; }
    is_nixos_system() { return 1; }
    is_transactional_system() { return 1; }

    while IFS='|' read -r id like command expected; do
        OS_ID="$id"; OS_ID_LIKE="$like"; AVAILABLE="$command"; SYSTEM_MANAGER=
        detect_system_manager || return 1
        assert_equal "$expected" "$SYSTEM_MANAGER" || return 1
    done <<'EOF'
ubuntu|debian|apt-get|apt
fedora||dnf5:dnf:yum|dnf5
rocky|rhel centos|dnf|dnf
opensuse-tumbleweed|suse|zypper|zypper
arch||pacman|pacman
alpine||apk|apk
void||xbps-install|xbps
gentoo||emerge|emerge
solus||eopkg|eopkg
clear-linux-os||swupd|swupd
slackware||slackpkg|slackpkg
mageia||urpmi|urpmi
EOF

    OS_ID=unknown; OS_ID_LIKE=; AVAILABLE='dnf:apt-get'; SYSTEM_MANAGER=
    detect_system_manager || return 1
    assert_equal apt "$SYSTEM_MANAGER"
}

test_immutable_system_precedence() {
    have_system_command() { return 0; }
    is_ostree_system() { return 0; }
    is_nixos_system() { return 0; }
    is_transactional_system() { return 0; }
    OS_ID=fedora; OS_ID_LIKE=; SYSTEM_MANAGER=
    detect_system_manager || return 1
    assert_equal rpm-ostree "$SYSTEM_MANAGER" || return 1

    is_ostree_system() { return 1; }
    SYSTEM_MANAGER=; detect_system_manager || return 1
    assert_equal nixos "$SYSTEM_MANAGER" || return 1

    is_nixos_system() { return 1; }
    SYSTEM_MANAGER=; detect_system_manager || return 1
    assert_equal transactional-update "$SYSTEM_MANAGER"
}

test_all_native_manager_dispatch_paths() {
    local manager
    called=
    # Invoked indirectly through update_system_packages.
    # shellcheck disable=SC2317
    update_apt() { called=apt; }
    # shellcheck disable=SC2317
    update_dnf5() { called=dnf5; }
    # shellcheck disable=SC2317
    update_dnf() { called=dnf; }
    # shellcheck disable=SC2317
    update_yum() { called=yum; }
    # shellcheck disable=SC2317
    update_zypper() { called=zypper; }
    # shellcheck disable=SC2317
    update_transactional() { called=transactional-update; }
    # shellcheck disable=SC2317
    update_pacman() { called=pacman; }
    # shellcheck disable=SC2317
    update_apk() { called=apk; }
    # shellcheck disable=SC2317
    update_xbps() { called=xbps; }
    # shellcheck disable=SC2317
    update_emerge() { called=emerge; }
    # shellcheck disable=SC2317
    update_eopkg() { called=eopkg; }
    # shellcheck disable=SC2317
    update_swupd() { called=swupd; }
    # shellcheck disable=SC2317
    update_rpm_ostree() { called=rpm-ostree; }
    # shellcheck disable=SC2317
    update_nixos() { called=nixos; }
    # shellcheck disable=SC2317
    update_slackpkg() { called=slackpkg; }
    # shellcheck disable=SC2317
    update_urpmi() { called=urpmi; }

    for manager in apt dnf5 dnf yum zypper transactional-update pacman apk xbps emerge eopkg swupd rpm-ostree nixos slackpkg urpmi; do
        SYSTEM_MANAGER="$manager"; called=
        update_system_packages || return 1
        assert_equal "$manager" "$called" || return 1
    done
}

test_privilege_tool_selection() {
    is_root() { return 1; }
    find_system_command() { [[ "$1" == sudo ]] && printf '/usr/bin/sudo\n'; }
    PRIVILEGE_TOOL=
    select_privilege_tool
    assert_equal /usr/bin/sudo "$PRIVILEGE_TOOL" || return 1

    find_system_command() { [[ "$1" == doas ]] && printf '/usr/bin/doas\n'; }
    select_privilege_tool
    assert_equal /usr/bin/doas "$PRIVILEGE_TOOL" || return 1

    find_system_command() { return 1; }
    select_privilege_tool
    assert_equal unavailable "$PRIVILEGE_TOOL"
}

test_apt_cleanup_and_safe_upgrade() {
    local output
    DRY_RUN=1; DO_CLEANUP=0; PRIVILEGE_TOOL=/usr/bin/sudo
    is_root() { return 1; }
    output="$(update_apt 2>&1)" || return 1
    assert_contains "$output" 'Always-Include-Phased-Updates=true' || return 1
    assert_contains "$output" 'upgrade --with-new-pkgs -y' || return 1
    assert_not_contains "$output" 'autoremove' || return 1
    assert_not_contains "$output" 'apt-get clean' || return 1

    DO_CLEANUP=1
    output="$(update_apt 2>&1)" || return 1
    assert_contains "$output" 'autoremove -y' || return 1
    assert_contains "$output" 'apt-get clean'
}

test_no_cleanup_disables_homebrew_automatic_cleanup() {
    local output
    is_root() { return 1; }
    DRY_RUN=1; DO_CLEANUP=0
    output="$(update_homebrew 2>&1)" || return 1
    assert_contains "$output" 'HOMEBREW_NO_INSTALL_CLEANUP=1' || return 1
    assert_not_contains "$output" 'brew cleanup'
}

test_flatpak_inventory_failure_is_reported_but_other_scope_continues() {
    local output status
    flatpak() {
        if [[ "$1" == remote-list && "$2" == --user ]]; then
            printf 'user inventory failed\n'
            return 6
        fi
        if [[ "$1" == remote-list && "$2" == --system ]]; then
            printf 'system-remote\n'
            return 0
        fi
        return 0
    }
    is_root() { return 1; }
    find_system_command() { printf '/usr/bin/%s\n' "$1"; }
    DRY_RUN=1; DO_CLEANUP=0; PRIVILEGE_TOOL=/usr/bin/sudo
    output="$(update_flatpak 2>&1)"; status=$?
    assert_status 1 "$status" || return 1
    assert_contains "$output" 'Unable to inspect the Flatpak user installation' || return 1
    assert_contains "$output" 'update --system'
}

test_failure_isolation_and_accounting() {
    # Invoked indirectly through run_task.
    # shellcheck disable=SC2317
    fail_manager() { return 7; }
    # Invoked indirectly through run_task.
    # shellcheck disable=SC2317
    pass_manager() { return 0; }
    DRY_RUN=0; FAILED=(); SUCCEEDED=()
    run_task 'failing updater' fail_manager
    run_task 'working updater' pass_manager
    assert_equal 1 "${#FAILED[@]}" || return 1
    assert_equal 1 "${#SUCCEEDED[@]}" || return 1
    assert_contains "${FAILED[0]}" 'exit 7'
}

test_exit_codes_zero_and_one() {
    local status output
    uname() { printf 'Linux\n'; }
    is_root() { return 1; }
    load_os_release() { DISTRO_NAME='Test Linux'; }
    select_privilege_tool() { PRIVILEGE_TOOL=sudo; }
    validate_privileges() { return 0; }
    detect_system_manager() { SYSTEM_MANAGER=apt; return 0; }
    # Invoked indirectly through main/run_task.
    # shellcheck disable=SC2317
    update_system_packages() { return 0; }
    FAILED=(); SUCCEEDED=(); SKIPPED=(); PLANNED=()
    output="$(main --system-only --dry-run 2>&1)"; status=$?
    assert_status 0 "$status" || return 1
    assert_contains "$output" 'Dry run completed' || return 1

    detect_system_manager() { return 1; }
    FAILED=(); SUCCEEDED=(); SKIPPED=(); PLANNED=(); DRY_RUN=0
    output="$(main --system-only 2>&1)"; status=$?
    assert_status 1 "$status" || return 1
    assert_contains "$output" 'no supported native package manager'
}

test_restart_and_quoted_dry_run_output() {
    local output
    DISTRO_NAME='Test Linux'; SYSTEM_MANAGER=rpm-ostree
    SUCCEEDED=(); FAILED=(); SKIPPED=(); PLANNED=()
    output="$(print_summary 2>&1)"
    if [[ "$output" != *'Reboot to activate'* && "$output" != *'A system reboot is required'* ]]; then
        fail 'expected a reboot notice for rpm-ostree' || return 1
    fi

    output="$(print_command '/tmp/a path/tool' 'label;with punctuation' 2>&1)"
    assert_contains "$output" '/tmp/a\ path/tool' || return 1
    assert_contains "$output" 'label\;with\ punctuation'
}

run_test 'help and version output' test_help_and_version
run_test 'invalid option and unsupported platform' test_invalid_option_and_platform
run_test 'whole-script root execution is refused' test_root_execution_is_refused
run_test 'distribution mapping and fallback' test_distribution_mapping_and_fallback
run_test 'immutable-system precedence' test_immutable_system_precedence
run_test 'all native manager dispatch paths' test_all_native_manager_dispatch_paths
run_test 'sudo and doas selection' test_privilege_tool_selection
run_test 'APT cleanup toggle and non-removing upgrade' test_apt_cleanup_and_safe_upgrade
run_test 'no-cleanup also disables Homebrew automatic cleanup' test_no_cleanup_disables_homebrew_automatic_cleanup
run_test 'Flatpak inventory errors preserve other-scope execution' test_flatpak_inventory_failure_is_reported_but_other_scope_continues
run_test 'updater failure isolation and accounting' test_failure_isolation_and_accounting
run_test 'process exit codes zero and one' test_exit_codes_zero_and_one
run_test 'restart notice and quoted paths' test_restart_and_quoted_dry_run_output

finish_tests
