# phx status (docs/design.md -> Commands): what PSPhoenix knows about this machine and what needs
# attention. Reads the config, the last scan and `gh auth status`; writes nothing but a probe file
# in the target, removed at once. Only a config it cannot read stops it: any other problem is a
# warning line, counted at the end.

function Format-PhxAge {
    # "just now", "1 minute ago", "3 hours ago", "2 days ago".
    param([Parameter(Mandatory)][datetime]$Since)
    $age = [DateTime]::UtcNow - $Since.ToUniversalTime()
    if ($age.TotalMinutes -lt 1) { return 'just now' }
    $count, $unit = if ($age.TotalHours -lt 1) { [Math]::Floor($age.TotalMinutes), 'minute' }
    elseif ($age.TotalDays -lt 2) { [Math]::Floor($age.TotalHours), 'hour' }
    else { [Math]::Floor($age.TotalDays), 'day' }
    '{0} {1}{2} ago' -f $count, $unit, $(if ($count -eq 1) { '' } else { 's' })
}

function ConvertTo-PhxScanTime {
    # The scan's timestamp, or nothing when it is not one. ConvertFrom-Json already turns the ISO
    # text into a DateTime; anything else is parsed, and a cache edited by hand may hold neither.
    param($Value)
    if ($Value -is [datetime]) { return $Value }
    $parsed = [datetime]::MinValue
    $styles = [Globalization.DateTimeStyles]::RoundtripKind
    if ([datetime]::TryParse("$Value", [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) { $parsed }
}

function Test-PhxWritableFolder {
    # True when a file can be created in the folder: a read-only share, a write-protected disk or a
    # folder without permission fails here rather than at the first backup.
    param([Parameter(Mandatory)][string]$Path)
    $probe = Join-Path $Path ".phx-write-test-$([guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::Create($probe, 1, [IO.FileOptions]::DeleteOnClose).Dispose()
        $true
    }
    catch { $false }
}

function Get-PhxNeededAccount {
    # The accounts the scanned repositories need, per host: { Host, Login, Count }.
    param([object[]]$Records = @(), [System.Collections.IDictionary]$Accounts = @{})
    $Records | Where-Object { Get-PhxIdentityOwner $_.identity } | ForEach-Object {
        $login = Get-PhxRepoAccount -Record $_ -Accounts $Accounts
        if ($login) { [pscustomobject]@{ Host = $_.identity.Split('/')[0]; Login = $login } }
    } | Group-Object Host, Login | ForEach-Object {
        [pscustomobject]@{ Host = $_.Group[0].Host; Login = $_.Group[0].Login; Count = $_.Count }
    }
}

function Show-PhxStatus {
    $configPath = Get-PhxConfigPath
    Write-Host "PSPhoenix $(Get-PhxVersion)"
    if (-not [IO.File]::Exists($configPath)) {
        Write-Host 'not set up yet - run: phx init' -ForegroundColor Yellow
        return
    }
    $config = Read-PhxConfig
    $warnings = [Collections.Generic.List[string]]::new()
    $line = { param($Label, $Text, [switch]$Warn)
        $text = '  {0,-10} {1}' -f $Label, $Text
        if ($Warn) { Write-Host $text -ForegroundColor Yellow; $warnings.Add($Label) } else { Write-Host $text }
    }

    & $line 'config' "$configPath (format $($config.version))"
    if (-not $config.target -or -not $config.target.path) { & $line 'target' 'not set - phx init' -Warn }
    elseif (-not [IO.Directory]::Exists($config.target.path)) { & $line 'target' "$($config.target.path) - folder not found (a disconnected drive? phx init changes it)" -Warn }
    elseif (-not (Test-PhxWritableFolder $config.target.path)) { & $line 'target' "$($config.target.path) - cannot write there (read-only, full, or no permission)" -Warn }
    else { & $line 'target' $config.target.path }
    & $line 'interval' "$($config.interval) - the background run arrives with M2 (phx schedule)"

    $roots = @($config.roots | Where-Object { $_ })
    $cache = Read-PhxRepoCache
    if (-not $roots) { & $line 'roots' 'none - phx roots add <path>, or phx init' -Warn }
    $unscanned = 0
    foreach ($root in $roots) {
        # A root the last scan did not cover (added since) is "not scanned", not "0 repositories".
        $found = Get-PhxRootRepoCount -Cache $cache -Root $root.path
        $missing = -not [IO.Directory]::Exists($root.path)
        if ($null -eq $found -and -not $missing) { $unscanned++ }
        $count = if ($missing) { 'folder not found' } elseif ($null -eq $found) { 'not scanned' } else { "$found repositories" }
        & $line 'root' "$($root.path)   depth $($root.depth)   $count" -Warn:$missing
    }
    if (-not $cache) { & $line 'scan' 'not scanned yet - phx scan' -Warn }
    elseif ($unscanned) { & $line 'scan' "$unscanned root(s) not scanned yet - phx scan" -Warn }
    else {
        $scanned = ConvertTo-PhxScanTime $cache.scannedAt
        if ($scanned) { & $line 'scan' "$(Format-PhxAge $scanned) - phx scan refreshes it" }
        else { & $line 'scan' 'time unknown - phx scan refreshes it' -Warn }
    }

    # Each provider says what it knows.
    $context = New-PhxContext -Provider 'status' -Config $config
    foreach ($provider in @(Get-PhxProvider)) {
        $lines = @(try { & $provider.Status $context } catch { "status failed: $($_.Exception.Message)" })
        for ($i = 0; $i -lt $lines.Count; $i++) { & $line $(if ($i) { '' } else { $provider.Name }) $lines[$i] }
    }

    # Restore stops when gh lacks an account a repository needs - better to know now.
    if ($cache) {
        $needed = @(Get-PhxNeededAccount -Records @(Get-PhxScannedRecord -Cache $cache -Config $config) -Accounts $config.accounts)
        if ($needed) {
            $logins = @(Get-PhxGhAccount)
            foreach ($need in $needed) {
                $known = @($logins | Where-Object { $_.Host -eq $need.Host -and $_.Login -eq $need.Login }).Count
                if ($known) { & $line 'account' "$($need.Login) on $($need.Host) ($($need.Count) repositories) - logged in to gh" }
                else { & $line 'account' "$($need.Login) on $($need.Host) ($($need.Count) repositories) - not logged in to gh: gh auth login --hostname $($need.Host)" -Warn }
            }
        }
    }

    & $line 'last run' 'arrives with M2 (phx run)'
    & $line 'review' 'gitignored files to decide on - arrives with M3 (phx review)'
    & $line 'wip' 'local-only work - arrives with M4'
    if ($warnings.Count) { Write-Host "$($warnings.Count) thing(s) need attention" -ForegroundColor Yellow }
    else { Write-Host 'nothing needs attention' -ForegroundColor Green }
}
