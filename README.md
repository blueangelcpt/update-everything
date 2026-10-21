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

All three scripts use the repository-wide version `2.1.0`.

> [!IMPORTANT]
> The macOS script never performs a major macOS upgrade unless asked. On a Mac
> running OpenCore Legacy Patcher it additionally refuses any release that the
> installed OCLP version does not support. A Mac without OCLP has no version
> ceiling, and never sees OCLP mentioned in the output. See
> [Major macOS upgrades](#major-macos-upgrades).

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

Do not run the whole script with `sudo`: it exits with status `2` if started as root. It requests `sudo` or `doas` only for the operations that need administrator privileges, and resolves those privileged executables from fixed system directories rather than from the caller's `PATH`. Running as the normal user is also required for Homebrew.

## Linux command-line options

```text
Usage: update-everything.sh [options]

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
  -h, --help               Show the help text.
  -v, --version            Show the script version.
```

Examples:

```bash
# Update the operating system and every supported additional manager detected
./linux/update-everything.sh

# Update only the distribution's native packages
./linux/update-everything.sh --system-only

# Update only Snap, Flatpak, and Homebrew, leaving system packages alone
./linux/update-everything.sh --skip-system-update

# Install updates without automatic cache or unused-package cleanup
./linux/update-everything.sh --no-cleanup

# Also install Ubuntu updates that are still being phased in
./linux/update-everything.sh --include-phased-updates

# Safely preview the managers and commands without changing the machine
./linux/update-everything.sh --dry-run
```

## What the Linux script does

1. Confirms that it is running on Linux, and refuses to run as root so that only
   the individual operations that need it are elevated.
2. Reads `/etc/os-release` where available.
3. Detects the native system package manager associated with the distribution.
4. Requests administrator privileges using `sudo` or `doas` when required.
   With `--skip-system-update`, steps 3 to 7 are skipped and no privileges are
   requested up front; Snap and system-wide Flatpak updates still elevate, so
   `sudo` or `doas` may prompt when the script reaches them.
5. Refreshes package metadata and installs available updates. APT uses
   `upgrade --with-new-pkgs`, which may add required dependencies but does not
   remove installed packages.
6. Names every APT package the distribution kept back, most often because of a
   phased rollout, in a separate "Held back" section of the summary.
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
| `-SkipWindowsUpdate` | Run the application updaters only. `-SkipSystemUpdate` is an alias. |
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
5. Runs `choco upgrade all --yes` without progress output, accepting only the
   exit codes Chocolatey documents as valid and treating a reboot-detection
   code as a failure that needs attention.
6. Runs `scoop update` and `scoop update *`, and cleans up old versions and the download cache unless `-NoCleanup` is given.
7. Verifies Patch My PC's Authenticode publisher, then runs the Home Updater
   with `/s`, its fully silent automatic mode.
8. Triggers a Microsoft Store update scan, which installs what it finds in the background. The scan needs an elevated session, and is reported as skipped in a normal one.
9. Continues with the remaining updaters if one of them fails.
10. Prints a summary and exits with a non-zero status if any operation failed.

### How the Windows script finds each updater

| Updater | How it is located |
|---|---|
| WinGet | In a normal session, `PATH` and the per-user App Execution Alias; otherwise the newest App Installer package in a 64-bit or 32-bit Program Files root. Elevated runs never trust per-user candidates. |
| Chocolatey | `%ChocolateyInstall%\bin\choco.exe`, then `%ProgramData%\chocolatey\bin\choco.exe` |
| Scoop | `PATH` (`scoop.cmd` or `scoop.exe`) |
| Patch My PC | Signed machine-wide Program Files or HKLM `App Paths` candidates, or an explicitly supplied `-PatchMyPCPath` |
| Microsoft Store | The `MDM_EnterpriseModernAppManagement_AppManagement01` management class, which only answers an elevated session |

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

## Major macOS upgrades

The script reads every update that `softwareupdate` offers, works out the macOS
release each one leads to, and then installs the approved ones by label. It
never runs `softwareupdate --install --all`, so a held-back release cannot be
installed as a side effect of installing something else.

Two rules decide what is held back on an ordinary Mac:

1. A major upgrade, meaning any release newer than the one currently
   installed, is held back unless `--allow-major-upgrade` is given.
2. An offer for a release older than the one installed is always held back.

A Mac without OpenCore Legacy Patcher has no version ceiling. With
`--allow-major-upgrade` it may be upgraded to whatever release Apple offers it,
because Apple offers a major upgrade only to a Mac it supports.

A third rule applies on a Mac running OpenCore Legacy Patcher, where the
installed OCLP version sets a ceiling:

3. A release newer than the one the installed OCLP version supports is held
   back, even with `--allow-major-upgrade`.

| Installed OCLP | Highest macOS release installed |
|---|---|
| 3.x and newer | macOS 26 Tahoe |
| 2.5.x and older | macOS 15 Sequoia |
| Version not confirmed | macOS 15 Sequoia, assumed |

macOS has no releases 16 to 25, so the supported numbers jump from 15 straight
to 26. An OCLP generation newer than 3.x keeps the macOS 26 ceiling until it
has been verified; `--max-macos-major` raises it in the meantime, and that
option appears in `--help` only on a Mac where a ceiling applies.

Updates within the installed release, such as 15.6 to 15.6.1, and non-macOS
updates such as Safari and the Command Line Tools, are installed normally, on
every Mac. Every held-back update is named in the summary along with the reason
it was held back.

## OpenCore Legacy Patcher

Macs running an otherwise unsupported release of macOS through [OpenCore Legacy Patcher](https://dortania.github.io/OpenCore-Legacy-Patcher/) need care, because a macOS update removes the root patches that make their hardware work.

The script looks for OCLP in several independent places, since any one of them can be absent depending on how the Mac was set up:

- `/System/Library/CoreServices/OpenCore-Legacy-Patcher.plist`
- `/System/Library/CoreServices/OpenCore-Patcher.app`
- `/Library/Application Support/Dortania`
- `/Applications/OpenCore-Patcher.app`
- The `OCLP-Version` NVRAM variable
- An `opencore-version` entry in the booted device tree

OCLP exists only for Intel Macs that Apple no longer supports, so a Mac on
Apple silicon never looks for it.

When OCLP is detected, the script:

- Reads the version of each OCLP component separately — the application, the
  active bootloader from the `OCLP-Version` NVRAM variable, and the root
  patches from the exact `OpenCore Legacy Patcher` key of their property list —
  because OCLP updates them in three separate steps. The **oldest** component
  decides the newest macOS release it may install.
- Refuses any major upgrade beyond that release, even with
  `--allow-major-upgrade`, and refuses every upgrade past macOS 15 unless both
  the active bootloader and the application versions can be read.
- Warns when the components are at different versions, which means an OCLP
  update was started but not finished.
- Warns that OCLP itself should be updated first, so that the installed version supports the release being applied.
- Prints a reminder after installing a macOS update that root patches must be re-applied in OpenCore Legacy Patcher after the restart.

When OCLP is not detected, nothing about it is printed, no ceiling is applied,
and `--max-macos-major` is not offered in the help text.

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
  --allow-major-upgrade    Permit an upgrade to a newer major macOS release.
  --max-macos-major N      Highest major macOS release to install on this Mac,
                           overriding the release that the installed OpenCore
                           Legacy Patcher is known to support. Listed in
                           --help only on a Mac where a ceiling applies.
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

# Allow a major upgrade to whatever release Apple offers this Mac
./macos/update-everything.sh --allow-major-upgrade

# On an OCLP Mac, allow macOS 27 once that OCLP version has been verified
./macos/update-everything.sh --allow-major-upgrade --max-macos-major 27

# Evaluate every offered label without installing or cleaning up anything
./macos/update-everything.sh --dry-run
```

## What the macOS script does

1. Confirms that it is running on macOS, and reports the release, hardware model, and architecture.
2. Looks for OpenCore Legacy Patcher on an Intel Mac, and where it is found
   reports its version, the evidence, and the resulting ceiling.
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
- Upgrade a Mac running OpenCore Legacy Patcher beyond the release that the
  installed OCLP version supports, unless the ceiling is deliberately raised
  with `--max-macos-major`. Maintenance updates for an already-installed
  release remain eligible.
- Add, remove, or modify software repositories, package sources, or Windows Update settings.
- Install package managers or updaters that are not already present.
- Update project-level dependencies such as Composer packages, npm dependencies, Python virtual environments, Cargo projects, NuGet packages, or application-specific dependency locks.
- Reboot the computer.
- Guarantee that a newly released package is free of regressions.

APT phased updates are held back by default. Phasing deliberately delays
selected updates for part of the user base while regressions are monitored, so
the script leaves that safety mechanism in place, names each package APT kept
back in the summary, and installs them only when `--include-phased-updates` is
given. Packages can also be kept back for other reasons, such as an upgrade that
would need to remove another package; those are reported the same way and are
left for you to resolve deliberately.

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
| `130` | Interrupted by `SIGINT` (Ctrl-C) — Linux and macOS |
| `143` | Interrupted by `SIGTERM` — Linux and macOS |

Individual package-manager commands may return other statuses internally. The script records those failures, continues where possible, and returns `1` after printing its summary.

Updates that were deliberately held back — a phased APT package, or a macOS
release above what the Mac may install — are named in the summary and do not by
themselves change the exit code. Skipped managers do not either. Only a failed
operation produces `1`.

On Linux and macOS, an interrupted run still prints its summary: what had
completed, failed, or been held back, the manager that was running when the
signal arrived, and a note that nothing after it was started. The script then
exits `130` for `SIGINT` or `143` for `SIGTERM`, whatever had failed before.
Bash runs the handler only once the running command exits: Ctrl-C reaches that
command too, so it normally stops at once, but `SIGTERM` sent to the script
alone waits for the current command to finish. The interrupted manager may be
partly applied, so run the script again. Press Ctrl-C a second time to skip the
summary.

On Windows, Ctrl+C stops the script without a summary, and the exit code is
then set by PowerShell rather than by the script. A blocking Windows Update
call cannot be interrupted until it returns, and Windows PowerShell 5.1 does
not let a script report an interruption reliably, so `130` and `143` are not
used there.

## Reboot notices

On Linux, the script reports a reboot requirement when:

- `/var/run/reboot-required` or `/run/reboot-required` exists, which is the
  Debian and Ubuntu convention;
- `needs-restarting -r` is available and exits `1`, which is the DNF and YUM
  equivalent; or
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

Each suite runs under the same interpreter as the runner, so running the runner
with Apple's Bash really does exercise Bash 3.2:

```bash
/bin/bash tests/run-shell-tests.sh
```

`tests/shell/test-bash32-compat.sh` additionally rejects post-3.2 Bash features
statically, so the constraint is enforced on machines that have no Bash 3.2.

Run the Windows tests with Pester 5.7.1 or later in Windows PowerShell 5.1:

```powershell
Invoke-Pester -Path .\tests\windows -CI
```

Most of the Windows suite also runs on PowerShell 7 on Linux or macOS, which is
useful while developing; the four tests that launch `powershell.exe` are skipped
off Windows and only CI's Windows job covers them.

With Docker installed, run the Linux script's dry run in a disposable container
of a real distribution and check the manager it detects. Images without bash
need a setup command, which runs only inside the container:

```bash
tests/container-dry-run.sh debian:stable apt
tests/container-dry-run.sh alpine:latest apk 'apk add --no-cache bash'
```

CI runs syntax checks, pinned ShellCheck 0.10.0, the shell tests under Linux
and Apple's Bash 3.2, the Linux dry run in digest-pinned containers of Debian,
Ubuntu, Fedora, Rocky Linux, openSUSE Tumbleweed, Arch Linux, Alpine, Void
Linux, and Gentoo, the Windows PowerShell 5.1 parser, pinned PSScriptAnalyzer
1.25.0, and Pester. It never runs a live updater.

### Testing limitations

The unit tests use shell functions, mocked commands, fixtures, and dry-run
paths. On top of those, CI runs `linux/update-everything.sh --dry-run` as an
unprivileged user in real Debian, Ubuntu, Fedora, Rocky Linux, openSUSE
Tumbleweed, Arch Linux, Alpine, Void Linux, and Gentoo container images. That
verifies distribution and manager detection against each image's genuine
`/etc/os-release` and binary locations, and that the dry-run plan is produced
without error. It does not run a single update command: the containers are
offline during the dry run, and a container has no kernel, bootloader, or
services to update. NixOS, rpm-ostree, transactional-update, Solus, Clear
Linux, Slackware, and Mageia have no container leg, so their detection is
covered only by mocks.

No part of this project has been verified against a live update on real
hardware as part of its release process. In particular, these remain untested:
every distribution-specific package-manager invocation actually being executed,
live Windows Update and third-party updater runs, `softwareupdate` behavior on
Intel and Apple silicon Macs, and any behavior on OCLP-patched hardware. Treat
the first live run on a new platform as a manual test, and take a backup first.

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
│   ├── README.md
│   └── update-everything.sh
├── macos/
│   ├── README.md
│   └── update-everything.sh
├── windows/
│   ├── README.md
│   └── update-everything.ps1
├── tests/
│   ├── container-dry-run.sh
│   ├── fixtures/macos/softwareupdate-list.txt
│   ├── run-shell-tests.sh
│   ├── shell/
│   └── windows/update-everything.Tests.ps1
├── PSScriptAnalyzerSettings.psd1
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
