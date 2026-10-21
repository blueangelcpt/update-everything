#!/usr/bin/env bash
# update-everything.sh
#
# Update the current Linux distribution using its native package manager,
# then update supported cross-distribution application managers.
#
# Supported native/system managers:
#   APT, DNF5, DNF, YUM, Zypper, transactional-update, Pacman, APK,
#   XBPS, Portage/emerge, eopkg, swupd, rpm-ostree, NixOS, Slackpkg,
#   and URPMI.
#
# Supported additional managers:
#   Snap, Flatpak, and Homebrew on Linux.
#
# This script intentionally does not update project or language dependencies
# such as Composer, npm project packages, pip environments, Cargo projects,
# or application-specific self-updaters.

set -uo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="2.0.0"
readonly SYSTEM_COMMAND_PATH="/run/current-system/sw/bin:/usr/sbin:/usr/bin:/sbin:/bin"

DO_CLEANUP=1
DO_ADDITIONAL_MANAGERS=1
DO_SYSTEM_UPDATE=1
INCLUDE_PHASED_UPDATES=0
DRY_RUN=0

SYSTEM_MANAGER=""
DISTRO_NAME="Linux"
OS_ID=""
OS_ID_LIKE=""

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

Update all available packages managed by the Linux distribution's native
package manager, followed by supported cross-distribution managers.

Options:
  --system-only            Update only the native system package manager.
  --skip-system-update     Update only Snap, Flatpak, and Homebrew. Snap and
                           system Flatpak still ask for sudo or doas when
                           they reach a step that needs it.
  --no-cleanup             Do not remove unused dependencies or cached packages.
  --include-phased-updates Install APT updates that are still being phased in.
                           Phasing is a distribution safety mechanism, so these
                           are held back and reported by default.
  --dry-run                Detect managers and print mutating commands without
                           running them.
  -h, --help               Show this help text.
  -v, --version            Show the script version.

Run this script as your normal user. It will request elevated privileges only
for commands that require them.

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

# The start-up banner: the Update Everything ring-and-tick logo as ASCII art,
# beside the name, version, tagline and a subtitle. The ring's four arcs are
# coloured light blue, blue, green and grey around a green tick. The art is
# pure ASCII, so it also prints in a locale that is not UTF-8, where the
# divider and separator fall back to ASCII as well. Terminals narrower than 72
# columns get a short form instead, and a subtitle too long for the terminal is
# shortened rather than wrapped. Colour is used only when standard output is a
# terminal, TERM is not "dumb", and NO_COLOR is unset.
readonly BANNER_MIN_COLUMNS=72
readonly BANNER_TEXT_COLUMN=45

banner_uses_color() {
    [[ -z "${NO_COLOR:-}" && -t 1 && "${TERM:-}" != "dumb" ]]
}

banner_locale_is_utf8() {
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
        *UTF-8*|*utf-8*|*UTF8*|*utf8*) return 0 ;;
    esac
    return 1
}

terminal_columns() {
    local columns="${COLUMNS:-}" tput_path

    if [[ ! "$columns" =~ ^[0-9]+$ ]]; then
        columns=""
        if tput_path="$(find_system_command tput)"; then
            columns="$("$tput_path" cols 2>/dev/null)" || columns=""
        fi
    fi
    [[ "$columns" =~ ^[0-9]+$ ]] || columns=80
    printf '%s\n' "$columns"
}

