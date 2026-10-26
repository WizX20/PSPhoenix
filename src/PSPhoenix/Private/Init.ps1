# phx init (docs/design.md -> Commands): the wizard that decides what to back up and where. It asks
# for the roots, the GitHub account per owner, the target folder, this machine's name in it, the age
# key secrets are encrypted to and the interval, and turns the background run on. Each step is
# counted (Step 3 of 8), asks one plain question with a line of why - ? shows the details - and
# ends with one line that confirms the answer. Nothing is saved before the last question - not the
# config, not the scan of the chosen roots; `q` at any prompt, Ctrl+C or the end of input stops
# without saving. A second run starts from the current values, so Enter all the way changes
# nothing. Once saved, it offers the review of the gitignored files (phx review), which saves each
# answer itself.

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

function Test-PhxPersonalCloudPath {
    # Whether a folder lies in a personal cloud account - the personal OneDrive, Dropbox, Google
    # Drive, iCloud - where company data does not belong.
    param([Parameter(Mandatory)][string]$Path)
    $business = [Environment]::GetEnvironmentVariable('OneDriveCommercial')
    foreach ($name in 'OneDriveConsumer', 'OneDrive') {
        $base = [Environment]::GetEnvironmentVariable($name)
        if (-not $base -or ($business -and [string]::Equals($base, $business, (Get-PhxPathComparison)))) { continue }
        if (Test-PhxPathWithin $Path $base) { return $true }
    }
    @($Path -split '[\\/]' | Where-Object { $_ -match '^(Dropbox( \(Personal\))?|Google Drive|My Drive|iCloudDrive|iCloud Drive)$' }).Count -gt 0
}

function Read-PhxInitAnswer {
    # A wizard answer; `q` stops the wizard without saving, `?` shows -Help and asks again.
    param([Parameter(Mandatory)][string]$Prompt, [string]$Default = '', [string[]]$Help = @())
    while ($true) {
        $answer = Read-PhxAnswer -Prompt $Prompt -Default $Default
        if ($answer -eq 'q') { throw [OperationCanceledException]::new('stopped') }
        if ($answer -ne '?' -or -not $Help.Count) { return $answer }
        foreach ($line in $Help) { Write-Host "  $line" -ForegroundColor DarkGray }
    }
}

function Read-PhxInitYesNo {
    param([Parameter(Mandatory)][string]$Prompt, [bool]$Default = $true, [string[]]$Help = @())
    while ($true) {
        $answer = Read-PhxInitAnswer -Prompt "$Prompt ($(if ($Default) { 'Y/n' } else { 'y/N' }))" -Help $Help
        if (-not $answer) { return $Default }
        if ($answer -match '^(y|yes)$') { return $true }
        if ($answer -match '^(n|no)$') { return $false }
        Write-Host '  y or n, please' -ForegroundColor Yellow
    }
}

# Where the wizard is: the step it is on, and how many there are (Invoke-PhxInit sets both).
$script:PhxInitStep = [pscustomobject]@{ At = 0; Of = 0 }

function Write-PhxInitStep {
    # A step's head: "Step 3 of 8 - Accounts", the plain question, one line of why.
    param([Parameter(Mandatory)][string]$Title, [string]$Question, [string]$Why)
    $script:PhxInitStep.At++
    Write-Host
    Write-Host ('Step {0} of {1} - {2}' -f $script:PhxInitStep.At, $script:PhxInitStep.Of, $Title) -ForegroundColor Cyan
    if ($Question) { Write-Host "  $Question" }
    if ($Why) { Write-Host "  $Why" -ForegroundColor DarkGray }
}

function Write-PhxInitHeading {
    # A part of the wizard that is no step: the summary, the review after saving.
    param([Parameter(Mandatory)][string]$Title, [string]$Hint)
    Write-Host
    Write-Host $Title -ForegroundColor Cyan
    if ($Hint) { Write-Host "  $Hint" -ForegroundColor DarkGray }
}

function Get-PhxTick {
    # A check mark where the console can show one; a console on an OEM code page (437, 850) would
    # print a question mark instead.
    $tick = [string][char]0x2713
    $encoding = try { [Console]::OutputEncoding } catch { $null }
    if ($encoding -and $encoding.GetString($encoding.GetBytes($tick)) -eq $tick) { $tick } else { '+' }
}

function Write-PhxInitDone {
    # The one line that confirms a step's answer.
    param([Parameter(Mandatory)][string]$Text)
    Write-Host "  $(Get-PhxTick) $Text" -ForegroundColor Green
}

