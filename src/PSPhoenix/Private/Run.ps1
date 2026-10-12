# phx run (docs/design.md -> Commands): one backup run - what the scheduled task calls. It checks
# the set-up and the target, takes a lock so two runs never overlap, refreshes discovery when it is
# due, runs every provider that is enabled, applies to this platform and is due (or the one named),
# each into a staging folder of its own, and publishes those that succeeded into the snapshot. A
# provider that fails does not stop the others and keeps its previous snapshot; the run reports it
# and fails at the end. Everything it prints also goes to a log per run in the state folder.

$script:PhxRunLogKeep = 30
$script:PhxRunLog = $null

function Write-PhxRunLog {
    # One line into this run's log file, if one is open: UTC time, the source in brackets, the text.
    param([AllowEmptyString()][string]$Message, [string]$Source = 'run')
    if (-not $script:PhxRunLog) { return }
    # The indentation that groups lines on screen means nothing next to a [source] tag.
    [IO.File]::AppendAllText($script:PhxRunLog, ('{0} [{1}] {2}{3}' -f [DateTime]::UtcNow.ToString('o'), $Source, $Message.Trim(), [Environment]::NewLine))
}

function Invoke-PhxLogged {
    # Runs $Action and shows what it writes to the host as usual - in its own colours - while
    # copying every line into the run's log, so a run nobody watches still says what happened.
    param([Parameter(Mandatory)][scriptblock]$Action, [string]$Source = 'run')
    & $Action 6>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.InformationRecord]) {
            $data = $_.MessageData
            $text = if ($data -is [System.Management.Automation.HostInformationMessage]) { $data.Message } else { "$data" }
            Write-PhxRunLog -Message $text -Source $Source
            # A line without a colour of its own carries the host's, which is -1 - no colour - on a
            # host without a console (a CI runner, a redirected run): not one Write-Host takes.
            $color = if ($data -is [System.Management.Automation.HostInformationMessage]) { $data.ForegroundColor }
            if ($null -ne $color -and [Enum]::IsDefined([ConsoleColor], $color)) { Write-Host $text -ForegroundColor $color }
            else { Write-Host $text }
        }
        else { $_ }
    }
}

function Write-PhxRunLine {
    # A line of the run itself: to the host and to the log.
    param([Parameter(Mandatory)][string]$Message, [string]$Color)
    Write-PhxRunLog -Message $Message
    if ($Color) { Write-Host $Message -ForegroundColor $Color } else { Write-Host $Message }
}