# fit_banner_subtitle text room
# Print the text, shortened with "..." when it is longer than room columns.
# A room too small to hold anything useful leaves the text unchanged.
fit_banner_subtitle() {
    local text="$1" room="$2"

    if (( room >= 4 && ${#text} > room )); then
        text="${text:0:room-3}..."
    fi
    printf '%s\n' "$text"
}

# print_banner [subtitle part]...
# The parts are joined with a middle dot, or with a hyphen without UTF-8.
print_banner() {
    local BL="" B="" G="" S="" T="" D="" BOLD="" X=""
    local separator=' - ' divider='|' subtitle="" part bar columns room utf8=0

    if banner_uses_color; then
        if [[ "${COLORTERM:-}" == *truecolor* || "${COLORTERM:-}" == *24bit* ]]; then
            BL=$'\033[38;2;96;165;250m'
            B=$'\033[38;2;59;130;246m'
            G=$'\033[38;2;34;197;94m'
            S=$'\033[38;2;156;163;175m'
            T=$'\033[38;2;229;231;235m'
            D=$'\033[38;2;107;114;128m'
        else
            BL=$'\033[38;5;75m'
            B=$'\033[38;5;69m'
            G=$'\033[38;5;41m'
            S=$'\033[38;5;248m'
            T=$'\033[38;5;254m'
            D=$'\033[38;5;243m'
        fi
        BOLD=$'\033[1m'
        X=$'\033[0m'
    fi

    if banner_locale_is_utf8; then
        utf8=1
        separator=' · '
        divider='│'
    fi
    for part in "$@"; do
        [[ -n "$part" ]] || continue
        if [[ -n "$subtitle" ]]; then
            subtitle="$subtitle$separator$part"
        else
            subtitle="$part"
        fi
    done

    # Each form indents the subtitle differently. Leave the last column free,
    # so that the subtitle line never wraps.
    columns="$(terminal_columns)"
    if (( columns < BANNER_MIN_COLUMNS )); then
        if (( utf8 )); then
            subtitle="$(fit_banner_subtitle "$subtitle" $(( columns - 3 )))"
            printf '%s●%s %s%sUpdate Everything%s %s%s%s\n' "$G" "$X" "$BOLD" "$G" "$X" "$D" "$SCRIPT_VERSION" "$X"
            printf '  %sEverything, carefully.%s\n' "$T" "$X"
            [[ -z "$subtitle" ]] || printf '  %s%s%s\n' "$D" "$subtitle" "$X"
        else
            subtitle="$(fit_banner_subtitle "$subtitle" $(( columns - 6 )))"
            printf '%s[ok]%s %s%sUpdate Everything%s %s%s%s - Everything, carefully.\n' \
                "$G" "$X" "$BOLD" "$G" "$X" "$D" "$SCRIPT_VERSION" "$X"
            [[ -z "$subtitle" ]] || printf '     %s%s%s\n' "$D" "$subtitle" "$X"
        fi
        printf '\n'
        return 0
    fi

    room=$(( columns - BANNER_TEXT_COLUMN - 1 ))
    subtitle="$(fit_banner_subtitle "$subtitle" "$room")"

    bar="${D}${divider}${X}"
    printf '%s\n' \
        "                  ${BL}%${X}" \
        "           ${BL}@@@@@@@@${X}  ${B}@@@@@@@%${X}" \
        "        ${BL}@@@@@@@@@@@${X}  ${B}@%%%%@@@@@#${X}" \
        "      ${BL}@@@@@@@@@@@@@%${X} ${B}@@@@@@%%%@@@@${X}" \
        "     ${BL}@@@@@@@@@@${X}          ${B}@@@@@%%@@@${X}" \
        "    ${BL}@@@@@@@@${X}                ${B}@@@@@@@+${X}" \
        "  ${G}@@${X}   ${BL}=@@${X}                    ${B}@@${X}    ${S}@@${X}" \
        "  ${G}@@@@@@${X}                  ${G}@@${X}    ${S}@@@@@@${X}" \
        " ${G}@@%%%@@${X}                ${G}@@@@@${X}   ${S}@@@@@@@${X}" \
        " ${G}@%%%%@@${X}              ${G}@@@%@@%${X}   ${S}:@@@@@@${X}    ${bar} ${BOLD}${G}Update Everything${X} ${D}${SCRIPT_VERSION}${X}" \
        " ${G}@%%%%@${X}    ${G}@@@@${X}     ${G}*@@%@@@${X}      ${S}@@@@@@${X}    ${bar} ${T}Everything, carefully.${X}" \
        " ${G}@%%%%@${X}    ${G}@@@@@@${X}  ${G}@@@@@@${X}        ${S}@@@@@@${X}    ${bar} ${D}${subtitle}${X}" \
        " ${G}@%%%%@@${X}    ${G}@@@%@@@@@@@${X}          ${S}@@@@@@${X}" \
        " ${G}@@%%%@@${X}      ${G}@@@%%@@@${X}          ${S}@@@@@@@${X}" \
        "  ${G}@@%%%@@${X}       ${G}@@@@${X}           ${S}@@@@@@@${X}" \
        "  ${G}@@@%%%@@${X}                    ${S}@@@@@@@@${X}" \
        "   ${G}@@@%%%@@@${X}                ${S}@@@@@@@@@${X}" \
        "     ${G}@@%%%%@@@@${X}          ${S}@@@@@@@@@@${X}" \
        "      ${G}@@@@%%%%@@@@@@${X}${S}=@@@@@@@@@@@@@${X}" \
        "        ${G}@@@@@%%%%%@${X}  ${S}@@@@@@@@@@@${X}" \
        "           ${G}@@@@@@@@${X}  ${S}@@@@@@@@${X}" \
        "                  ${G}@${X}  ${S}@${X}" \
        ""
}

have_command() {
    command -v "$1" >/dev/null 2>&1
}

find_system_command() {
    PATH="$SYSTEM_COMMAND_PATH" command -v "$1" 2>/dev/null
}

have_system_command() {
    find_system_command "$1" >/dev/null
}

# Run a read-only system command from a trusted location, without elevation.
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

load_os_release() {
    if [[ -r /etc/os-release ]]; then
        # /etc/os-release is a system-owned shell-compatible data file.
        set +u
        # shellcheck disable=SC1091
        . /etc/os-release
        set -u

        DISTRO_NAME="${PRETTY_NAME:-${NAME:-Linux}}"
        OS_ID="${ID:-}"
        OS_ID_LIKE="${ID_LIKE:-}"
    fi
}

select_privilege_tool() {
    if is_root; then
        PRIVILEGE_TOOL=""
    elif PRIVILEGE_TOOL="$(find_system_command sudo)" && [[ -n "$PRIVILEGE_TOOL" ]]; then
        :
    elif PRIVILEGE_TOOL="$(find_system_command doas)" && [[ -n "$PRIVILEGE_TOOL" ]]; then
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
        elif [[ "$PRIVILEGE_TOOL" == */sudo || "$PRIVILEGE_TOOL" == */doas ]]; then
            print_command "$PRIVILEGE_TOOL" "$command_path" "$@"
        else
            print_command "<administrator>" "$command_path" "$@"
        fi
    elif is_root; then
        "$command_path" "$@"
    elif [[ "$PRIVILEGE_TOOL" == */sudo || "$PRIVILEGE_TOOL" == */doas ]]; then
        "$PRIVILEGE_TOOL" "$command_path" "$@"
    else
        error "This operation requires root privileges, but neither sudo nor doas is installed."
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

    case "$PRIVILEGE_TOOL" in
        */sudo)
            info "Requesting administrator privileges..."
            "$PRIVILEGE_TOOL" -v
            ;;
        */doas)
            info "Requesting administrator privileges..."
            "$PRIVILEGE_TOOL" "$(find_system_command true)"
            ;;
        *)
            error "Administrator privileges are required, but neither sudo nor doas is available."
            return 1
            ;;
    esac
}

