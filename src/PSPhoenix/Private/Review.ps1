# phx review (docs/design.md -> Gitignored files: filters and review): the gitignored files nobody
# decided on yet, per repository, and the answer for each - include, secret, exclude, or not a
# secret after all. Measured on a first machine: ~700 candidates of which ~60 matter, so a whole
# folder or a pattern is decided at once. Every answer is saved in the config straight away; q stops,
# keeping what was decided. phx init ends with it.

function Format-PhxSize {
    # 512 B, 1.2 KB, 3.4 MB.
    param([long]$Bytes)
    if ($Bytes -lt 1024) { return "$Bytes B" }
    if ($Bytes -lt 1MB) { return '{0:0.#} KB' -f ($Bytes / 1KB) }
    '{0:0.#} MB' -f ($Bytes / 1MB)
}

function Get-PhxReviewEntry {
    # The pending files as the review lists them: grouped by their first folder below $Prefix, a
    # folder of one file shown as that file, and an opened folder ($Open) as what is in it.
    # Each entry: { Path, Folder, Files, Size } - a folder's Path ends in /.
    param([object[]]$Files = @(), [string[]]$Open = @(), [string]$Prefix = '')
    $groups = $Files | Group-Object { ($_.Path.Substring($Prefix.Length) -split '/')[0] } | Sort-Object { $_.Name } -Culture ([cultureinfo]::InvariantCulture)
    foreach ($group in $groups) {
        $folder = "$Prefix$($group.Name)/"
        $inFolder = @($group.Group | Where-Object { $_.Path.StartsWith($folder, [StringComparison]::Ordinal) })
        if (-not $inFolder.Count -or $group.Count -eq 1) {
            foreach ($file in $group.Group) { [pscustomobject]@{ Path = $file.Path; Folder = $false; Files = @($file); Size = $file.Size } }
        }
        elseif ($Open -contains $folder) { Get-PhxReviewEntry -Files $group.Group -Open $Open -Prefix $folder }
        else {
            [pscustomobject]@{ Path = $folder; Folder = $true; Files = @($group.Group); Size = [long]($group.Group | Measure-Object Size -Sum).Sum }
        }
    }
}

function Get-PhxReviewNote {
    # What the review says about an entry: its size, and why it is secret - by its name, or by what
    # is in it (the kind and the line, never the value).
    param([Parameter(Mandatory)]$Entry)
    if ($Entry.Folder) {
        $secret = @($Entry.Files | Where-Object { $_.SecretName -or @($_.Findings | Where-Object { $_ }).Count }).Count
        $text = "$($Entry.Files.Count) files, $(Format-PhxSize $Entry.Size)"
        if ($secret) { $text += ", $secret secret" }
        return $text
    }
    $file = $Entry.Files[0]
    $text = Format-PhxSize $file.Size
    if ($file.SecretName) { return "$text   secret by its name - stored encrypted" }
    $finding = @($file.Findings)[0]
    if ($finding) { return "$text   holds $($finding.Description) on line $($finding.Line) - stored encrypted; n if it is none" }
    $text
}

function ConvertTo-PhxReviewPattern {
    # The pattern a decision on an entry stores: its path from the repository's top - /notes.md,
    # /leftover/ - so it does not also match a file of that name deeper down.
    param([Parameter(Mandatory)]$Entry)
    "/$($Entry.Path)"
}

function Get-PhxReviewSelection {
    # The entries an answer names: numbers and ranges (1,3-5), or * for all. Throws on a number not
    # in the list.
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][object[]]$Entries)
    if ($Text.Trim() -eq '*') { return $Entries }
    foreach ($part in @($Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        if ($part -notmatch '^(?<from>\d+)(?:\s*-\s*(?<to>\d+))?$') { throw "'$part' is not a number or a range" }
        $from = [int]$Matches.from
        $to = if ($Matches.to) { [int]$Matches.to } else { $from }
        if ($from -lt 1 -or $to -gt $Entries.Count -or $from -gt $to) { throw "there is no $part in the list (1-$($Entries.Count))" }
        for ($i = $from; $i -le $to; $i++) { $Entries[$i - 1] }
    }
}

