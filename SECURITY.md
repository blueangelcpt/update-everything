# Security policy

## Supported versions

Security fixes are provided for the latest published release.

| Version | Supported |
|---|---|
| 2.0.x | Yes |
| Earlier, unreleased history | No |

## Reporting a vulnerability

Do not open a public issue for a vulnerability that could enable command
injection, privilege escalation, unsafe update selection, updater substitution,
or destructive cleanup. Use GitHub's
[private vulnerability reporting](https://github.com/blueangelcpt/update-everything/security/advisories/new)
and include the affected platform, script version, prerequisites, a minimal
reproduction, and the likely impact. Remove credentials and unrelated personal
information from logs.

You should receive an acknowledgement within seven days. A fix and disclosure
timeline will be coordinated according to severity and the availability of a
safe remediation.

## Security model

These scripts deliberately execute configured operating-system and package
updates, sometimes with administrator privileges. They do not make an untrusted
repository or package safe. Linux and macOS must be launched by a normal user;
privileged executables are resolved from fixed system locations. Windows avoids
per-user executable discovery in elevated paths and validates the Patch My PC
publisher signature. Users remain responsible for backups, configured sources,
and reviewing dry-run output before a live update.