run_task() {
    local label="$1"
    shift

    section "$label"
    CURRENT_TASK="$label"

    if "$@"; then
        if (( DRY_RUN )); then
            PLANNED+=("$label")
            info "$label was planned; no changes were made."
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

family_contains() {
    local needle="$1"
    local family=" ${OS_ID} ${OS_ID_LIKE} "
    [[ "$family" == *" $needle "* ]]
}

is_ostree_system() {
    [[ -e /run/ostree-booted ]]
}

is_nixos_system() {
    [[ -e /etc/NIXOS ]]
}

is_transactional_system() {
    [[ -r /etc/transactional-update.conf || -d /var/lib/transactional-update ]]
}

detect_system_manager() {
    # Immutable/image-based systems must be detected before their underlying
    # package tooling, which may also be installed but is not the host updater.
    if is_ostree_system && have_system_command rpm-ostree; then
        SYSTEM_MANAGER="rpm-ostree"
        return 0
    fi

    if is_nixos_system && have_system_command nixos-rebuild; then
        SYSTEM_MANAGER="nixos"
        return 0
    fi

    if have_system_command transactional-update && is_transactional_system; then
        SYSTEM_MANAGER="transactional-update"
        return 0
    fi

    # Prefer the package manager associated with the detected distribution.
    if family_contains debian || family_contains ubuntu; then
        have_system_command apt-get && SYSTEM_MANAGER="apt"
    elif family_contains fedora || family_contains rhel || family_contains centos; then
        if have_system_command dnf5; then
            SYSTEM_MANAGER="dnf5"
        elif have_system_command dnf; then
            SYSTEM_MANAGER="dnf"
        elif have_system_command yum; then
            SYSTEM_MANAGER="yum"
        fi
    elif family_contains suse || family_contains opensuse; then
        have_system_command zypper && SYSTEM_MANAGER="zypper"
    elif family_contains arch || family_contains manjaro; then
        have_system_command pacman && SYSTEM_MANAGER="pacman"
    elif family_contains alpine; then
        have_system_command apk && SYSTEM_MANAGER="apk"
    elif family_contains void; then
        have_system_command xbps-install && SYSTEM_MANAGER="xbps"
    elif family_contains gentoo; then
        have_system_command emerge && SYSTEM_MANAGER="emerge"
    elif family_contains solus; then
        have_system_command eopkg && SYSTEM_MANAGER="eopkg"
    elif family_contains clear-linux-os || family_contains clearlinux; then
        have_system_command swupd && SYSTEM_MANAGER="swupd"
    elif family_contains slackware; then
        have_system_command slackpkg && SYSTEM_MANAGER="slackpkg"
    elif family_contains mageia || family_contains mandriva; then
        have_system_command urpmi && SYSTEM_MANAGER="urpmi"
    fi

    [[ -n "$SYSTEM_MANAGER" ]] && return 0

    # Fallback for derivatives with incomplete or unusual os-release metadata.
    local candidate
    for candidate in apt-get dnf5 dnf yum zypper pacman apk xbps-install emerge eopkg swupd slackpkg urpmi; do
        if have_system_command "$candidate"; then
            case "$candidate" in
                apt-get)      SYSTEM_MANAGER="apt" ;;
                xbps-install) SYSTEM_MANAGER="xbps" ;;
                *)            SYSTEM_MANAGER="$candidate" ;;
            esac
            return 0
        fi
    done

    return 1
}

