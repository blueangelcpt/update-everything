# Windows updater

`update-everything.ps1` version 2.1.0 installs available Windows updates, then
runs every supported application updater that is installed on the machine.
Each updater runs in its own silent or unattended mode, so the script never
stops to ask a question.

## What it updates

| Updater | Command used |
|---|---|
| Windows Update | The PSWindowsUpdate module when installed, or the Windows Update Agent COM API |
| WinGet | `winget upgrade --all --silent --accept-package-agreements --accept-source-agreements` |
| Chocolatey | `choco upgrade all --yes --no-progress --use-package-exit-codes` |
| Scoop | `scoop update` and `scoop update *` |
| Patch My PC Home Updater | Publisher verification, then `PatchMyPC.exe /s` |
| Microsoft Store | An `UpdateScanMethod` scan through the application management class, in an elevated session only |

An updater that is not installed is reported as skipped, not as a failure. One updater failing does not stop the others.

## Running it

Run the script from an **elevated** PowerShell session, because Windows Update and Chocolatey both require administrator privileges:

```powershell
.\update-everything.ps1
```

PowerShell blocks unsigned scripts by default. To bypass the policy for a single run without changing any setting:

```powershell
powershell -ExecutionPolicy Bypass -File .\update-everything.ps1
```

Windows Update, Chocolatey and the Microsoft Store scan all need administrator
privileges and are reported as failed or skipped without them. Scoop is the
opposite: it refuses to run elevated, so it is skipped in an elevated session.
Run the script again as your normal user to update Scoop packages:

```powershell
.\update-everything.ps1 -SkipWindowsUpdate
```

## Options

| Option | Effect |
|---|---|
| `-SystemOnly` | Install Windows updates only, and run no application updater. |
| `-SkipWindowsUpdate` | Run the application updaters only. |
| `-IncludeDrivers` | Also install driver updates offered by Windows Update. |
| `-NoCleanup` | Skip Scoop's old-version and download-cache cleanup commands. Other managers retain their own built-in behavior. |
| `-PatchMyPCPath <path>` | Full path to `PatchMyPC.exe`, for a portable copy the script does not find on its own. |
| `-DryRun` | Detect and evaluate updaters without installing, accepting EULAs, or cleaning up. |
| `-Version` | Print the script version and exit. |

Full help is available with:

```powershell
Get-Help .\update-everything.ps1 -Detailed
```

`-SystemOnly` and `-SkipWindowsUpdate` cannot be combined. Portable Patch My
PC executables are never discovered in downloads or other user-writable
folders; pass an explicit path. Automatic and explicit candidates must have a
valid Authenticode signature whose signer identifies Patch My PC.

Dry-run mode may perform read-only Windows Update and updater discovery. It
does not download or install updates, accept EULAs, invoke external updaters,
trigger a Microsoft Store scan, or clean caches.

## Exit codes

| Code | Meaning |
|---:|---|
| `0` | Every detected update operation completed successfully |
| `1` | At least one detected update operation failed |
| `2` | Conflicting options, or the script was started on a platform other than Windows |

An unrecognised option is reported by the script itself and also returns `2`.

## Exit-code handling for external updaters

| Updater | Accepted as success | Treated as needing a reboot | Everything else |
|---|---|---|---|
| WinGet | `0`, and `0x8A15002B` (`-1978335189`, "no applicable upgrade found") | — | Failure |
| Chocolatey | `0`, `1605`, `1614`, `1641`, `3010` — the codes Chocolatey documents as valid | `1641`, `3010`, and the reboot-detection codes `350` and `1604` | Failure, including `2` |
| Scoop | `0` | — | Failure |
| Patch My PC | `0` | — | Failure |

`350` means Chocolatey refused to start because a reboot was already pending,
and `1604` means it stopped part-way through when a package asked for one.
Both set the reboot notice and fail the Chocolatey task, because packages were
left un-upgraded.

## Testing limitations

Automated tests run with Pester and cover updater exit-code handling, elevation
decisions, trusted path selection, cleanup, failure isolation, summaries, and
dry runs. They do not perform live Windows, driver, Store, or third-party
application updates, and no live Windows run has been performed as part of the
release process. CI exercises the suite under Windows PowerShell 5.1; most of it
also runs on PowerShell 7, and the tests that launch `powershell.exe` are
skipped off Windows.

See the [repository README](../README.md) for the full description, including how each updater is located and what the script deliberately does not do.
