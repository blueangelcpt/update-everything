# Windows updater

`update-everything.ps1` installs available Windows updates, then runs every supported application updater that is installed on the machine. Each updater runs in its own silent or unattended mode, so the script never stops to ask a question.

## What it updates

| Updater | Command used |
|---|---|
| Windows Update | The PSWindowsUpdate module when installed, or the Windows Update Agent COM API |
| WinGet | `winget upgrade --all --silent --accept-package-agreements --accept-source-agreements` |
| Chocolatey | `choco upgrade all --yes --no-progress` |
| Scoop | `scoop update` and `scoop update *` |
| Patch My PC Home Updater | `PatchMyPC.exe /auto` |
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
| `-NoCleanup` | Do not remove superseded package versions or cached installers. |
| `-PatchMyPCPath <path>` | Full path to `PatchMyPC.exe`, for a portable copy the script does not find on its own. |
| `-Version` | Print the script version and exit. |

Full help is available with:

```powershell
Get-Help .\update-everything.ps1 -Detailed
```

## Exit codes

| Code | Meaning |
|---:|---|
| `0` | Every detected update operation completed successfully |
| `1` | At least one detected update operation failed |
| `2` | The script was started on a platform other than Windows |

See the [repository README](../README.md) for the full description, including how each updater is located and what the script deliberately does not do.
