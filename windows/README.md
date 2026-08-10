# Windows updater

`update-everything.ps1` version 2.0.0 installs available Windows updates, then
runs every supported application updater that is installed on the machine.
Each updater runs in its own silent or unattended mode, so the script never
stops to ask a question.

## What it updates

| Updater | Command used |
|---|---|
| Windows Update | The PSWindowsUpdate module when installed, or the Windows Update Agent COM API |
| WinGet | `winget upgrade --all --silent --accept-package-agreements --accept-source-agreements` |
| Chocolatey | `choco upgrade all --yes --no-progress` |
| Scoop | `scoop update` and `scoop update *` |
| Patch My PC Home Updater | Publisher verification, then `PatchMyPC.exe /s` |
| Microsoft Store | An `UpdateScanMethod` scan through the application management class |

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

Scoop refuses to run elevated. It is skipped in an elevated session, so run the script again as your normal user to update Scoop packages:

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

Unknown parameter names are rejected by PowerShell before the script starts,
so the host may return a different non-zero code for those binding errors.

Automated tests run with Pester under Windows PowerShell 5.1 and cover updater
exit-code handling, elevation decisions, trusted path selection, cleanup,
failure isolation, summaries, and dry runs. They do not perform live Windows,
driver, Store, or third-party application updates.

See the [repository README](../README.md) for the full description, including how each updater is located and what the script deliberately does not do.
