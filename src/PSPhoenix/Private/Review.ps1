# phx review (docs/design.md -> Gitignored files: filters and review): the gitignored files nobody
# decided on yet, per repository, and the answer for each - include, secret, exclude, or not a
# secret after all. Measured on a first machine: ~700 candidates of which ~60 matter, so a whole
# folder or a pattern is decided at once, a file found in several repositories once for all of
# them, and one key accepts the rest as proposed. On a console it is a list with check boxes;
# elsewhere typed answers. Every answer is saved in the config straight away; q stops, keeping
# what was decided. phx init ends with it.

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
    # is in it (the kind and the line, never the value). A file found in several repositories says
    # in how many.
    param([Parameter(Mandatory)]$Entry)
    if ($Entry.PSObject.Properties['Repositories']) {
        $file = @($Entry.Files | Where-Object { $_.SecretName -or @($_.Findings | Where-Object { $_ }).Count })[0]
        $text = "in $($Entry.Repositories) repositories"
        if ($file.SecretName) { return "$text   secret by its name - stored encrypted" }
        $finding = @($file.Findings)[0]
        if ($finding) { return "$text   holds $($finding.Description) in one - stored encrypted" }
        return $text
    }
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
    # Adds patterns to one of a repository's lists (include, secret, exclude) - or, with no
    # identity, to the lists for every repository (files.include, files.secret, files.exclude); the
    # same pattern leaves the other two - a new answer replaces an old one.
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Identity,
        [Parameter(Mandatory)][ValidateSet('include', 'secret', 'exclude')][string]$List,
        [Parameter(Mandatory)][string[]]$Patterns
    )
    $decisions = if ($Identity) { Get-PhxRepoDecision -Config $Config -Identity $Identity } else { $Config.files }
    foreach ($name in 'include', 'secret', 'exclude') {
        $current = @($decisions[$name] | Where-Object { $_ })
        # A list even of one: the config holds arrays.
        $decisions[$name] = [string[]]$(if ($name -eq $List) { @($current + @($Patterns | Where-Object { $current -notcontains $_ })) }
            else { @($current | Where-Object { $Patterns -notcontains $_ }) })
        # files.include and the rest stay, empty; a repository's empty lists go.
        if ($Identity -and -not @($decisions[$name] | Where-Object { $_ }).Count) { $decisions.Remove($name) }
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
        # Empty: a decision for every repository.
        [Parameter(Mandatory)][AllowEmptyString()][string]$Identity,
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
    if ($verb -eq 'n' -and -not $Identity) { throw "n is decided per repository - the file's own repository lists it next" }
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
    Write-Host '  a: accept the rest as proposed; Enter: next repository (the rest stays pending); q: stop' -ForegroundColor DarkGray
}

function Get-PhxReviewRepository {
    # Every scanned repository that can be read now, with its gitignored files through the built-in
    # filters: { Record, Key, List }. A repository git cannot list is passed over, with a warning.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    $cache = Read-PhxRepoCache
    if (-not $cache) { throw 'no scan yet - phx scan' }
    foreach ($record in @(Get-PhxScannedRecord -Cache $cache -Config $Config | Sort-Object { Get-PhxRepoKey $_ })) {
        $key = Get-PhxRepoKey $record
        if ($record.offline -or -not [IO.Directory]::Exists((Join-PhxPath $key '.git'))) { continue }
        $own = if ($Config.files.repos -is [System.Collections.IDictionary]) { $Config.files.repos[$record.identity] }
        try { $list = Get-PhxIgnoredFile -Path $key -MaxBytes (Get-PhxMaxFileBytes $Config) -SecretPatterns ([string[]]@($own.secret | Where-Object { $_ })) -Rules (Get-PhxRepoFileRule -Config $Config -Identity $record.identity) }
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
                try { $found = [object[]]@([PSPhoenix.Engine.SecretScanner]::ScanFile([IO.Path]::GetFullPath((Join-PhxPath $Repository.Key $file.Path))).Findings) }
                catch { $null = $_ }
            }
            $Scans[$file.Path] = $found
        }
        $file | Add-Member -NotePropertyName Findings -NotePropertyValue $Scans[$file.Path] -PassThru
    }
}