function Get-PhxRepoDecision {
    # The review's decisions for one repository in the config, made when there are none yet.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config, [Parameter(Mandatory)][string]$Identity)
    if ($Config.files.repos -isnot [System.Collections.IDictionary]) { $Config.files.repos = [ordered]@{} }
    if ($Config.files.repos[$Identity] -isnot [System.Collections.IDictionary]) { $Config.files.repos[$Identity] = [ordered]@{} }
    $Config.files.repos[$Identity]
}

function Add-PhxReviewDecision {
    # Adds patterns to one of a repository's lists (include, secret, exclude); the same pattern
    # leaves the other two - a new answer replaces an old one.
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)][ValidateSet('include', 'secret', 'exclude')][string]$List,
        [Parameter(Mandatory)][string[]]$Patterns
    )
    $decisions = Get-PhxRepoDecision -Config $Config -Identity $Identity
    foreach ($name in 'include', 'secret', 'exclude') {
        $current = @($decisions[$name] | Where-Object { $_ })
        # A list even of one: the config holds arrays.
        $decisions[$name] = [string[]]$(if ($name -eq $List) { @($current + @($Patterns | Where-Object { $current -notcontains $_ })) }
            else { @($current | Where-Object { $Patterns -notcontains $_ }) })
        if (-not @($decisions[$name] | Where-Object { $_ }).Count) { $decisions.Remove($name) }
    }
}

function Set-PhxReviewPlain {
    # "Not a secret": the file is backed up as it is, the findings the review saw in it accepted.
    # Another kind of secret in it later, or one under another key, makes it secret again.
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string[]]$Signatures
    )
    $decisions = Get-PhxRepoDecision -Config $Config -Identity $Identity
    if ($decisions.plain -isnot [System.Collections.IDictionary]) { $decisions.plain = [ordered]@{} }
    $decisions.plain[$Pattern] = [string[]]@($Signatures | Select-Object -Unique)
    foreach ($name in 'secret', 'exclude') {
        if ($decisions.Contains($name)) {
            $decisions[$name] = [string[]]@($decisions[$name] | Where-Object { $_ -ne $Pattern })
            if (-not @($decisions[$name] | Where-Object { $_ }).Count) { $decisions.Remove($name) }
        }
    }
}

function Invoke-PhxReviewAnswer {
    # Applies one answer to a repository's decisions in $Config; returns what it did, as a line.
    # Throws when the answer is not one.
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)][string]$Answer,
        [Parameter(Mandatory)][object[]]$Entries,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[string]]$Open
    )
    if ($Answer -notmatch '^(?<verb>[isxno])\s+(?<what>.+)$') { throw 'an answer is a letter and what it is for: i 1,3 - s 2 - x 4-6 - x *.log - o 5 - n 2 - or ? for help' }
    $verb = $Matches.verb
    $what = $Matches.what.Trim()
    $byNumber = $what -eq '*' -or $what -match '^[\d\s,-]+$'
    if (-not $byNumber) {
        if ($verb -in 'o', 'n') { throw "$verb takes numbers from the list" }
        $parsed = $null
        $why = $null
        if (-not [PSPhoenix.Engine.PathPattern]::TryParse($what, [ref]$parsed, [ref]$why)) { throw "'$what' is not a path pattern: $why" }
        $list = @{ i = 'include'; s = 'secret'; x = 'exclude' }[$verb]
        Add-PhxReviewDecision -Config $Config -Identity $Identity -List $list -Patterns $what
        return "${list}: $what"
    }
    $chosen = @(Get-PhxReviewSelection -Text $what -Entries $Entries)
    switch ($verb) {
        'o' {
            $folders = @($chosen | Where-Object Folder)
            if ($folders.Count -ne $chosen.Count) { throw 'o opens a folder - the entries ending in /' }
            foreach ($entry in $folders) { if (-not $Open.Contains($entry.Path)) { $Open.Add($entry.Path) } }
            return "opened: $(($folders.Path) -join ', ')"
        }
        'n' {
            $files = @($chosen | Where-Object { -not $_.Folder -and -not $_.Files[0].SecretName -and @($_.Files[0].Findings | Where-Object { $_ }).Count })
            if ($files.Count -ne $chosen.Count) { throw 'n is for a file whose content looks like a secret but is none - a folder, or a file secret by its name, needs i, s or x' }
            foreach ($entry in $files) {
                Set-PhxReviewPlain -Config $Config -Identity $Identity -Pattern (ConvertTo-PhxReviewPattern $entry) -Signatures @($entry.Files[0].Findings | ForEach-Object Signature)
            }
            return "not a secret, backed up as it is: $(($files | ForEach-Object { ConvertTo-PhxReviewPattern $_ }) -join ', ')"
        }
        default {
            $list = @{ i = 'include'; s = 'secret'; x = 'exclude' }[$verb]
            $patterns = [string[]]@($chosen | ForEach-Object { ConvertTo-PhxReviewPattern $_ })
            Add-PhxReviewDecision -Config $Config -Identity $Identity -List $list -Patterns $patterns
            "${list}: $($patterns -join ', ')"
        }
    }
}

