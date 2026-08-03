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

DO_CLEANUP=1
DO_ADDITIONAL_MANAGERS=1

SYSTEM_MANAGER=""
DISTRO_NAME="Linux"
OS_ID=""
OS_ID_LIKE=""

PRIVILEGE_TOOL=""

SUCCEEDED=()
FAILED=()
SKIPPED=()

usage() {
    cat <<USAGE
Usage: $SCRIPT_NAME [options]

Update all available packages managed by the Linux distribution's native
package manager, followed by supported cross-distribution managers.

Options:
  --system-only   Update only the native system package manager.
  --no-cleanup    Do not remove unused dependencies or cached packages.
  -h, --help      Show this help text.
  -v, --version   Show the script version.

Run this script as your normal user. It will request elevated privileges only
for commands that require them.
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

load_os_release() {
    if [[ -r /etc/os-release ]]; then
        # /etc/os-release is a system-owned shell-compatible data file.
        # shellcheck disable=SC1091
        set +u
        . /etc/os-release
        set -u

        DISTRO_NAME="${PRETTY_NAME:-${NAME:-Linux}}"
        OS_ID="${ID:-}"
        OS_ID_LIKE="${ID_LIKE:-}"
    fi
}

select_privilege_tool() {
    if (( EUID == 0 )); then
        PRIVILEGE_TOOL=""
    elif have_command sudo; then
        PRIVILEGE_TOOL="sudo"
    elif have_command doas; then
        PRIVILEGE_TOOL="doas"
    else
        PRIVILEGE_TOOL="unavailable"
    fi
}

as_root() {
    if (( EUID == 0 )); then
        "$@"
    elif [[ "$PRIVILEGE_TOOL" == "sudo" ]]; then
        sudo "$@"
    elif [[ "$PRIVILEGE_TOOL" == "doas" ]]; then
        doas "$@"
    else
        error "This operation requires root privileges, but neither sudo nor doas is installed."
        return 127
    fi
}

validate_privileges() {
    if (( EUID == 0 )); then
        return 0
    fi

    case "$PRIVILEGE_TOOL" in
        sudo)
            info "Requesting administrator privileges..."
            sudo -v
            ;;
        doas)
            info "Requesting administrator privileges..."
            doas true
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

family_contains() {
    local needle="$1"
    local family=" ${OS_ID} ${OS_ID_LIKE} "
    [[ "$family" == *" $needle "* ]]
}

detect_system_manager() {
    # Immutable/image-based systems must be detected before their underlying
    # package tooling, which may also be installed but is not the host updater.
    if [[ -e /run/ostree-booted ]] && have_command rpm-ostree; then
        SYSTEM_MANAGER="rpm-ostree"
        return 0
    fi

    if [[ -e /etc/NIXOS ]] && have_command nixos-rebuild; then
        SYSTEM_MANAGER="nixos"
        return 0
    fi

    if have_command transactional-update \
        && { [[ -r /etc/transactional-update.conf ]] || [[ -d /var/lib/transactional-update ]]; }; then
        SYSTEM_MANAGER="transactional-update"
        return 0
    fi

    # Prefer the package manager associated with the detected distribution.
    if family_contains debian || family_contains ubuntu; then
        have_command apt-get && SYSTEM_MANAGER="apt"
    elif family_contains fedora || family_contains rhel || family_contains centos; then
        if have_command dnf5; then
            SYSTEM_MANAGER="dnf5"
        elif have_command dnf; then
            SYSTEM_MANAGER="dnf"
        elif have_command yum; then
            SYSTEM_MANAGER="yum"
        fi
    elif family_contains suse || family_contains opensuse; then
        have_command zypper && SYSTEM_MANAGER="zypper"
    elif family_contains arch || family_contains manjaro; then
        have_command pacman && SYSTEM_MANAGER="pacman"
    elif family_contains alpine; then
        have_command apk && SYSTEM_MANAGER="apk"
    elif family_contains void; then
        have_command xbps-install && SYSTEM_MANAGER="xbps"
    elif family_contains gentoo; then
        have_command emerge && SYSTEM_MANAGER="emerge"
    elif family_contains solus; then
        have_command eopkg && SYSTEM_MANAGER="eopkg"
    elif family_contains clear-linux-os || family_contains clearlinux; then
        have_command swupd && SYSTEM_MANAGER="swupd"
    elif family_contains slackware; then
        have_command slackpkg && SYSTEM_MANAGER="slackpkg"
    elif family_contains mageia || family_contains mandriva; then
        have_command urpmi && SYSTEM_MANAGER="urpmi"
    fi

    [[ -n "$SYSTEM_MANAGER" ]] && return 0

    # Fallback for derivatives with incomplete or unusual os-release metadata.
    local candidate
    for candidate in apt-get dnf5 dnf yum zypper pacman apk xbps-install emerge eopkg swupd slackpkg urpmi; do
        if have_command "$candidate"; then
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

update_apt() {
    as_root apt-get clean &&
    as_root apt-get update &&
    as_root env DEBIAN_FRONTEND=noninteractive apt-get \
        -o APT::Get::Always-Include-Phased-Updates=true \
        dist-upgrade -y || return 1

    if (( DO_CLEANUP )); then
        as_root env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y
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
    if [[ -f /etc/nixos/flake.nix ]] && have_command nix; then
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

flatpak_has_user_installation() {
    [[ -n "$(flatpak remote-list --user --columns=name 2>/dev/null)" ]]
}

flatpak_has_system_installation() {
    [[ -n "$(flatpak remote-list --system --columns=name 2>/dev/null)" ]]
}

update_flatpak() {
    local found=0
    local status=0

    if flatpak_has_user_installation; then
        found=1
        flatpak update --user -y || status=1
        if (( DO_CLEANUP )); then
            flatpak uninstall --user --unused -y || status=1
        fi
    fi

    if flatpak_has_system_installation; then
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
    if (( EUID == 0 )); then
        error "Homebrew must not be run as root. Run $SCRIPT_NAME as your normal user instead of with sudo."
        return 1
    fi

    brew update &&
    brew upgrade || return 1

    if (( DO_CLEANUP )); then
        brew cleanup
    fi
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

    if [[ -f /var/run/reboot-required ]]; then
        printf '\n[NOTICE] A system reboot is required.\n'
    elif [[ "$SYSTEM_MANAGER" == "rpm-ostree" || "$SYSTEM_MANAGER" == "transactional-update" ]]; then
        printf '\n[NOTICE] Reboot to activate any staged system update.\n'
    fi
}

main() {
    while (($#)); do
        case "$1" in
            --system-only)
                DO_ADDITIONAL_MANAGERS=0
                ;;
            --no-cleanup)
                DO_CLEANUP=0
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

    if [[ "$(uname -s)" != "Linux" ]]; then
        error "This script supports Linux only."
        return 2
    fi

    if (( EUID == 0 )) && [[ -n "${SUDO_USER:-}" ]]; then
        warn "Run this script without sudo. It elevates only the commands that need it."
    fi

    load_os_release
    select_privilege_tool

    printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
    info "Detected distribution: $DISTRO_NAME"

    if detect_system_manager; then
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
        if have_command snap; then
            run_task "Snap packages" update_snap
        else
            SKIPPED+=("Snap")
        fi

        if have_command flatpak; then
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

    print_summary

    if ((${#FAILED[@]})); then
        error "Updates finished with one or more failures."
        return 1
    fi

    info "All detected package managers completed successfully."
}

main "$@"
