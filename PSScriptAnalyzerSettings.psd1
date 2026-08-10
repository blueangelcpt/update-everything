@{
    Severity = @('Error', 'Warning')
    ExcludeRules = @(
        # This is a console application; color-coded status output is intentional.
        'PSAvoidUsingWriteHost',
        # Script parameters are consumed by helper functions; the analyzer
        # cannot follow those script-scope references and reports false positives.
        'PSReviewUnusedParameter',
        # State changes are the purpose of the updater functions and are gated by
        # the script-level -DryRun switch rather than PowerShell ShouldProcess.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
