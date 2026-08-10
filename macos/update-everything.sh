#!/usr/bin/env bash
# update-everything.sh
#
# Update macOS and the supported application managers installed on the
# machine, without installing an unsupported major macOS release.
#
# Supported system updater:
#   softwareupdate, which covers macOS updates, Safari, and the Xcode
#   Command Line Tools.
#
# Supported additional managers:
#   mas (Mac App Store), Homebrew formulae and casks, MacPorts, and Nix.
#
# Major macOS upgrades are never installed by default, and no macOS release
# newer than MAX_MACOS_MAJOR is installed at all. On a Mac running
# OpenCore Legacy Patcher, a major upgrade is refused outright, because it
# must be planned through OCLP rather than applied automatically.
#
# This script intentionally does not update project or language dependencies
# such as Composer, npm project packages, pip environments, Cargo projects,
# or application-specific self-updaters.
#
# macOS ships GNU bash 3.2, so this script avoids later bash features.

set -uo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="2.0.0"
readonly SYSTEM_COMMAND_PATH="/usr/sbin:/usr/bin:/sbin:/bin:/opt/local/sbin:/opt/local/bin"

# Major upgrades to macOS 26 and later are not supported by default. Raise this
# only when the newer release has been verified on the machines it will run on.
DEFAULT_MAX_MACOS_MAJOR=25

DO_CLEANUP=1
DO_ADDITIONAL_MANAGERS=1
DO_SYSTEM_UPDATE=1
DO_GREEDY_CASKS=0
ALLOW_MAJOR_UPGRADE=0
MAX_MACOS_MAJOR="$DEFAULT_MAX_MACOS_MAJOR"
DRY_RUN=0

MACOS_VERSION=""
MACOS_MAJOR=""
MACOS_NAME="macOS"
HARDWARE_MODEL=""
ARCHITECTURE=""

OCLP_DETECTED=0
OCLP_EVIDENCE=""

MACOS_UPDATE_INSTALLED=0
RESTART_REQUIRED=0

PRIVILEGE_TOOL=""

SUCCEEDED=()
FAILED=()
SKIPPED=()
HELD_BACK=()
PLANNED=()

usage() {
    cat <<USAGE
Usage: $SCRIPT_NAME [options]

Install available macOS updates, then update the supported application
managers that are present on this Mac.

Options:
  --system-only            Update only macOS itself.
  --skip-system-update     Update only the additional managers.
  --no-cleanup             Do not remove cached downloads or unused packages.
  --greedy-casks           Also upgrade Homebrew casks that update themselves.
  --allow-major-upgrade    Permit an upgrade to a newer major macOS release,
                           up to the supported maximum. Refused on a Mac
                           running OpenCore Legacy Patcher.
  --max-macos-major N      Highest target for a major macOS upgrade
                           (default: $DEFAULT_MAX_MACOS_MAJOR).
  --dry-run                List and evaluate updates, but do not install or
                           clean up anything.
  -h, --help               Show this help text.
  -v, --version            Show the script version.

Run this script as your normal user. It will request elevated privileges only
for commands that require them, and Homebrew refuses to run as root.
USAGE
}

info() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

error() {
    printf '[ERROR] %s\n' "$*" >&2
}

section() {
    printf '\n==> %s\n' "$*"
}

have_command() {
    command -v "$1" >/dev/null 2>&1
}

find_system_command() {
    PATH="$SYSTEM_COMMAND_PATH" command -v "$1" 2>/dev/null
}

run_system_command() {
    local command_path
    command_path="$(find_system_command "$1")"
    if [[ -z "$command_path" ]]; then
        return 127
    fi
    shift
    "$command_path" "$@"
}

is_root() {
    (( EUID == 0 ))
}

print_command() {
    local argument

    printf '[DRY-RUN]'
    for argument in "$@"; do
        printf ' %q' "$argument"
    done
    printf '\n'
}