apt_phased_option() {
    if (( INCLUDE_PHASED_UPDATES )); then
        printf 'APT::Get::Always-Include-Phased-Updates=true'
    else
        printf 'APT::Get::Always-Include-Phased-Updates=false'
    fi
}

# List the packages APT will refuse to upgrade, most often because Ubuntu is
# still phasing them in. `-s` is a simulation and needs no privileges, so this
# neither changes the system nor triggers a second authentication prompt.
apt_kept_back_packages() {
    LC_ALL=C run_system_command apt-get -s \
        -o "$(apt_phased_option)" upgrade --with-new-pkgs 2>/dev/null |
    awk '
        /^The following packages have been kept back:/ { collecting = 1; next }
        collecting {
            if ($0 ~ /^[[:space:]]/) {
                for (field = 1; field <= NF; field++) { print $field }
                next
            }
            collecting = 0
        }
    '
}

record_apt_kept_back_packages() {
    local package reason
    local kept_back=""

    kept_back="$(apt_kept_back_packages)"
    [[ -n "$kept_back" ]] || return 0

    if (( INCLUDE_PHASED_UPDATES )); then
        reason="APT kept it back; a phased rollout is not the cause because --include-phased-updates was given"
    else
        reason="APT kept it back, which is usually a phased rollout; --include-phased-updates installs it anyway"
    fi

    while IFS= read -r package; do
        [[ -n "$package" ]] || continue
        warn "Holding back \"$package\": $reason."
        HELD_BACK+=("APT package: $package ($reason)")
    done <<EOF
$kept_back
EOF
}

