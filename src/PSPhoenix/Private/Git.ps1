# The one way PSPhoenix calls git. Tests run real git against throwaway repositories under
# $TestDrive; only `gh` is ever mocked.

function Invoke-PhxGit {
    # git in a repository; returns stdout as lines. A non-zero exit throws with git's own message,
    # unless -AllowFailure, which returns nothing instead (`git config --get-regexp` exits 1 when
    # nothing matches). Output is read as UTF-8 - git writes it so - whatever the console code page.
    param(
        [Parameter(Mandatory)][string]$Repository,
        # Empty strings are real arguments: `credential.helper =` resets the helper list.
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Arguments,
        [switch]$AllowFailure
    )
    $savedEncoding = $null
    try { $savedEncoding = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { $savedEncoding = $null }
    try {
        $output = & git -C $Repository @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        if ($savedEncoding) { try { [Console]::OutputEncoding = $savedEncoding } catch { $null = $_ } }
    }
    $lines = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
    if ($exitCode -ne 0) {
        if ($AllowFailure) { return }
        $message = (@($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join ' ').Trim()
        throw "git $($Arguments -join ' ') failed in ${Repository}: $message"
    }
    $lines
}
