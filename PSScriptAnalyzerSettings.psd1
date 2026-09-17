@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Interactive setup output and an interactive profile: Write-Host is the point.
        'PSAvoidUsingWriteHost'
        # Oh My Posh's documented init pattern is 'oh-my-posh init pwsh | Invoke-Expression'.
        'PSAvoidUsingInvokeExpression'
        # Profile helpers like 'touch' and 'mkcd' are deliberately terse.
        'PSUseShouldProcessForStateChangingFunctions'
        # False positives: parameters used inside nested script blocks, and the
        # fixed param() signature that Register-ArgumentCompleter requires.
        'PSReviewUnusedParameter'
    )
}
