# Contributing

Bug reports and focused pull requests are welcome. Preserve the project's
safety boundaries: do not install managers, change repositories, update
project dependencies, perform distribution upgrades, reboot automatically, or
replace selective macOS labels with `softwareupdate --install --all`.

Run scripts only on disposable or backed-up test systems. Never run live update
commands in CI. New behavior should be exercised through mocks, fixtures,
temporary command shims, direct function tests, or dry-run paths.

## Required validation

For shell changes:

```bash
bash -n linux/update-everything.sh macos/update-everything.sh
shellcheck linux/update-everything.sh macos/update-everything.sh tests/run-shell-tests.sh tests/shell/*.sh
tests/run-shell-tests.sh
```

The macOS script and its tests must also pass Apple's GNU Bash 3.2. Avoid
associative arrays and other post-3.2 features.

For Windows changes, use Windows PowerShell 5.1:

```powershell
$tokens = $null
$errors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path .\windows\update-everything.ps1).Path,
    [ref]$tokens,
    [ref]$errors
)
$errors
Invoke-ScriptAnalyzer -Path .\windows\update-everything.ps1 -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-Pester -Path .\tests\windows -CI
```

Update relevant help, platform READMEs, root documentation, tests, and the
changelog in the same change. Cite current primary vendor documentation in the
pull request when adding or changing unattended flags, result-code handling,
privilege behavior, or destructive cleanup.

Do not include credentials, tokens, private repository URLs, or machine-specific
secrets in issues, fixtures, logs, or commits.
