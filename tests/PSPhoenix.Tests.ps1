# Pester 5+ suite for the PSPhoenix module. Nothing here may touch the real machine: config and
# state paths are redirected into $TestDrive through the environment variables they derive from,
# and later providers get the same treatment (a fake home per test, never ~/.claude, the registry
# or Task Scheduler). `phx` prints through Write-Host, so output is captured with 6>&1. CI runs
# the suite on Windows and Linux (pwsh), so paths are built with Join-Path and matched with [\\/].

BeforeAll {
    $script:ModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src/PSPhoenix/PSPhoenix.psd1'
    Import-Module $script:ModulePath -Force

    function script:Get-PhxOutput {
        # Runs the block (a real `phx ...` call line, switches included) and returns everything
        # it printed as one string.
        param([scriptblock]$Call)
        (& $Call 6>&1 | Out-String)
    }

    function script:Use-TestHome {
        # Points every directory PSPhoenix derives its paths from at a fresh folder under
        # $TestDrive. Returns that folder.
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $root | Out-Null
        $env:APPDATA = Join-Path $root 'Roaming'
        $env:LOCALAPPDATA = Join-Path $root 'Local'
        $env:XDG_CONFIG_HOME = Join-Path $root 'config'
        $env:XDG_STATE_HOME = Join-Path $root 'state'
        $root
    }

    $script:SavedEnv = @{}
    foreach ($name in 'APPDATA', 'LOCALAPPDATA', 'XDG_CONFIG_HOME', 'XDG_STATE_HOME') {
        $script:SavedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
    }
}

AfterAll {
    foreach ($name in $script:SavedEnv.Keys) {
        [Environment]::SetEnvironmentVariable($name, $script:SavedEnv[$name])
    }
}

