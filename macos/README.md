# macOS updater

`update-everything.sh` installs available macOS updates, then updates every supported application manager installed on the Mac. It will not install macOS 26 or later, and it will not perform a major macOS upgrade unless you ask for one.

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

macOS 26 and later are not installed. The script reads every update that `softwareupdate` offers, works out the macOS release each one leads to, and installs the approved ones by label. It never runs `softwareupdate --install --all`, so a held-back release cannot be installed by accident.

Three rules decide what is held back:

1. Any macOS release newer than the maximum, which is macOS 25 by default, is always held back. Raise it with `--max-macos-major` once a newer release has been verified on the machines it will run on.
2. A major upgrade, meaning any release newer than the one currently installed, is held back unless `--allow-major-upgrade` is given.
3. On a Mac running OpenCore Legacy Patcher, a major upgrade is always held back, even with `--allow-major-upgrade`.

Updates within the installed release, such as 15.6 to 15.6.1, and non-macOS updates such as Safari and the Command Line Tools, are installed normally. Everything held back is named in the summary along with the reason.

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
| `--max-macos-major N` | Highest major macOS release the script may install (default `25`). |
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

See the [repository README](../README.md) for the full description, including what the script deliberately does not do.