update_apt() {
    as_root apt-get update || return 1

    record_apt_kept_back_packages

    as_root env PATH="$SYSTEM_COMMAND_PATH" DEBIAN_FRONTEND=noninteractive apt-get \
        -o "$(apt_phased_option)" \
        upgrade --with-new-pkgs -y || return 1

    if (( DO_CLEANUP )); then
        as_root env PATH="$SYSTEM_COMMAND_PATH" DEBIAN_FRONTEND=noninteractive apt-get autoremove -y &&
        as_root apt-get clean
    fi
}

update_dnf5() {
    if (( DO_CLEANUP )); then
        as_root dnf5 clean all || return 1
    fi

    as_root dnf5 --refresh upgrade -y || return 1

    if (( DO_CLEANUP )); then
        as_root dnf5 autoremove -y
    fi
}

update_dnf() {
    if (( DO_CLEANUP )); then
        as_root dnf clean all || return 1
    fi

    as_root dnf upgrade --refresh -y || return 1

    if (( DO_CLEANUP )); then
        as_root dnf autoremove -y
    fi
}

update_yum() {
    if (( DO_CLEANUP )); then
        as_root yum clean all || return 1
    fi

    as_root yum update -y
}

update_zypper() {
    if (( DO_CLEANUP )); then
        as_root zypper --non-interactive clean --all || return 1
    fi

    as_root zypper --non-interactive refresh &&
    as_root zypper --non-interactive --auto-agree-with-licenses update
}

update_transactional() {
    as_root transactional-update up
}

update_pacman() {
    as_root pacman -Syu --noconfirm
}

update_apk() {
    as_root apk update &&
    as_root apk upgrade
}

update_xbps() {
    # Void recommends a second pass when XBPS itself was updated in the first.
    as_root xbps-install -Suy &&
    as_root xbps-install -Suy
}

update_emerge() {
    as_root emerge --sync &&
    as_root emerge --update --deep --newuse --with-bdeps=y @world
}

update_eopkg() {
    as_root eopkg update-repo &&
    as_root eopkg upgrade -y
}

update_swupd() {
    as_root swupd update
}

update_rpm_ostree() {
    as_root rpm-ostree upgrade
}

update_nixos() {
    if [[ -f /etc/nixos/flake.nix ]] && have_system_command nix; then
        as_root nix flake update --flake /etc/nixos &&
        as_root nixos-rebuild switch --flake /etc/nixos
    else
        as_root nixos-rebuild switch --upgrade
    fi
}

update_slackpkg() {
    # Batch mode avoids the dialog-based package selection interface.
    as_root slackpkg -batch=on -default_answer=y update &&
    as_root slackpkg -batch=on -default_answer=y upgrade-all
}

update_urpmi() {
    as_root urpmi --auto-update --auto
}

update_system_packages() {
    case "$SYSTEM_MANAGER" in
        apt)                  update_apt ;;
        dnf5)                 update_dnf5 ;;
        dnf)                  update_dnf ;;
        yum)                  update_yum ;;
        zypper)               update_zypper ;;
        transactional-update) update_transactional ;;
        pacman)               update_pacman ;;
        apk)                  update_apk ;;
        xbps)                 update_xbps ;;
        emerge)               update_emerge ;;
        eopkg)                update_eopkg ;;
        swupd)                update_swupd ;;
        rpm-ostree)           update_rpm_ostree ;;
        nixos)                update_nixos ;;
        slackpkg)             update_slackpkg ;;
        urpmi)                update_urpmi ;;
        *)
            error "Internal error: unsupported manager '$SYSTEM_MANAGER'."
            return 1
            ;;
    esac
}

update_snap() {
    as_root snap refresh
}

update_flatpak() {
    local found=0
    local status=0
    local user_remotes system_remotes

    if ! user_remotes="$(flatpak remote-list --user --columns=name 2>&1)"; then
        printf '%s\n' "$user_remotes" >&2
        error "Unable to inspect the Flatpak user installation."
        status=1
    elif [[ -n "$user_remotes" ]]; then
        found=1
        run_command flatpak update --user -y || status=1
        if (( DO_CLEANUP )); then
            run_command flatpak uninstall --user --unused -y || status=1
        fi
    fi

    if ! system_remotes="$(flatpak remote-list --system --columns=name 2>&1)"; then
        printf '%s\n' "$system_remotes" >&2
        error "Unable to inspect the Flatpak system installation."
        status=1
    elif [[ -n "$system_remotes" ]]; then
        found=1
        as_root flatpak update --system -y || status=1
        if (( DO_CLEANUP )); then
            as_root flatpak uninstall --system --unused -y || status=1
        fi
    fi

    if (( ! found )); then
        info "Flatpak is installed, but no user or system remotes are configured."
    fi

    return "$status"
}

