# Questions to the user. Every typed answer goes through Read-PhxAnswer, so a test replaces this one
# function and drives a whole conversation with scripted answers.

function Read-PhxAnswer {
    # One answer, trimmed; Enter takes the default (shown in brackets). The end of input (stdin
    # redirected from a file that ran out) cancels: Read-Host then returns nothing on every call,
    # which would otherwise loop on a question or take every default unasked.
    param([Parameter(Mandatory)][string]$Prompt, [string]$Default = '')
    $shown = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
    try { $answer = Read-Host $shown }
    catch [System.Management.Automation.PSInvalidOperationException] {
        throw 'this needs an interactive console - run it in a terminal, not with -NonInteractive'
    }
    if ($null -eq $answer) { throw [OperationCanceledException]::new('input ended') }
    $answer = $answer.Trim()
    if ($answer) { $answer } else { $Default }
}

function Show-PhxSecretLine {
    # A line that holds a secret - a new age key: straight to the console, past PowerShell's
    # streams, so a transcript (Start-Transcript, or one a group policy turns on) does not record it.
    # Tests replace this one as well.
    param([Parameter(Mandatory)][string]$Text)
    [Console]::Out.WriteLine($Text)
}

function Read-PhxSecretAnswer {
    # A secret answer - a passphrase: not echoed, not trimmed. Tests replace this one too.
    param([Parameter(Mandatory)][string]$Prompt)
    try { $secure = Read-Host $Prompt -AsSecureString }
    catch [System.Management.Automation.PSInvalidOperationException] {
        throw 'this needs an interactive console - run it in a terminal, not with -NonInteractive'
    }
    if ($null -eq $secure) { throw [OperationCanceledException]::new('input ended') }
    [Net.NetworkCredential]::new('', $secure).Password
}

function Test-PhxChoiceConsole {
    # Whether a choice can be made with the arrow keys: a console that is read and written
    # directly, in a session that may ask. Otherwise Read-PhxChoice asks for typed answers.
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { return $false }
    if ($Host.Name -ne 'ConsoleHost') { return $false }
    if (@([Environment]::GetCommandLineArgs() | Where-Object { $_ -match '^-noni' }).Count) { return $false }
    $true
}

function Read-PhxKey {
    # One key from the console, not echoed. Tests replace this one to drive a choice list.
    [Console]::ReadKey($true)
}

function Step-PhxChoice {
    # One key on a choice list: moves the cursor, ticks a row (multi-select) or ends the choice.
    # Returns what the key did: move, toggle, accept, cancel or none.
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][ConsoleKeyInfo]$Key)
    $rows = $State.Rows
    switch ($Key.Key) {
        { $_ -in 'UpArrow', 'K' } { $State.Index = ($State.Index - 1 + $rows) % $rows; return 'move' }
        { $_ -in 'DownArrow', 'J', 'Tab' } { $State.Index = ($State.Index + 1) % $rows; return 'move' }
        'Home' { $State.Index = 0; return 'move' }
        'End' { $State.Index = $rows - 1; return 'move' }
        'Spacebar' {
            if (-not $State.Multi) { return 'accept' }
            if ($State.Index -lt $State.Selected.Count) { $State.Selected[$State.Index] = -not $State.Selected[$State.Index]; return 'toggle' }
            return 'accept'
        }
        'A' {
            if (-not $State.Multi) { return 'none' }
            $all = $State.Selected -notcontains $false
            for ($i = 0; $i -lt $State.Selected.Count; $i++) { $State.Selected[$i] = -not $all }
            return 'toggle'
        }
        'Enter' { return 'accept' }
        { $_ -in 'Escape', 'Q' } { return 'cancel' }
    }
    'none'
}

function Format-PhxChoiceRow {
    # One row of a choice list as shown: cursor, tick box (multi-select), label - cut to the width,
    # so a row never wraps (a redraw counts rows).
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][int]$Row, [int]$Width = 120)
    $cursor = if ($Row -eq $State.Index) { '>' } else { ' ' }
    $label = if ($Row -lt $State.Labels.Count) { $State.Labels[$Row] } else { $State.Other }
    $box = if (-not $State.Multi -or $Row -ge $State.Labels.Count) { '' } elseif ($State.Selected[$Row]) { '[x] ' } else { '[ ] ' }
    $text = "  $cursor $box$label"
    if ($text.Length -ge $Width) { $text = $text.Substring(0, [Math]::Max(1, $Width - 4)) + '...' }
    $text
}

