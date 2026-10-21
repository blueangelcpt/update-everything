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
# A major macOS upgrade is never installed unless --allow-major-upgrade is
# given. A macOS version ceiling applies only on a Mac running OpenCore Legacy
# Patcher, where the installed OCLP version decides the newest macOS release
# that may be installed. OCLP runs only on Intel Macs; a Mac without it has no
# ceiling and never sees OCLP mentioned in the output.
#
# This script intentionally does not update project or language dependencies
# such as Composer, npm project packages, pip environments, Cargo projects,
# or application-specific self-updaters.
#
# macOS ships GNU bash 3.2, so this script avoids later bash features.

set -uo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="2.1.0"
readonly SYSTEM_COMMAND_PATH="/usr/sbin:/usr/bin:/sbin:/bin:/opt/local/sbin:/opt/local/bin"

# OpenCore Legacy Patcher runs only on Intel Macs, and each generation of it
# supports a different newest macOS release: OCLP 3.x added macOS 26 Tahoe,
# while 2.5.x and older stop at macOS 15 Sequoia. Raise these only when a newer
# OCLP generation has been verified. macOS has no releases 16 to 25, so the
# numbers jump from 15 straight to 26.
readonly OCLP_TAHOE_CAPABLE_MAJOR=3
readonly OCLP_MAX_MACOS_MAJOR_MODERN=26
readonly OCLP_MAX_MACOS_MAJOR_LEGACY=15

DO_CLEANUP=1
DO_ADDITIONAL_MANAGERS=1
DO_SYSTEM_UPDATE=1
DO_GREEDY_CASKS=0
ALLOW_MAJOR_UPGRADE=0
# An empty ceiling means no ceiling at all, which is the case on every Mac
# without OpenCore Legacy Patcher.
MAX_MACOS_MAJOR=""
MAX_MACOS_MAJOR_EXPLICIT=0
DRY_RUN=0

MACOS_VERSION=""
MACOS_MAJOR=""
MACOS_NAME="macOS"
HARDWARE_MODEL=""
ARCHITECTURE=""

OCLP_DETECTED=0
OCLP_EVIDENCE=""
# OCLP is updated in three separate steps -- the application, then the EFI
# bootloader, then the root patches -- so each can be at a different version.
OCLP_APP_VERSION=""
OCLP_APP_SOURCE=""
OCLP_BOOTLOADER_VERSION=""
OCLP_ROOT_PATCH_VERSION=""
# The effective version is the oldest of the components above, and is empty
# when the application or the active bootloader could not be read. The source
# names the component that set it, or says why it is unknown.
OCLP_VERSION=""
OCLP_VERSION_SOURCE=""

readonly OCLP_NVRAM_VARIABLE="4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:OCLP-Version"
readonly OCLP_ROOT_PATCH_PLIST="/System/Library/CoreServices/OpenCore-Legacy-Patcher.plist"
readonly OCLP_ROOT_PATCH_KEY="OpenCore Legacy Patcher"

MACOS_UPDATE_INSTALLED=0
RESTART_REQUIRED=0

PRIVILEGE_TOOL=""

# The task that run_task is executing, and the signal that stopped the run, so
# that an interrupted run can still say what had finished.
CURRENT_TASK=""
INTERRUPTED_BY=""

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
  --allow-major-upgrade    Permit an upgrade to a newer major macOS release.
USAGE

    # The ceiling exists only on a Mac running OpenCore Legacy Patcher, so the
    # option that overrides it is offered only where it has an effect.
    if (( OCLP_DETECTED )); then
        cat <<USAGE
  --max-macos-major N      Highest major macOS release to install on this Mac,
                           overriding the release that the installed OpenCore
                           Legacy Patcher is known to support.
USAGE
    fi

    cat <<USAGE
  --dry-run                List and evaluate updates, but do not install or
                           clean up anything.
  -h, --help               Show this help text.
  -v, --version            Show the script version.

Run this script as your normal user. It will request elevated privileges only
for commands that require them, and Homebrew refuses to run as root.

Exit status: 0 success, 1 an updater failed, 2 invalid or conflicting options
or an unsupported system, 130 or 143 interrupted by SIGINT or SIGTERM.
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
    CURRENT_TASK="$label"

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
    CURRENT_TASK=""

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
        run_system_command nvram "$OCLP_NVRAM_VARIABLE" >/dev/null 2>&1
}