run_command() {
    if (( DRY_RUN )); then
        print_command "$@"
        return 0
    fi

    "$@"
}

run_brew_command() {
    if (( DO_CLEANUP )); then
        run_command brew "$@"
    elif (( DRY_RUN )); then
        print_command env HOMEBREW_NO_INSTALL_CLEANUP=1 brew "$@"
    else
        HOMEBREW_NO_INSTALL_CLEANUP=1 brew "$@"
    fi
}

select_privilege_tool() {
    if is_root; then
        PRIVILEGE_TOOL=""
    elif PRIVILEGE_TOOL="$(find_system_command sudo)" && [[ -n "$PRIVILEGE_TOOL" ]]; then
        :
    else
        PRIVILEGE_TOOL="unavailable"
    fi
}

as_root() {
    local command_name="$1"
    local command_path
    shift

    if [[ "$command_name" == */* ]]; then
        command_path="$command_name"
    else
        command_path="$(find_system_command "$command_name")"
    fi

    if [[ -z "$command_path" ]]; then
        error "Required system command is not installed in a trusted location: $command_name"
        return 127
    fi

    if (( DRY_RUN )); then
        if is_root; then
            print_command "$command_path" "$@"
        elif [[ "$PRIVILEGE_TOOL" == */sudo ]]; then
            print_command "$PRIVILEGE_TOOL" "$command_path" "$@"
        else
            print_command "<administrator>" "$command_path" "$@"
        fi
    elif is_root; then
        "$command_path" "$@"
    elif [[ "$PRIVILEGE_TOOL" == */sudo ]]; then
        "$PRIVILEGE_TOOL" "$command_path" "$@"
    else
        error "This operation requires root privileges, but sudo is not available."
        return 127
    fi
}

validate_privileges() {
    if (( DRY_RUN )); then
        return 0
    fi

    if is_root; then
        return 0
    fi

    if [[ "$PRIVILEGE_TOOL" == */sudo ]]; then
        info "Requesting administrator privileges..."
        "$PRIVILEGE_TOOL" -v
        return $?
    fi

    error "Administrator privileges are required, but sudo is not available."
    return 1
}

run_task() {
    local label="$1"
    shift

    section "$label"

    if "$@"; then
        if (( DRY_RUN )); then
            PLANNED+=("$label")
            info "$label was evaluated; no changes were made."
        else
            SUCCEEDED+=("$label")
            info "$label completed."
        fi
    else
        local status=$?
        FAILED+=("$label (exit $status)")
        error "$label failed with exit status $status. Continuing with the remaining managers."
    fi

    # A failed manager should not prevent unrelated managers from being tried.
    return 0
}

load_system_information() {
    MACOS_VERSION="$(run_system_command sw_vers -productVersion 2>/dev/null)"
    MACOS_MAJOR="${MACOS_VERSION%%.*}"

    local product_name
    product_name="$(run_system_command sw_vers -productName 2>/dev/null)"
    if [[ -n "$product_name" ]]; then
        MACOS_NAME="$product_name"
    fi

    HARDWARE_MODEL="$(run_system_command sysctl -n hw.model 2>/dev/null)"
    ARCHITECTURE="$(run_system_command uname -m 2>/dev/null)"

    if [[ ! "$MACOS_MAJOR" =~ ^[0-9]+$ ]]; then
        error "Unable to determine the macOS version from sw_vers."
        return 1
    fi
}

add_oclp_evidence() {
    if [[ -n "$OCLP_EVIDENCE" ]]; then
        OCLP_EVIDENCE="$OCLP_EVIDENCE, $1"
    else
        OCLP_EVIDENCE="$1"
    fi

    OCLP_DETECTED=1
}

oclp_path_exists() {
    [[ -e "$1" ]]
}

oclp_nvram_present() {
    find_system_command nvram >/dev/null &&
        run_system_command nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:OCLP-Version >/dev/null 2>&1
}