function Format-PhxInitCount {
    # "1 repository", "27 repositories".
    param([int]$Count)
    if ($Count -eq 1) { '1 repository' } else { "$Count repositories" }
}

function Select-PhxInitRoot {
    # Step 1: the roots - the current ones and the usual folders that hold repositories, ticked in a
    # list, or any path typed in.
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

    $labels = [string[]]@($offers | ForEach-Object { '{0} ({1}{2})' -f $_.Path, (Format-PhxInitCount $_.Count), $(if ($_.Current) { ', current' } else { '' }) })
    $defaults = [int[]]@(for ($i = 0; $i -lt $offers.Count; $i++) { if ($offers[$i].Current -or -not $Current.Count) { $i } })
    $help = @(
        "a folder is searched $script:PhxDefaultRootDepth levels deep; phx roots add <path> -Depth <n> (1-10) searches deeper later"
        'folders may not lie inside each other: the repositories in both would be counted twice'
        'the code itself is never copied - a restore clones it again'
    )
    while ($true) {
        $picked = @(Read-PhxChoice -Prompt 'Folders' -Options $labels -Default $defaults -Multi -Other 'another folder - type its path' -TypedHint 'and/or paths' -Help $help -NoEcho)
        try {
            $chosen = [Collections.Generic.List[object]]::new()
            foreach ($token in $picked) {
                if ($token -is [int]) { $chosen.Add($offers[$token]) }
                else {
                    $full = ConvertTo-PhxFullPath $token
                    if (-not [IO.Directory]::Exists($full)) { throw "no such folder: $full" }
                    $full = Get-PhxActualPath $full
                    $known = $offers | Where-Object { [string]::Equals($_.Path, $full, (Get-PhxPathComparison)) } | Select-Object -First 1
                    $chosen.Add($(if ($known) { $known } else { [pscustomobject]@{ Path = $full; Depth = $script:PhxDefaultRootDepth; Count = @(Find-PhxRepository -Root $full -Depth $script:PhxDefaultRootDepth).Count } }))
                }
            }
            if (-not $chosen.Count) { throw 'at least one folder, please' }
            $paths = @()
            foreach ($root in $chosen) { Assert-PhxRootFits -Path $root.Path -Roots $paths; $paths += $root.Path }
            foreach ($root in $chosen) { Write-PhxInitDone "$($root.Path) - $(Format-PhxInitCount $root.Count)" }
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
    $help = @(
        'it must be an account gh is logged in with (gh auth login); phx never switches the active one'
        'suggested: the account set before, else the one the repositories'' own credential helper names, else the active one'
    )
    $logins = @(Get-PhxGhAccount)
    if (-not $logins) {
        Write-Host '  gh is not logged in, or not installed - skipped; run phx init again after gh auth login' -ForegroundColor Yellow
        return $result
    }
    Write-Host "  gh is logged in as: $(($logins | ForEach-Object { "$($_.Login) ($($_.Host))" }) -join ', ')" -ForegroundColor DarkGray
    $owners = @($Records | Where-Object { Get-PhxIdentityOwner $_.identity } |
            Group-Object { Get-PhxIdentityOwner $_.identity } |
            Sort-Object @{ Expression = 'Count'; Descending = $true }, Name)
    $asked = 0
    foreach ($owner in $owners) {
        $hostName = $owner.Name.Split('/')[0]
        $names = @($logins | Where-Object Host -EQ $hostName | ForEach-Object Login)
        if (-not $names) { continue }
        $asked++
        # github.com/WizX20 reads as WizX20; an owner on another host keeps the host's name.
        $shown = if ($hostName -eq 'github.com') { $owner.Name.Substring($hostName.Length + 1) } else { $owner.Name }
        $count = Format-PhxInitCount $owner.Count
        # An account set before stays a choice - the default even - when gh is not logged in with
        # it on this machine: Enter all the way must change nothing.
        $configured = $result[$owner.Name]
        $choices = @($names)
        if ($configured -and $names -notcontains $configured) {
            Write-Host "  $($owner.Name) uses $configured, but gh is not logged in as $configured - gh auth login --hostname $hostName" -ForegroundColor Yellow
            $choices = @($configured) + $names
        }
        if ($choices.Count -eq 1) { $result[$owner.Name] = $choices[0]; Write-PhxInitDone "$shown ($count) - account $($choices[0])"; continue }
        # Default: what is set, else what the repositories' own credential helpers say, else the
        # active account.
        $fromHelpers = @($owner.Group | Where-Object { $_.helperAccount } | Group-Object { $_.helperAccount } | Sort-Object Count -Descending | ForEach-Object Name)
        $active = @($logins | Where-Object { $_.Host -eq $hostName -and $_.Active } | ForEach-Object Login)
        $default = @(@($configured) + $fromHelpers + $active + $names | Where-Object { $_ -and $choices -contains $_ })[0]
        $picked = @(Read-PhxChoice -Prompt "Which account clones the repositories of ${shown}? ($count)" -Options ([string[]]$choices) -Default @([array]::IndexOf($choices, $default)) -Help $help -NoEcho)
        $result[$owner.Name] = $choices[$picked[0]]
        Write-PhxInitDone "$shown ($count) - account $($result[$owner.Name])"
    }
    if (-not $asked) { Write-PhxInitDone 'nothing to ask: no repositories on a host gh is logged in to' }
    $result
}

function Select-PhxInitTarget {
    # Step 4: the folder snapshots go to. A suggested folder that does not exist yet is created when
    # saving; a typed one only after asking when the folder it is in is missing too (a typo?).
    param([System.Collections.IDictionary]$Current)
    $suggestions = @(Get-PhxTargetSuggestion)
    $help = @(
        'a snapshot holds the list of your repositories, their local-only work, selected local files and settings - passwords and tokens encrypted'
        'several machines can share one target: each gets a folder of its own'
        'a folder that does not exist yet is created when saving'
    )
    $offers = [Collections.Generic.List[object]]::new()
    if ($Current.path -and -not @($suggestions | Where-Object { [string]::Equals($_.Path, $Current.path, (Get-PhxPathComparison)) }).Count) {
        $offers.Add([pscustomobject]@{ Path = "$($Current.path)"; Label = 'current' })
    }
    foreach ($suggestion in $suggestions) { $offers.Add($suggestion) }
    $labels = [string[]]@($offers | ForEach-Object { '{0} ({1}{2})' -f $_.Path, $_.Label, $(if (-not [IO.Directory]::Exists($_.Path)) { ', created when saving' } else { '' }) })
    $default = @(for ($i = 0; $i -lt $offers.Count; $i++) { if ([string]::Equals($offers[$i].Path, $Current.path, (Get-PhxPathComparison))) { $i } })
    if (-not $default.Count -and $offers.Count) { $default = @(0) }
    while ($true) {
        $picked = @(Read-PhxChoice -Prompt 'Target' -Options $labels -Default ([int[]]$default) -Other 'another folder - type its path' -TypedHint 'or a path' -Help $help -NoEcho)
        $typed = $picked[0] -isnot [int]
        $path = if ($typed) { Get-PhxActualPath (ConvertTo-PhxFullPath $picked[0]) } else { $offers[$picked[0]].Path }
        if ([IO.File]::Exists($path)) { Write-Host "  $path is a file" -ForegroundColor Yellow; continue }
        $new = -not [IO.Directory]::Exists($path)
        if ($typed -and $new -and -not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($path)) -and
            -not (Read-PhxInitYesNo -Prompt "  neither $path nor the folder it is in exists - create both when saving?" -Default $false)) { continue }
        Write-PhxInitDone "$path$(if ($new) { ' (new - created when saving)' })"
        # On a work machine - one with OneDrive for Business - company data stays in company storage.
        if (@($suggestions | Where-Object Business).Count -and (Test-PhxPersonalCloudPath $path)) {
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
    $help = @(
        'letters, digits, dot, dash and underscore'
        'a folder another installation wrote (this machine before a reinstall) is not taken: a restore needs its snapshot'
    )
    $id = if ($Current -and $Current.id) { "$($Current.id)" } else { [guid]::NewGuid().ToString() }
    $default = if ($Current -and $Current.name) { "$($Current.name)" } else { [Environment]::MachineName }
    while ($true) {
        $name = Read-PhxInitAnswer -Prompt '  Name' -Default $default -Help $help
        if (-not (Test-PhxMachineName $name)) { Write-Host '  letters, digits, dot, dash and underscore, please' -ForegroundColor Yellow; continue }
        $problem = Get-PhxSnapshotProblem -Path (Join-PhxPath $TargetPath $name) -Id $id
        if ($problem) {
            Write-Host "  $problem" -ForegroundColor Yellow
            for ($n = 2; [IO.Directory]::Exists((Join-PhxPath $TargetPath "$name-$n")); $n++) { }
            $default = "$name-$n"
            continue
        }
        Write-PhxInitDone "$name - snapshots in $(Join-PhxPath $TargetPath $name)"
        return [ordered]@{ name = $name; id = $id }
    }
}

function Test-PhxPassphrase {
    # Long enough to guard a key copy in a synced folder: four different words of three letters or
    # more, 15 letters in all - not "ab cd ef gh" - or 20 characters, eight of them different.
    param([string]$Text)
    $words = @($Text -split '[\s\-_.,;:]+' | Where-Object { $_.Length -ge 3 } | Sort-Object -Unique)
    $wordy = $words.Count -ge 4 -and ($words -join '').Length -ge 15
    $long = $Text.Length -ge 20 -and @($Text.ToCharArray() | Sort-Object -Unique -CaseSensitive).Count -ge 8
    $wordy -or $long
}

function Select-PhxInitSecret {
    # Step 6: the age key secrets are encrypted to (docs/design.md -> Secrets). The current one is
    # kept on Enter. A new one gets a passphrase-protected copy in the target, unless declined, and
    # its secret half is shown once after saving. Or the recipient of a key the user already has.
    param([string]$Current)
    if ($Current) {
        Write-Host "  current key: $Current"
        if (Read-PhxInitYesNo -Prompt '  Keep it?') {
            Write-PhxInitDone 'the current key'
            return [pscustomobject]@{ Recipient = $Current; Identity = $null; Passphrase = $null; Source = 'current' }
        }
        Write-Host '  note: the next run encrypts every secret to the new key; older versions in the target stay encrypted to the current one - keep it as well' -ForegroundColor DarkYellow
    }
    while ($true) {
        $answer = Read-PhxInitAnswer -Prompt '  Enter for a new key, or the age1... recipient of a key you have'
        if (-not $answer) { break }
        if ([PSPhoenix.Engine.Age]::IsRecipient($answer)) {
            Write-PhxInitDone "your key $(Format-PhxRecipient $answer)"
            return [pscustomobject]@{ Recipient = $answer; Identity = $null; Passphrase = $null; Source = 'yours' }
        }
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
    Write-PhxInitDone "a new key, $(if ($passphrase) { 'a passphrase-protected copy in the target' } else { 'no copy in the target' }) - shown once after saving"
    [pscustomobject]@{ Recipient = $key.Recipient; Identity = $key.Identity; Passphrase = $passphrase; Source = 'new' }
}

function Select-PhxInitInterval {
    # Step 7: how often the background run goes.
    param([string]$Current)
    $values = [Collections.Generic.List[string]]@('15m', '30m', '1h', '4h', '1d')
    if ($Current -and $values -notcontains $Current) { $values.Add($Current) }
    $labels = [string[]]@($values | ForEach-Object { if ($_ -eq '1h') { '1h (recommended)' } else { $_ } })
    $default = $values.IndexOf($(if ($Current) { $Current } else { '1h' }))
    while ($true) {
        $picked = @(Read-PhxChoice -Prompt 'Interval' -Options $labels -Default @($default) -Other 'another interval - type it (45m, 2h, 7d)' -TypedHint 'or an interval like 2h' -Help 'from 15 minutes (15m) to 31 days (31d)' -NoEcho)
        $answer = if ($picked[0] -is [int]) { $values[$picked[0]] } else { $picked[0] }
        if (Test-PhxInterval $answer) { Write-PhxInitDone "every $answer"; return $answer }
        Write-Host '  like 30m, 1h or 1d - from 15m to 31d' -ForegroundColor Yellow
    }
}

function Invoke-PhxInitReview {
    # The step after saving: the gitignored files to decide on (phx review), when there are any.
    # A failure here leaves the saved set-up as it is: phx review tries again.
    Write-PhxInitHeading 'Gitignored files - which local files to back up' 'a file nobody decided on is not backed up; Enter skips, phx review does it later'
    try { Invoke-PhxReview -Ask }
    catch [OperationCanceledException] { Write-Host '  review stopped - phx review goes on later' -ForegroundColor Yellow }
    catch { Write-Host "  review: $($_.Exception.Message) - phx review tries again" -ForegroundColor Yellow }
}

function Invoke-PhxInit {
    $configPath = Get-PhxConfigPath
    $config = Read-PhxConfig
    $verb = if ([IO.File]::Exists($configPath)) { 'changing' } else { 'setting up' }
    # The schedule step only where phx schedule works (Windows, for now).
    $canSchedule = Test-PhxCanSchedule
    $script:PhxInitStep.At = 0
    $script:PhxInitStep.Of = if ($canSchedule) { 8 } else { 7 }
    Write-Host "phx init - $verb PSPhoenix in $($script:PhxInitStep.Of) steps. Enter takes what is suggested, ? explains a question, q stops without saving." -ForegroundColor Green
    try {
        Write-PhxInitStep 'Repositories' 'Where do you keep your git repositories?' 'phx notes every repository there - its remotes, account and local-only work - so a new machine can clone them all again'
        $roots = Select-PhxInitRoot -Current @($config.roots | Where-Object { $_ })
        Write-PhxInitStep 'Discovery' 'Reading the repositories in those folders.'
        $records = @(Invoke-PhxScan -Roots $roots -NoSave -PassThru -Brief)
        Write-PhxInitDone (Format-PhxRepoCount $records)
        Write-PhxInitStep 'Accounts' 'Which GitHub account should clone the repositories of each owner?' 'a restore clones with it, so a new machine needs only gh auth login with the same accounts'
        $accounts = Select-PhxInitAccount -Records $records -Current $config.accounts
        Write-PhxInitStep 'Target' 'Where should the snapshots go?' 'a folder that outlives this machine: a synced folder (OneDrive, Dropbox), a NAS share or a USB disk'
        $target = Select-PhxInitTarget -Current $config.target
        Write-PhxInitStep 'Machine' 'What should this machine be called in the target?' 'its snapshots go in a folder of that name, so several machines can share one target'
        $machine = Select-PhxInitMachine -TargetPath $target.path -Current $config.machine
        Write-PhxInitStep 'Secrets' 'Which key should passwords and tokens in your files be encrypted to?' 'an age key: the background run needs only its public half; the secret half stays with you and opens them on a new machine'
        $secret = Select-PhxInitSecret -Current $config.secrets.recipient
        Write-PhxInitStep 'Interval' 'How often should phx back up?' 'a run backs up only what no remote has - never the code; with nothing changed it takes seconds and writes nothing'
        $interval = Select-PhxInitInterval -Current $config.interval
        # Step 8: the background run. The default is what is so now - on for a first init - so Enter
        # all the way changes nothing.
        $schedule = $false
        $registered = $null
        if ($canSchedule) {
            $registered = Get-PhxScheduledTask
            $default = if ([IO.File]::Exists($configPath)) { [bool]$registered } else { $true }
            Write-PhxInitStep 'Schedule' 'Back up in the background?' "a Task Scheduler task runs phx hidden, at below-normal priority, 5 minutes after logon and every $interval; phx schedule off stops it"
            $schedule = Read-PhxInitYesNo -Prompt '  In the background?' -Default $default
            Write-PhxInitDone $(if ($schedule) { "in the background, every $interval" } else { 'not in the background - phx run backs up by hand, phx schedule on turns it on later' })
        }

        Write-PhxInitHeading 'Summary'
        foreach ($root in $roots) { Write-Host "  root      $($root.path)   depth $($root.depth)" }
        foreach ($owner in $accounts.Keys) { Write-Host "  account   $owner -> $($accounts[$owner])" }
        Write-Host "  target    $($target.path)$(if (-not [IO.Directory]::Exists($target.path)) { '   (new)' })"
        Write-Host "  machine   $($machine.name)   snapshot in $(Join-PhxPath $target.path $machine.name)"
        $keyNote = switch ($secret.Source) {
            'current' { 'the current key' }
            'yours' { 'your key' }
            default { if ($secret.Passphrase) { "a new key, its passphrase copy $(Split-Path -Leaf (Get-PhxKeyCopyPath -Config @{ target = $target; machine = $machine } -Recipient $secret.Recipient)) in the snapshot" } else { 'a new key, no copy in the snapshot' } }
        }
        Write-Host "  secrets   $(Format-PhxRecipient $secret.Recipient)   $keyNote"
        Write-Host "  interval  $interval"
        if ($canSchedule) { Write-Host "  schedule  $(if ($schedule) { 'on' } else { 'off - phx schedule on later' })" }
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
    $enabled = $false
    try {
        Save-PhxRepoCache -Roots $roots -Records $records
        if ($schedule) {
            # Registered already, as it should be (the same interval, this module): left alone.
            if (-not $registered -or @(Get-PhxScheduleProblem -Task $registered -Config $config).Count) { Enable-PhxSchedule; $enabled = $true }
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
    # When the first backup comes: the task's first run, its next one, or none until phx run.
    $first = if ($enabled) { "the first background run starts within a minute, then every $interval" }
    elseif ($schedule -and $registered.NextRunTime) { "the next background run is at $($registered.NextRunTime.ToString('HH:mm'))" }
    elseif ($schedule) { "the background run goes every $interval" }
    else { 'nothing runs in the background' }
    Write-Host "next: $first - phx run backs up now, phx status shows how it went" -ForegroundColor Green
}
