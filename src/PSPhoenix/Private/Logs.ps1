# phx logs (docs/design.md -> Logging): a look back at the runs - every run, the scheduled one
# included, writes a log in the state folder. An overview of the last runs, one run's log, or what
# went wrong lately; and logging.verbose, which puts the detail of every run in its log (per
# provider its time, per repository whether git was asked, per file how it was staged) and keeps
# those logs by age.

$script:PhxLogLine = '^(?<at>\S+) \[(?<source>[^\]]+)\] (?<text>.*)$'

function Get-PhxLogDir { Join-PhxPath (Get-PhxStateDir) 'logs' }

function Get-PhxRunLogFile {
    # The run logs, newest first.
    $dir = Get-PhxLogDir
    if (-not [IO.Directory]::Exists($dir)) { return }
    @(Get-ChildItem -LiteralPath $dir -Filter 'run-*.log' | Sort-Object Name -Descending)
}

function Write-PhxStagedDetail {
    # The detail of one provider's staging for a verbose log: per file whether it was kept as the
    # last run staged it, staged again, encrypted or held back - never what is in it - and the
    # provider's time.
    param([Parameter(Mandatory)][string]$Name, $Stager, [Parameter(Mandatory)][datetime]$Began)
    if (-not $script:PhxRunVerbose) { return }
    if ($Stager) {
        foreach ($entry in $Stager.Entries) {
            $how = switch ("$($entry.As)") {
                'Sealed' { 'encrypted' }
                'HeldBack' { 'held back (a secret, no age key)' }
                default { 'plain' }
            }
            $kept = if ($Stager.WasReused($entry.Path)) { 'kept from the last run' } else { 'staged' }
            Write-PhxRunDetail -Source $Name "$($entry.Path): $kept, $how"
        }
    }
    Write-PhxRunDetail -Source $Name ([string]::Format([Globalization.CultureInfo]::InvariantCulture, 'took {0:0.0}s', ([DateTime]::UtcNow - $Began).TotalSeconds))
}

function Read-PhxRunLogSummary {
    # One run's log in short: when it started, how long it took, how it ended, what each provider
    # did, and how many warnings and errors it holds.
    param([Parameter(Mandatory)][IO.FileInfo]$File)
    $lines = @([IO.File]::ReadAllLines($File.FullName) | ForEach-Object { if ($_ -match $script:PhxLogLine) { [pscustomobject]@{ At = $Matches.at; Source = $Matches.source; Text = $Matches.text } } })
    $times = @($lines | ForEach-Object { $t = [datetime]::MinValue; if ([datetime]::TryParse($_.At, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$t)) { $t } })
    $providers = [ordered]@{}
    $result = 'unfinished'
    foreach ($line in @($lines | Where-Object Source -EQ 'run')) {
        # In the order they ran: each starts with a line of its name.
        if ($line.Text -match '^(?<name>[a-z0-9-]+):$') { $providers[$Matches.name] = 'unfinished' }
        elseif ($line.Text -match '^(?<name>[a-z0-9-]+): \d+ written') { $providers[$Matches.name] = 'ok' }
        elseif ($line.Text -match '^(?:error: )?(?<name>[a-z0-9-]+) failed') { $providers[$Matches.name] = 'failed' }
        if ($line.Text -match '^done in ') { $result = 'ok' }
        elseif ($line.Text -match '^(?:error: )?failed: ') { $result = 'failed' }
    }
    [pscustomobject]@{
        File      = $File.FullName
        At        = if ($times.Count) { $times[0] } else { $File.LastWriteTimeUtc }
        Seconds   = if ($times.Count -gt 1) { ($times[-1] - $times[0]).TotalSeconds } else { 0 }
        Result    = $result
        Providers = $providers
        Warnings  = @($lines | Where-Object { $_.Text -like 'warning: *' }).Count
        Errors    = @($lines | Where-Object { $_.Text -like 'error: *' }).Count
        Verbose   = @($lines | Where-Object { $_.Text -like 'verbose: *' }).Count -gt 0
    }
}

function Show-PhxLogs {
    # phx logs: the last runs, newest first, numbered for phx logs <n>.
    param([int]$Count = 15)
    $files = @(Get-PhxRunLogFile)
    if (-not $files.Count) { Write-Host "no runs logged yet - phx run does one ($(Get-PhxLogDir))"; return }
    $verbose = (Read-PhxConfig).logging.verbose -eq $true
    $note = if ($verbose) { "verbose, kept $((Read-PhxConfig).logging.keepDays) days" } else { 'the newest 30 kept; phx logs verbose on for the detail' }
    Write-Host "runs logged in $(Get-PhxLogDir) ($note)" -ForegroundColor Cyan
    Write-Host ('  {0,3}  {1,-16}  {2,7}  {3,-8}  {4,8}  {5,6}  {6}' -f '#', 'when', 'took', 'result', 'warnings', 'errors', 'providers')
    for ($i = 0; $i -lt [Math]::Min($Count, $files.Count); $i++) {
        $run = Read-PhxRunLogSummary $files[$i]
        $names = @(foreach ($name in $run.Providers.Keys) { if ($run.Providers[$name] -eq 'ok') { $name } else { "$name ($($run.Providers[$name]))" } }) -join ', '
        $line = '  {0,3}  {1,-16}  {2,6:0.0}s  {3,-8}  {4,8}  {5,6}  {6}' -f ($i + 1), $run.At.ToLocalTime().ToString('yyyy-MM-dd HH:mm'), $run.Seconds, $run.Result, $run.Warnings, $run.Errors, $names
        $color = if ($run.Result -ne 'ok' -or $run.Errors) { 'Red' } elseif ($run.Warnings) { 'Yellow' } else { 'Gray' }
        Write-Host $line -ForegroundColor $color
    }
    if ($files.Count -gt $Count) { Write-Host "  ... $($files.Count - $Count) older" -ForegroundColor DarkGray }
    Write-Host '  phx logs <n> shows one run, phx logs errors what went wrong lately' -ForegroundColor DarkGray
}

