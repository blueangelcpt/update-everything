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
readonly SCRIPT_VERSION="1.0.0"

# macOS 26 and later are not supported by this script. Raise this only when
# the newer release has been verified on the machines it will run on.
DEFAULT_MAX_MACOS_MAJOR=25

DO_CLEANUP=1
DO_ADDITIONAL_MANAGERS=1
DO_SYSTEM_UPDATE=1
DO_GREEDY_CASKS=0
ALLOW_MAJOR_UPGRADE=0
MAX_MACOS_MAJOR="$DEFAULT_MAX_MACOS_MAJOR"

MACOS_VERSION=""
MACOS_MAJOR=""
MACOS_NAME="macOS"
HARDWARE_MODEL=""
ARCHITECTURE=""

OCLP_DETECTED=0
OCLP_EVIDENCE=""

SYSTEM_UPDATE_INSTALLED=0
RESTART_REQUIRED=0

PRIVILEGE_TOOL=""

SUCCEEDED=()
FAILED=()
SKIPPED=()

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
  --max-macos-major N      Highest major macOS release this script may
                           install (default: $DEFAULT_MAX_MACOS_MAJOR).
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

select_privilege_tool() {
    if (( EUID == 0 )); then
        PRIVILEGE_TOOL=""
    elif have_command sudo; then
        PRIVILEGE_TOOL="sudo"
    else
        PRIVILEGE_TOOL="unavailable"
    fi
}

as_root() {
    if (( EUID == 0 )); then
        "$@"
    elif [[ "$PRIVILEGE_TOOL" == "sudo" ]]; then
        sudo "$@"
    else
        error "This operation requires root privileges, but sudo is not available."
        return 127
    fi
}

validate_privileges() {
    if (( EUID == 0 )); then
        return 0
    fi

    if [[ "$PRIVILEGE_TOOL" == "sudo" ]]; then
        info "Requesting administrator privileges..."
        sudo -v
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
        SUCCEEDED+=("$label")
        info "$label completed."
    else
        local status=$?
        FAILED+=("$label (exit $status)")
        error "$label failed with exit status $status. Continuing with the remaining managers."
    fi

    # A failed manager should not prevent unrelated managers from being tried.
    return 0
}

load_system_information() {
    MACOS_VERSION="$(sw_vers -productVersion 2>/dev/null)"
    MACOS_MAJOR="${MACOS_VERSION%%.*}"

    local product_name
    product_name="$(sw_vers -productName 2>/dev/null)"
    if [[ -n "$product_name" ]]; then
        MACOS_NAME="$product_name"
    fi

    HARDWARE_MODEL="$(sysctl -n hw.model 2>/dev/null)"
    ARCHITECTURE="$(uname -m 2>/dev/null)"

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
        if [[ -e "$path" ]]; then
            add_oclp_evidence "$path"
        fi
    done

    if have_command nvram; then
        if nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:OCLP-Version >/dev/null 2>&1; then
            add_oclp_evidence "OCLP-Version NVRAM variable"
        fi
    fi

    if have_command ioreg; then
        # OpenCore records its version in the device tree of the booted system.
        if ioreg -p IODeviceTree -n chosen -r 2>/dev/null | grep -q "opencore-version"; then
            add_oclp_evidence "OpenCore device tree entry"
        fi
    fi

    (( OCLP_DETECTED ))
}

# Parse `softwareupdate --list` into one tab-separated record per update:
#   label<TAB>title<TAB>version<TAB>action
parse_software_updates() {
    awk '
        /^[[:space:]]*\* Label: / {
            label = $0
            sub(/^[[:space:]]*\* Label: /, "", label)
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

            printf "%s\t%s\t%s\t%s\n", label, title, version, action
        }
    '
}

# A macOS release update is identified by its title, because only those
# updates change the major release and need the version guard.
is_macos_release_update() {
    local title="$1"

    case "$title" in
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

    if ! is_macos_release_update "$title"; then
        return 0
    fi

    local major
    major="$(update_target_major "$version")"

    if [[ -z "$major" ]]; then
        printf 'its macOS version could not be determined'
        return 1
    fi

    if (( major > MAX_MACOS_MAJOR )); then
        printf 'macOS %s is above the supported maximum of macOS %s' "$major" "$MAX_MACOS_MAJOR"
        return 1
    fi

    if (( major > MACOS_MAJOR )); then
        if (( OCLP_DETECTED )); then
            printf 'a major upgrade must be planned through OpenCore Legacy Patcher'
            return 1
        fi

        if (( ! ALLOW_MAJOR_UPGRADE )); then
            printf 'it is a major upgrade, which needs --allow-major-upgrade'
            return 1
        fi
    fi

    return 0
}

