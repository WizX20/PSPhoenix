# phx init (docs/design.md -> Commands): the wizard that decides what to back up and where. It asks
# for the roots, the GitHub account per owner, the target folder, this machine's name in it, the age
# key secrets are encrypted to and the interval, and turns the background run on. Nothing is saved
# before the last question - not the config, not the scan of the chosen roots; `q` at any prompt,
# Ctrl+C or the end of input stops without saving. A second run starts from the current values, so
# Enter all the way changes nothing. Once saved, it offers the review of the gitignored files (phx
# review), which saves each answer itself.

function Get-PhxRootCandidate {
    # Folders that commonly hold repositories; the wizard offers the ones that exist and hold any.
    $names = 'source/repos', 'repos', 'src', 'source', 'code', 'projects', 'dev', 'git'
    $bases = @($HOME)
    if ($script:OnWindows) {
        $bases += @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } | ForEach-Object { $_.RootDirectory.FullName })
    }
    foreach ($base in $bases) { foreach ($name in $names) { Join-PhxPath $base $name } }
}

function Get-PhxTargetSuggestion {
    # Where snapshots can go without more set-up: the OneDrive folders of this account, business first.
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($pair in @('OneDriveCommercial', 'OneDrive for Business'), @('OneDriveConsumer', 'OneDrive, personal'), @('OneDrive', 'OneDrive')) {
        $base = [Environment]::GetEnvironmentVariable($pair[0])
        if ($base -and [IO.Directory]::Exists($base) -and $seen.Add($base)) {
            [pscustomobject]@{ Path = Join-PhxPath $base 'PSPhoenix'; Label = $pair[1]; Business = $pair[0] -eq 'OneDriveCommercial' }
        }
    }
}

function Read-PhxInitAnswer {
    # A wizard answer; `q` stops the wizard without saving.
    param([Parameter(Mandatory)][string]$Prompt, [string]$Default = '')
    $answer = Read-PhxAnswer -Prompt $Prompt -Default $Default
    if ($answer -eq 'q') { throw [OperationCanceledException]::new('stopped') }
    $answer
}

function Read-PhxInitYesNo {
    param([Parameter(Mandatory)][string]$Prompt, [bool]$Default = $true)
    while ($true) {
        $answer = Read-PhxInitAnswer -Prompt "$Prompt ($(if ($Default) { 'Y/n' } else { 'y/N' }))"
        if (-not $answer) { return $Default }
        if ($answer -match '^(y|yes)$') { return $true }
        if ($answer -match '^(n|no)$') { return $false }
        Write-Host '  y or n, please' -ForegroundColor Yellow
    }
}

function Write-PhxInitStep {
    param([Parameter(Mandatory)][string]$Title, [string]$Hint)
    Write-Host
    Write-Host $Title -ForegroundColor Cyan
    if ($Hint) { Write-Host "  $Hint" -ForegroundColor DarkGray }
}

