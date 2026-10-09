<#
.SYNOPSIS
Merges a stack of pull requests bottom-up, each as its own squash commit.

.DESCRIPTION
A stack is a row of pull requests where each one's base is the branch of the one below it and
the lowest one's base is main (.claude/skills/pr-stack/SKILL.md). For each number, in order:

1. A pull request that is merged already is skipped, so a re-run after a failure continues
   where it stopped.
2. After the one below was squash-merged, GitHub retargets this one to main. When it is then
   behind or in conflict, main is merged into its branch with the branch's own tree: main is
   exactly the merged pull request's head, which this branch already contains, so nothing
   changes but the history. The merge commit is made on the remote branch (git commit-tree) and
   pushed as a fast-forward; no checkout or worktree is touched. Anything else on main stops the
   script: that merge needs a person.
3. Waits until every check on the pull request has passed.
4. Squash-merges it through the asynchronous merge API, the one GitHub accepts for a stacked
   pull request, with the full head SHA, and waits until GitHub reports it merged.

Stops at the first problem. GitHub is reached through `git gh`, so the repository's account
routing applies (.gitconfig).

.PARAMETER Number
The pull requests, bottom of the stack first.

.PARAMETER PollSeconds
How often to look again while waiting for checks, a retarget or a merge.

.PARAMETER TimeoutMinutes
How long to wait for one pull request's checks before giving up.

.EXAMPLE
task merge-stack -- 38 39 40 41

.EXAMPLE
./scripts/merge-stack.ps1 38 39 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0, ValueFromRemainingArguments)][int[]]$Number,
    [int]$PollSeconds = 20,
    [int]$TimeoutMinutes = 30
)
$ErrorActionPreference = 'Stop'
$wait = @{ Seconds = $PollSeconds; Minutes = $TimeoutMinutes }

function Invoke-Git {
    # git, failing loudly; -Gh runs `git gh` (the GitHub CLI as this repository's account).
    # -AllowFailure returns stdout whatever the exit code ($LASTEXITCODE tells): `gh pr checks`
    # exits 8 while checks are pending, `git diff --quiet` 1 when there is a difference.
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$Gh, [switch]$AllowFailure)
    $all = if ($Gh) { @('gh') + $Arguments } else { $Arguments }
    $output = & git @all 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) { throw "git $($all -join ' ') failed: $(($output | Out-String).Trim())" }
    $output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }
}

function Get-StackPr {
    param([Parameter(Mandatory)][int]$Pr)
    (Invoke-Git -Gh 'pr', 'view', $Pr, '--json', 'number,state,baseRefName,headRefName,headRefOid,mergeStateStatus') -join "`n" | ConvertFrom-Json
}

function Wait-Until {
    # Calls $Condition every -PollSeconds until it returns something, or throws $Message on timeout.
    param([Parameter(Mandatory)][scriptblock]$Condition, [Parameter(Mandatory)][string]$Message, [int]$Minutes = $wait.Minutes)
    $deadline = [DateTime]::UtcNow.AddMinutes($Minutes)
    while ($true) {
        $result = & $Condition
        if ($result) { return $result }
        if ([DateTime]::UtcNow -gt $deadline) { throw $Message }
        Start-Sleep -Seconds $wait.Seconds
    }
}

function Sync-StackBranch {
    # Merges main into the pull request's branch without changing its tree; see step 2 above.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Pr, [Parameter(Mandatory)][int]$Below, [Parameter(Mandatory)][string]$BelowHead)
    $branch = $Pr.headRefName
    Invoke-Git 'fetch', '-q', 'origin', 'main', $branch | Out-Null
    Invoke-Git 'diff', '--quiet', 'origin/main', $BelowHead, '--' -AllowFailure | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "main is not just #$Below's head - merge main into $branch by hand, then run this again" }
    # The head below may itself be such a merge; then its first parent is what this branch holds.
    $holds = foreach ($commit in $BelowHead, "$BelowHead^1") {
        Invoke-Git 'merge-base', '--is-ancestor', $commit, "origin/$branch" -AllowFailure | Out-Null
        if ($LASTEXITCODE -eq 0) { $true; break }
    }
    if (-not $holds) { throw "$branch does not contain #$Below's head - merge it up by hand, then run this again" }
    $tree = Invoke-Git 'rev-parse', "origin/${branch}^{tree}"
    $commit = Invoke-Git 'commit-tree', $tree, '-p', "origin/$branch", '-p', 'origin/main', '-m', "Merge main after #$Below's squash merge"
    if ($PSCmdlet.ShouldProcess($branch, "push $commit (main merged, tree unchanged)")) {
        Invoke-Git 'push', '-q', 'origin', "${commit}:refs/heads/$branch" | Out-Null
        Write-Host "  $branch`: main merged, tree unchanged" -ForegroundColor DarkGray
    }
    $commit
}