function Show-PhxReviewHelp {
    Write-Host '  i <numbers>  include: back it up (encrypted when it holds a secret)' -ForegroundColor DarkGray
    Write-Host '  s <numbers>  secret: back it up, always encrypted' -ForegroundColor DarkGray
    Write-Host '  x <numbers>  exclude: never back it up' -ForegroundColor DarkGray
    Write-Host '  n <numbers>  not a secret: what looks like one in it is none - back it up as it is' -ForegroundColor DarkGray
    Write-Host '  o <numbers>  open a folder, to decide on what is in it' -ForegroundColor DarkGray
    Write-Host '  numbers: 3, 1,4, 2-6, or * for all; i, s and x also take a pattern: x *.log, i src/**/local.json, x tmp/' -ForegroundColor DarkGray
    Write-Host '  Enter: next repository (the rest stays pending); q: stop' -ForegroundColor DarkGray
}

function Get-PhxReviewRepository {
    # Every scanned repository that can be read now, with its gitignored files through the built-in
    # filters: { Record, Key, List }. A repository git cannot list is passed over, with a warning.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    $cache = Read-PhxRepoCache
    if (-not $cache) { throw 'no scan yet - phx scan' }
    foreach ($record in @(Get-PhxScannedRecord -Cache $cache -Config $Config | Sort-Object { Get-PhxRepoKey $_ })) {
        $key = Get-PhxRepoKey $record
        if ($record.offline -or -not [IO.Directory]::Exists((Join-Path $key '.git'))) { continue }
        $own = if ($Config.files.repos -is [System.Collections.IDictionary]) { $Config.files.repos[$record.identity] }
        try { $list = Get-PhxIgnoredFile -Path $key -MaxBytes (Get-PhxMaxFileBytes $Config) -SecretPatterns ([string[]]@($own.secret | Where-Object { $_ })) }
        catch { Write-Host "  could not list the gitignored files of ${key}: $(Hide-PhxSecret $_.Exception.Message)" -ForegroundColor Yellow; continue }
        [pscustomobject]@{ Record = $record; Key = $key; List = $list }
    }
}

function Get-PhxReviewPending {
    # A repository's pending files under the config's current decisions, each with what the secret
    # scan finds in it (the review shows it; never the value).
    param([Parameter(Mandatory)]$Repository, [Parameter(Mandatory)][System.Collections.IDictionary]$Config, [hashtable]$Scans = @{})
    $candidates = Get-PhxRepoFileCandidate -Record $Repository.Record -Config $Config -List $Repository.List
    foreach ($file in @($candidates.Files | Where-Object Decision -EQ 'Pending')) {
        if (-not $Scans.ContainsKey($file.Path)) {
            # Assigned, never output: an empty list must stay one, not become nothing.
            $found = [object[]]@()
            if (-not $file.SecretName) {
                try { $found = [object[]]@([PSPhoenix.Engine.SecretScanner]::ScanFile([IO.Path]::GetFullPath((Join-Path $Repository.Key $file.Path))).Findings) }
                catch { $null = $_ }
            }
            $Scans[$file.Path] = $found
        }
        $file | Add-Member -NotePropertyName Findings -NotePropertyValue $Scans[$file.Path] -PassThru
    }
}