oclp_device_tree_present() {
    local device_tree
    find_system_command ioreg >/dev/null || return 1
    device_tree="$(run_system_command ioreg -p IODeviceTree -n chosen -r 2>/dev/null)" || return 1
    [[ "$device_tree" == *"opencore-version"* ]]
}

detect_oclp() {
    # OpenCore Legacy Patcher exists only for Intel Macs that Apple no longer
    # supports, so Apple silicon never looks for it and never mentions it.
    if [[ "$ARCHITECTURE" != "x86_64" ]]; then
        return 1
    fi

    # OpenCore Legacy Patcher leaves several traces, and any single one of
    # them can be missing depending on how the Mac was set up, so each is
    # treated as independent evidence rather than as a requirement.
    local path
    for path in \
        "$OCLP_ROOT_PATCH_PLIST" \
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

# Print the first version-looking token in the input. Each reader below hands
# it a single value, never a listing of several, so the token it finds cannot
# belong to a different field.
first_version_in() {
    awk '{
        if (match($0, /[0-9]+\.[0-9]+(\.[0-9]+)*/)) {
            print substr($0, RSTART, RLENGTH)
            exit
        }
    }'
}

# Succeed when version $1 is older than version $2. Each dotted component is
# compared as a number, so 2.10 is newer than 2.9 and 3.0 equals 3.0.0.
version_is_older() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        n = split(a, x, ".")
        m = split(b, y, ".")
        k = (n > m) ? n : m
        for (i = 1; i <= k; i++) {
            xi = (i <= n) ? x[i] + 0 : 0
            yi = (i <= m) ? y[i] + 0 : 0
            if (xi < yi) exit 0
            if (xi > yi) exit 1
        }
        exit 1
    }'
}

oclp_bundle_version() {
    local bundle="$1"

    [[ -d "$bundle" ]] || return 1
    run_system_command defaults read "$bundle/Contents/Info" CFBundleShortVersionString 2>/dev/null
}

oclp_root_patch_plist_readable() {
    [[ -r "$OCLP_ROOT_PATCH_PLIST" ]]
}

# The root patch property list also records the patched macOS version and the
# PatcherSupportPkg version, and `plutil -p` lists keys alphabetically, which
# puts "OS Version" before "OpenCore Legacy Patcher". Only the value of that
# exact key is read. `defaults` takes the path without its .plist extension,
# and the value carries a leading "v", as in "v2.5.1".
oclp_root_patch_version() {
    oclp_root_patch_plist_readable || return 1
    run_system_command defaults read "${OCLP_ROOT_PATCH_PLIST%.plist}" "$OCLP_ROOT_PATCH_KEY" 2>/dev/null
}

# OCLP writes its own version into the EFI configuration when it builds the
# bootloader, so this NVRAM variable reports the bootloader the Mac actually
# booted through. Installing a newer application does not change it. `nvram`
# prints the variable name, a tab, then the value; only the value is returned.
oclp_bootloader_version() {
    local line

    oclp_nvram_present || return 1
    line="$(run_system_command nvram "$OCLP_NVRAM_VARIABLE" 2>/dev/null)" || return 1
    [[ "$line" == *$'\t'* ]] || return 1
    printf '%s\n' "${line#*$'\t'}"
}

# Read the version of each OCLP component, then settle on the effective one.
# OCLP is updated as three separate steps -- the application, the bootloader,
# then the root patches -- and a Mac is only as capable as the step it has not
# taken yet, so the oldest component sets the version. The active bootloader
# and the application must both be readable: the Mac boots through the first,
# and only the second can re-apply root patches after an upgrade.
detect_oclp_version() {
    local bundle

    OCLP_APP_VERSION=""
    OCLP_APP_SOURCE=""
    for bundle in \
        "/Applications/OpenCore-Patcher.app" \
        "/System/Library/CoreServices/OpenCore-Patcher.app"; do
        OCLP_APP_VERSION="$(oclp_bundle_version "$bundle" | first_version_in)"
        if [[ -n "$OCLP_APP_VERSION" ]]; then
            OCLP_APP_SOURCE="$bundle"
            break
        fi
    done

    OCLP_BOOTLOADER_VERSION="$(oclp_bootloader_version | first_version_in)"
    OCLP_ROOT_PATCH_VERSION="$(oclp_root_patch_version | first_version_in)"

    OCLP_VERSION=""
    if [[ -z "$OCLP_BOOTLOADER_VERSION" ]]; then
        OCLP_VERSION_SOURCE="the active bootloader version could not be read from NVRAM"
        return 1
    fi
    if [[ -z "$OCLP_APP_VERSION" ]]; then
        OCLP_VERSION_SOURCE="no installed OpenCore Legacy Patcher application could be read"
        return 1
    fi

    OCLP_VERSION="$OCLP_BOOTLOADER_VERSION"
    OCLP_VERSION_SOURCE="the active bootloader"
    if version_is_older "$OCLP_APP_VERSION" "$OCLP_VERSION"; then
        OCLP_VERSION="$OCLP_APP_VERSION"
        OCLP_VERSION_SOURCE="the application"
    fi
    if [[ -n "$OCLP_ROOT_PATCH_VERSION" ]] &&
        version_is_older "$OCLP_ROOT_PATCH_VERSION" "$OCLP_VERSION"; then
        OCLP_VERSION="$OCLP_ROOT_PATCH_VERSION"
        OCLP_VERSION_SOURCE="the root patches"
    fi
    return 0
}