function Wait-StackChecks {
    # Until every check on the head commit has passed; a failed or cancelled one stops the script.
    param([Parameter(Mandatory)][int]$Pr, [Parameter(Mandatory)][string]$Head)
    $expected = $Head
    Wait-Until -Message "#$Pr`: checks did not finish within $($wait.Minutes) minutes" -Condition {
        if ((Get-StackPr $Pr).headRefOid -ne $expected) { return }   # GitHub has not seen the push yet
        $json = (Invoke-Git -Gh 'pr', 'checks', $Pr, '--json', 'name,bucket' -AllowFailure) -join "`n"
        $checks = if ($json.Trim()) { @($json | ConvertFrom-Json) } else { @() }   # none reported yet
        $failed = @($checks | Where-Object bucket -In 'fail', 'cancel')
        if ($failed) { throw "#$Pr`: $(($failed | ForEach-Object name) -join ', ') failed - fix it, then run this again" }
        $checks.Count -and -not @($checks | Where-Object bucket -EQ 'pending').Count
    } | Out-Null
}

function Merge-StackPr {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][int]$Pr, [Parameter(Mandatory)][string]$Head, [Parameter(Mandatory)][string]$Repository)
    $state = Wait-Until -Minutes 5 -Message "#$Pr is not mergeable: $((Get-StackPr $Pr).mergeStateStatus)" -Condition {
        $status = (Get-StackPr $Pr).mergeStateStatus
        if ($status -in 'CLEAN', 'UNSTABLE', 'HAS_HOOKS') { $status }
    }
    Write-Host "  #$Pr is $state - merging $($Head.Substring(0, 7))" -ForegroundColor DarkGray
    if (-not $PSCmdlet.ShouldProcess("#$Pr", "squash-merge $Head")) { return }
    $request = (Invoke-Git -Gh 'api', '-X', 'PUT', "repos/$Repository/pulls/$Pr/merge-async", '-f', 'merge_method=squash', '-f', "sha=$Head" -AllowFailure) -join "`n"
    if ($LASTEXITCODE -eq 0) {
        $uuid = ($request | ConvertFrom-Json).details.uuid
        $result = Wait-Until -Minutes 5 -Message "#$Pr`: the merge did not finish" -Condition {
            $status = ((Invoke-Git -Gh 'api', "repos/$Repository/pulls/$Pr/merge-async/$uuid") -join "`n" | ConvertFrom-Json).status
            if ($status -ne 'pending') { $status }
        }
        if ($result -ne 'merged') { throw "#$Pr`: GitHub says the merge is $result" }
    }
    else {
        # Not every pull request goes through the asynchronous API; one outside a stack merges the usual way.
        Invoke-Git -Gh 'pr', 'merge', $Pr, '--squash', '--match-head-commit', $Head | Out-Null
        Wait-Until -Minutes 5 -Message "#$Pr`: the merge did not finish" -Condition { (Get-StackPr $Pr).state -eq 'MERGED' } | Out-Null
    }
}

$repository = Invoke-Git -Gh 'repo', 'view', '--json', 'nameWithOwner', '-q', '.nameWithOwner'
$below = $null
$belowHead = $null
foreach ($n in $Number) {
    $pr = Get-StackPr $n
    if ($pr.state -eq 'MERGED') {
        Write-Host "#$n is merged already" -ForegroundColor DarkGray
        $below, $belowHead = $n, $pr.headRefOid
        continue
    }
    if ($pr.state -ne 'OPEN') { throw "#$n is $($pr.state.ToLower())" }
    Write-Host "#$n $($pr.headRefName)" -ForegroundColor Cyan

    if ($pr.baseRefName -ne 'main') {
        if (-not $below) { throw "#$n is based on $($pr.baseRefName), not main - start at the bottom of the stack" }
        if ($WhatIfPreference) { Write-Host "  would wait for GitHub to retarget it to main"; $below, $belowHead = $n, $pr.headRefOid; continue }
        $pr = Wait-Until -Minutes 5 -Message "#$n was not retargeted to main after #$below's merge" -Condition {
            $now = Get-StackPr $n
            if ($now.baseRefName -eq 'main') { $now }
        }
    }
    $head = $pr.headRefOid
    if ($below) {
        $pr = Wait-Until -Minutes 5 -Message "#$n`: GitHub did not work out its merge state" -Condition {
            $now = Get-StackPr $n
            if ($now.mergeStateStatus -ne 'UNKNOWN') { $now }
        }
        if ($pr.mergeStateStatus -in 'DIRTY', 'BEHIND') { $head = Sync-StackBranch -Pr $pr -Below $below -BelowHead $belowHead }
    }
    if ($WhatIfPreference) { Write-Host "  would wait for its checks, then squash-merge it"; $below, $belowHead = $n, $head; continue }
    Wait-StackChecks -Pr $n -Head $head
    Merge-StackPr -Pr $n -Head $head -Repository $repository
    Write-Host "  #$n merged" -ForegroundColor Green
    $below, $belowHead = $n, $head
}
