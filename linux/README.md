# Linux updater

`update-everything.sh` version 2.0.0 updates one detected native system package
manager, then Snap, user and system Flatpak installations, and Linuxbrew when
they are present. One manager failing does not stop unrelated managers.

Run the script as a normal user. Whole-script root execution is refused; only
individual system operations are elevated through a trusted `sudo` or `doas`
executable. Elevated package-manager commands are resolved from fixed
system-owned locations rather than the caller's `PATH`.

## Options

| Option | Effect |
|---|---|
| `--system-only` | Update only the native system package manager. |
| `--no-cleanup` | Skip unused-dependency and package-cache cleanup. |
| `--include-phased-updates` | Install APT updates that are still being phased in. Held back and reported by default. |
| `--dry-run` | Detect managers and print mutating commands without running them or prompting for elevation. |
| `-h`, `--help` | Show help and exit. |
| `-v`, `--version` | Show version and exit. |

APT uses `upgrade --with-new-pkgs`: required new dependencies may be installed,
but existing packages are not removed by the upgrade itself. The optional
`autoremove` cleanup can remove dependencies APT now considers unused; use
`--no-cleanup` to prevent that and all cache cleanup.

Phased updates are held back by default. Ubuntu phases selected updates to part
of the user base while regressions are monitored, and the script leaves that
mechanism alone rather than opting every machine in. It runs an unprivileged
`apt-get -s upgrade` simulation to learn which packages APT will keep back, and
names each one in a "Held back" section of the summary. Held-back packages do
not fail the run. `--include-phased-updates` sets
`APT::Get::Always-Include-Phased-Updates=true` for the upgrade, which installs
them immediately.

A reboot requirement is reported from `/var/run/reboot-required` or
`/run/reboot-required`, from `needs-restarting -r` exiting `1` where that
command exists, and for a staged rpm-ostree or transactional deployment. The
script never reboots.

The script never changes configured repositories, performs a distribution
release upgrade, installs a package manager, updates project dependencies, or
reboots the system. NixOS flake updates update `/etc/nixos/flake.lock` before
rebuilding, so that system configuration should be backed up or version
controlled.

## Validation limits

The safe shell suite covers options, exit codes, root and privilege behavior,
manager selection and fallback, immutable-system precedence, cleanup, phased
APT arguments, kept-back package parsing, failure isolation, summaries, quoted
paths, dry runs, and reboot notices. Every test replaces command discovery and
execution with shell functions, so no test can reach a real package manager.

CI does not run live package updates, and no distribution has been verified
against a live update as part of the release process. Distribution-specific
behavior still needs validation on disposable or backed-up installations.

See the [repository README](../README.md) for the full manager list, safety
boundaries, exit-code contract, and contribution instructions.