function Get-PhxReviewKind {
    # The pending files found under the same path in more than one repository - .env in 9 of them -
    # as entries the review decides on once for all: { Path, Folder, Files, Size, Repositories },
    # the most widespread first.
    param([object[]]$Work = @())
    $files = @(foreach ($item in $Work) { foreach ($file in @($item.Pending)) { [pscustomobject]@{ Key = $item.Repository.Key; File = $file } } })
    $kinds = foreach ($group in @($files | Group-Object { $_.File.Path })) {
        $repositories = @($group.Group.Key | Select-Object -Unique).Count
        if ($repositories -lt 2) { continue }
        [pscustomobject]@{ Path = $group.Name; Folder = $false; Files = @($group.Group.File); Size = [long]($group.Group.File | Measure-Object Size -Sum).Sum; Repositories = $repositories }
    }
    @($kinds | Sort-Object @{ Expression = 'Repositories'; Descending = $true }, @{ Expression = { $_.Path } })
}

function Get-PhxReviewProposal {
    # What the review proposes for an entry, until a decision of #89 does it for it: a file is
    # included - secret when its name or content says so; a folder of several files, unknown, is
    # left out. Returns { Include, Secret }.
    param([Parameter(Mandatory)]$Entry)
    $secret = @($Entry.Files | Where-Object { $_.SecretName -or @($_.Findings | Where-Object { $_ }).Count }).Count -gt 0
    [pscustomobject]@{ Include = -not $Entry.Folder; Secret = $secret -and -not $Entry.Folder }
}

function New-PhxReviewRow {
    # One row of the review's list: the entry, and the decision on it - the proposal until changed.
    # Locked: secret by its name, so secret it stays.
    param([Parameter(Mandatory)]$Entry)
    $proposal = Get-PhxReviewProposal $Entry
    [pscustomobject]@{
        Entry   = $Entry
        Include = $proposal.Include
        Secret  = $proposal.Secret
        Locked  = -not $Entry.Folder -and @($Entry.Files | Where-Object { -not $_.SecretName }).Count -eq 0
    }
}

function Save-PhxReviewRow {
    # The decisions on a list's rows into $Config (not saved): excluded, secret (always encrypted),
    # included - and a file whose content looked like a secret, included without the secret mark,
    # is "not a secret" (per repository only). Returns what it did, as a line.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config, [Parameter(Mandatory)][AllowEmptyString()][string]$Identity, [object[]]$Rows = @())
    $lists = @{ include = [Collections.Generic.List[string]]::new(); secret = [Collections.Generic.List[string]]::new(); exclude = [Collections.Generic.List[string]]::new() }
    $plain = 0
    foreach ($row in $Rows) {
        $pattern = ConvertTo-PhxReviewPattern $row.Entry
        $findings = @($row.Entry.Files | ForEach-Object { @($_.Findings) } | Where-Object { $_ })
        if (-not $row.Include) { $lists.exclude.Add($pattern) }
        elseif ($row.Secret) { $lists.secret.Add($pattern) }
        elseif ($Identity -and -not $row.Entry.Folder -and $findings.Count) {
            Set-PhxReviewPlain -Config $Config -Identity $Identity -Pattern $pattern -Signatures @($findings | ForEach-Object Signature)
            $plain++
        }
        else { $lists.include.Add($pattern) }
    }
    foreach ($name in 'include', 'secret', 'exclude') {
        if ($lists[$name].Count) { Add-PhxReviewDecision -Config $Config -Identity $Identity -List $name -Patterns $lists[$name].ToArray() }
    }
    $parts = @(
        if ($lists.include.Count + $plain) { "$($lists.include.Count + $plain) included" }
        if ($lists.secret.Count) { "$($lists.secret.Count) secret" }
        if ($lists.exclude.Count) { "$($lists.exclude.Count) excluded" }
    )
    if ($parts.Count) { $parts -join ', ' } else { 'nothing decided' }
}

