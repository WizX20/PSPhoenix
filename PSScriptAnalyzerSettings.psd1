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
        'PSUseSingularNouns'
        # PSReviewUnusedParameter stays on: the one intended exception, phx's flags of later
        # milestones, carries a SuppressMessage attribute of its own.
    )
}