describe_oclp_components() {
    printf 'application %s, active bootloader %s, root patches %s' \
        "${OCLP_APP_VERSION:-unreadable}" \
        "${OCLP_BOOTLOADER_VERSION:-unreadable}" \
        "${OCLP_ROOT_PATCH_VERSION:-none recorded}"
}

# Succeed when the components that could be read are not all the same version,
# which means an OCLP update was started but not finished.
oclp_components_differ() {
    local reference="" component

    for component in "$OCLP_APP_VERSION" "$OCLP_BOOTLOADER_VERSION" "$OCLP_ROOT_PATCH_VERSION"; do
        [[ -n "$component" ]] || continue
        if [[ -z "$reference" ]]; then
            reference="$component"
        elif version_is_older "$component" "$reference" || version_is_older "$reference" "$component"; then
            return 0
        fi
    done
    return 1
}

# Only a Mac running OpenCore Legacy Patcher has a ceiling, and the installed
# OCLP version sets it. An explicit --max-macos-major always wins.
resolve_macos_ceiling() {
    if (( MAX_MACOS_MAJOR_EXPLICIT )); then
        return 0
    fi

    if (( ! OCLP_DETECTED )); then
        MAX_MACOS_MAJOR=""
        return 0
    fi

    local oclp_major="${OCLP_VERSION%%.*}"

    # An unreadable OCLP version is treated as an old one, because installing
    # a release that OCLP cannot patch leaves the Mac without its drivers.
    if [[ "$oclp_major" =~ ^[0-9]+$ ]] && (( oclp_major >= OCLP_TAHOE_CAPABLE_MAJOR )); then
        MAX_MACOS_MAJOR="$OCLP_MAX_MACOS_MAJOR_MODERN"
    else
        MAX_MACOS_MAJOR="$OCLP_MAX_MACOS_MAJOR_LEGACY"
    fi
}

report_macos_ceiling() {
    if [[ -z "$MAX_MACOS_MAJOR" ]]; then
        return 0
    fi

    if (( OCLP_DETECTED && ! MAX_MACOS_MAJOR_EXPLICIT )); then
        if [[ -n "$OCLP_VERSION" ]]; then
            info "OpenCore Legacy Patcher $OCLP_VERSION, set by $OCLP_VERSION_SOURCE, supports macOS up to $MAX_MACOS_MAJOR, which is the ceiling for this run."
        else
            warn "The OpenCore Legacy Patcher version could not be confirmed ($OCLP_VERSION_SOURCE), so macOS $MAX_MACOS_MAJOR is assumed as the ceiling. Override it with --max-macos-major."
        fi
    fi

    if (( MACOS_MAJOR > MAX_MACOS_MAJOR )); then
        warn "This Mac already runs macOS $MACOS_MAJOR, which is above the ceiling of macOS $MAX_MACOS_MAJOR. Updates within that release are still installed."
    fi
}

