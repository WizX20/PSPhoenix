# Pester suite for the dev scripts in scripts/ (the module's own suite is PSPhoenix.Tests.ps1).
# Like everything in tests/, nothing here touches the real machine: each script is pointed at a
# scratch folder under $TestDrive.

Describe 'dev-link' {
    BeforeAll {
        $script:DevLink = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/dev-link.ps1'
        $script:SrcManifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'src/PSPhoenix/PSPhoenix.psd1'

        function script:New-TestLink {
            # A link like the one dev-link makes, to $Target, in a fresh modules folder.
            param([string]$Modules, [string]$Target)
            New-Item -ItemType Directory -Force -Path $Modules | Out-Null
            New-Item -ItemType ($IsWindows ? 'Junction' : 'SymbolicLink') -Path (Join-Path $Modules 'PSPhoenix') -Target $Target | Out-Null
        }
    }
    # Every test removes its link in `finally`: a link into src/ left in $TestDrive must never
    # meet a recursive cleanup.

    It 'links the working copy, says so the second time, and removes only the link' {
        $modules = Join-Path $TestDrive 'once'
        try {
            & $script:DevLink -ModulesPath $modules 6>$null
            (Get-Item -LiteralPath (Join-Path $modules 'PSPhoenix')).LinkType | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath (Join-Path $modules 'PSPhoenix/PSPhoenix.psd1') | Should -BeTrue
            (& $script:DevLink -ModulesPath $modules 6>&1 | Out-String) | Should -Match 'already linked'
        }
        finally { & $script:DevLink -ModulesPath $modules -Remove 6>$null }
        Test-Path -LiteralPath (Join-Path $modules 'PSPhoenix') | Should -BeFalse
        Test-Path -LiteralPath $script:SrcManifest | Should -BeTrue
    }

    It 're-points a link whose checkout is gone' {
        $modules = Join-Path $TestDrive 'gone'
        $old = Join-Path $TestDrive 'old-worktree'
        New-Item -ItemType Directory -Path $old | Out-Null
        New-TestLink -Modules $modules -Target $old
        Remove-Item -LiteralPath $old
        try {
            (& $script:DevLink -ModulesPath $modules 6>&1 | Out-String) | Should -Match 're-pointing'
            Test-Path -LiteralPath (Join-Path $modules 'PSPhoenix/PSPhoenix.psd1') | Should -BeTrue
        }
        finally { & $script:DevLink -ModulesPath $modules -Remove 6>$null }
    }

    It 're-points a link to another checkout' {
        $modules = Join-Path $TestDrive 'other'
        $other = Join-Path $TestDrive 'other-checkout'
        New-Item -ItemType Directory -Path $other | Out-Null
        New-TestLink -Modules $modules -Target $other
        try {
            (& $script:DevLink -ModulesPath $modules 6>&1 | Out-String) | Should -Match 're-pointing'
            Test-Path -LiteralPath (Join-Path $modules 'PSPhoenix/PSPhoenix.psd1') | Should -BeTrue
            Test-Path -LiteralPath $other | Should -BeTrue
        }
        finally { & $script:DevLink -ModulesPath $modules -Remove 6>$null }
    }

    It 'refuses to replace or remove a real directory' {
        $modules = Join-Path $TestDrive 'real'
        New-Item -ItemType Directory -Path (Join-Path $modules 'PSPhoenix') | Out-Null
        { & $script:DevLink -ModulesPath $modules 6>$null } | Should -Throw '*real directory*'
        { & $script:DevLink -ModulesPath $modules -Remove 6>$null } | Should -Throw '*real directory*'
        Test-Path -LiteralPath (Join-Path $modules 'PSPhoenix') | Should -BeTrue
    }
}