Describe 'module surface' {
    It 'exports exactly one command: phx' {
        $m = Get-Module PSPhoenix
        $m.ExportedFunctions.Keys | Should -Be @('phx')
        $m.ExportedAliases.Count | Should -Be 0
    }

    It 'prints help for no arguments, --help, -h, help and /?' {
        Get-PhxOutput { phx } | Should -Match 'USAGE:'
        Get-PhxOutput { phx --help } | Should -Match 'USAGE:'
        Get-PhxOutput { phx -h } | Should -Match 'USAGE:'
        Get-PhxOutput { phx help } | Should -Match 'USAGE:'
        Get-PhxOutput { phx /? } | Should -Match 'USAGE:'
    }

    It 'help documents every command and flag' {
        $help = Get-PhxOutput { phx --help }
        foreach ($text in 'phx init', 'phx status', 'phx scan', 'phx roots', 'phx run', '-Provider', 'phx schedule',
            '-Every', 'phx review', 'phx restore', '-From', 'phx providers', 'phx version', 'docs/design.md') {
            $help | Should -Match ([regex]::Escape($text))
        }
    }

    It 'help shows the config path' {
        Use-TestHome | Out-Null
        $expected = InModuleScope PSPhoenix { Get-PhxConfigPath }
        Get-PhxOutput { phx help } | Should -Match ([regex]::Escape($expected))
    }

    It 'tab-completes the sub-commands' {
        $c = [System.Management.Automation.CommandCompletion]::CompleteInput('phx re', 6, $null)
        $c.CompletionMatches.CompletionText | Should -Contain 'review'
        $c.CompletionMatches.CompletionText | Should -Contain 'restore'
        $c.CompletionMatches.CompletionText | Should -Not -Contain 'run'
    }

    It 'prints the module version' {
        $version = (Get-Module PSPhoenix).Version.ToString()
        Get-PhxOutput { phx version } | Should -Match ([regex]::Escape("PSPhoenix $version"))
    }

    It 'fails a command that is not built yet, naming its milestone' {
        { phx init -ErrorAction Stop } | Should -Throw '*not built yet*M1*'
        { phx restore -ErrorAction Stop } | Should -Throw '*not built yet*M6*'
        phx run -ErrorAction SilentlyContinue
        $? | Should -BeFalse
    }

    It 'every planned command appears in the help with its milestone' {
        $help = Get-PhxOutput { phx --help }
        $planned = InModuleScope PSPhoenix { $script:PhxPlanned }
        foreach ($name in $planned.Keys) {
            $help | Should -Match ("phx $name\b.*\($($planned[$name])\)")
        }
    }

    It 'fails an unknown command' {
        { phx frobnicate -ErrorAction Stop } | Should -Throw "*unknown command 'frobnicate'*"
        phx frobnicate -ErrorAction SilentlyContinue
        $? | Should -BeFalse
    }

    It 'exits with 1 from pwsh -Command on an unknown command, as a scheduled task would see it' {
        Use-TestHome | Out-Null
        $pwsh = (Get-Process -Id $PID).Path
        & $pwsh -NoProfile -NonInteractive -Command "Import-Module '$script:ModulePath'; phx frobnicate" 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 1
        & $pwsh -NoProfile -NonInteractive -Command "Import-Module '$script:ModulePath'; phx version" 6>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    It 'keeps -P and -E as short forms of -Provider and -Every' {
        $bound = InModuleScope PSPhoenix {
            $cmd = Get-Command phx
            @{ P = $cmd.ResolveParameter('P').Name; E = $cmd.ResolveParameter('E').Name }
        }
        $bound.P | Should -Be 'Provider'
        $bound.E | Should -Be 'Every'
    }
}

Describe 'paths' {
    It 'keeps config and state apart, both under the redirected home' {
        $root = Use-TestHome
        $paths = InModuleScope PSPhoenix { @{ Config = Get-PhxConfigDir; State = Get-PhxStateDir } }
        $paths.Config | Should -Not -Be $paths.State
        $paths.Config.StartsWith($root) | Should -BeTrue
        $paths.State.StartsWith($root) | Should -BeTrue
    }

    It 'uses the platform convention' {
        $root = Use-TestHome
        $paths = InModuleScope PSPhoenix { @{ Config = Get-PhxConfigDir; State = Get-PhxStateDir; OnWindows = $script:OnWindows } }
        if ($paths.OnWindows) {
            $paths.Config | Should -Be (Join-Path $root 'Roaming/PSPhoenix')
            $paths.State | Should -Be (Join-Path $root 'Local/PSPhoenix')
        }
        else {
            $paths.Config | Should -Be (Join-Path $root 'config/psphoenix')
            $paths.State | Should -Be (Join-Path $root 'state/psphoenix')
        }
    }
}

Describe 'config' {
    It 'returns the defaults when there is no config yet' {
        Use-TestHome | Out-Null
        $config = InModuleScope PSPhoenix { Read-PhxConfig }
        $config.version | Should -Be 1
        $config.interval | Should -Be '1h'
        @($config.roots).Count | Should -Be 0
        $config.files.maxKB | Should -Be 1024
    }

    It 'round-trips through Save-PhxConfig' {
        Use-TestHome | Out-Null
        $config = InModuleScope PSPhoenix {
            $c = Read-PhxConfig
            $c.roots = @(@{ path = 'C:\Repos'; depth = 3 })
            $c.accounts['github.com/WizX20'] = 'WizX20'
            Save-PhxConfig $c
            Read-PhxConfig
        }
        $config.roots[0].path | Should -Be 'C:\Repos'
        $config.roots[0].depth | Should -Be 3
        $config.accounts['github.com/WizX20'] | Should -Be 'WizX20'
        Test-Path ((InModuleScope PSPhoenix { Get-PhxConfigPath }) + '.tmp') | Should -BeFalse
    }

    It 'refuses a config written by a newer PSPhoenix' {
        Use-TestHome | Out-Null
        InModuleScope PSPhoenix {
            $path = Get-PhxConfigPath
            New-Item -ItemType Directory -Force -Path (Split-Path $path -Parent) | Out-Null
            Set-Content -LiteralPath $path -Value '{ "version": 99 }'
            { Read-PhxConfig } | Should -Throw '*version 99*'
        }
    }
}

Describe 'provider registry' {
    BeforeEach {
        InModuleScope PSPhoenix { $script:SavedProviders = $script:PhxProviders; $script:PhxProviders = [ordered]@{} }
    }
    AfterEach {
        InModuleScope PSPhoenix { $script:PhxProviders = $script:SavedProviders }
    }

    It 'registers a complete provider and defaults it to every platform' {
        InModuleScope PSPhoenix {
            Register-PhxProvider @{ Name = 'demo'; Description = 'demo'; Backup = {}; Restore = {}; Status = {} }
            (Get-PhxProvider 'demo').Platforms | Should -Be @('Windows', 'Linux', 'macOS')
            @(Get-PhxProvider).Name | Should -Contain 'demo'
        }
    }

    It 'rejects a provider without <Missing>' -ForEach @(
        @{ Missing = 'Name' }, @{ Missing = 'Backup' }, @{ Missing = 'Restore' }, @{ Missing = 'Status' }, @{ Missing = 'Description' }
    ) {
        InModuleScope PSPhoenix -Parameters @{ Missing = $Missing } {
            param($Missing)
            $p = @{ Name = 'demo'; Description = 'demo'; Backup = {}; Restore = {}; Status = {} }
            $p.Remove($Missing)
            { Register-PhxProvider $p } | Should -Throw "*missing '$Missing'*"
        }
    }

    It 'rejects a non-scriptblock action, an unknown platform and a duplicate name' {
        InModuleScope PSPhoenix {
            { Register-PhxProvider @{ Name = 'a'; Description = 'a'; Backup = 'nope'; Restore = {}; Status = {} } } |
                Should -Throw '*must be a scriptblock*'
            { Register-PhxProvider @{ Name = 'b'; Description = 'b'; Backup = {}; Restore = {}; Status = {}; Platforms = @('Amiga') } } |
                Should -Throw '*unknown platform*'
            Register-PhxProvider @{ Name = 'c'; Description = 'c'; Backup = {}; Restore = {}; Status = {} }
            { Register-PhxProvider @{ Name = 'c'; Description = 'c'; Backup = {}; Restore = {}; Status = {} } } |
                Should -Throw '*registered twice*'
        }
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'an unknown key (a typo of Platforms)'; Extra = @{ Platform = @('Windows') }; Message = '*unknown key(s) Platform*' }
        @{ Case = 'a name with a path in it'; Extra = @{ Name = '../evil' }; Message = '*lowercase letters*' }
        @{ Case = 'a blank name'; Extra = @{ Name = ' ' }; Message = '*lowercase letters*' }
        @{ Case = 'an upper-case name'; Extra = @{ Name = 'Winget' }; Message = '*lowercase letters*' }
        @{ Case = 'an empty Platforms'; Extra = @{ Platforms = @() }; Message = '*Platforms is empty*' }
        @{ Case = 'a Cadence that is not a duration'; Extra = @{ Cadence = 'banana' }; Message = "*Cadence 'banana'*" }
        @{ Case = 'a zero Cadence'; Extra = @{ Cadence = '0h' }; Message = "*Cadence '0h'*" }
    ) {
        InModuleScope PSPhoenix -Parameters @{ Extra = $Extra; Message = $Message } {
            param($Extra, $Message)
            $p = @{ Name = 'demo'; Description = 'demo'; Backup = {}; Restore = {}; Status = {} }
            foreach ($key in $Extra.Keys) { $p[$key] = $Extra[$key] }
            { Register-PhxProvider $p } | Should -Throw $Message
        }
    }

    It 'accepts a cadence in minutes, hours or days' {
        InModuleScope PSPhoenix {
            foreach ($cadence in '30m', '1h', '7d') {
                Register-PhxProvider @{ Name = "p$cadence"; Description = 'd'; Backup = {}; Restore = {}; Status = {}; Cadence = $cadence }
            }
            (Get-PhxProvider 'p7d').Cadence | Should -Be '7d'
        }
    }

    It 'lists only the providers for the current platform' {
        InModuleScope PSPhoenix {
            $here = Get-PhxCurrentPlatform
            $elsewhere = @('Windows', 'Linux', 'macOS') | Where-Object { $_ -ne $here } | Select-Object -First 1
            Register-PhxProvider @{ Name = 'here'; Description = 'h'; Backup = {}; Restore = {}; Status = {}; Platforms = @($here) }
            Register-PhxProvider @{ Name = 'away'; Description = 'a'; Backup = {}; Restore = {}; Status = {}; Platforms = @($elsewhere) }
            @(Get-PhxProvider).Name | Should -Be @('here')
            (Get-PhxProvider 'away').Name | Should -Be 'away'
        }
    }

    It 'phx providers says so when nothing is registered' {
        Get-PhxOutput { phx providers } | Should -Match 'no providers registered yet'
    }
}