function Get-PhxReviewVisible {
    # The rows a list shows: those whose path holds the filter, ignoring case - all without one.
    param([Parameter(Mandatory)]$State)
    if (-not $State.Filter) { return @($State.Rows) }
    @($State.Rows | Where-Object { $_.Entry.Path.IndexOf($State.Filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
}

function Step-PhxReview {
    # One key on the review's list: moves the cursor, changes the decision on a row, opens a folder,
    # or ends the list. Returns what the key did: move, toggle, open, filter, save, rest, skip,
    # stop or none.
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][ConsoleKeyInfo]$Key)
    $visible = @(Get-PhxReviewVisible $State)
    $count = $visible.Count
    if ($Key.KeyChar -eq '/') { return 'filter' }
    switch ($Key.Key) {
        'Enter' { return 'save' }
        'A' { return 'rest' }
        'Escape' { return 'skip' }
        'Q' { return 'stop' }
    }
    if (-not $count) { return 'none' }
    if ($State.Index -ge $count) { $State.Index = $count - 1 }
    $row = $visible[$State.Index]
    switch ($Key.Key) {
        { $_ -in 'UpArrow', 'K' } { $State.Index = ($State.Index - 1 + $count) % $count; return 'move' }
        { $_ -in 'DownArrow', 'J', 'Tab' } { $State.Index = ($State.Index + 1) % $count; return 'move' }
        'Home' { $State.Index = 0; return 'move' }
        'End' { $State.Index = $count - 1; return 'move' }
        'Spacebar' { $row.Include = -not $row.Include; return 'toggle' }
        'S' {
            if ($row.Locked) { return 'none' }
            $row.Secret = -not $row.Secret
            # Secret means backed up, encrypted.
            if ($row.Secret) { $row.Include = $true }
            return 'toggle'
        }
        'RightArrow' {
            if (-not $row.Entry.Folder -or -not $State.CanOpen) { return 'none' }
            # The folder gives way to what is in it, each taking the folder's include.
            $children = @(Get-PhxReviewEntry -Files $row.Entry.Files -Prefix $row.Entry.Path | ForEach-Object {
                    $child = New-PhxReviewRow $_
                    $child.Include = $row.Include
                    $child
                })
            $at = $State.Rows.IndexOf($row)
            $State.Rows.RemoveAt($at)
            $State.Rows.InsertRange($at, [object[]]$children)
            return 'open'
        }
    }
    'none'
}

function Format-PhxReviewRow {
    # One row of the review's list as shown: cursor, tick box, the decision, path and note - cut to
    # the width, so a row never wraps (a redraw counts rows).
    param([Parameter(Mandatory)]$Row, [switch]$Current, [int]$Width = 120)
    $cursor = if ($Current) { '>' } else { ' ' }
    $box = if ($Row.Include) { '[x]' } else { '[ ]' }
    $what = if (-not $Row.Include) { 'exclude' } elseif ($Row.Secret) { 'secret' } else { 'include' }
    $text = '  {0} {1} {2,-8} {3,-40} {4}' -f $cursor, $box, $what, $Row.Entry.Path, (Get-PhxReviewNote $Row.Entry)
    $text = $text.TrimEnd()
    if ($text.Length -ge $Width) { $text = $text.Substring(0, [Math]::Max(1, $Width - 4)) + '...' }
    $text
}

function Read-PhxReviewList {
    # The review's list on a console: drawn, and redrawn in place on every key - as many rows as fit,
    # scrolling with the cursor. Returns how it ended: save, rest, skip or stop; the decisions are in
    # $State.Rows.
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)]$State)
    $width = try { [Console]::WindowWidth } catch { 0 }
    if ($width -lt 20) { $width = 120 }
    $height = try { [Console]::WindowHeight } catch { 0 }
    $room = if ($height -lt 12) { 20 } else { $height - 6 }
    $open = if ($State.CanOpen) { ', right opens a folder' } else { '' }
    Write-Host
    Write-Host $Title -ForegroundColor Cyan
    Write-Host "  space includes or excludes, s marks secret$open, / filters; Enter saves and goes on, a accepts the rest as proposed, Esc skips, q stops" -ForegroundColor DarkGray
    $escape = [char]27
    $visible = try { [Console]::CursorVisible } catch { $true }
    $drawn = 0
    $top = 0
    try {
        try { [Console]::CursorVisible = $false } catch { $null = $_ }
        while ($true) {
            if ($drawn) { Write-Host "$escape[$($drawn)F$escape[0J" -NoNewline }
            $rows = @(Get-PhxReviewVisible $State)
            if ($State.Index -ge $rows.Count) { $State.Index = [Math]::Max(0, $rows.Count - 1) }
            if ($State.Index -lt $top) { $top = $State.Index }
            if ($State.Index -ge $top + $room) { $top = $State.Index - $room + 1 }
            if ($top -gt [Math]::Max(0, $rows.Count - $room)) { $top = [Math]::Max(0, $rows.Count - $room) }
            $drawn = 0
            for ($i = $top; $i -lt [Math]::Min($rows.Count, $top + $room); $i++) {
                $color = if ($i -eq $State.Index) { 'Cyan' } else { 'Gray' }
                Write-Host (Format-PhxReviewRow -Row $rows[$i] -Current:($i -eq $State.Index) -Width $width) -ForegroundColor $color
                $drawn++
            }
            $footer = @(
                if ($State.Filter) { "filter '$($State.Filter)': $($rows.Count) of $($State.Rows.Count)" }
                if ($top -gt 0) { "$top more above" }
                if ($rows.Count -gt $top + $room) { "$($rows.Count - $top - $room) more below" }
            )
            Write-Host "  $($footer -join ' - ')" -ForegroundColor DarkGray
            $drawn++
            $action = Step-PhxReview -State $State -Key (Read-PhxKey)
            if ($action -eq 'filter') {
                Write-Host "$escape[$($drawn)F$escape[0J" -NoNewline
                $drawn = 0
                try { [Console]::CursorVisible = $true } catch { $null = $_ }
                $State.Filter = Read-PhxAnswer -Prompt '  Filter (Enter: none)'
                # The question's line goes as well.
                Write-Host "$escape[1F$escape[0J" -NoNewline
                try { [Console]::CursorVisible = $false } catch { $null = $_ }
                $State.Index = 0
                $top = 0
                continue
            }
            if ($action -in 'save', 'rest', 'skip', 'stop') {
                Write-Host "$escape[$($drawn)F$escape[0J" -NoNewline
                return $action
            }
        }
    }
    finally { try { [Console]::CursorVisible = $visible } catch { $null = $_ } }
}

