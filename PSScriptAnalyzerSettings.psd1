@{
    # Information-level rules (comment help, positional parameters) are style advice for
    # published cmdlets; `phx` is a console tool with its own help.
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # `phx` is an interactive console tool: coloured Write-Host lines ARE its output.
        'PSAvoidUsingWriteHost',
        # State-changing helpers are driven by `phx` sub-commands that carry their own
        # confirmation flow (the wizard, restore's per-step prompts) instead of ShouldProcess.
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseSingularNouns',
        # Argument-completer script blocks must declare the leading positions of the
        # ($commandName, $parameterName, $wordToComplete, ...) signature to reach the later
        # ones; and `phx` declares the flags of milestones that are not built yet, so the help
        # and the command line agree from the start.
        'PSReviewUnusedParameter',
        # False positive on `if ($x -eq (git ... 2>$null))`: the rule sees the '>' of a
        # stderr redirection inside a condition and suspects a mistyped comparison.
        'PSPossibleIncorrectUsageOfRedirectionOperator'
    )
}
