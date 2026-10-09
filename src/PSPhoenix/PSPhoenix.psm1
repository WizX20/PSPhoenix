# PSPhoenix - back up what a developer machine would lose in a crash, and rebuild a new machine
# from it. What is already in a remote is not copied: the backup is the delta - the repository
# inventory (remotes, account, identity), local-only git work, gitignored local files, Claude Code
# memory and settings, and the machine setup (winget, Scoop, PowerShell, Windows Terminal, WSL,
# environment). The design, including what is not built yet, is docs/design.md.
#
# Exports one command, `phx`. Helpers live in Private/, one file per concern; every backup unit is
# a provider in Providers/ that registers itself through Register-PhxProvider. PowerShell 7.4+:
# unlike PSWorktree this module is not 5.1-compatible - the scheduled run, the parallel clones and
# the JSON handling lean on PowerShell 7.

$script:OnWindows = [System.Environment]::OSVersion.Platform -eq 'Win32NT'
# No module-wide $ErrorActionPreference: a caller's 'Stop' must reach phx's errors. (From
# PowerShell 7.2 on, a native tool's stderr is no error record unless redirected, so 'Stop' does
# not turn git's progress output into a throw.)

# A foreach statement, not ForEach-Object: dot-sourcing must land in the module scope.
foreach ($folder in 'Private', 'Providers') {
    $dir = Join-Path $PSScriptRoot $folder
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    foreach ($file in (Get-ChildItem -LiteralPath $dir -Filter '*.ps1' | Sort-Object Name)) { . $file.FullName }
}

# Commands that exist in the help but arrive with a later milestone (docs/design.md -> Roadmap).
$script:PhxPlanned = [ordered]@{
    run      = 'M2'
    schedule = 'M2'
    review   = 'M3'
    restore  = 'M6'
}
$script:PhxCommands = @($script:PhxPlanned.Keys) + @('init', 'status', 'roots', 'scan', 'providers', 'version', 'help')

function Get-PhxVersion { (Get-Module PSPhoenix).Version }

function Show-PhxHelp {
    @"
phx - PSPhoenix $(Get-PhxVersion): back up what your machine would lose in a crash, rebuild a new one from it.

Code in a remote is safe already. phx keeps the rest: which repositories you had (remotes,
GitHub account, identity), local-only git work, gitignored local files, Claude Code memory
and settings, and the machine setup - winget, Scoop, PowerShell, Windows Terminal, WSL and
environment variables.

USAGE:
  phx init                        set up or change: roots, accounts, target, interval
  phx status                      what is set up, and what needs attention
  phx scan                        re-discover repositories under the roots
  phx roots add|rm|list [<path>]  the folders that hold your repositories; add: -Depth <n>
  phx run [-Provider <name>]      one backup run now (the scheduled task calls this)   (M2)
  phx schedule on|off|status      the background task; -Every <n>h sets the interval   (M2)
  phx review                      decide on new gitignored files                       (M3)
  phx restore [-From <target>]    rebuild this machine from a snapshot                 (M6)
  phx providers                   what gets backed up on this platform
  phx version                     module version
  phx help | -h | --help          show this help

NOTES:
  - (Mx): not built yet, arrives with that milestone - docs/design.md -> Roadmap.
  - config: $(Get-PhxConfigPath)
  - module: $PSScriptRoot
  - project: https://github.com/WizX20/PSPhoenix
"@ | Write-Host
}

function Show-PhxProviders {
    $providers = @(Get-PhxProvider)
    if (-not $providers) {
        Write-Host "no providers registered yet for $(Get-PhxCurrentPlatform) - they arrive from M1 on (docs/design.md -> Providers)" -ForegroundColor Yellow
        return
    }
    $providers | ForEach-Object {
        Write-Host ('  {0,-12} {1}' -f $_.Name, $_.Description)
    }
}

function phx {
    # An advanced function so a failure is an error a caller can see: $? is false, -ErrorAction
    # Stop throws, and `pwsh -Command phx ...` - what a scheduled task runs - exits with 1. The
    # aliases keep -P and -E unambiguous next to the common parameters (-PipelineVariable,
    # -ProgressAction, -ErrorAction, ...). It declares the flags of milestones that are not built
    # yet, so the help and the command line agree from the start. One suppression per flag, so
    # the rule stays live for every other parameter; each goes once its milestone uses the flag.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Provider', Justification = 'phx run -Provider arrives with M2.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Every', Justification = 'phx schedule -Every arrives with M2.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'From', Justification = 'phx restore -From arrives with M6.')]
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Command,
        [Parameter(Position = 1)][string]$Arg,
        [Parameter(Position = 2)][string]$Arg2,
        [ValidateRange(1, 10)][int]$Depth,
        [Alias('P')][string]$Provider,
        [Alias('E')][string]$Every,
        [string]$From,
        [Alias('h')][switch]$Help
    )
    if ($Help -or $Command -in '', '--help', 'help', '-h', '/?') { Show-PhxHelp; return }
    if ($script:PhxPlanned.Contains($Command)) {
        $message = "phx $Command is not built yet - it arrives with milestone $($script:PhxPlanned[$Command]) (docs/design.md -> Roadmap)"
        $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                [System.NotImplementedException]::new($message), 'PhxNotBuiltYet', 'NotImplemented', $Command))
        return
    }
    # Unknown before the try: its error must not be caught and wrapped a second time.
    if ($script:PhxCommands -notcontains $Command) {
        $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new("unknown command '$Command' - see: phx help"), 'PhxUnknownCommand', 'InvalidArgument', $Command))
        return
    }
    # A command that fails throws; that becomes an error of phx itself - "phx: <message>", $? false,
    # exit code 1 - rather than an exception pointing into a helper. A fresh exception (the
    # original as its inner one): reusing a thrown one carries the throw site along.
    # Ctrl+C is no failure: PowerShell never hands a PipelineStoppedException to a catch block.
    try {
        switch ($Command) {
            'roots' { Invoke-PhxRootsCommand -Action $Arg -Path $Arg2 -Depth $Depth }
            'scan' { Invoke-PhxScan }
            'init' { Invoke-PhxInit }
            'status' { Show-PhxStatus }
            'providers' { Show-PhxProviders }
            'version' { Write-Host "PSPhoenix $(Get-PhxVersion)" }
        }
    }
    catch {
        $PSCmdlet.WriteError([System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new($_.Exception.Message, $_.Exception), 'PhxCommandFailed', 'InvalidOperation', $Command))
    }
}

Register-ArgumentCompleter -CommandName phx -ParameterName Command -ScriptBlock {
    # Completers get ($commandName, $parameterName, $wordToComplete, ...); only the third matters.
    $word = $args[2]
    $script:PhxCommands | Where-Object { $_.StartsWith($word, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    }
}

Export-ModuleMember -Function phx