oclp_device_tree_present() {
    local device_tree
    find_system_command ioreg >/dev/null || return 1
    device_tree="$(run_system_command ioreg -p IODeviceTree -n chosen -r 2>/dev/null)" || return 1
    [[ "$device_tree" == *"opencore-version"* ]]
}

detect_oclp() {
    # OpenCore Legacy Patcher leaves several traces, and any single one of
    # them can be missing depending on how the Mac was set up, so each is
    # treated as independent evidence rather than as a requirement.
    local path
    for path in \
        "/System/Library/CoreServices/OpenCore-Legacy-Patcher.plist" \
        "/System/Library/CoreServices/OpenCore-Patcher.app" \
        "/Library/Application Support/Dortania" \
        "/Applications/OpenCore-Patcher.app"; do
        if oclp_path_exists "$path"; then
            add_oclp_evidence "$path"
        fi
    done

    if oclp_nvram_present; then
        add_oclp_evidence "OCLP-Version NVRAM variable"
    fi

    # OpenCore records its version in the device tree of the booted system.
    if oclp_device_tree_present; then
        add_oclp_evidence "OpenCore device tree entry"
    fi

    (( OCLP_DETECTED ))
}

# Parse `softwareupdate --list` into one record per update. ASCII file
# separators preserve empty fields when Bash 3.2 reads the records.
parse_software_updates() {
    awk '
        /^[[:space:]]*[*-] Label: / {
            label = $0
            sub(/^[[:space:]]*[*-] Label: /, "", label)
            title = ""
            version = ""
            action = ""

            if ((getline detail) > 0) {
                if (match(detail, /Title: [^,]*/)) {
                    title = substr(detail, RSTART + 7, RLENGTH - 7)
                }
                if (match(detail, /Version: [^,]*/)) {
                    version = substr(detail, RSTART + 9, RLENGTH - 9)
                }
                if (match(detail, /Action: [^,]*/)) {
                    action = substr(detail, RSTART + 8, RLENGTH - 8)
                }
            }

            printf "%s\034%s\034%s\034%s\n", label, title, version, action
        }
    '
}

list_software_updates() {
    LC_ALL=C run_system_command softwareupdate --list
}

# A macOS release update is identified from its title or label, because only
# those updates change the major release and need the version guard.
is_macos_release_update() {
    local title="$1"
    local label="${2:-}"

    case "$title" in
        macOS*|MacOS*|OS\ X*|Mac\ OS\ X*) return 0 ;;
    esac

    case "$label" in
        macOS*|MacOS*|OS\ X*|Mac\ OS\ X*) return 0 ;;
        *) return 1 ;;
    esac
}

update_target_major() {
    local version="$1"
    local major="${version%%.*}"

    if [[ "$major" =~ ^[0-9]+$ ]]; then
        printf '%s' "$major"
    else
        printf ''
    fi
}

# Decide whether one listed update may be installed. Prints the reason it was
# refused, and returns 1, when it may not be.
should_install_update() {
    local title="$1"
    local version="$2"
    local label="${3:-}"

    if ! is_macos_release_update "$title" "$label"; then
        return 0
    fi

    local major
    major="$(update_target_major "$version")"

    if [[ -z "$major" ]]; then
        printf 'its macOS version could not be determined'
        return 1
    fi

    # A configured ceiling controls upgrades, not security and point updates
    # for the release that is already running.
    if (( major == MACOS_MAJOR )); then
        return 0
    fi

    if (( major < MACOS_MAJOR )); then
        printf 'it targets older macOS %s while this Mac runs macOS %s' "$major" "$MACOS_MAJOR"
        return 1
    fi

    if (( major > MAX_MACOS_MAJOR )); then
        printf 'macOS %s is above the supported maximum of macOS %s' "$major" "$MAX_MACOS_MAJOR"
        return 1
    fi

    if (( OCLP_DETECTED )); then
        printf 'a major upgrade must be planned through OpenCore Legacy Patcher'
        return 1
    fi

    if (( ! ALLOW_MAJOR_UPGRADE )); then
        printf 'it is a major upgrade, which needs --allow-major-upgrade'
        return 1
    fi

    return 0
}

