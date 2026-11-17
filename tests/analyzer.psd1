@{
    # PSScriptAnalyzer settings for this repo. Three rule families do not apply to one script
    # file that is fetched and run as a string, or to its console test runner, and each would
    # fire on every future function of the same shape. Everything else stays in force, including
    # PSAvoidUsingWriteHost for check.ps1: the report must go through Write-Line, because
    # Write-Host would bypass the UTF-8 byte path that redirected output depends on.
    ExcludeRules = @(
        # Names cmdlets for discoverability in a module. These are internal functions, and the
        # tests are named after the behaviour they assert ("...Fails", "...Warns", "...Passes").
        'PSUseSingularNouns',

        # Asks for -WhatIf and -Confirm on anything named Set-, New- or Remove-. That is for
        # cmdlets a user calls; these create a temporary folder or a record inside one run.
        'PSUseShouldProcessForStateChangingFunctions',

        # An empty catch is the design here, not an oversight: restoring an encoding, killing a
        # timed-out program and flushing a stream must never turn into a failed check on a
        # student's computer. Each site says so in a comment above it.
        'PSAvoidUsingEmptyCatchBlock'
    )
}
