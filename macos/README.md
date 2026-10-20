# macOS updater

`update-everything.sh` version 2.0.0 installs available macOS updates, then
updates every supported application manager installed on the Mac. It will not
upgrade a Mac to macOS 26 or later by default, and it will not perform any major
macOS upgrade unless you ask for one.

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

Major upgrades to macOS 26 and later are held back by default. The script reads
every update that `softwareupdate` offers, works out the macOS release each one
leads to, and installs the approved ones by label. It never runs
`softwareupdate --install --all`, so a held-back release cannot be installed by
accident.

Three rules decide what is held back:

1. Any major-upgrade target newer than the maximum, which is macOS 25 by
   default, is held back. Raise it with `--max-macos-major` only after a newer
   release has been verified. Maintenance updates for the installed release
   remain eligible even when that Mac is already above the ceiling.
2. A major upgrade, meaning any release newer than the one currently installed, is held back unless `--allow-major-upgrade` is given.
3. On a Mac running OpenCore Legacy Patcher, a major upgrade is always held back, even with `--allow-major-upgrade`.

Updates within the installed release, such as 15.6 to 15.6.1, and non-macOS updates such as Safari and the Command Line Tools, are installed normally. Everything held back is named in the summary along with the reason.

The maximum applies to upgrades, not maintenance of the release already
installed. If a Mac already runs a release above the configured maximum,
updates within that same release remain eligible while any further upgrade is
held back.

## OpenCore Legacy Patcher

The script looks for OCLP in several independent places, because any one of them can be absent depending on how the Mac was set up:

- `/System/Library/CoreServices/OpenCore-Legacy-Patcher.plist`
- `/System/Library/CoreServices/OpenCore-Patcher.app`
- `/Library/Application Support/Dortania`
- `/Applications/OpenCore-Patcher.app`
- The `OCLP-Version` NVRAM variable
- An `opencore-version` entry in the booted device tree

When OCLP is detected, the script:

- Refuses every major macOS upgrade, so that upgrades stay a deliberate decision made through OCLP.
- Warns that OCLP itself should be updated before macOS updates are installed, so that the installed version supports the release being applied.
- Prints a reminder after installing a macOS update that root patches are removed by macOS updates and must be re-applied in OpenCore Legacy Patcher after the restart.

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
| `--allow-major-upgrade` | Permit a major macOS upgrade, up to the supported maximum. Refused on an OCLP Mac. |
| `--max-macos-major N` | Highest target for a major macOS upgrade (default `25`). |
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

# Allow macOS 26 once it has been verified on this Mac
./update-everything.sh --allow-major-upgrade --max-macos-major 26

# Evaluate offered labels without making changes or prompting for sudo
./update-everything.sh --dry-run
```

## Exit codes

| Code | Meaning |
|---:|---|
| `0` | Every detected update operation completed successfully |
| `1` | At least one detected update operation failed |
| `2` | Invalid usage, or the script was started on a system other than macOS |
| `130` | Interrupted by `SIGINT` (Ctrl-C) |
| `143` | Interrupted by `SIGTERM` |

On `SIGINT` or `SIGTERM` the script starts no further manager, prints the
summary of what had completed, failed, or been held back, names the manager
that was interrupted, and exits `130` or `143`. Because Bash waits for the
running command before handling a signal, a `SIGTERM` sent to the script alone
lets the current command, such as a `softwareupdate` install, finish first.

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
