# Update Everything

A small collection of scripts that updates the operating system and supported package managers in one command.

The project is intended for people who want a straightforward way to install all available software updates without remembering a different set of commands for every platform or Linux distribution.

> [!IMPORTANT]
> The Linux and Windows scripts are available now. The macOS script will be added in a later release.

## Current status

| Platform | Script | Status |
|---|---|---|
| Linux | `linux/update-everything.sh` | Available |
| Windows | `windows/update-everything.ps1` | Available |
| macOS | `macos/update-everything.sh` | Planned |

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
| `-NoCleanup` | Do not remove superseded package versions or cached installers. |
| `-PatchMyPCPath <path>` | Full path to `PatchMyPC.exe`, for a portable copy the script does not find on its own. |
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
```

## What the Windows script does

1. Confirms that it is running on Windows and reports the detected release and build.
2. Reports whether the session is elevated, and which updaters that allows.
3. Searches for, downloads, and installs applicable Windows updates, accepting each licence agreement and skipping any update that would prompt for input.
4. Runs `winget upgrade --all` in silent mode, accepting package and source agreements.
5. Runs `choco upgrade all --yes` without progress output.
6. Runs `scoop update` and `scoop update *`, and cleans up old versions and the download cache unless `-NoCleanup` is given.
7. Runs the Patch My PC Home Updater with `/auto`, which updates every out-of-date application without showing its selection interface.
8. Triggers a Microsoft Store update scan, which installs what it finds in the background.
9. Continues with the remaining updaters if one of them fails.
10. Prints a summary and exits with a non-zero status if any operation failed.

### How the Windows script finds each updater

| Updater | How it is located |
|---|---|
| WinGet | `PATH`, then the App Execution Alias in `%LOCALAPPDATA%`, then the App Installer package folder |
| Chocolatey | `PATH`, then `%ChocolateyInstall%\bin\choco.exe` |
| Scoop | `PATH` (`scoop.cmd` or `scoop.exe`) |
| Patch My PC | `PATH`, common installation folders, the registry `App Paths` entry, or `-PatchMyPCPath` |
| Microsoft Store | The `MDM_EnterpriseModernAppManagement_AppManagement01` management class |

The Patch My PC Home Updater is often kept as a portable executable in a downloads folder. The script does not run executables from download folders on its own; pass `-PatchMyPCPath` to use a copy kept there.

## Scope and safety

This project installs updates that are already available through configured repositories, package managers, and update services. It does **not**:

- Perform major operating-system release upgrades, such as moving from one Ubuntu or Fedora release to the next, or installing a Windows feature update that Windows Update does not already offer.
- Add, remove, or modify software repositories, package sources, or Windows Update settings.
- Install package managers or updaters that are not already present.
- Update project-level dependencies such as Composer packages, npm dependencies, Python virtual environments, Cargo projects, NuGet packages, or application-specific dependency locks.
- Reboot the computer.
- Guarantee that a newly released package is free of regressions.

APT phased updates are deliberately included. Phasing normally delays selected non-security updates for part of the user base while regressions are monitored. Using this script opts into those packages immediately.

On Windows, every updater runs unattended, which means each one accepts its own licence and package agreements on your behalf. Windows updates that would prompt for input are skipped and named in the output rather than answered automatically.

Automatic cleanup is enabled by default where the package manager offers an appropriate and reasonably safe command. Use `--no-cleanup` on Linux or `-NoCleanup` on Windows to disable it.

Always keep current backups of important data before applying system-wide updates.

## Exit codes

| Code | Meaning |
|---:|---|
| `0` | Every detected update operation completed successfully |
| `1` | At least one detected update operation failed |
| `2` | Invalid usage or unsupported operating system |

Individual package-manager commands may return other statuses internally. The script records those failures, continues where possible, and returns `1` after printing its summary.

The exit codes are the same on both platforms. On Windows, code `2` is returned when the script is started on a platform other than Windows.

## Reboot notices

On Linux, the script reports a reboot requirement when:

- `/var/run/reboot-required` exists; or
- an rpm-ostree or transactional update may have staged a new deployment.

On Windows, it reports a reboot requirement when:

- Windows Update reports that the installed updates need one;
- Chocolatey returns exit code `1641` or `3010`; or
- a pending servicing operation or a queued file rename is recorded in the registry.

Neither script reboots the computer automatically.

## Development

Validate the Bash script syntax with:

```bash
bash -n linux/update-everything.sh
```

When ShellCheck is installed:

```bash
shellcheck linux/update-everything.sh
```

Validate the PowerShell script syntax without running it:

```powershell
$errors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\windows\update-everything.ps1).Path, [ref]$null, [ref]$errors)
$errors
```

When PSScriptAnalyzer is installed:

```powershell
Invoke-ScriptAnalyzer -Path .\windows\update-everything.ps1
```

Both scripts are organised the same way: detection is separate from execution, every updater has its own function, and each one is run through a wrapper that records success or failure and lets the remaining updaters continue.

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

## Repository layout

```text
update-everything/
├── linux/
│   └── update-everything.sh
├── macos/
│   └── README.md
├── windows/
│   ├── README.md
│   └── update-everything.ps1
├── LICENSE
└── README.md
```

The `macos` directory holds a placeholder until that script is added.

## Contributing

Bug reports and pull requests are welcome. When reporting a Linux problem, include:

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

Do not include credentials, repository secrets, access tokens, or other sensitive information in an issue.

## License

This project is licensed under the GNU General Public License, version 3 or later. See [`LICENSE`](LICENSE).
