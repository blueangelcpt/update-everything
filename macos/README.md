# macOS updater

`update-everything.sh` version 2.1.0 installs available macOS updates, then
updates every supported application manager installed on the Mac. It will not
perform a major macOS upgrade unless you ask for one, and on a Mac running
OpenCore Legacy Patcher it will not install a release that the installed OCLP
version does not support.

## What it updates

| Manager | Command used |
|---|---|
| macOS, Safari, Command Line Tools | `softwareupdate --install <label>`, one approved label at a time |
| Mac App Store | `mas upgrade` |
| Homebrew | `brew update`, `brew upgrade`, and `brew upgrade --cask --greedy` with `--greedy-casks` |
| MacPorts | `port selfupdate` and `port upgrade outdated` |
| Nix | `nix-channel --update` and `nix-env --upgrade` |

A manager that is not installed is reported as skipped, not as a failure. One manager failing does not stop the others.

## Version guard

The script reads every update that `softwareupdate` offers, works out the macOS
release each one leads to, and installs the approved ones by label. It never
runs `softwareupdate --install --all`, so a held-back release cannot be
installed by accident.

On a Mac without OpenCore Legacy Patcher there is no version ceiling. Two rules
decide what is held back:

1. A major upgrade, meaning any release newer than the one currently
   installed, is held back unless `--allow-major-upgrade` is given.
2. An offer for a release older than the installed one is always held back.

On a Mac running OpenCore Legacy Patcher, the installed OCLP version adds a
ceiling that `--allow-major-upgrade` cannot cross:

| Installed OCLP | Highest macOS release installed |
|---|---|
| 3.x and newer | macOS 26 Tahoe |
| 2.5.x and older | macOS 15 Sequoia |
| Version not confirmed | macOS 15 Sequoia, assumed |

macOS has no releases 16 to 25, so the supported numbers jump from 15 straight
to 26. An OCLP generation newer than 3.x keeps the macOS 26 ceiling until it
has been verified; raise it with `--max-macos-major` in the meantime.

Updates within the installed release, such as 15.6 to 15.6.1, and non-macOS
updates such as Safari and the Command Line Tools, are installed normally on
every Mac. Everything held back is named in the summary along with the reason.

The ceiling applies to upgrades, not to maintenance of the release already
installed. If a Mac already runs a release above its ceiling, updates within
that same release remain eligible while any further upgrade is held back.

## OpenCore Legacy Patcher

OCLP exists only for Intel Macs that Apple no longer supports, so a Mac on
Apple silicon never looks for it and never mentions it.

On an Intel Mac the script looks for OCLP in several independent places,
because any one of them can be absent depending on how the Mac was set up:

- `/System/Library/CoreServices/OpenCore-Legacy-Patcher.plist`
- `/System/Library/CoreServices/OpenCore-Patcher.app`
- `/Library/Application Support/Dortania`
- `/Applications/OpenCore-Patcher.app`
- The `OCLP-Version` NVRAM variable
- An `opencore-version` entry in the booted device tree

