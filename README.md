# Update Everything

A small collection of scripts that updates the operating system and supported package managers in one command.

The project is intended for people who want a straightforward way to install all available software updates without remembering a different set of commands for every platform or Linux distribution.

> [!IMPORTANT]
> The Linux script is available now. The macOS and Windows scripts will be added in later releases.

## Current status

| Platform | Script | Status |
|---|---|---|
| Linux | `linux/update-everything.sh` | Available |
| macOS | `macos/update-everything.sh` | Planned |
| Windows | `windows/update-everything.ps1` | Planned |

## Linux support

The Linux script detects the host distribution and selects one appropriate native system package manager. It then updates supported cross-distribution package managers that are installed.

### Native system package managers

- APT / APT Get — Debian, Ubuntu, Linux Mint, Pop!_OS, Kali Linux, and derivatives
- DNF5, DNF, or YUM — Fedora, Red Hat Enterprise Linux, Rocky Linux, AlmaLinux, CentOS, and derivatives
- Zypper — openSUSE and SUSE Linux Enterprise
- `transactional-update` — transactional openSUSE systems
- Pacman — Arch Linux, Manjaro, and derivatives
- APK — Alpine Linux
- XBPS — Void Linux
- Portage / `emerge` — Gentoo
- eopkg — Solus
- swupd — Clear Linux
- rpm-ostree — Fedora Silverblue, Kinoite, and other OSTree-based systems
- `nixos-rebuild` — NixOS
- Slackpkg — Slackware
- URPMI — Mageia and supported Mandriva derivatives

### Additional package managers

When installed, the script also updates:

- Snap
- Flatpak user and system installations
- Homebrew on Linux

## Linux installation

Clone the repository and make the script executable:

```bash
# Replace the URL with this repository's GitHub URL after publishing it.
git clone <repository-url>
cd update-everything
chmod +x linux/update-everything.sh
```

Run the script as your normal user:

```bash
./linux/update-everything.sh
```

Do not run the whole script with `sudo`. It requests `sudo` or `doas` only for operations that need administrator privileges. Running as the normal user is also required for Homebrew.

## Linux command-line options

```text
Usage: update-everything.sh [options]

Options:
  --system-only   Update only the native system package manager.
  --no-cleanup    Do not remove unused dependencies or cached packages.
  -h, --help      Show the help text.
  -v, --version   Show the script version.
```

Examples:

```bash
# Update the operating system and every supported additional manager detected
./linux/update-everything.sh

# Update only the distribution's native packages
./linux/update-everything.sh --system-only

# Install updates without automatic cache or unused-package cleanup
./linux/update-everything.sh --no-cleanup
```

## What the Linux script does

1. Confirms that it is running on Linux.
2. Reads `/etc/os-release` where available.
3. Detects the native system package manager associated with the distribution.
4. Requests administrator privileges using `sudo` or `doas` when required.
5. Refreshes package metadata and installs all available updates.
6. Includes APT packages held back only because of phased rollout.
7. Optionally removes unused dependencies and package caches.
8. Updates Snap, Flatpak, and Linux Homebrew installations when present.
9. Continues with unrelated package managers if one update operation fails.
10. Prints a summary and exits with a non-zero status if any operation failed.

## Scope and safety

This project installs updates that are already available through configured repositories and package managers. It does **not**:

- Perform major operating-system release upgrades, such as moving from one Ubuntu or Fedora release to the next.
- Add, remove, or modify software repositories.
- Install package managers that are not already present.
- Update project-level dependencies such as Composer packages, npm dependencies, Python virtual environments, Cargo projects, or application-specific dependency locks.
- Guarantee that a newly released package is free of regressions.

APT phased updates are deliberately included. Phasing normally delays selected non-security updates for part of the user base while regressions are monitored. Using this script opts into those packages immediately.

Automatic cleanup is enabled by default where the package manager offers an appropriate and reasonably safe command. Use `--no-cleanup` to disable it.

Always keep current backups of important data before applying system-wide updates.

## Exit codes

| Code | Meaning |
|---:|---|
| `0` | Every detected update operation completed successfully |
| `1` | At least one detected update operation failed |
| `2` | Invalid usage or unsupported operating system |

Individual package-manager commands may return other statuses internally. The script records those failures, continues where possible, and returns `1` after printing its summary.

## Reboot notices

The script reports a reboot requirement when:

- `/var/run/reboot-required` exists; or
- an rpm-ostree or transactional update may have staged a new deployment.

The script does not reboot the computer automatically.

## Development

Validate the Bash script syntax with:

```bash
bash -n linux/update-everything.sh
```

When ShellCheck is installed:

```bash
shellcheck linux/update-everything.sh
```

The updater is organised into separate functions for package-manager detection and execution. Support for another Linux distribution should normally be added by:

1. Extending `detect_system_manager`.
2. Adding a dedicated update function.
3. Adding the function to `update_system_packages`.
4. Updating this README.
5. Testing on the target distribution or in a suitable disposable environment.

## Planned repository layout

```text
update-everything/
├── linux/
│   └── update-everything.sh
├── macos/
│   └── update-everything.sh
├── windows/
│   └── update-everything.ps1
├── LICENSE
└── README.md
```

The empty `macos` and `windows` directories are placeholders until those scripts are added. Git does not track empty directories, so they may not appear after the initial push unless placeholder files are retained.

## Contributing

Bug reports and pull requests are welcome. When reporting a Linux problem, include:

- Distribution and version
- Package manager and version
- Script version from `--version`
- The relevant command output
- Whether the script was run as root or as a normal user

Do not include credentials, repository secrets, access tokens, or other sensitive information in an issue.

## License

This project is licensed under the GNU General Public License, version 3 or later. See [`LICENSE`](LICENSE).