function Invoke-PhxReview {
    # phx review: per repository its pending files, and an answer at a time until none is left,
    # Enter moves on or q stops. With -Ask (phx init) it asks first whether to review at all.
    # Afterwards the state's pending list (phx status) is what is left.
    param([switch]$Ask)
    if (-not [IO.File]::Exists((Get-PhxConfigPath))) { throw 'not set up yet - run: phx init' }
    $config = Read-PhxConfig
    $repositories = @(Get-PhxReviewRepository -Config $config)
    $work = @(foreach ($repository in $repositories) {
            $scans = @{}
            [pscustomobject]@{ Repository = $repository; Scans = $scans; Pending = @(Get-PhxReviewPending -Repository $repository -Config $config -Scans $scans) }
        })
    $total = [int]($work | ForEach-Object { $_.Pending.Count } | Measure-Object -Sum).Sum
    $withPending = @($work | Where-Object { $_.Pending.Count })
    if (-not $total) {
        Write-Host 'every gitignored file is decided on - nothing to review' -ForegroundColor Green
        Save-PhxRepoFilesPending -Pending @()
        return
    }
    Write-Host "$total gitignored file(s) in $($withPending.Count) repositories wait for a decision; until then they are not backed up" -ForegroundColor Cyan
    if ($Ask) {
        $now = try { Read-PhxInitYesNo -Prompt '  Review them now? (later: phx review)' } catch [OperationCanceledException] { $false }
        if (-not $now) { return }
    }
    Show-PhxReviewHelp
    $stopped = $false
    foreach ($item in $withPending) {
        if ($stopped) { break }
        $repository = $item.Repository
        $open = [Collections.Generic.List[string]]::new()
        while ($true) {
            $pending = @(Get-PhxReviewPending -Repository $repository -Config $config -Scans $item.Scans)
            $item.Pending = $pending
            if (-not $pending.Count) { Write-Host '  all decided' -ForegroundColor Green; break }
            $entries = @(Get-PhxReviewEntry -Files $pending -Open @($open))
            Write-Host
            Write-Host "$($repository.Record.identity)   $($repository.Key)   $($pending.Count) pending" -ForegroundColor Cyan
            for ($i = 0; $i -lt $entries.Count; $i++) {
                Write-Host ('  {0,3}. {1,-44} {2}' -f ($i + 1), $entries[$i].Path, (Get-PhxReviewNote $entries[$i]))
            }
            $answer = Read-PhxAnswer -Prompt '  Decide (? for help)'
            if (-not $answer) { break }
            if ($answer -eq 'q') { $stopped = $true; break }
            if ($answer -in '?', 'h', 'help') { Show-PhxReviewHelp; continue }
            try { $done = Invoke-PhxReviewAnswer -Config $config -Identity $repository.Record.identity -Answer $answer -Entries $entries -Open $open }
            catch { Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow; continue }
            if ($answer -notmatch '^o\s') {
                # Saved at once: what is decided stays decided, whatever comes next.
                Save-PhxConfig $config
            }
            Write-Host "  $done" -ForegroundColor Green
        }
    }
    $left = @($work | Where-Object { $_.Pending.Count })
    Save-PhxRepoFilesPending -Pending @($left | ForEach-Object {
            [ordered]@{
                identity = $_.Repository.Record.identity
                path     = $_.Repository.Key
                files    = @($_.Pending | ForEach-Object { [ordered]@{ path = $_.Path; size = $_.Size; secret = $_.SecretName } })
            }
        })
    $count = [int]($left | ForEach-Object { $_.Pending.Count } | Measure-Object -Sum).Sum
    if ($count) { Write-Host "$count file(s) still pending - phx review again any time; the next phx run backs up what you decided" -ForegroundColor Yellow }
    else { Write-Host 'every gitignored file is decided on - the next phx run backs up what you decided' -ForegroundColor Green }
}
