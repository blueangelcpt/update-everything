# Changelog

All notable changes are documented here. The project uses one repository-wide
[Semantic Version](https://semver.org/) for Linux, Windows, and macOS.

## [Unreleased]

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

[Unreleased]: https://github.com/blueangelcpt/update-everything/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/blueangelcpt/update-everything/releases/tag/v2.0.0