update_homebrew() {
    if is_root; then
        error "Homebrew must not be run as root. Run $SCRIPT_NAME as your normal user instead of with sudo."
        return 1
    fi

    run_brew_command update &&
    run_brew_command upgrade || return 1

    if (( DO_CLEANUP )); then
        run_brew_command cleanup
    fi
}

# Report a pending reboot without ever performing one. The marker file is the
# Debian and Ubuntu convention; `needs-restarting -r` is the DNF and YUM
# equivalent and exits 1 exactly when a reboot is required.
reboot_marker_exists() {
    [[ -f /var/run/reboot-required || -f /run/reboot-required ]]
}

reboot_is_required() {
    if reboot_marker_exists; then
        return 0
    fi

    if have_system_command needs-restarting; then
        local status=0
        run_system_command needs-restarting -r >/dev/null 2>&1 || status=$?
        if (( status == 1 )); then
            return 0
        fi
    fi

    return 1
}

print_summary() {
    local item

    section "Summary"
    printf 'Distribution: %s\n' "$DISTRO_NAME"

    if ((${#SUCCEEDED[@]})); then
        printf '\nCompleted:\n'
        for item in "${SUCCEEDED[@]}"; do
            printf '  - %s\n' "$item"
        done
    fi

    if ((${#PLANNED[@]})); then
        printf '\nPlanned (dry run; not executed):\n'
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

    if reboot_is_required; then
        printf '\n[NOTICE] A system reboot is required.\n'
    elif [[ "$SYSTEM_MANAGER" == "rpm-ostree" || "$SYSTEM_MANAGER" == "transactional-update" ]]; then
        printf '\n[NOTICE] Reboot to activate any staged system update.\n'
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
            --include-phased-updates)
                INCLUDE_PHASED_UPDATES=1
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

    if [[ "$(uname -s)" != "Linux" ]]; then
        error "This script supports Linux only."
        return 2
    fi

    if is_root; then
        error "Run this script as a normal user, not as root or through sudo."
        return 2
    fi

    trap 'handle_interrupt INT 130' INT
    trap 'handle_interrupt TERM 143' TERM

    load_os_release
    select_privilege_tool

    if (( DRY_RUN )); then
        print_banner "$DISTRO_NAME" "dry run"
    else
        print_banner "$DISTRO_NAME"
    fi
    info "Detected distribution: $DISTRO_NAME"

    if (( ! DO_SYSTEM_UPDATE )); then
        # Nothing is validated up front: Flatpak user installations and
        # Homebrew need no privileges, and as_root lets sudo or doas prompt
        # on demand for Snap and system Flatpak.
        SKIPPED+=("System packages (--skip-system-update)")
    elif detect_system_manager; then
        info "Detected native system manager: $SYSTEM_MANAGER"

        if validate_privileges; then
            run_task "System packages ($SYSTEM_MANAGER)" update_system_packages
        else
            FAILED+=("System packages ($SYSTEM_MANAGER): administrator privileges unavailable")
        fi
    else
        FAILED+=("System packages: no supported native package manager detected")
        error "No supported native package manager was detected."
    fi

    if (( DO_ADDITIONAL_MANAGERS )); then
        if have_system_command snap; then
            run_task "Snap packages" update_snap
        else
            SKIPPED+=("Snap")
        fi

        if have_system_command flatpak; then
            run_task "Flatpak applications and runtimes" update_flatpak
        else
            SKIPPED+=("Flatpak")
        fi

        if have_command brew; then
            run_task "Homebrew packages" update_homebrew
        else
            SKIPPED+=("Homebrew")
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