function Select-PhxInitRoot {
    # Step 1: the roots - the current ones and the usual folders that hold repositories, by number,
    # or any path typed in.
    param([object[]]$Current = @())
    $offers = [Collections.Generic.List[object]]::new()
    foreach ($root in $Current) { $offers.Add([pscustomobject]@{ Path = $root.path; Depth = [int]$root.depth; Current = $true; Count = 0 }) }
    foreach ($candidate in @(Get-PhxRootCandidate)) {
        if (-not [IO.Directory]::Exists($candidate)) { continue }
        $full = Get-PhxActualPath (ConvertTo-PhxFullPath $candidate)
        if (@($offers | Where-Object { (Test-PhxPathWithin $full $_.Path) -or (Test-PhxPathWithin $_.Path $full) }).Count) { continue }
        $offers.Add([pscustomobject]@{ Path = $full; Depth = $script:PhxDefaultRootDepth; Current = $false; Count = 0 })
    }
    foreach ($offer in $offers) {
        if ([IO.Directory]::Exists($offer.Path)) { $offer.Count = @(Find-PhxRepository -Root $offer.Path -Depth $offer.Depth).Count }
    }
    $offers = @($offers | Where-Object { $_.Current -or $_.Count })

    Write-PhxInitStep 'Roots - the folders that hold your repositories' "numbers from the list and/or paths, comma-separated; a new root searches $script:PhxDefaultRootDepth levels deep (later: phx roots add <path> -Depth <n>)"
    for ($i = 0; $i -lt $offers.Count; $i++) {
        $note = if ($offers[$i].Current) { '   (current)' } else { '' }
        Write-Host ('  {0}. {1}   {2} repositories{3}' -f ($i + 1), $offers[$i].Path, $offers[$i].Count, $note)
    }
    $defaults = @(for ($i = 0; $i -lt $offers.Count; $i++) { if ($offers[$i].Current -or -not $Current.Count) { $i + 1 } })
    while ($true) {
        $answer = Read-PhxInitAnswer -Prompt '  Roots' -Default ($defaults -join ',')
        try {
            $chosen = [Collections.Generic.List[object]]::new()
            foreach ($token in @($answer -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                if ($token -match '^\d+$') {
                    $number = [int]$token
                    if ($number -lt 1 -or $number -gt $offers.Count) { throw "there is no number $token in the list" }
                    $chosen.Add($offers[$number - 1])
                }
                else {
                    $full = ConvertTo-PhxFullPath $token
                    if (-not [IO.Directory]::Exists($full)) { throw "no such folder: $full" }
                    $full = Get-PhxActualPath $full
                    $known = $offers | Where-Object { [string]::Equals($_.Path, $full, (Get-PhxPathComparison)) } | Select-Object -First 1
                    $chosen.Add($(if ($known) { $known } else { [pscustomobject]@{ Path = $full; Depth = $script:PhxDefaultRootDepth } }))
                }
            }
            if (-not $chosen.Count) { throw 'at least one root, please' }
            $paths = @()
            foreach ($root in $chosen) { Assert-PhxRootFits -Path $root.Path -Roots $paths; $paths += $root.Path }
            return @($chosen | ForEach-Object { [ordered]@{ path = $_.Path; depth = $_.Depth } })
        }
        catch { Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow }
    }
}

function Select-PhxInitAccount {
    # Step 3: for every owner on a host gh is logged in to, the account its repositories use.
    # Hosts gh does not know (Azure DevOps, GitLab, ...) sign in through Git Credential Manager.
    param([object[]]$Records = @(), [System.Collections.IDictionary]$Current = @{})
    $result = [ordered]@{}
    foreach ($key in @($Current.Keys)) { $result[$key] = $Current[$key] }
    Write-PhxInitStep 'Accounts - which GitHub account the repositories of each owner use' 'restore clones each repository with this account; never gh auth switch'
    $logins = @(Get-PhxGhAccount)
    if (-not $logins) {
        Write-Host '  gh is not logged in, or not installed - skipped; run phx init again after gh auth login' -ForegroundColor Yellow
        return $result
    }
    Write-Host "  gh is logged in as: $(($logins | ForEach-Object { "$($_.Login) ($($_.Host))" }) -join ', ')"
    $owners = @($Records | Where-Object { Get-PhxIdentityOwner $_.identity } |
            Group-Object { Get-PhxIdentityOwner $_.identity } |
            Sort-Object @{ Expression = 'Count'; Descending = $true }, Name)
    foreach ($owner in $owners) {
        $hostName = $owner.Name.Split('/')[0]
        $names = @($logins | Where-Object Host -EQ $hostName | ForEach-Object Login)
        if (-not $names) { continue }
        # An account set before stays a choice - the default even - when gh is not logged in with
        # it on this machine: Enter all the way must change nothing.
        $configured = $result[$owner.Name]
        $choices = @($names)
        if ($configured -and $names -notcontains $configured) {
            Write-Host "  $($owner.Name) uses $configured, but gh is not logged in as $configured - gh auth login --hostname $hostName" -ForegroundColor Yellow
            $choices = @($configured) + $names
        }
        if ($choices.Count -eq 1) { $result[$owner.Name] = $choices[0]; Write-Host "  $($owner.Name): $($choices[0])"; continue }
        # Default: what is set, else what the repositories' own credential helpers say, else the
        # active account.
        $fromHelpers = @($owner.Group | Where-Object { $_.helperAccount } | Group-Object { $_.helperAccount } | Sort-Object Count -Descending | ForEach-Object Name)
        $active = @($logins | Where-Object { $_.Host -eq $hostName -and $_.Active } | ForEach-Object Login)
        $default = @(@($configured) + $fromHelpers + $active + $names | Where-Object { $_ -and $choices -contains $_ })[0]
        while ($true) {
            $answer = Read-PhxInitAnswer -Prompt "  $($owner.Name) ($($owner.Count) repositories) - $($choices -join ' / ')" -Default $default
            $match = @($choices | Where-Object { $_ -eq $answer })[0]
            if ($match) { $result[$owner.Name] = $match; break }
            Write-Host "  one of: $($choices -join ', ')" -ForegroundColor Yellow
        }
    }
    $result
}

function Select-PhxInitTarget {
    # Step 4: the folder snapshots go to.
    param([System.Collections.IDictionary]$Current)
    $suggestions = @(Get-PhxTargetSuggestion)
    Write-PhxInitStep 'Target - the folder snapshots go to' 'a synced folder (OneDrive, Dropbox), a NAS share or a USB disk; a number or a path'
    for ($i = 0; $i -lt $suggestions.Count; $i++) { Write-Host ('  {0}. {1}   ({2})' -f ($i + 1), $suggestions[$i].Path, $suggestions[$i].Label) }
    $default = @(@($Current.path) + @($suggestions | ForEach-Object Path) | Where-Object { $_ })[0]
    while ($true) {
        $answer = Read-PhxInitAnswer -Prompt '  Target' -Default $default
        if (-not $answer) { Write-Host '  a folder, please' -ForegroundColor Yellow; continue }
        # A bare number picks from the list; a folder named like one is typed as a path (./2).
        if ($answer -match '^\d+$') {
            $number = 0
            if (-not [int]::TryParse($answer, [ref]$number) -or $number -lt 1 -or $number -gt $suggestions.Count) {
                Write-Host "  there is no number $answer in the list - a folder named ${answer}: .$([IO.Path]::DirectorySeparatorChar)$answer" -ForegroundColor Yellow
                continue
            }
            $path = $suggestions[$number - 1].Path
        }
        else { $path = Get-PhxActualPath (ConvertTo-PhxFullPath $answer) }
        if ([IO.File]::Exists($path)) { Write-Host "  $path is a file" -ForegroundColor Yellow; continue }
        if (-not [IO.Directory]::Exists($path) -and -not (Read-PhxInitYesNo -Prompt "  $path does not exist yet - create it when saving?")) { continue }
        if (-not @($suggestions | Where-Object { $_.Business -and [string]::Equals($_.Path, $path, (Get-PhxPathComparison)) }).Count) {
            Write-Host '  note: a snapshot holds your Claude Code memory and local config - on a work machine keep it inside the company storage (OneDrive for Business), not a personal account' -ForegroundColor DarkYellow
        }
        return [ordered]@{ type = 'folder'; path = $path }
    }
}

function Select-PhxInitMachine {
    # Step 5: this machine's folder in the target - the computer name unless chosen otherwise. A
    # folder another installation wrote (a machine reinstalled under the same name) is not taken:
    # its snapshot is what a restore needs.
    param([Parameter(Mandatory)][string]$TargetPath, [System.Collections.IDictionary]$Current)
    Write-PhxInitStep 'Machine - the name of this machine''s folder in the target' 'several machines can share one target side by side; letters, digits, dot, dash, underscore'
    $id = if ($Current -and $Current.id) { "$($Current.id)" } else { [guid]::NewGuid().ToString() }
    $default = if ($Current -and $Current.name) { "$($Current.name)" } else { [Environment]::MachineName }
    while ($true) {
        $name = Read-PhxInitAnswer -Prompt '  Machine' -Default $default
        if (-not (Test-PhxMachineName $name)) { Write-Host '  letters, digits, dot, dash and underscore, please' -ForegroundColor Yellow; continue }
        $problem = Get-PhxSnapshotProblem -Path (Join-PhxPath $TargetPath $name) -Id $id
        if ($problem) {
            Write-Host "  $problem" -ForegroundColor Yellow
            for ($n = 2; [IO.Directory]::Exists((Join-PhxPath $TargetPath "$name-$n")); $n++) { }
            $default = "$name-$n"
            continue
        }
        return [ordered]@{ name = $name; id = $id }
    }
}

function Test-PhxPassphrase {
    # Long enough to guard a key copy in a synced folder: four words or more, or 20 characters.
    param([string]$Text)
    $words = @($Text -split '[\s\-_.,;:]+' | Where-Object { $_.Length -ge 2 })
    $words.Count -ge 4 -or $Text.Length -ge 20
}

function Select-PhxInitSecret {
    # Step 6: the age key secrets are encrypted to (docs/design.md -> Secrets). The current one is
    # kept on Enter. A new one gets a passphrase-protected copy in the target, unless declined, and
    # its secret half is shown once after saving. Or the recipient of a key the user already has.
    param([string]$Current)
    Write-PhxInitStep 'Secrets - the key that files with a password or token in them are encrypted to' 'an age key: the public half goes into the config, so the background run needs no secret; the secret half stays with you'
    if ($Current) {
        Write-Host "  current key: $Current"
        if (Read-PhxInitYesNo -Prompt '  Keep it?') { return [pscustomobject]@{ Recipient = $Current; Identity = $null; Passphrase = $null; Source = 'current' } }
        Write-Host '  note: the next run encrypts every secret to the new key; older versions in the target stay encrypted to the current one - keep it as well' -ForegroundColor DarkYellow
    }
    while ($true) {
        $answer = Read-PhxInitAnswer -Prompt '  Enter for a new key, or the age1... recipient of a key you have'
        if (-not $answer) { break }
        if ([PSPhoenix.Engine.Age]::IsRecipient($answer)) { return [pscustomobject]@{ Recipient = $answer; Identity = $null; Passphrase = $null; Source = 'yours' } }
        if ($answer -match '^AGE-SECRET-KEY-') { Write-Host '  that is the secret half of the key - keep it to yourself; its public half starts with age1 (age-keygen -y <key file> prints it)' -ForegroundColor Yellow; continue }
        Write-Host '  an age recipient starts with age1 - or Enter for a new key' -ForegroundColor Yellow
    }
    $key = [PSPhoenix.Engine.Age]::NewKey()
    Write-Host '  a passphrase protects a copy of the new key in the target: a restore then needs only the passphrase - four words or more, or 20 characters' -ForegroundColor DarkGray
    while ($true) {
        $passphrase = Read-PhxSecretAnswer -Prompt '  Passphrase (Enter for none)'
        if (-not $passphrase) {
            if (Read-PhxInitYesNo -Prompt '  No copy of the key in the target: only the key shown at the end restores your secrets. Sure?' -Default $false) { break }
            continue
        }
        # The target may be a shared or synced folder: whoever can read the copy can try passphrases
        # at leisure, so a short one with a few substitutions will not do.
        if (-not (Test-PhxPassphrase $passphrase)) { Write-Host '  four words or more, or at least 20 characters, please - whoever can read the target can try passphrases at leisure' -ForegroundColor Yellow; continue }
        if ((Read-PhxSecretAnswer -Prompt '  The same passphrase again') -cne $passphrase) { Write-Host '  not the same - once more' -ForegroundColor Yellow; continue }
        break
    }
    [pscustomobject]@{ Recipient = $key.Recipient; Identity = $key.Identity; Passphrase = $passphrase; Source = 'new' }
}

function Select-PhxInitInterval {
    # Step 7: how often the background run goes.
    param([string]$Current)
    Write-PhxInitStep 'Interval - how often the background run backs up' 'minutes, hours or days: 30m, 1h, 4h, 1d'
    $default = if ($Current) { $Current } else { '1h' }
    while ($true) {
        $answer = Read-PhxInitAnswer -Prompt '  Interval' -Default $default
        if (Test-PhxInterval $answer) { return $answer }
        Write-Host '  like 30m, 1h or 1d - from 15m to 31d' -ForegroundColor Yellow
    }
}

function Invoke-PhxInitReview {
    # The step after saving: the gitignored files to decide on (phx review), when there are any.
    # A failure here leaves the saved set-up as it is: phx review tries again.
    Write-PhxInitStep 'Gitignored files - which local files to back up' 'a file nobody decided on is not backed up; Enter skips, phx review does it later'
    try { Invoke-PhxReview -Ask }
    catch [OperationCanceledException] { Write-Host '  review stopped - phx review goes on later' -ForegroundColor Yellow }
    catch { Write-Host "  review: $($_.Exception.Message) - phx review tries again" -ForegroundColor Yellow }
}

function Invoke-PhxInit {
    $configPath = Get-PhxConfigPath
    $config = Read-PhxConfig
    $verb = if ([IO.File]::Exists($configPath)) { 'changing' } else { 'setting up' }
    Write-Host "phx init - $verb PSPhoenix. Enter keeps the answer in [brackets]; q stops without saving." -ForegroundColor Green
    try {
        $roots = Select-PhxInitRoot -Current @($config.roots | Where-Object { $_ })
        Write-PhxInitStep 'Discovery'
        $records = @(Invoke-PhxScan -Roots $roots -NoSave -PassThru)
        $accounts = Select-PhxInitAccount -Records $records -Current $config.accounts
        $target = Select-PhxInitTarget -Current $config.target
        $machine = Select-PhxInitMachine -TargetPath $target.path -Current $config.machine
        $secret = Select-PhxInitSecret -Current $config.secrets.recipient
        $interval = Select-PhxInitInterval -Current $config.interval
        # Step 8: the background run. Asked only where phx schedule works (Windows, for now). The
        # default is what is so now - on for a first init - so Enter all the way changes nothing.
        $schedule = $false
        $registered = $null
        if (Test-PhxCanSchedule) {
            $registered = Get-PhxScheduledTask
            $default = if ([IO.File]::Exists($configPath)) { [bool]$registered } else { $true }
            Write-PhxInitStep 'Schedule - back up in the background' "a task in your Task Scheduler runs phx every $interval and after logon; phx schedule off removes it"
            $schedule = Read-PhxInitYesNo -Prompt '  Run it in the background?' -Default $default
        }

        Write-PhxInitStep 'Summary'
        foreach ($root in $roots) { Write-Host "  root      $($root.path)   depth $($root.depth)" }
        foreach ($owner in $accounts.Keys) { Write-Host "  account   $owner -> $($accounts[$owner])" }
        Write-Host "  target    $($target.path)"
        Write-Host "  machine   $($machine.name)   snapshot in $(Join-PhxPath $target.path $machine.name)"
        $keyNote = switch ($secret.Source) {
            'current' { 'the current key' }
            'yours' { 'your key' }
            default { if ($secret.Passphrase) { "a new key, its passphrase copy $(Split-Path -Leaf (Get-PhxKeyCopyPath -Config @{ target = $target; machine = $machine } -Recipient $secret.Recipient)) in the snapshot" } else { 'a new key, no copy in the snapshot' } }
        }
        Write-Host "  secrets   $(Format-PhxRecipient $secret.Recipient)   $keyNote"
        Write-Host "  interval  $interval"
        if (Test-PhxCanSchedule) { Write-Host "  schedule  $(if ($schedule) { 'on' } else { 'off - phx schedule on later' })" }
        if (-not (Read-PhxInitYesNo -Prompt "Save to ${configPath}?")) { throw [OperationCanceledException]::new('not confirmed') }
    }
    catch [OperationCanceledException] {
        Write-Host "phx init: $($_.Exception.Message) - nothing saved" -ForegroundColor Yellow
        return
    }
    [IO.Directory]::CreateDirectory($target.path) | Out-Null
    $config.roots = @($roots)
    $config.accounts = $accounts
    $config.target = $target
    $config.machine = $machine
    $config.secrets.recipient = $secret.Recipient
    $config.interval = $interval
    # The key's copy before the config: if the target cannot take it, nothing changed.
    if ($secret.Passphrase) { Save-PhxKeyCopy -Config $config -Identity $secret.Identity -Passphrase $secret.Passphrase }
    Save-PhxConfig $config
    Write-Host "saved $configPath" -ForegroundColor Green
    # From here on the config names the new key: it is shown whatever else goes wrong.
    try {
        Save-PhxRepoCache -Roots $roots -Records $records
        if ($schedule) {
            # Registered already, as it should be (the same interval, this module): left alone.
            if (-not $registered -or @(Get-PhxScheduleProblem -Task $registered -Config $config).Count) { Enable-PhxSchedule }
        }
        elseif ($registered) { Disable-PhxSchedule }
    }
    finally {
        if ($secret.Identity) {
            Write-Host
            Write-Host 'Your new age key - put it in your password manager now, it is not shown again:' -ForegroundColor Yellow
            Show-PhxSecretLine "  $($secret.Identity)"
            $restore = if ($secret.Passphrase) { "it, or the passphrase for $(Split-Path -Leaf (Get-PhxKeyCopyPath $config)) in the snapshot, opens your secrets on a new machine" } else { 'it is the only way to open your secrets on a new machine' }
            Write-Host "  $restore" -ForegroundColor DarkGray
        }
    }
    Invoke-PhxInitReview
    Write-Host 'next: phx run for a first backup now, then phx status' -ForegroundColor Green
}