function Invoke-PhxReviewList {
    # One list of the review - the files in several repositories, or one repository's - until it is
    # done: next, rest (accept the rest as proposed) or stop. $Entries gives the entries as they
    # are now, with the folders in its argument opened. On a console a list with check boxes, saved
    # as a whole; elsewhere typed answers, each saved at once.
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Identity,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][scriptblock]$Entries,
        [switch]$Console
    )
    $open = [Collections.Generic.List[string]]::new()
    if ($Console) {
        $rows = [Collections.Generic.List[object]]::new()
        foreach ($entry in @(& $Entries @())) { $rows.Add((New-PhxReviewRow $entry)) }
        if (-not $rows.Count) { return 'next' }
        $files = @($rows | ForEach-Object { $_.Entry.Files }).Count
        $state = [pscustomobject]@{ Rows = $rows; Index = 0; Filter = ''; CanOpen = [bool]$Identity }
        $action = Read-PhxReviewList -Title "$Title   $files pending" -State $state
        if ($action -in 'skip', 'stop') { return @{ skip = 'next'; stop = 'stop' }[$action] }
        $done = Save-PhxReviewRow -Config $Config -Identity $Identity -Rows @($rows)
        Save-PhxConfig $Config
        Write-Host "$Title - $done" -ForegroundColor Green
        return @{ save = 'next'; rest = 'rest' }[$action]
    }
    $show = $true
    while ($true) {
        $current = @(& $Entries @($open))
        if (-not $current.Count) { Write-Host '  all decided' -ForegroundColor Green; return 'next' }
        if ($show) {
            $files = @($current | ForEach-Object { $_.Files }).Count
            Write-Host
            Write-Host "$Title   $files pending" -ForegroundColor Cyan
            for ($i = 0; $i -lt $current.Count; $i++) {
                $proposal = Get-PhxReviewProposal $current[$i]
                $proposed = if (-not $proposal.Include) { 'exclude' } elseif ($proposal.Secret) { 'secret' } else { 'include' }
                Write-Host ('  {0,3}. {1,-44} {2}   proposed: {3}' -f ($i + 1), $current[$i].Path, (Get-PhxReviewNote $current[$i]), $proposed)
            }
        }
        # After an answer that went wrong only the message, not the whole list again.
        $show = $false
        $answer = Read-PhxAnswer -Prompt '  Decide (? for help)'
        if (-not $answer) { return 'next' }
        if ($answer -eq 'q') { return 'stop' }
        if ($answer -eq 'a') { return 'rest' }
        if ($answer -in '?', 'h', 'help') { Show-PhxReviewHelp; continue }
        if ($answer -match '^(\*|[\d\s,-]+)$') {
            # Numbers without a letter: which decision, then.
            $letter = Read-PhxAnswer -Prompt "  $answer - include (i), secret (s) or exclude (x)?"
            if ($letter -notin 'i', 's', 'x') { Write-Host '  include (i), secret (s) or exclude (x) - nothing decided' -ForegroundColor Yellow; continue }
            $answer = "$letter $answer"
        }
        try { $done = Invoke-PhxReviewAnswer -Config $Config -Identity $Identity -Answer $answer -Entries $current -Open $open }
        catch { Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow; continue }
        if ($answer -notmatch '^o\s') {
            # Saved at once: what is decided stays decided, whatever comes next.
            Save-PhxConfig $Config
        }
        Write-Host "  $done" -ForegroundColor Green
        $show = $true
    }
}

