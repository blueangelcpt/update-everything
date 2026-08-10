# Update Everything

[![CI](https://github.com/blueangelcpt/update-everything/actions/workflows/ci.yml/badge.svg)](https://github.com/blueangelcpt/update-everything/actions/workflows/ci.yml)
[![GitHub release](https://img.shields.io/github/v/release/blueangelcpt/update-everything)](https://github.com/blueangelcpt/update-everything/releases)
[![License: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue.svg)](LICENSE)

A small collection of scripts that updates the operating system and supported package managers in one command.

The project is intended for people who want a straightforward way to install all available software updates without remembering a different set of commands for every platform or Linux distribution.

## Current status

| Platform | Script | Status |
|---|---|---|
| Linux | `linux/update-everything.sh` | Available |
| Windows | `windows/update-everything.ps1` | Available |
| macOS | `macos/update-everything.sh` | Available |

All three scripts use the repository-wide version `2.0.0`.

> [!IMPORTANT]
> The macOS script does not upgrade a Mac to macOS 26 or later by default, and
> never performs any major macOS upgrade unless asked. Maintenance updates for
> the release already installed remain eligible. See
> [Protection against unsupported macOS releases](#protection-against-unsupported-macos-releases).

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
git clone https://github.com/blueangelcpt/update-everything.git
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
  --dry-run       Detect managers and print mutating commands without running them.
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

# Safely preview the managers and commands without changing the machine
./linux/update-everything.sh --dry-run
```

## What the Linux script does

1. Confirms that it is running on Linux.
2. Reads `/etc/os-release` where available.
3. Detects the native system package manager associated with the distribution.
4. Requests administrator privileges using `sudo` or `doas` when required.
5. Refreshes package metadata and installs available updates. APT uses
   `upgrade --with-new-pkgs`, which may add required dependencies but does not
   remove installed packages.
6. Includes APT packages held back only because of phased rollout.
7. Optionally removes unused dependencies and package caches.
8. Updates Snap, Flatpak, and Linux Homebrew installations when present.
9. Continues with unrelated package managers if one update operation fails.
10. Prints a summary and exits with a non-zero status if any operation failed.

## Windows support

The Windows script installs available Windows updates, then runs every supported application updater that is installed on the machine. Each updater is run in its own silent or unattended mode, so the script never stops to ask a question.

### System updater

- Windows Update, through the [PSWindowsUpdate](https://www.powershellgallery.com/packages/PSWindowsUpdate) module when it is installed, or through the Windows Update Agent COM API otherwise

Software updates are installed by default. Add `-IncludeDrivers` to also install the driver updates that Windows Update offers.

### Application updaters

When installed, the script also updates:

- WinGet packages
- Chocolatey packages
- Scoop packages and buckets
- Applications known to the Patch My PC Home Updater
- Microsoft Store applications

An updater that is not installed is reported as skipped, not as a failure.

## Windows installation

Clone the repository in PowerShell:

```powershell
git clone https://github.com/blueangelcpt/update-everything.git
cd update-everything
```

PowerShell blocks unsigned scripts by default. Either allow local scripts for your account once:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

Or bypass the policy for a single run, which changes no setting:

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\update-everything.ps1
```

A file downloaded as a ZIP archive rather than cloned is marked as coming from the internet. Unblock it before running it:

```powershell
Unblock-File .\windows\update-everything.ps1
```

## Windows usage

Run the script from an **elevated** PowerShell session. Windows Update and Chocolatey both require administrator privileges:

```powershell
.\windows\update-everything.ps1
```

Scoop refuses to run elevated, because it installs into the profile of the user who owns the installation. The script skips Scoop in an elevated session and reports it as skipped. To update Scoop as well, run the script a second time as your normal user:

```powershell
.\windows\update-everything.ps1 -SkipWindowsUpdate
```

## Windows command-line options

| Option | Effect |
|---|---|
| `-SystemOnly` | Install Windows updates only, and run no application updater. |
| `-SkipWindowsUpdate` | Run the application updaters only. |
| `-IncludeDrivers` | Also install driver updates offered by Windows Update. |
| `-NoCleanup` | Skip Scoop's old-version and download-cache cleanup commands. Other managers retain their own built-in behavior. |
| `-PatchMyPCPath <path>` | Full path to `PatchMyPC.exe`, for a portable copy the script does not find on its own. |
| `-DryRun` | Detect updaters and show mutating work without executing it. |
| `-Version` | Print the script version and exit. |

The script uses standard PowerShell help. Read the full description with:

```powershell
Get-Help .\windows\update-everything.ps1 -Detailed
```

Examples:

```powershell
# Install Windows updates and run every detected application updater
.\windows\update-everything.ps1

# Install Windows updates only
.\windows\update-everything.ps1 -SystemOnly

# Run the application updaters only, including a portable Patch My PC copy
.\windows\update-everything.ps1 -SkipWindowsUpdate -PatchMyPCPath "$env:USERPROFILE\Downloads\PatchMyPC.exe"

# Preview without installing updates, accepting EULAs, or cleaning up packages
.\windows\update-everything.ps1 -DryRun
```

## What the Windows script does

1. Confirms that it is running on Windows and reports the detected release and build.
2. Reports whether the session is elevated, and which updaters that allows.
3. Searches for, downloads, and installs applicable Windows updates, accepting each licence agreement and skipping any update that would prompt for input.
4. Runs `winget upgrade --all` in silent mode, accepting package and source agreements.
5. Runs `choco upgrade all --yes` without progress output.
6. Runs `scoop update` and `scoop update *`, and cleans up old versions and the download cache unless `-NoCleanup` is given.
7. Verifies Patch My PC's Authenticode publisher, then runs the Home Updater
   with `/s`, its fully silent automatic mode.
8. Triggers a Microsoft Store update scan, which installs what it finds in the background.
9. Continues with the remaining updaters if one of them fails.
10. Prints a summary and exits with a non-zero status if any operation failed.

### How the Windows script finds each updater

| Updater | How it is located |
|---|---|
| WinGet | In a normal session, `PATH` and the per-user App Execution Alias; otherwise the newest App Installer package in a 64-bit or 32-bit Program Files root. Elevated runs never trust per-user candidates. |
| Chocolatey | `%ChocolateyInstall%\bin\choco.exe`, then `%ProgramData%\chocolatey\bin\choco.exe` |
| Scoop | `PATH` (`scoop.cmd` or `scoop.exe`) |
| Patch My PC | Signed machine-wide Program Files or HKLM `App Paths` candidates, or an explicitly supplied `-PatchMyPCPath` |
| Microsoft Store | The `MDM_EnterpriseModernAppManagement_AppManagement01` management class |

The Patch My PC Home Updater is often kept as a portable executable in a
downloads folder. The script never auto-discovers executables in user-writable
directories. Pass `-PatchMyPCPath` for a portable copy; the file is still
refused unless Windows reports a valid Patch My PC Authenticode signature.

## macOS support

The macOS script installs available macOS updates, then updates every supported application manager installed on the Mac. It is written for the GNU bash 3.2 that ships with macOS, so it needs no newer bash to run.

### System updater

- `softwareupdate`, which covers macOS updates, Safari, and the Xcode Command Line Tools

### Additional managers

When installed, the script also updates:

- Mac App Store applications, through [`mas`](https://github.com/mas-cli/mas)
- Homebrew formulae and casks
- MacPorts ports
- Nix packages installed in a user profile

Homebrew is the macOS counterpart of Chocolatey and Scoop, and MacPorts is the other established equivalent. `--greedy-casks` adds `brew upgrade --cask --greedy`, which also refreshes casks that carry their own updater; that is the closest macOS equivalent of the Patch My PC Home Updater. It is not the default, because it re-downloads applications that would have updated themselves.

## Protection against unsupported macOS releases

Major upgrades to macOS 26 and later are held back by default. The script reads
every update that `softwareupdate` offers, works out the macOS release each one
leads to, and then installs the approved ones by label. It never runs
`softwareupdate --install --all`, so a held-back release cannot be installed as
a side effect of installing something else.

Three rules decide what is held back:

1. Any major-upgrade target newer than the maximum, which is macOS 25 by
   default, is held back. Raise it with `--max-macos-major` only after a newer
   release has been verified on the machines it will run on. Maintenance
   updates for the release already installed remain eligible even if that Mac
   is already above the ceiling.
2. A major upgrade, meaning any release newer than the one currently installed, is held back unless `--allow-major-upgrade` is given.
3. On a Mac running OpenCore Legacy Patcher, a major upgrade is always held back, even with `--allow-major-upgrade`.

Updates within the installed release, such as 15.6 to 15.6.1, and non-macOS updates such as Safari and the Command Line Tools, are installed normally. Every held-back update is named in the summary along with the reason it was held back.

## OpenCore Legacy Patcher

Macs running an otherwise unsupported release of macOS through [OpenCore Legacy Patcher](https://dortania.github.io/OpenCore-Legacy-Patcher/) need care, because a macOS update removes the root patches that make their hardware work.

The script looks for OCLP in several independent places, since any one of them can be absent depending on how the Mac was set up:

- `/System/Library/CoreServices/OpenCore-Legacy-Patcher.plist`
- `/System/Library/CoreServices/OpenCore-Patcher.app`
- `/Library/Application Support/Dortania`
- `/Applications/OpenCore-Patcher.app`
- The `OCLP-Version` NVRAM variable
- An `opencore-version` entry in the booted device tree

When OCLP is detected, the script:

- Refuses every major macOS upgrade, so that upgrades stay a deliberate decision made through OCLP.
- Warns that OCLP itself should be updated first, so that the installed version supports the release being applied.
- Prints a reminder after installing a macOS update that root patches must be re-applied in OpenCore Legacy Patcher after the restart.

Minor macOS updates are still installed on an OCLP Mac, because they are the security updates for the release already running. They do remove root patches until OCLP re-applies them, so use `--skip-system-update` to update applications now and leave macOS for a time when you can re-patch and restart.

## macOS installation

Clone the repository and make the script executable:

```bash
git clone https://github.com/blueangelcpt/update-everything.git
cd update-everything
chmod +x macos/update-everything.sh
```

Run the script as your normal user:

```bash
./macos/update-everything.sh
```

Do not run the whole script with `sudo`. It requests `sudo` only for operations that need administrator privileges, and Homebrew refuses to run as root.

## macOS command-line options

```text
Usage: update-everything.sh [options]

Options:
  --system-only            Update only macOS itself.
  --skip-system-update     Update only the additional managers.
  --no-cleanup             Do not remove cached downloads or unused packages.
  --greedy-casks           Also upgrade Homebrew casks that update themselves.
  --allow-major-upgrade    Permit an upgrade to a newer major macOS release,
                           up to the supported maximum. Refused on a Mac
                           running OpenCore Legacy Patcher.
  --max-macos-major N      Highest target for a major macOS upgrade
                           (default: 25).
  --dry-run                List and evaluate updates, but do not install or
                           clean up anything.
  -h, --help               Show the help text.
  -v, --version            Show the script version.
```

Examples:

```bash
# Install macOS updates and update every detected manager
./macos/update-everything.sh

# Update applications now, and leave macOS for a time when you can restart
./macos/update-everything.sh --skip-system-update

# Also refresh casks that normally update themselves
./macos/update-everything.sh --greedy-casks

# Allow macOS 26 once it has been verified on this Mac
./macos/update-everything.sh --allow-major-upgrade --max-macos-major 26

# Evaluate every offered label without installing or cleaning up anything
./macos/update-everything.sh --dry-run
```

## What the macOS script does

1. Confirms that it is running on macOS, and reports the release, hardware model, and architecture.
2. Looks for OpenCore Legacy Patcher, and reports the evidence it found.
3. Lists everything `softwareupdate` offers, and decides for each item whether it may be installed.
4. Installs the approved updates one label at a time, so a held-back release can never be installed by accident.
5. Upgrades Mac App Store applications with `mas`.
6. Updates Homebrew, upgrades formulae and casks, and cleans up unless `--no-cleanup` is given.
7. Runs `port selfupdate` and upgrades outdated MacPorts ports, then removes inactive ports.
8. Updates Nix channels and packages in a user profile.
9. Continues with the remaining managers if one of them fails.
10. Prints a summary, any restart notice, and the OCLP root-patch reminder where it applies.

## Scope and safety

This project installs updates that are already available through configured repositories, package managers, and update services. It does **not**:

- Perform major operating-system release upgrades, such as moving from one Ubuntu or Fedora release to the next, installing a Windows feature update that Windows Update does not already offer, or upgrading macOS to a newer major release unless `--allow-major-upgrade` is given.
- Upgrade a Mac to macOS 26 or later unless the maximum is deliberately raised
  with `--max-macos-major`. Maintenance updates for an already-installed
  release remain eligible.
- Add, remove, or modify software repositories, package sources, or Windows Update settings.
- Install package managers or updaters that are not already present.
- Update project-level dependencies such as Composer packages, npm dependencies, Python virtual environments, Cargo projects, NuGet packages, or application-specific dependency locks.
- Reboot the computer.
- Guarantee that a newly released package is free of regressions.

APT phased updates are deliberately included. Phasing normally delays selected non-security updates for part of the user base while regressions are monitored. Using this script opts into those packages immediately.

On Windows, every updater runs unattended, which means each one accepts its own licence and package agreements on your behalf. Windows updates that would prompt for input are skipped and named in the output rather than answered automatically.

On macOS, a macOS update removes the root patches on a Mac running OpenCore Legacy Patcher, and the hardware they support stops working until the patches are re-applied. Read [OpenCore Legacy Patcher](#opencore-legacy-patcher) before running the script on such a Mac.

Automatic cleanup is enabled by default where the package manager offers an
appropriate and reasonably safe command. Use `--no-cleanup` on Linux and macOS,
or `-NoCleanup` on Windows, to disable the script's explicit cleanup commands.
A manager may still apply its own inseparable installation behavior.

All platforms provide a dry-run mode. Linux prints the trusted commands it
would run. macOS performs the read-only `softwareupdate --list` and manager
inventory queries needed to evaluate labels. Windows performs a read-only
Windows Update search and updater discovery. Dry runs do not elevate, accept
EULAs, download or install updates, refresh package metadata, trigger Store
updates, or clean up packages. A dry run is a preview of orchestration, not a
guarantee that a later live update will succeed.

Always keep current backups of important data before applying system-wide updates.

## Exit codes

| Code | Meaning |
|---:|---|
| `0` | Every detected update operation completed successfully |
| `1` | At least one detected update operation failed |
| `2` | Invalid or conflicting script options, or unsupported operating system |

Individual package-manager commands may return other statuses internally. The script records those failures, continues where possible, and returns `1` after printing its summary.

PowerShell itself handles unknown parameter names before the script begins and
may use its own non-zero host exit code. Conflicting Windows modes and an
unsupported operating system return `2` from the script.

## Reboot notices

On Linux, the script reports a reboot requirement when:

- `/var/run/reboot-required` exists; or
- an rpm-ostree or transactional update may have staged a new deployment.

On Windows, it reports a reboot requirement when:

- Windows Update reports that the installed updates need one;
- Chocolatey returns exit code `1641` or `3010`; or
- a pending servicing operation or a queued file rename is recorded in the registry.

On macOS, it reports a restart requirement when an installed update was listed with `Action: restart`. On a Mac running OpenCore Legacy Patcher, it also prints a reminder to re-apply root patches after that restart.

None of the scripts reboots the computer automatically.

## Development

Validate the Bash script syntax with:

```bash
bash -n linux/update-everything.sh
```

When ShellCheck is installed:

```bash
shellcheck linux/update-everything.sh
```

The same two checks apply to the macOS script:

```bash
bash -n macos/update-everything.sh
```

The macOS script is written for the GNU bash 3.2 that ships with macOS. Avoid associative arrays, `mapfile`, `readarray`, and case-conversion expansions such as `${variable,,}`, none of which exist in that version.

Validate the PowerShell script syntax without running it:

```powershell
$errors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\windows\update-everything.ps1).Path, [ref]$null, [ref]$errors)
$errors
```

When PSScriptAnalyzer is installed:

```powershell
Invoke-ScriptAnalyzer -Path .\windows\update-everything.ps1 -Settings .\PSScriptAnalyzerSettings.psd1
```

Run all safe shell tests with:

```bash
tests/run-shell-tests.sh
```

Run the Windows tests with Pester 5.7.1 or later in Windows PowerShell 5.1:

```powershell
Invoke-Pester -Path .\tests\windows -CI
```

CI runs syntax checks, pinned ShellCheck 0.10.0, the shell tests under Linux
and Apple's Bash 3.2, the Windows PowerShell 5.1 parser, pinned
PSScriptAnalyzer 1.25.0, and Pester. It never runs a live updater. The automated
tests use functions, mocked commands, fixtures, and dry-run paths; they do not
replace manual testing on each supported distribution, Windows release, Intel
and Apple silicon Macs, or OCLP-patched hardware.

All three scripts are organised the same way: detection is separate from execution, every updater has its own function, and each one is run through a wrapper that records success or failure and lets the remaining updaters continue.

Support for another Linux distribution should normally be added by:

1. Extending `detect_system_manager`.
2. Adding a dedicated update function.
3. Adding the function to `update_system_packages`.
4. Updating this README.
5. Testing on the target distribution or in a suitable disposable environment.

Support for another Windows updater should normally be added by:

1. Adding a function that locates the updater's executable.
2. Adding a dedicated update function that runs it in its silent mode.
3. Adding both to `Invoke-ApplicationUpdate`, including the skip reason used when the updater is not installed.
4. Updating this README.
5. Testing on a Windows installation or in a suitable disposable virtual machine.

Support for another macOS manager should normally be added by:

1. Adding a dedicated update function that runs the manager without prompting.
2. Adding the detection and the `run_task` call to `main`, including the skip reason used when the manager is not installed.
3. Updating this README.
4. Testing on a Mac, and on a Mac running OpenCore Legacy Patcher where the change affects macOS updates.

Changes to the macOS version guard should be covered by exercising `should_install_update` directly, with the current release, the maximum, the OCLP flag, and the major-upgrade flag set to each combination that matters.

## Repository layout

```text
update-everything/
├── .github/workflows/ci.yml
├── linux/
│   └── update-everything.sh
├── macos/
│   ├── README.md
│   └── update-everything.sh
├── windows/
│   ├── README.md
│   └── update-everything.ps1
├── tests/
├── CHANGELOG.md
├── CONTRIBUTING.md
├── SECURITY.md
├── LICENSE
└── README.md
```

## Contributing

Bug reports and pull requests are welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md)
for validation and safety requirements. When reporting a Linux problem, include:

- Distribution and version
- Package manager and version
- Script version from `--version`
- The relevant command output
- Whether the script was run as root or as a normal user

When reporting a Windows problem, include:

- Windows edition, release version, and build number
- The updater involved, and its version
- Script version from `-Version`
- The output of `$PSVersionTable.PSVersion`
- The relevant command output, including the script's summary
- Whether the session was elevated

When reporting a macOS problem, include:

- macOS version from `sw_vers`, and the model from `sysctl -n hw.model`
- Whether the Mac runs OpenCore Legacy Patcher, and which version
- Script version from `--version`
- The manager involved, and its version
- The relevant command output, including the script's summary and the `softwareupdate --list` output where macOS updates are involved

Do not include credentials, repository secrets, access tokens, or other sensitive information in an issue.

## Versioning and releases

The repository uses one [Semantic Version](https://semver.org/) for all three
scripts. A release updates each embedded version together, adds a changelog
entry, and publishes an annotated `vMAJOR.MINOR.PATCH` tag from a tested commit
on `main`. Security and bug fixes use patch releases, backward-compatible
functionality uses minor releases, and intentional breaking changes use major
releases. See [`CHANGELOG.md`](CHANGELOG.md) for release history and
[`SECURITY.md`](SECURITY.md) for private vulnerability reporting.

## License

This project is licensed under the GNU General Public License, version 3 or later. See [`LICENSE`](LICENSE).
