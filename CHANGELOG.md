# Changelog

All notable changes are documented here. The project uses one repository-wide
[Semantic Version](https://semver.org/) for Linux, Windows, and macOS.

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
- Add least-privilege GitHub Actions jobs for Linux, macOS Bash 3.2, and
  Windows PowerShell 5.1, with pinned actions and test-tool versions and no live
  operating-system updates.

[2.0.0]: https://github.com/blueangelcpt/update-everything/releases/tag/v2.0.0