update_macos() {
    local listing
    local status=0

    info "Checking for macOS updates..."

    if ! listing="$(list_software_updates 2>&1)"; then
        printf '%s\n' "$listing" >&2
        error "softwareupdate could not list the available updates."
        return 1
    fi

    printf '%s\n' "$listing"

    local records
    records="$(printf '%s\n' "$listing" | parse_software_updates)"

    if [[ -z "$records" ]]; then
        case "$listing" in
            *"No new software available"*|*"No updates are available"*)
                info "No macOS updates are available."
                return 0
                ;;
            *)
                error "softwareupdate output could not be parsed safely. No update was installed."
                return 1
                ;;
        esac
    fi

    local labels=()
    local restart_flags=()
    local macos_flags=()
    local label title version action reason

    while IFS=$'\034' read -r label title version action; do
        [[ -n "$label" ]] || continue

        if [[ -z "$title" ]]; then
            reason="its title could not be determined from softwareupdate output"
            warn "Holding back \"$label\": $reason."
            HELD_BACK+=("macOS update: $label ($reason)")
            status=1
            continue
        fi

        if reason="$(should_install_update "$title" "$version" "$label")"; then
            labels+=("$label")
            if [[ "$action" == *restart* || "$action" == *Restart* ]]; then
                restart_flags+=(1)
            else
                restart_flags+=(0)
            fi
            if is_macos_release_update "$title" "$label"; then
                macos_flags+=(1)
            else
                macos_flags+=(0)
            fi
        else
            warn "Holding back \"${title:-$label}\": $reason."
            HELD_BACK+=("macOS update: ${title:-$label} ($reason)")
            if is_macos_release_update "$title" "$label" &&
                [[ -z "$(update_target_major "$version")" ]]; then
                status=1
            fi
        fi
    done <<EOF
