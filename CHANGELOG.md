# Changelog

All notable changes are documented here. The project uses one repository-wide
[Semantic Version](https://semver.org/) for Linux, Windows, and macOS.

## [Unreleased]

### Added

- Open every run with the Update Everything start-up banner: the
  ring-and-tick logo as ASCII art, in the brand colours, beside the version,
  the tagline, the detected operating system and the dry-run mode. Terminals
  narrower than 72 columns get a short form without the logo, long subtitles
  are shortened rather than wrapped, and non-UTF-8 locales on Linux and macOS
  get ASCII punctuation. Colour honours `NO_COLOR`, and uses 24-bit colour
  where the terminal supports it, including Windows consoles that process
  escape sequences. The banner replaces the plain `update-everything <version>`
  line printed at the start of a run.
- Publish the project website on GitHub Pages from the `gh-pages` branch.

## [2.1.0] - 2026-10-21

### Added

- Add `--skip-system-update` to the Linux script, matching macOS. It updates
  only Snap, Flatpak, and Homebrew, skips native-manager detection and the
  up-front privilege check, and is recorded as skipped in the summary. Snap and
  system Flatpak updates still elevate per command, so `sudo` or `doas` prompts
  when they are reached. Combining it with `--system-only` exits `2`.
- Accept `-SkipSystemUpdate` on Windows as an alias of `-SkipWindowsUpdate`,
  which keeps working.
- Handle `SIGINT` and `SIGTERM` in the Linux and macOS scripts. An interrupted
  run starts no further updater, prints the summary of what had completed,
  failed, or been held back along with the updater that was interrupted, and
  exits `130` or `143`.

### Changed

- Make the macOS version ceiling conditional on OpenCore Legacy Patcher. A Mac
  without OCLP now has no ceiling at all: a major upgrade still needs
  `--allow-major-upgrade`, but no release is refused for being too new, because
  Apple offers a major upgrade only to a Mac it supports.
- Derive the ceiling on an OCLP Mac from the installed OCLP version instead of
  a fixed number: OCLP 3.x and newer may install up to macOS 26 Tahoe, while
  2.5.x and older stop at macOS 15 Sequoia. An unreadable OCLP version is
  treated as an old one. The previous default of "macOS 25" named a release
  that does not exist, since macOS has no releases 16 to 25.
- Replace the outright refusal of every major upgrade on an OCLP Mac with the
  version-derived ceiling, so that an OCLP release which does support the
  target may install it when `--allow-major-upgrade` is given.
- Read the version of each OCLP component separately and let the oldest one
  set the ceiling. OCLP updates the application, the bootloader and the root
  patches as three separate steps, so a 3.x application over a 2.5.x
  bootloader is treated as 2.5.x rather than unlocking macOS 26. The active
  bootloader's version comes from the `OCLP-Version` NVRAM variable, and the
  version counts as unconfirmed, keeping the macOS 15 ceiling, unless both it
  and the application can be read. The output names every component and the
  one that set the ceiling, and warns when they differ.
- Read the root patch version from the exact `OpenCore Legacy Patcher` key of
  its property list. Scanning `plutil -p` output for version-like lines found
  `OS Version` first, so a 2.5.1 installation patched on macOS 15.7.1 was read
  as OCLP "15.7.1" and could unlock macOS 26.
- Say nothing about OpenCore Legacy Patcher on a Mac that does not have it.
  The summary omits the OCLP and ceiling lines, held-back reasons never name
  it, and `--help` lists `--max-macos-major` only where a ceiling applies.
- Skip OCLP detection entirely on Apple silicon, which OCLP does not support.

### Documentation

- Document exit codes `130` and `143`, and that the Windows script prints no
  summary on Ctrl+C because Windows PowerShell 5.1 cannot report the
  interruption reliably.

### Tests and CI

- Run the Linux script's `--dry-run` as an unprivileged user inside
  digest-pinned containers of Debian stable, Ubuntu 24.04, Fedora, Rocky
  Linux 9, openSUSE Tumbleweed, Arch Linux, Alpine, Void Linux, and Gentoo.
  Each leg fails unless the expected native manager is detected from the
  image's genuine `/etc/os-release` and binary locations and the dry run exits
  0. The container is disconnected from the network before the script starts,
  so no leg can perform a live update. The check lives in
  `tests/container-dry-run.sh` and also runs locally with Docker.

## [2.0.0] - 2026-08-09

First consolidated cross-platform release containing Linux, Windows, and macOS
support.

### Safety and correctness

- Refuse whole-script root execution on Linux and macOS, elevate only trusted
  system commands, and avoid resolving privileged executables through a
  user-controlled `PATH`.
- Change APT updates from removal-capable `dist-upgrade` to
  `upgrade --with-new-pkgs`; make `--no-cleanup` consistently suppress APT
  cache and unused-dependency cleanup.
- Stop overriding Ubuntu's phased-update rollout by default. Packages APT keeps
  back are discovered with an unprivileged simulation, named in a new "Held
  back" section of the Linux summary, and installed only when the new
  `--include-phased-updates` option is given.
- Report a Linux reboot requirement from `/run/reboot-required` as well as
  `/var/run/reboot-required`, and from `needs-restarting -r` on DNF and YUM
  systems.
- Stop treating Chocolatey exit code `2` as success. Only the exit codes
  Chocolatey documents as valid are accepted, and the reboot-detection codes
  `350` and `1604` set the reboot notice and then fail the task, because
  packages were left un-upgraded.
- Skip the Microsoft Store update scan in a session that is not elevated,
  instead of failing the run with an access-denied error that a normal user
  cannot avoid.
- Report an unrecognised Windows option from the script with exit code `2`
  rather than leaving it to PowerShell's parameter binder.
- Correct macOS release filtering so maintenance updates for the installed
  release remain eligible even when that release is above the configured
  ceiling; reject older-release offers and malformed macOS records safely.
- Parse both recommended and non-recommended `softwareupdate` labels in a
  fixed locale, preserve empty fields and punctuation, and remove the
  undocumented `--no-scan` install option.
- Report macOS restart and OCLP root-patch notices only after a relevant update
  actually installs; report held-back releases separately from ordinary skips.
- Reject conflicting system-only/application-only modes on macOS and Windows.
- Limit elevated WinGet and Chocolatey discovery to machine-wide locations,
  account for 32-bit and 64-bit Program Files paths, and require a valid Patch
  My PC publisher signature.
- Use Patch My PC's fully silent `/s` switch instead of graphical `/auto`.
- Treat Windows Update partial success as failure, retain update-level skip
  reasons, and handle Chocolatey success, no-op, restart, and pending-reboot
  exit codes explicitly.

### Usability and maintainability

- Normalize all embedded versions to `2.0.0`.
- Add non-mutating `--dry-run` modes to Linux and macOS and `-DryRun` to
  Windows, with planned work distinguished from completed work.
- Improve trusted path discovery, diagnostics, summary accounting, help text,
  platform documentation, security guidance, and contribution instructions.

### Tests and CI

- Add fixture-backed shell tests for manager selection, option and privilege
  handling, cleanup, failure isolation, summaries, exit codes, restart state,
  `softwareupdate` parsing, and the complete macOS/OCLP upgrade matrix.
- Add Pester tests for PowerShell 5.1 behavior, external exit codes, elevation,
  signed updater discovery, Scoop, WinGet compatibility, dry runs, and process
  option handling.
- Run every shell suite under the interpreter that launched the runner, so the
  macOS job really exercises Apple's Bash 3.2 instead of a newer bash found
  earlier on `PATH`, and make the suites hermetic so they pass on any host.
- Add a static Bash 3.2 compatibility check that rejects post-3.2 features and
  unguarded empty-array expansions, which `set -u` rejects before Bash 4.4.
- Add least-privilege GitHub Actions jobs for Linux, macOS Bash 3.2, and
  Windows PowerShell 5.1, with pinned actions and test-tool versions, checkout
  credentials not persisted, per-job timeouts, and no live operating-system
  updates.

[2.1.0]: https://github.com/blueangelcpt/update-everything/releases/tag/v2.1.0
[2.0.0]: https://github.com/blueangelcpt/update-everything/releases/tag/v2.0.0