# `--help` is answered before the run begins, so the OCLP state that decides
# which options are listed has to be established on its own.
prepare_help_context() {
    if [[ -z "$ARCHITECTURE" ]]; then
        ARCHITECTURE="$(run_system_command uname -m 2>/dev/null)"
    fi

    detect_oclp >/dev/null 2>&1
    return 0
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

    # A ceiling restricts upgrades, not the security and point updates for the
    # release that is already running.
    if (( major == MACOS_MAJOR )); then
        return 0
    fi

    if (( major < MACOS_MAJOR )); then
        printf 'it targets older macOS %s while this Mac runs macOS %s' "$major" "$MACOS_MAJOR"
        return 1
    fi

    if [[ -n "$MAX_MACOS_MAJOR" ]] && (( major > MAX_MACOS_MAJOR )); then
        if (( OCLP_DETECTED && ! MAX_MACOS_MAJOR_EXPLICIT )); then
            if [[ -n "$OCLP_VERSION" ]]; then
                printf 'OpenCore Legacy Patcher %s, set by %s, supports macOS up to %s, not macOS %s' \
                    "$OCLP_VERSION" "$OCLP_VERSION_SOURCE" "$MAX_MACOS_MAJOR" "$major"
            else
                printf 'the OpenCore Legacy Patcher version could not be confirmed (%s), so macOS %s is the assumed maximum' \
                    "$OCLP_VERSION_SOURCE" "$MAX_MACOS_MAJOR"
            fi
        else
            printf 'macOS %s is above the configured maximum of macOS %s' "$major" "$MAX_MACOS_MAJOR"
        fi
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

    # Neither OpenCore Legacy Patcher nor a ceiling is reported on a Mac that
    # has neither of them.
    if (( OCLP_DETECTED )); then
        if [[ -n "$OCLP_VERSION" ]]; then
            printf 'OpenCore Legacy Patcher: %s, set by %s (%s)\n' \
                "$OCLP_VERSION" "$OCLP_VERSION_SOURCE" "$(describe_oclp_components)"
        else
            printf 'OpenCore Legacy Patcher: detected, version not confirmed (%s)\n' "$(describe_oclp_components)"
        fi
    fi

    if [[ -n "$MAX_MACOS_MAJOR" ]]; then
        printf 'Ceiling for major upgrades: macOS %s\n' "$MAX_MACOS_MAJOR"
    fi

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

    if [[ -n "$INTERRUPTED_BY" ]]; then
        printf '\nInterrupted by %s:\n' "$INTERRUPTED_BY" >&2
        if [[ -n "$CURRENT_TASK" ]]; then
            printf '  - %s (stopped while running; it may be partly applied)\n' "$CURRENT_TASK" >&2
        fi
        printf '  - Any manager that had not started yet was not run.\n' >&2
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

# Run from the INT and TERM traps. Bash runs a trap only once the foreground
# command has exited, so by now the interrupted updater has stopped. The
# handler only reports: it restores the default dispositions first, so that a
# second Ctrl-C ends the script at once, and it never returns to main, so no
# further updater can start.
handle_interrupt() {
    local signal="$1"
    local status="$2"

    trap - INT TERM
    INTERRUPTED_BY="SIG$signal"
    printf '\n' >&2
    warn "Received SIG$signal. No further updates will be started."
    print_summary
    error "Updates were interrupted before they finished."
    exit "$status"
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
                    error "--max-macos-major requires a whole number, for example: --max-macos-major 26"
                    return 2
                fi
                MAX_MACOS_MAJOR="$2"
                MAX_MACOS_MAJOR_EXPLICIT=1
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            -h|--help)
                prepare_help_context
                usage
                return 0
                ;;
            -v|--version)
                printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
                return 0
                ;;
            *)
                error "Unknown option: $1"
                prepare_help_context
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

    trap 'handle_interrupt INT 130' INT
    trap 'handle_interrupt TERM 143' TERM

    load_system_information || return 2
    select_privilege_tool

    printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
    info "Detected system: $MACOS_NAME $MACOS_VERSION on ${HARDWARE_MODEL:-an unknown model} (${ARCHITECTURE:-unknown architecture})"

    # A Mac without OpenCore Legacy Patcher says nothing about it, and has no
    # ceiling unless one was asked for explicitly.
    if detect_oclp; then
        detect_oclp_version
        info "OpenCore Legacy Patcher detected: $(describe_oclp_components); evidence: $OCLP_EVIDENCE"
        if [[ -n "$OCLP_APP_SOURCE" ]]; then
            info "OpenCore Legacy Patcher application version read from $OCLP_APP_SOURCE"
        fi
        if oclp_components_differ; then
            warn "OpenCore Legacy Patcher is only partly updated. It updates the application, the bootloader and the root patches as three separate steps; finish all three before a major macOS upgrade."
        fi
        warn "Root patches are removed by a macOS update and must be re-applied in OpenCore Legacy Patcher afterwards."
        warn "Update OpenCore Legacy Patcher itself first, so that the installed version supports the release being applied."
    fi

    resolve_macos_ceiling
    report_macos_ceiling

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

    # From here on there is nothing left to interrupt but the summary itself.
    trap - INT TERM
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