function Approve-PhxReviewProposal {
    # "Accept the rest as proposed": every pending file of these repositories decided as the review
    # proposes, in one go. Returns how many files.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config, [object[]]$Work = @())
    $count = 0
    foreach ($item in $Work) {
        $pending = @(Get-PhxReviewPending -Repository $item.Repository -Config $Config -Scans $item.Scans)
        if (-not $pending.Count) { continue }
        $rows = @(Get-PhxReviewEntry -Files $pending | ForEach-Object { New-PhxReviewRow $_ })
        Save-PhxReviewRow -Config $Config -Identity $item.Repository.Record.identity -Rows $rows | Out-Null
        $count += $pending.Count
    }
    Save-PhxConfig $Config
    $count
}

function Invoke-PhxReview {
    # phx review: first the files found in several repositories, decided once for all of them; then
    # per repository its pending files, until none is left - Enter (or Esc on a console) moves on,
    # a accepts the rest as proposed, q stops. With -Ask (phx init) it asks first whether to review
    # at all. Afterwards the state's pending list (phx status) is what is left.
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
    $console = Test-PhxChoiceConsole
    if (-not $console) { Show-PhxReviewHelp }
    $refresh = {
        foreach ($item in $withPending) { $item.Pending = @(Get-PhxReviewPending -Repository $item.Repository -Config $config -Scans $item.Scans) }
    }
    $outcome = 'next'
    $from = 0
    if (@(Get-PhxReviewKind -Work $withPending).Count) {
        $outcome = Invoke-PhxReviewList -Config $config -Identity '' -Title 'In more than one repository - one decision for all of them' -Console:$console -Entries {
            & $refresh
            Get-PhxReviewKind -Work $withPending
        }
    }
    for (; $from -lt $withPending.Count -and $outcome -eq 'next'; $from++) {
        $item = $withPending[$from]
        $repository = $item.Repository
        $outcome = Invoke-PhxReviewList -Config $config -Identity $repository.Record.identity -Title "$($repository.Record.identity)   $($repository.Key)" -Console:$console -Entries {
            param($Open)
            $item.Pending = @(Get-PhxReviewPending -Repository $repository -Config $config -Scans $item.Scans)
            Get-PhxReviewEntry -Files $item.Pending -Open @($Open)
        }
    }
    if ($outcome -eq 'rest') {
        # This repository's rest too: a list on a console has saved it all, typed answers not.
        $start = [Math]::Max(0, $from - 1)
        $accepted = Approve-PhxReviewProposal -Config $config -Work @($withPending | Select-Object -Skip $start)
        Write-Host "accepted as proposed: $accepted file(s)" -ForegroundColor Green
    }
    & $refresh
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
