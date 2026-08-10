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
| `--dry-run` | Detect managers and print mutating commands without running them or prompting for elevation. |
| `-h`, `--help` | Show help and exit. |
| `-v`, `--version` | Show version and exit. |

APT includes phased updates and uses `upgrade --with-new-pkgs`: required new
dependencies may be installed, but existing packages are not removed by the
upgrade itself. The optional `autoremove` cleanup can remove dependencies APT
now considers unused; use `--no-cleanup` to prevent that and all cache cleanup.

The script never changes configured repositories, performs a distribution
release upgrade, installs a package manager, updates project dependencies, or
reboots the system. NixOS flake updates update `/etc/nixos/flake.lock` before
rebuilding, so that system configuration should be backed up or version
controlled.

## Validation limits

The safe shell suite covers options, exit codes, root and privilege behavior,
manager selection and fallback, immutable-system precedence, cleanup, phased
APT arguments, failure isolation, summaries, quoted paths, dry runs, and reboot
notices. CI does not run live package updates. Distribution-specific behavior
still needs validation on disposable or backed-up installations.

See the [repository README](../README.md) for the full manager list, safety
boundaries, exit-code contract, and contribution instructions.