function Open-PhxRunLock {
    # The lock that keeps two runs apart: a file held open without sharing for the whole run - the
    # operating system lets it go even when the process dies. Throws when another run holds it.
    $path = Join-Path (Get-PhxStateDir) 'run.lock'
    [IO.Directory]::CreateDirectory((Split-Path $path)) | Out-Null
    try { [IO.FileStream]::new($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch [System.IO.IOException] { throw 'another phx run is in progress - try again when it is done' }
}

function New-PhxRunLog {
    # A fresh log file for this run, and the oldest ones beyond the last $script:PhxRunLogKeep gone.
    $dir = Join-Path (Get-PhxStateDir) 'logs'
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    $path = Join-Path $dir ('run-{0}.log' -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
    [IO.File]::WriteAllText($path, '')
    @(Get-ChildItem -LiteralPath $dir -Filter 'run-*.log' | Sort-Object Name -Descending | Select-Object -Skip $script:PhxRunLogKeep) |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -ErrorAction SilentlyContinue }
    $path
}

function Get-PhxRunProvider {
    # The providers this run runs: the one named - whatever its cadence - or every one that applies
    # to this platform, is enabled and is due. Says why it leaves one out.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config, [Parameter(Mandatory)][System.Collections.IDictionary]$State, [string]$Name)
    if ($Name) {
        $provider = Get-PhxProvider $Name
        if (-not $provider) { throw "no provider '$Name' - see: phx providers" }
        if ($provider.Platforms -notcontains (Get-PhxCurrentPlatform)) { throw "provider '$Name' does not run on $(Get-PhxCurrentPlatform)" }
        return $provider
    }
    foreach ($provider in @(Get-PhxProvider)) {
        $settings = $Config.providers[$provider.Name]
        if ($settings -is [System.Collections.IDictionary] -and $settings.enabled -eq $false) { Write-PhxRunLine "  $($provider.Name): disabled in the config"; continue }
        if (-not (Test-PhxProviderDue -Provider $provider -State $State -Config $Config)) { Write-PhxRunLine "  $($provider.Name): not due yet"; continue }
        $provider
    }
}

function Invoke-PhxRun {
    param([string]$Provider)
    if (-not [IO.File]::Exists((Get-PhxConfigPath))) { throw 'not set up yet - run: phx init' }
    $config = Read-PhxConfig
    if (-not $config.target -or -not $config.target.path) { throw 'no target yet - run: phx init' }
    if (-not [IO.Directory]::Exists($config.target.path)) { throw "target $($config.target.path) not found - a disconnected drive? (phx status)" }
    if (-not (Test-PhxWritableFolder $config.target.path)) { throw "cannot write to the target $($config.target.path) - read-only, full, or no permission" }
    if (-not $config.machine.id) {
        # A config from before machine ids (M1): this installation gets one now.
        $config.machine = [ordered]@{ name = Get-PhxMachineName $config; id = [guid]::NewGuid().ToString() }
        Save-PhxConfig $config
    }
    $snapshot = Get-PhxSnapshotPath $config
    Assert-PhxSnapshotWritable -Path $snapshot -Config $config | Out-Null

    $lock = Open-PhxRunLock
    $script:PhxRunLog = New-PhxRunLog
    try {
        $started = [DateTime]::UtcNow
        Write-PhxRunLine "phx run $(Get-PhxVersion) -> $snapshot" Green
        $state = Read-PhxState
        if (@($config.roots).Count -and (Test-PhxScanDue -Cache (Read-PhxRepoCache -Quiet) -Config $config)) {
            Write-PhxRunLine 'scan: discovery is due'
            # A scan that fails leaves the last one in place: the providers can still run from it.
            try { Invoke-PhxLogged -Source 'scan' -Action { Invoke-PhxScan } | Out-Null }
            catch { Write-PhxRunLine "  scan failed: $(Hide-PhxSecret $_.Exception.Message) - going on with the last scan" Yellow }
        }
        $providers = @(Get-PhxRunProvider -Config $config -State $state -Name $Provider)
        $succeeded = [Collections.Generic.List[string]]::new()
        $failed = [Collections.Generic.List[string]]::new()
        foreach ($entry in $providers) {
            $name = $entry.Name
            $staging = Get-PhxStagingPath $name
            # A fresh staging folder: what is in it afterwards is exactly what this run produced.
            if ([IO.Directory]::Exists($staging)) { Remove-Item -LiteralPath $staging -Recurse -Force }
            [IO.Directory]::CreateDirectory($staging) | Out-Null
            Write-PhxRunLine "${name}:" Cyan
            $context = New-PhxContext -Provider $name -Staging $staging -Config $config -State $state
            try {
                Invoke-PhxLogged -Source $name -Action { & $entry.Backup $context } | Out-Null
                $succeeded.Add($name)
            }
            catch {
                $message = Hide-PhxSecret $_.Exception.Message
                Write-PhxRunLine "  ${name} failed: $message" Red
                $failed.Add($name)
                $state.providers[$name] = [ordered]@{ lastRun = $state.providers[$name].lastRun; lastResult = "failed: $message" }
            }
        }
        $results = if ($succeeded.Count) { Publish-PhxSnapshot -Config $config -Provider @($succeeded) -State $state } else { @{} }
        $now = [DateTime]::UtcNow.ToString('o')
        foreach ($name in $succeeded) {
            $result = $results[$name]
            $state.providers[$name] = [ordered]@{ lastRun = $now; lastResult = 'ok' }
            Write-PhxRunLine ('  {0}: {1} written, {2} unchanged, {3} removed' -f $name, $result.Written, $result.Unchanged, $result.Removed)
        }
        $state.lastRun = [ordered]@{ at = $now; providers = @($providers.Name); failed = @($failed); log = $script:PhxRunLog }
        Save-PhxState $state
        $seconds = [Math]::Round(([DateTime]::UtcNow - $started).TotalSeconds, 1)
        if ($failed.Count) { throw "$($failed.Count) provider(s) failed: $($failed -join ', ') - log: $script:PhxRunLog" }
        Write-PhxRunLine "done in ${seconds}s: $($succeeded.Count) provider(s) - log: $script:PhxRunLog" Green
    }
    catch {
        Write-PhxRunLog -Message "failed: $(Hide-PhxSecret $_.Exception.Message)"
        throw
    }
    finally {
        $script:PhxRunLog = $null
        $lock.Dispose()
    }
}