OCLP is updated in [three separate steps](https://github.com/dortania/OpenCore-Legacy-Patcher/blob/main/docs/FAQ.md#how-do-i-make-sure-im-all-up-to-date)
— the application, then the bootloader, then the root patches — so a Mac can
have a new application while it still boots through an old bootloader. The
script reads each component's version separately:

| Component | Read from |
|---|---|
| Application | `CFBundleShortVersionString` of `/Applications/OpenCore-Patcher.app`, else of `/System/Library/CoreServices/OpenCore-Patcher.app` |
| Active bootloader | The `OCLP-Version` NVRAM variable, which OCLP writes into the EFI configuration when it builds the bootloader |
| Root patches | Only the `OpenCore Legacy Patcher` key of `/System/Library/CoreServices/OpenCore-Legacy-Patcher.plist`; that file also records the patched macOS version and other version numbers, which are never read |

The **oldest** of these sets the OCLP version used for the ceiling, so a 3.x
application over a 2.5.x bootloader is treated as 2.5.x. The version counts as
**not confirmed** — and the macOS 15 ceiling applies — unless both the active
bootloader and the application can be read: the Mac boots through the first,
and only the second can re-apply root patches after an upgrade. A Mac that has
never needed root patches records none, and that component is then ignored.

The output names every component's version and which one set the ceiling, and
warns when they differ, because that means an OCLP update was started but not
finished.

When OCLP is detected, the script:

- Holds back any macOS release newer than its oldest OCLP component supports,
  even with `--allow-major-upgrade`, and holds back every upgrade past macOS 15
  when the OCLP version cannot be confirmed.
- Warns that OCLP itself should be updated before macOS updates are installed, so that the installed version supports the release being applied.
- Prints a reminder after installing a macOS update that root patches are removed by macOS updates and must be re-applied in OpenCore Legacy Patcher after the restart.

When OCLP is not detected, nothing about it is printed, no ceiling is applied,
and `--max-macos-major` is not listed in the help text.

Minor macOS updates are still installed on an OCLP Mac, because they are the security updates for the release already running. They do remove root patches until OCLP re-applies them, so use `--skip-system-update` if you would rather update applications now and schedule macOS updates for a time when you can re-patch and restart.

## Running it

Run the script as your normal user. It requests `sudo` only for the commands that need it, and Homebrew refuses to run as root:

```bash
./update-everything.sh
```

## Options

| Option | Effect |
|---|---|
| `--system-only` | Update only macOS itself. |
| `--skip-system-update` | Update only the additional managers. |
| `--no-cleanup` | Do not remove cached downloads or unused packages. |
| `--greedy-casks` | Also upgrade Homebrew casks that carry their own updater. |
| `--allow-major-upgrade` | Permit a major macOS upgrade. On an OCLP Mac it cannot cross the OCLP ceiling. |
| `--max-macos-major N` | Highest major macOS release to install on this Mac, overriding what the installed OCLP version supports. Listed in `--help` only on a Mac where a ceiling applies. |
| `--dry-run` | List and evaluate updates without installing or cleaning up anything. |
| `-h`, `--help` | Show the help text. |
| `-v`, `--version` | Show the script version. |

Examples:

```bash
# Install macOS updates and update every detected manager
./update-everything.sh

# Update applications now, and leave macOS for a time when you can restart
./update-everything.sh --skip-system-update

# Also refresh casks that normally update themselves
./update-everything.sh --greedy-casks

# Allow a major upgrade to whatever release Apple offers this Mac
./update-everything.sh --allow-major-upgrade

# On an OCLP Mac, allow macOS 27 once that OCLP version has been verified
./update-everything.sh --allow-major-upgrade --max-macos-major 27

# Evaluate offered labels without making changes or prompting for sudo
./update-everything.sh --dry-run
```

## Exit codes

| Code | Meaning |
|---:|---|
| `0` | Every detected update operation completed successfully |
| `1` | At least one detected update operation failed |
| `2` | Invalid usage, or the script was started on a system other than macOS |

## Notes

- The Mac App Store needs the `mas` command, which is not installed with macOS. Install it with `brew install mas`.
- On Apple silicon, an update that restarts the Mac can require authentication that `softwareupdate` cannot supply from a script. If one fails for that reason, install it from System Settings.
- A Mac managed by nix-darwin is reported as skipped, because its configuration must be rebuilt from its own flake or configuration file rather than upgraded in place.
- The script is written for the GNU bash 3.2 that ships with macOS, so it runs without installing a newer bash.
- `--system-only` and `--skip-system-update` are mutually exclusive.
- Dry-run mode executes read-only inventory commands, including
  `softwareupdate --list`, but never elevates or invokes an install, upgrade,
  cleanup, channel update, or EULA acceptance operation.
- Automated tests exercise parsing, punctuation in labels, failure isolation,
  restart state, and the OCLP/major-upgrade matrix, all through fixtures and
  replaced shell functions. `softwareupdate` is never invoked by a test.
- No part of this script has been live-tested on Intel, Apple silicon, or
  OCLP-patched hardware as part of its release process. CI runs the suite under
  Apple's Bash 3.2 on a macOS runner, which verifies interpreter compatibility
  and script logic, not real update behavior.

See the [repository README](../README.md) for the full description, including what the script deliberately does not do.