Describe 'cut-changelog' {
    BeforeAll {
        $script:CutChangelog = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/cut-changelog.ps1'

        function script:New-ChangelogRepo {
            # A throwaway repository root: CHANGELOG.md with an Unreleased and a released section,
            # and the given fragments in changelog.d/ (name -> content).
            param([string]$Unreleased = '', [hashtable]$Fragments = @{})
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Path (Join-Path $root 'changelog.d') | Out-Null
            Set-Content -LiteralPath (Join-Path $root 'changelog.d/README.md') -Value '# how to'
            foreach ($name in $Fragments.Keys) {
                [IO.File]::WriteAllText((Join-Path $root "changelog.d/$name"), $Fragments[$name])
            }
            [IO.File]::WriteAllText((Join-Path $root 'CHANGELOG.md'),
                "# Changelog`n`n## [Unreleased]`n`n$Unreleased`n## [0.1.0] - 2026-10-07`n`n### Added`n`n- first`n")
            $root
        }
    }

    It 'merges the fragments and the Unreleased lines into one section, in Keep a Changelog order' {
        $root = New-ChangelogRepo -Unreleased "### Fixed`n`n- hand-written fix`n" -Fragments @{
            'b-config.fixed.md'    = "- config fix`n"
            'a-install.changed.md' = "- install docs`r`n- second line`r`n"
            'c-new.added.md'       = '- a new command'
        }
        $notes = & $script:CutChangelog -Version 0.2.0 -Root $root 6>$null
        $expected = "### Added`n`n- a new command`n`n### Changed`n`n- install docs`n- second line`n`n### Fixed`n`n- hand-written fix`n- config fix"
        $notes | Should -Be $expected
        $changelog = [IO.File]::ReadAllText((Join-Path $root 'CHANGELOG.md'))
        $today = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
        $changelog.Contains("## [Unreleased]`n`n## [0.2.0] - $today`n`n$expected`n`n## [0.1.0] - 2026-10-07") | Should -BeTrue
        $changelog | Should -Not -Match "`n`n\z"
        @(Get-ChildItem -LiteralPath (Join-Path $root 'changelog.d')).Name | Should -Be @('README.md')
        [IO.File]::ReadAllText((Join-Path $root 'dist/release-notes.md')) | Should -Be "$expected`n"
    }

    It 'refuses a fragment that is <Case>' -ForEach @(
        @{ Case = 'misnamed'; Name = 'oops.fix.md'; Content = '- x'; Message = '*changelog.d/oops.fix.md: name it*' }
        @{ Case = 'not a bullet list'; Name = 'oops.fixed.md'; Content = 'Fixed a thing'; Message = "*changelog.d/oops.fixed.md: write one or more '- ' bullets*" }
    ) {
        $root = New-ChangelogRepo -Fragments @{ $Name = $Content }
        { & $script:CutChangelog -Check -Root $root 6>$null } | Should -Throw $Message
        { & $script:CutChangelog -Version 0.2.0 -Root $root 6>$null } | Should -Throw $Message
        Test-Path -LiteralPath (Join-Path $root "changelog.d/$Name") | Should -BeTrue
    }

    It 'refuses to release without notes' {
        $root = New-ChangelogRepo
        { & $script:CutChangelog -Version 0.2.0 -Root $root 6>$null } | Should -Throw '*No release notes*'
    }

    It 'falls back to the commit subjects, non-ASCII intact' {
        $dash = [char]0x2014   # an em-dash; spelled as a char code to keep this file ASCII
        $root = New-ChangelogRepo
        git -C $root init -q
        git -C $root -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m "Make the backup faster $dash twice as fast"
        $notes = & $script:CutChangelog -Version 0.2.0 -Root $root -FallbackFromGit 6>$null
        $notes | Should -Be "### Changed`n`n- Make the backup faster $dash twice as fast"
    }

    It "accepts this repository's own fragments" {
        # Runs on every pull request, so a misnamed fragment fails here rather than in the release.
        { & $script:CutChangelog -Check 6>$null } | Should -Not -Throw
    }
}