function Read-PhxChoice {
    # A choice from a list: with the arrow keys on a console (space ticks in a multi-select, Enter
    # accepts, q or Esc stops), else as typed answers through Read-PhxAnswer - numbers from the
    # list (comma-separated in a multi-select) or a label - so a test or a redirected run answers
    # the same questions. With -Other, a last row lets the user type what is not in the list.
    # Returns what was chosen: [int] indexes into -Options, and typed text as [string]. q stops
    # (OperationCanceledException).
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Options,
        [int[]]$Default = @(),
        [switch]$Multi,
        # The last row's label, e.g. 'another folder - type its path'.
        [string]$Other,
        # What else may be typed as an answer, e.g. 'and/or paths'.
        [string]$TypedHint
    )
    if (-not $Options.Count -and -not $Other) { throw 'nothing to choose from' }
    if (Test-PhxChoiceConsole) { return Read-PhxChoiceByKey @PSBoundParameters }

    # Typed answers: the list numbered, the default as numbers (a multi-select) or as its label.
    for ($i = 0; $i -lt $Options.Count; $i++) { Write-Host ('  {0}. {1}' -f ($i + 1), $Options[$i]) }
    $what = if ($Multi) { 'numbers from the list, comma-separated' } else { 'a number from the list' }
    if ($TypedHint) { $what += " $TypedHint" }
    Write-Host "  $what" -ForegroundColor DarkGray
    $shownDefault = if ($Multi) { ($Default | ForEach-Object { $_ + 1 }) -join ',' } elseif ($Default.Count) { $Options[$Default[0]] } else { '' }
    while ($true) {
        $answer = Read-PhxAnswer -Prompt "  $Prompt" -Default $shownDefault
        if ($answer -eq 'q') { throw [OperationCanceledException]::new('stopped') }
        $tokens = if ($Multi) { @($answer -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @($answer | Where-Object { $_ }) }
        $result = [Collections.Generic.List[object]]::new()
        $problem = $null
        foreach ($token in $tokens) {
            $label = @(for ($i = 0; $i -lt $Options.Count; $i++) { if ([string]::Equals($Options[$i], $token, [StringComparison]::OrdinalIgnoreCase)) { $i } })
            # A bare number picks from the list; a folder named like one is typed as a path (./2).
            if ($token -match '^\d+$') {
                $number = 0L
                if ([long]::TryParse($token, [ref]$number) -and $number -ge 1 -and $number -le $Options.Count) { $result.Add([int]($number - 1)) }
                else { $problem = "there is no number $token in the list" }
            }
            elseif ($label.Count) { $result.Add([int]$label[0]) }
            elseif ($Other) { $result.Add([string]$token) }
            else { $problem = "one of: $($Options -join ', ')" }
        }
        if (-not $problem -and -not $Multi -and -not $result.Count) { $problem = 'a choice, please' }
        if (-not $problem) { return $result.ToArray() }
        Write-Host "  $problem" -ForegroundColor Yellow
    }
}

function Read-PhxChoiceByKey {
    # Read-PhxChoice on a console: the list drawn once and redrawn in place on every key; once
    # chosen it gives way to one line with the answer.
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Options,
        [int[]]$Default = @(),
        [switch]$Multi,
        [string]$Other,
        [string]$TypedHint
    )
    $null = $TypedHint
    $state = [pscustomobject]@{
        Labels   = $Options
        Other    = $Other
        Rows     = $Options.Count + [int][bool]$Other
        Index    = if ($Default.Count) { $Default[0] } else { 0 }
        Selected = [bool[]]@(for ($i = 0; $i -lt $Options.Count; $i++) { $Default -contains $i })
        Multi    = [bool]$Multi
    }
    # A console without a size (a redirected or headless one reports 0) gets the usual width.
    $width = try { [Console]::WindowWidth } catch { 0 }
    if ($width -lt 20) { $width = 120 }
    $keys = if ($Multi) { 'up/down to move, space ticks, a ticks all, Enter accepts, q stops' } else { 'up/down to move, Enter chooses, q stops' }
    Write-Host "  $Prompt - $keys" -ForegroundColor DarkGray
    $escape = [char]27
    $visible = try { [Console]::CursorVisible } catch { $true }
    try {
        try { [Console]::CursorVisible = $false } catch { $null = $_ }
        $drawn = $false
        while ($true) {
            # Back to the first row, and every row cleared and written again.
            if ($drawn) { Write-Host "$escape[$($state.Rows)F" -NoNewline }
            for ($row = 0; $row -lt $state.Rows; $row++) {
                $color = if ($row -eq $state.Index) { 'Cyan' } else { 'Gray' }
                Write-Host ("$escape[2K" + (Format-PhxChoiceRow -State $state -Row $row -Width $width)) -ForegroundColor $color
            }
            $drawn = $true
            $action = Step-PhxChoice -State $state -Key (Read-PhxKey)
            if ($action -eq 'cancel') { throw [OperationCanceledException]::new('stopped') }
            if ($action -ne 'accept') { continue }
            $onOther = $Other -and $state.Index -eq $Options.Count
            $chosen = @(if ($Multi) { for ($i = 0; $i -lt $Options.Count; $i++) { if ($state.Selected[$i]) { $i } } } elseif (-not $onOther) { $state.Index })
            Write-Host "$escape[$($state.Rows)F$escape[0J" -NoNewline
            $typed = @()
            if ($onOther) {
                try { [Console]::CursorVisible = $visible } catch { $null = $_ }
                $text = Read-PhxAnswer -Prompt "  $Other"
                if ($text -eq 'q') { throw [OperationCanceledException]::new('stopped') }
                # Nothing typed: back to the list.
                if (-not $text) { try { [Console]::CursorVisible = $false } catch { $null = $_ }; $drawn = $false; continue }
                $typed = @([string]$text)
            }
            $shown = @(@($chosen | ForEach-Object { $Options[$_] }) + $typed)
            Write-Host "  ${Prompt}: $(if ($shown.Count) { $shown -join ', ' } else { 'none' })"
            return @(@($chosen | ForEach-Object { [int]$_ }) + $typed)
        }
    }
    finally { try { [Console]::CursorVisible = $visible } catch { $null = $_ } }
}