update_macos() {
    local listing
    local status=0

    info "Checking for macOS updates..."

    if ! listing="$(softwareupdate --list 2>&1)"; then
        printf '%s\n' "$listing" >&2
        error "softwareupdate could not list the available updates."
        return 1
    fi

    printf '%s\n' "$listing"

    local records
    records="$(printf '%s\n' "$listing" | parse_software_updates)"

    if [[ -z "$records" ]]; then
        info "No macOS updates are available."
        return 0
    fi

    local labels=()
    local restart_labels=()
    local label title version action reason

    while IFS=$'\t' read -r label title version action; do
        [[ -n "$label" ]] || continue

        if reason="$(should_install_update "$title" "$version")"; then
            labels+=("$label")
            if [[ "$action" == *restart* ]]; then
                restart_labels+=("$label")
            fi
        else
            warn "Holding back \"$title\": $reason."
            SKIPPED+=("macOS update: $title ($reason)")
        fi
    done <<EOF
$records
EOF

    if ((${#labels[@]} == 0)); then
        info "Every available macOS update was held back. Nothing was installed."
        return 0
    fi

    if [[ "$ARCHITECTURE" == "arm64" ]] && ((${#restart_labels[@]})); then
        warn "On Apple silicon, an update that restarts the Mac may need to be authorised in System Settings if it fails here."
    fi

    # Updates are installed one label at a time, rather than with --install
    # --all, so that a held-back release can never be installed by accident
    # and so that each failure is reported against the update that caused it.
    for label in "${labels[@]}"; do
        info "Installing update: $label"

        if as_root softwareupdate --install "$label" --no-scan; then
            SYSTEM_UPDATE_INSTALLED=1
        else
            error "Failed to install update: $label"
            status=1
        fi
    done

    if ((${#restart_labels[@]})); then
        RESTART_REQUIRED=1
    fi

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
    mas upgrade
}

update_homebrew() {
    if (( EUID == 0 )); then
        error "Homebrew must not be run as root. Run $SCRIPT_NAME as your normal user instead of with sudo."
        return 1
    fi

    brew update || return 1

    # Recent Homebrew upgrades outdated formulae and casks together.
    brew upgrade || return 1

    if (( DO_GREEDY_CASKS )); then
        # --greedy also upgrades casks that carry their own updater, which is
        # the closest equivalent to a third-party application patcher.
        brew upgrade --cask --greedy || return 1
    fi

    if (( DO_CLEANUP )); then
        brew cleanup
    fi
}

update_macports() {
    as_root port -q selfupdate || return 1

    local outdated
    outdated="$(port echo outdated 2>/dev/null)"

    if [[ -z "$outdated" ]]; then
        info "No MacPorts ports are outdated."
    else
        as_root port -N upgrade outdated || return 1
    fi

    if (( DO_CLEANUP )); then
        # Inactive ports are left behind by every upgrade, and removing them
        # is safe, but it fails harmlessly when there are none.
        as_root port -q -N uninstall inactive || true
    fi
}

update_nix() {
    nix-channel --update &&
    nix-env --upgrade
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

    printf 'Highest macOS release this run may install: macOS %s\n' "$MAX_MACOS_MAJOR"

    if ((${#SUCCEEDED[@]})); then
        printf '\nCompleted:\n'
        for item in "${SUCCEEDED[@]}"; do
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

    if (( OCLP_DETECTED && SYSTEM_UPDATE_INSTALLED )); then
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
                if (($# < 2)) || [[ ! "$2" =~ ^[0-9]+$ ]]; then
                    error "--max-macos-major requires a whole number, for example: --max-macos-major 25"
                    return 2
                fi
                MAX_MACOS_MAJOR="$2"
                shift
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

    if [[ "$(uname -s)" != "Darwin" ]]; then
        error "This script supports macOS only."
        return 2
    fi

    if (( EUID == 0 )) && [[ -n "${SUDO_USER:-}" ]]; then
        warn "Run this script without sudo. It elevates only the commands that need it."
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

    info "All detected package managers completed successfully."
}

main "$@"
