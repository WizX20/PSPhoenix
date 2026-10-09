# The one way PSPhoenix calls git. Tests run real git against throwaway repositories under
# $TestDrive; only `gh` is ever mocked.

function Invoke-PhxGit {
    # git in a repository; returns stdout as lines. A non-zero exit throws with git's own message -
    # credentials in any URL masked - unless the exit code is listed in -AllowExitCode (`git config
    # --get-regexp` exits 1 when nothing matches), or -AllowFailure, which returns nothing on any
    # failure.
    #
    # A process of its own rather than `& git`: PowerShell on Windows rewrites a native argument
    # that starts with `~` into the home folder, so a recorded `include.path=~/.gitconfig-work`
    # would come back as C:\Users\<old user>/.gitconfig-work. ArgumentList passes every argument as
    # it is, and the output is read as UTF-8 - git writes it so - whatever the console code page.
    param(
        [Parameter(Mandatory)][string]$Repository,
        # Empty strings are real arguments: `credential.helper =` resets the helper list.
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Arguments,
        [int[]]$AllowExitCode = @(),
        [switch]$AllowFailure
    )
    if (-not $script:PhxGitPath) {
        $script:PhxGitPath = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    }
    $start = [Diagnostics.ProcessStartInfo]::new($script:PhxGitPath)
    foreach ($argument in @('-C', $Repository) + $Arguments) { $start.ArgumentList.Add($argument) }
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $process = [Diagnostics.Process]::Start($start)
    try {
        # Both streams at once: a process that fills one pipe while nobody reads it never exits.
        $errorText = $process.StandardError.ReadToEndAsync()
        $output = $process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
        $exitCode = $process.ExitCode
        $message = $errorText.GetAwaiter().GetResult()
    }
    finally { $process.Dispose() }
    if ($exitCode -ne 0) {
        if ($AllowFailure -or $AllowExitCode -contains $exitCode) { return }
        throw (Hide-PhxSecret "git $($Arguments -join ' ') failed in ${Repository}: $(($message -split '\r?\n' | Where-Object { $_ }) -join ' ')")
    }
    # Lines, as PowerShell reads a native command's output: the last line break only ends a line,
    # and a lone line break is one empty line.
    if (-not $output) { return }
    ($output -replace '\r?\n\z', '') -split '\r?\n'
}
