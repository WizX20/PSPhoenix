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
# Native tools write progress to stderr; a caller with 'Stop' must not turn that into a throw.
$ErrorActionPreference = 'Continue'

# A foreach statement, not ForEach-Object: dot-sourcing must land in the module scope.
foreach ($folder in 'Private', 'Providers') {
    $dir = Join-Path $PSScriptRoot $folder
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    foreach ($file in (Get-ChildItem -LiteralPath $dir -Filter '*.ps1' | Sort-Object Name)) { . $file.FullName }
}

# Commands that exist in the help but arrive with a later milestone (docs/design.md -> Roadmap).
$script:PhxPlanned = [ordered]@{
    init     = 'M1'
    status   = 'M1'
    scan     = 'M1'
    roots    = 'M1'
    run      = 'M2'
    schedule = 'M2'
    review   = 'M3'
    restore  = 'M6'
}
$script:PhxCommands = @($script:PhxPlanned.Keys) + @('providers', 'version', 'help')

function Get-PhxVersion { (Get-Module PSPhoenix).Version }

function Show-PhxHelp {
    @"
phx - PSPhoenix $(Get-PhxVersion): back up what your machine would lose in a crash, rebuild a new one from it.

Code in a remote is safe already. phx keeps the rest: which repositories you had (remotes,
GitHub account, identity), local-only git work, gitignored local files, Claude Code memory
and settings, and the machine setup - winget, Scoop, PowerShell, Windows Terminal, WSL and
environment variables.

USAGE:
  phx init                        set up: roots, target, interval, secrets, schedule   (M1)
  phx status                      last run, pending review items, local-only work      (M1)
  phx scan                        re-discover repositories under the roots             (M1)
  phx roots add|rm|list [<path>]  the folders that hold your repositories              (M1)
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
    param(
        [Parameter(Position = 0)][string]$Command,
        [Parameter(Position = 1)][string]$Arg,
        [Parameter(Position = 2)][string]$Arg2,
        [string]$Provider,
        [string]$Every,
        [string]$From,
        [Alias('h')][switch]$Help
    )
    if ($Help -or $Command -in '', '--help', 'help', '-h', '/?') { Show-PhxHelp; return }
    if ($script:PhxPlanned.Contains($Command)) {
        Write-Host "phx $Command is not built yet - it arrives with milestone $($script:PhxPlanned[$Command]) (docs/design.md -> Roadmap)" -ForegroundColor Yellow
        return
    }
    switch ($Command) {
        'providers' { Show-PhxProviders }
        'version' { Write-Host "PSPhoenix $(Get-PhxVersion)" }
        default { Write-Host "unknown command '$Command' - see: phx help" -ForegroundColor Yellow }
    }
}

Register-ArgumentCompleter -CommandName phx -ParameterName Command -ScriptBlock {
    param($commandName, $parameterName, $word)
    $script:PhxCommands | Where-Object { $_.StartsWith($word, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    }
}

Export-ModuleMember -Function phx