function Show-PhxLog {
    # phx logs <n>: one run's log, its times local, warnings and errors in colour.
    param([Parameter(Mandatory)][int]$Number)
    $files = @(Get-PhxRunLogFile)
    if ($Number -lt 1 -or $Number -gt $files.Count) { throw "there is no run $Number - phx logs lists $($files.Count)" }
    $file = $files[$Number - 1]
    Write-Host $file.FullName -ForegroundColor Cyan
    foreach ($raw in [IO.File]::ReadAllLines($file.FullName)) {
        if ($raw -notmatch $script:PhxLogLine) { Write-Host $raw; continue }
        $at = [datetime]::MinValue
        $time = if ([datetime]::TryParse($Matches.at, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$at)) { $at.ToLocalTime().ToString('HH:mm:ss') } else { $Matches.at }
        $text = $Matches.text
        $color = if ($text -like 'error: *') { 'Red' } elseif ($text -like 'warning: *') { 'Yellow' } elseif ($text -like 'verbose: *') { 'DarkGray' } else { 'Gray' }
        Write-Host ('{0} {1,-12} {2}' -f $time, "[$($Matches.source)]", $text) -ForegroundColor $color
    }
}

function Show-PhxLogErrors {
    # phx logs errors: the warnings and errors of the last runs, newest first, per run.
    param([int]$Runs = 10)
    $shown = 0
    $number = 0
    foreach ($file in @(Get-PhxRunLogFile)) {
        $number++
        if ($number -gt $Runs) { break }
        $problems = @([IO.File]::ReadAllLines($file.FullName) | Where-Object { $_ -match $script:PhxLogLine -and ($Matches.text -like 'error: *' -or $Matches.text -like 'warning: *') })
        if (-not $problems.Count) { continue }
        $run = Read-PhxRunLogSummary $file
        Write-Host "run $number - $($run.At.ToLocalTime().ToString('yyyy-MM-dd HH:mm')), $($run.Result)" -ForegroundColor Cyan
        foreach ($problem in $problems) {
            $null = $problem -match $script:PhxLogLine
            $color = if ($Matches.text -like 'error: *') { 'Red' } else { 'Yellow' }
            Write-Host ('  {0,-12} {1}' -f "[$($Matches.source)]", $Matches.text) -ForegroundColor $color
        }
        $shown++
    }
    if (-not $shown) { Write-Host "no warnings or errors in the last $Runs runs" -ForegroundColor Green }
}

function Set-PhxLogVerbose {
    # phx logs verbose on|off: logging.verbose in the config - the scheduled run reads it, so the
    # task stays as it is.
    param([string]$Value)
    if (-not [IO.File]::Exists((Get-PhxConfigPath))) { throw 'not set up yet - run: phx init' }
    $config = Read-PhxConfig
    if (-not $Value) {
        $state = if ($config.logging.verbose) { "on - every run's detail in its log, kept $($config.logging.keepDays) days" } else { 'off - phx logs verbose on to turn it on' }
        Write-Host "verbose logging: $state"
        return
    }
    if ($Value -notin 'on', 'off') { throw "phx logs verbose on|off - not '$Value'" }
    $config.logging.verbose = $Value -eq 'on'
    Save-PhxConfig $config
    if ($config.logging.verbose) { Write-Host "verbose logging on: from the next run, its detail goes into its log, kept $($config.logging.keepDays) days - phx logs to look back" -ForegroundColor Green }
    else { Write-Host 'verbose logging off: the newest 30 logs are kept' -ForegroundColor Green }
}

function Invoke-PhxLogsCommand {
    # phx logs [<n>|errors|verbose on|off].
    param([string]$Action, [string]$Value)
    if (-not $Action) { Show-PhxLogs; return }
    $number = 0
    if ($Action -match '^\d+$') {
        if (-not [int]::TryParse($Action, [ref]$number)) { $number = [int]::MaxValue }
        Show-PhxLog -Number $number
        return
    }
    switch ($Action) {
        'errors' { Show-PhxLogErrors }
        'verbose' { Set-PhxLogVerbose -Value $Value }
        default { throw "unknown action '$Action' - phx logs [<n>|errors|verbose on|off]" }
    }
}