$records
EOF

    if ((${#labels[@]} == 0)); then
        info "Every available macOS update was held back. Nothing was installed."
        return "$status"
    fi

    # Indexed rather than a whole-array expansion, because Bash 3.2 treats
    # expanding an empty array as an unbound variable under `set -u`.
    local restart_offered=0
    local scan=0
    while (( scan < ${#restart_flags[@]} )); do
        (( restart_flags[scan] )) && restart_offered=1
        scan=$((scan + 1))
    done

    if [[ "$ARCHITECTURE" == "arm64" ]] && (( restart_offered )); then
        warn "On Apple silicon, an update that restarts the Mac may need to be authorised in System Settings if it fails here."
    fi

    # Updates are installed one label at a time, rather than with --install
    # --all, so that a held-back release can never be installed by accident
    # and so that each failure is reported against the update that caused it.
    local index=0
    while (( index < ${#labels[@]} )); do
        label="${labels[$index]}"
        info "Installing update: $label"

        if as_root env PATH="$SYSTEM_COMMAND_PATH" LC_ALL=C softwareupdate --install "$label"; then
            if (( ! DRY_RUN )); then
                (( restart_flags[index] )) && RESTART_REQUIRED=1
                (( macos_flags[index] )) && MACOS_UPDATE_INSTALLED=1
            fi
        else
            error "Failed to install update: $label"
            status=1
        fi
        index=$((index + 1))
    done

    return "$status"
}

update_mas() {
    local outdated

    # mas reports a missing App Store session as an error rather than as an
    # empty list, so its own status decides whether the task succeeded.
    if ! outdated="$(mas outdated 2>&1)"; then
        printf '%s\n' "$outdated" >&2
        return 1
    fi

    if [[ -z "$outdated" ]]; then
        info "No Mac App Store applications are outdated."
        return 0
    fi

    printf '%s\n' "$outdated"
    run_command mas upgrade
}

update_homebrew() {
    if is_root; then
        error "Homebrew must not be run as root. Run $SCRIPT_NAME as your normal user instead of with sudo."
        return 1
    fi

    run_brew_command update || return 1

    # Recent Homebrew upgrades outdated formulae and casks together.
    run_brew_command upgrade || return 1

    if (( DO_GREEDY_CASKS )); then
        # --greedy also upgrades casks that carry their own updater, which is
        # the closest equivalent to a third-party application patcher.
        run_brew_command upgrade --cask --greedy || return 1
    fi

    if (( DO_CLEANUP )); then
        run_brew_command cleanup
    fi
}

update_macports() {
    as_root port -q selfupdate || return 1

    local outdated
    if ! outdated="$(port echo outdated 2>&1)"; then
        printf '%s\n' "$outdated" >&2
        return 1
    fi

    if [[ -z "$outdated" ]]; then
        info "No MacPorts ports are outdated."
    else
        as_root port -N upgrade outdated || return 1
    fi

    if (( DO_CLEANUP )); then
        local inactive
        if ! inactive="$(port echo inactive 2>&1)"; then
            printf '%s\n' "$inactive" >&2
            return 1
        fi
        if [[ -n "$inactive" ]]; then
            as_root port -q -N uninstall inactive
        fi
    fi
}

update_nix() {
    run_command nix-channel --update &&
    run_command nix-env --upgrade
}

print_summary() {
    local item

    section "Summary"
    printf 'System: %s %s' "$MACOS_NAME" "$MACOS_VERSION"
    if [[ -n "$HARDWARE_MODEL" ]]; then
        printf ' on %s' "$HARDWARE_MODEL"
    fi
    if [[ -n "$ARCHITECTURE" ]]; then
        printf ' (%s)' "$ARCHITECTURE"
    fi
    printf '\n'

    if (( OCLP_DETECTED )); then
        printf 'OpenCore Legacy Patcher: detected (%s)\n' "$OCLP_EVIDENCE"
    fi

    printf 'Configured ceiling for major upgrades: macOS %s\n' "$MAX_MACOS_MAJOR"

    if ((${#SUCCEEDED[@]})); then
        printf '\nCompleted:\n'
        for item in "${SUCCEEDED[@]}"; do
            printf '  - %s\n' "$item"
        done
    fi

    if ((${#PLANNED[@]})); then
        printf '\nEvaluated (dry run; not executed):\n'
        for item in "${PLANNED[@]}"; do
            printf '  - %s\n' "$item"
        done
    fi

    if ((${#HELD_BACK[@]})); then
        printf '\nHeld back:\n'
        for item in "${HELD_BACK[@]}"; do
            printf '  - %s\n' "$item"
        done
    fi

    if ((${#SKIPPED[@]})); then
        printf '\nNot installed or skipped:\n'
        for item in "${SKIPPED[@]}"; do
            printf '  - %s\n' "$item"
        done
    fi

    if ((${#FAILED[@]})); then
        printf '\nFailed:\n' >&2
        for item in "${FAILED[@]}"; do
            printf '  - %s\n' "$item" >&2
        done
    fi

    if (( RESTART_REQUIRED )); then
        printf '\n[NOTICE] A restart is required to finish installing one or more updates.\n'
    fi

    if (( OCLP_DETECTED && MACOS_UPDATE_INSTALLED )); then
        printf '\n[NOTICE] A macOS update was installed on a Mac patched with OpenCore Legacy Patcher.\n'
        printf '         macOS updates remove root patches. After the Mac restarts, open OpenCore\n'
        printf '         Legacy Patcher and re-apply them, and confirm that its bootloader on the\n'
        printf '         EFI partition is current before restarting again.\n'
    fi
}

main() {
    while (($#)); do
        case "$1" in
            --system-only)
                DO_ADDITIONAL_MANAGERS=0
                ;;
            --skip-system-update)
                DO_SYSTEM_UPDATE=0
                ;;
            --no-cleanup)
                DO_CLEANUP=0
                ;;
            --greedy-casks)
                DO_GREEDY_CASKS=1
                ;;
            --allow-major-upgrade)
                ALLOW_MAJOR_UPGRADE=1
                ;;
            --max-macos-major)
                if (($# < 2)) || [[ ! "$2" =~ ^[1-9][0-9]*$ ]]; then
                    error "--max-macos-major requires a whole number, for example: --max-macos-major 25"
                    return 2
                fi
                MAX_MACOS_MAJOR="$2"
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            -h|--help)
                usage
                return 0
                ;;
            -v|--version)
                printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
                return 0
                ;;
            *)
                error "Unknown option: $1"
                usage >&2
                return 2
                ;;
        esac
        shift
    done

    if (( ! DO_ADDITIONAL_MANAGERS && ! DO_SYSTEM_UPDATE )); then
        error "--system-only and --skip-system-update cannot be used together."
        return 2
    fi

    if [[ "$(run_system_command uname -s)" != "Darwin" ]]; then
        error "This script supports macOS only."
        return 2
    fi

    if is_root; then
        error "Run this script as a normal user, not as root or through sudo."
        return 2
    fi

    load_system_information || return 2
    select_privilege_tool

    printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
    info "Detected system: $MACOS_NAME $MACOS_VERSION on ${HARDWARE_MODEL:-an unknown model} (${ARCHITECTURE:-unknown architecture})"

    if detect_oclp; then
        info "OpenCore Legacy Patcher detected: $OCLP_EVIDENCE"
        warn "This Mac runs macOS through OpenCore Legacy Patcher. Major upgrades are refused, and root patches must be re-applied after any macOS update."
        warn "Update OpenCore Legacy Patcher itself before installing macOS updates, so that the installed version supports this release."
    fi

    if (( MACOS_MAJOR > MAX_MACOS_MAJOR )); then
        warn "This Mac already runs macOS $MACOS_MAJOR, which is above the supported maximum of macOS $MAX_MACOS_MAJOR. Updates within that release are still installed."
    fi

    if (( DO_SYSTEM_UPDATE )); then
        if validate_privileges; then
            run_task "macOS updates" update_macos
        else
            FAILED+=("macOS updates: administrator privileges unavailable")
        fi
    else
        SKIPPED+=("macOS updates (--skip-system-update)")
    fi

    if (( DO_ADDITIONAL_MANAGERS )); then
        if have_command mas; then
            run_task "Mac App Store applications" update_mas
        else
            SKIPPED+=("Mac App Store (mas is not installed)")
        fi

        if have_command brew; then
            run_task "Homebrew formulae and casks" update_homebrew
        else
            SKIPPED+=("Homebrew")
        fi

        if have_command port; then
            run_task "MacPorts ports" update_macports
        else
            SKIPPED+=("MacPorts")
        fi

        if have_command darwin-rebuild; then
            # A nix-darwin system is described by its own configuration, and
            # rebuilding it is not equivalent to upgrading packages in place.
            SKIPPED+=("Nix (this Mac uses nix-darwin, which must be rebuilt from its own configuration)")
        elif have_command nix-env; then
            run_task "Nix packages" update_nix
        else
            SKIPPED+=("Nix")
        fi
    else
        SKIPPED+=("Additional package managers (--system-only)")
    fi

    print_summary

    if ((${#FAILED[@]})); then
        error "Updates finished with one or more failures."
        return 1
    fi

    if (( DRY_RUN )); then
        info "Dry run completed without executing mutating commands."
    else
        info "All detected package managers completed successfully."
    fi
}

if [[ "${UPDATE_EVERYTHING_TESTING:-0}" != "1" ]]; then
    main "$@"
fi
