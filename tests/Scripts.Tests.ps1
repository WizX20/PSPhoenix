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