Describe 'merge-stack' {
    BeforeAll {
        $script:MergeStack = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/merge-stack.ps1'
        $script:RealGit = (Get-Command git -CommandType Application | Select-Object -First 1).Source
        # git without the developer's global config (signing, hooks, default branch).
        $script:SavedGitConfig = $env:GIT_CONFIG_GLOBAL, $env:GIT_CONFIG_NOSYSTEM
        $env:GIT_CONFIG_GLOBAL = Join-Path $TestDrive 'gitconfig-empty'
        New-Item -ItemType File -Path $env:GIT_CONFIG_GLOBAL -Force | Out-Null
        $env:GIT_CONFIG_NOSYSTEM = '1'

        function script:New-StackRepo {
            # A bare origin with main, feature/a on main and feature/b on feature/a - then feature/a
            # squash-merged into main, as GitHub does it: one new commit with feature/a's tree.
            param([switch]$MoreOnMain)
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
            $origin = Join-Path $root 'origin.git'
            $work = Join-Path $root 'work'
            & $script:RealGit init -q --bare -b main $origin
            & $script:RealGit clone -q $origin $work 2>$null
            & $script:RealGit -C $work config user.name t
            & $script:RealGit -C $work config user.email t@example.invalid
            $commit = { param($File) Set-Content -LiteralPath (Join-Path $work $File) -Value $File; & $script:RealGit -C $work add -A; & $script:RealGit -C $work commit -q -m $File }
            & $script:RealGit -C $work symbolic-ref HEAD refs/heads/main
            & $commit 'base.txt'
            & $script:RealGit -C $work checkout -q -b feature/a
            & $commit 'a.txt'
            & $script:RealGit -C $work checkout -q -b feature/b
            & $commit 'b.txt'
            & $script:RealGit -C $work push -q origin main feature/a feature/b 2>$null
            $aHead = & $script:RealGit -C $work rev-parse feature/a
            $squash = & $script:RealGit -C $work commit-tree "feature/a^{tree}" -p main -m 'a (#1)'
            & $script:RealGit -C $work push -q origin "${squash}:refs/heads/main" 2>$null
            if ($MoreOnMain) {
                & $script:RealGit -C $work checkout -q -B main $squash
                & $commit 'other.txt'
                & $script:RealGit -C $work push -q origin main 2>$null
            }
            @{ Origin = $origin; Work = $work; AHead = "$aHead"; BHead = "$(& $script:RealGit -C $work rev-parse feature/b)" }
        }

        function script:Invoke-MergeStack {
            # Runs merge-stack.ps1 in $Repo's clone, with `git gh` answered by $Prs (number ->
            # scriptblock giving the PR) and everything else going to the real git. Returns the
            # gh calls made.
            param([hashtable]$Repo, [hashtable]$Prs, [object[]]$Arguments, [switch]$DryRun)
            $calls = [Collections.Generic.List[string]]::new()
            # Called from inside the script, where $script: is the script's own scope: plain names only.
            $realGit = $script:RealGit
            $answers = $Prs
            function git {
                if ($args[0] -ne 'gh') { & $realGit @args; return }
                $line = @($args | Select-Object -Skip 1) -join ' '
                $calls.Add($line)
                switch -Regex ($line) {
                    '^repo view' { 'o/r' }
                    '^pr view (\d+)' { & $answers[[int]$Matches[1]] | ConvertTo-Json -Compress }
                    '^pr checks' { '[{"name":"lint","bucket":"pass"}]' }
                    '^api -X PUT repos/o/r/pulls/\d+/merge-async' { '{"details":{"uuid":"u1"}}' }
                    '^api repos/o/r/pulls/\d+/merge-async/u1' { '{"status":"merged"}' }
                    default { throw "unexpected: git gh $line" }
                }
                & $realGit --version > $null   # $LASTEXITCODE 0, as the real gh would leave it
            }
            Push-Location $Repo.Work
            try { & $script:MergeStack @Arguments -PollSeconds 0 -WhatIf:$DryRun 6>$null }
            finally { Pop-Location }
            , $calls
        }

        function script:Get-StackPrs {
            # #1 merged; #2 open on main, in conflict until its branch moves.
            param([hashtable]$Repo, [string]$Base = 'main')
            $realGit = $script:RealGit
            $baseRef = $Base
            $origin = $Repo.Origin
            $bHead = $Repo.BHead
            @{
                1 = { @{ number = 1; state = 'MERGED'; baseRefName = 'main'; headRefName = 'feature/a'; headRefOid = $Repo.AHead; mergeStateStatus = 'UNKNOWN' } }.GetNewClosure()
                2 = {
                    $head = "$(& $realGit -C $origin rev-parse refs/heads/feature/b)"
                    @{ number = 2; state = 'OPEN'; baseRefName = $baseRef; headRefName = 'feature/b'; headRefOid = $head; mergeStateStatus = $(if ($head -eq $bHead) { 'DIRTY' } else { 'CLEAN' }) }
                }.GetNewClosure()
            }
        }
    }

    AfterAll { $env:GIT_CONFIG_GLOBAL, $env:GIT_CONFIG_NOSYSTEM = $script:SavedGitConfig }

    It 'merges main into the next branch without changing its tree, then squash-merges it' {
        $repo = New-StackRepo
        $calls = Invoke-MergeStack -Repo $repo -Prs (Get-StackPrs $repo) -Arguments 1, 2
        $head = & $script:RealGit -C $repo.Origin rev-parse refs/heads/feature/b
        $parents = (& $script:RealGit -C $repo.Origin rev-list --parents -n 1 $head) -split ' ' | Select-Object -Skip 1
        $parents | Should -Be @($repo.BHead, (& $script:RealGit -C $repo.Origin rev-parse refs/heads/main))
        & $script:RealGit -C $repo.Origin rev-parse "${head}^{tree}" | Should -Be (& $script:RealGit -C $repo.Origin rev-parse "$($repo.BHead)^{tree}")
        @($calls | Where-Object { $_ -like 'api -X PUT*' }) | Should -Be @("api -X PUT repos/o/r/pulls/2/merge-async -f merge_method=squash -f sha=$head")
    }

    It 'stops when main holds more than the merged pull request' {
        $repo = New-StackRepo -MoreOnMain
        { Invoke-MergeStack -Repo $repo -Prs (Get-StackPrs $repo) -Arguments 1, 2 } | Should -Throw '*merge main into feature/b by hand*'
        & $script:RealGit -C $repo.Origin rev-parse refs/heads/feature/b | Should -Be $repo.BHead
    }

    It 'refuses to start in the middle of a stack' {
        $repo = New-StackRepo
        { Invoke-MergeStack -Repo $repo -Prs (Get-StackPrs $repo -Base 'feature/a') -Arguments @(2) } | Should -Throw '*start at the bottom*'
    }

    It 'changes nothing with -WhatIf' {
        $repo = New-StackRepo
        $calls = Invoke-MergeStack -Repo $repo -Prs (Get-StackPrs $repo) -Arguments 1, 2 -DryRun
        & $script:RealGit -C $repo.Origin rev-parse refs/heads/feature/b | Should -Be $repo.BHead
        @($calls | Where-Object { $_ -like 'api*' }).Count | Should -Be 0
    }
}
