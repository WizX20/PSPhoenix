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
