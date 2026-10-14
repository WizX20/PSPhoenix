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
        # No OneDrive either: phx init would offer the real one.
        $env:OneDriveCommercial = $env:OneDriveConsumer = $env:OneDrive = $null
        $root
    }

    function script:New-TestRepository {
        # A throwaway repository with one commit and the given remotes, in order. Returns its path.
        param([Parameter(Mandatory)][string]$Path, [string[]]$Remote = @())
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
        git -c init.defaultBranch=main init -q $Path
        git -C $Path -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m init
        foreach ($entry in $Remote) {
            $name, $url = $entry -split '=', 2
            git -C $Path remote add $name $url
        }
        $Path
    }

    $script:SavedEnv = @{}
    foreach ($name in 'APPDATA', 'LOCALAPPDATA', 'XDG_CONFIG_HOME', 'XDG_STATE_HOME', 'OneDriveCommercial', 'OneDriveConsumer', 'OneDrive',
        'GH_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM', 'GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0') {
        $script:SavedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    # git without the developer's global and system config: a global commit.gpgsign, hooksPath or
    # credential helper must neither change what the tests see nor reach real keys or accounts.
    $script:EmptyGitConfig = Join-Path $TestDrive 'gitconfig-empty'
    New-Item -ItemType File -Path $script:EmptyGitConfig -Force | Out-Null
    $env:GIT_CONFIG_GLOBAL = $script:EmptyGitConfig
    $env:GIT_CONFIG_NOSYSTEM = '1'
    # No developer token in the tests, and no test reaches the real gh - Invoke-PhxGh is the one way
    # to it. Get-PhxGhAccount swallows errors, so a leak is also recorded: the last test of this
    # file fails on it.
    $env:GH_TOKEN = $env:GH_ENTERPRISE_TOKEN = $null
    $script:GhLeaks = [Collections.Generic.List[string]]::new()
    Mock Invoke-PhxGh -ModuleName PSPhoenix {
        $script:GhLeaks.Add("gh $($Arguments -join ' ')")
        throw 'a test reached gh - mock Get-PhxGhAccount or Get-PhxGhToken'
    }
    # Nor the Task Scheduler: no task is registered, and registering or removing one is a leak.
    $script:SchedulerLeaks = [Collections.Generic.List[string]]::new()
    Mock Get-PhxScheduledTask -ModuleName PSPhoenix { }
    Mock Register-PhxScheduledTask -ModuleName PSPhoenix { $script:SchedulerLeaks.Add('register'); throw 'a test reached the Task Scheduler' }
    Mock Unregister-PhxScheduledTask -ModuleName PSPhoenix { $script:SchedulerLeaks.Add('unregister'); throw 'a test reached the Task Scheduler' }
    # From here on no test derives anything from the real home - not even a path printed in the
    # help. A test that needs a folder of its own calls Use-TestHome again for its path. (Pester
    # has no root-level BeforeEach.)
    Use-TestHome | Out-Null
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

    It 'help is quoted word for word in the README' {
        # The README quotes `phx help` (task help). Three lines differ per machine or release and
        # are placeholders there: the version, the config path and the module folder.
        $readme = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'README.md') -Raw
        $quoted = [regex]::Match($readme, '(?s)## Help: `phx help`\s*```text\r?\n(.*?)\r?\n```').Groups[1].Value
        $quoted | Should -Not -BeNullOrEmpty
        $normalise = {
            param([string]$Text)
            @($Text.TrimEnd() -split '\r?\n' | ForEach-Object {
                    $_.TrimEnd() -replace '^(phx - PSPhoenix )[^:]+:', '$1<version>:' `
                        -replace '^(  - config: ).*', '$1<config>' `
                        -replace '^(  - module: ).*', '$1<module>'
                }) -join "`n"
        }
        (& $normalise (Get-PhxOutput { phx help })) | Should -Be (& $normalise $quoted)
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
        { phx restore -ErrorAction Stop } | Should -Throw '*not built yet*M6*'
        phx review -ErrorAction SilentlyContinue
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

Describe 'engine' {
    # The C# library in lib/ (engine/ in the repository; its own tests are in engine/tests).
    BeforeAll {
        $script:ModuleDir = Split-Path $script:ModulePath -Parent
        $script:EngineDll = [IO.Path]::GetFullPath((Join-Path $script:ModuleDir 'lib/PSPhoenix.Engine.dll'))
        $script:Engine = [AppDomain]::CurrentDomain.GetAssemblies().Where({ $_.GetName().Name -eq 'PSPhoenix.Engine' }, 'First')[0]
    }

    It 'is loaded from lib in the module folder, from its bytes' {
        $script:Engine | Should -Not -BeNullOrEmpty
        ([AppDomain]::CurrentDomain.GetData('PSPhoenix.Engine') -split ' ', 2)[1] | Should -Be $script:EngineDll
        # Loaded from bytes, the assembly has no file behind it.
        $script:Engine.Location | Should -BeNullOrEmpty
    }

    It 'does not hold the DLL open: an update or a build can replace it while sessions run' {
        $copy = Join-Path (Use-TestHome) 'PSPhoenix'
        Copy-Item -LiteralPath $script:ModuleDir -Destination $copy -Recurse
        $dll = Join-Path $copy 'lib/PSPhoenix.Engine.dll'
        $pwsh = (Get-Process -Id $PID).Path
        # The session that imported the module opens the file exclusively, then deletes it.
        $command = "Import-Module '$copy'; [IO.File]::Open('$dll', 'Open', 'ReadWrite', 'None').Dispose(); Remove-Item -LiteralPath '$dll'; 'replaceable'"
        & $pwsh -NoProfile -NonInteractive -Command $command 2>&1 | Out-String | Should -Match 'replaceable'
    }

    It 'carries the version of the module' {
        # scripts/build.ps1 stamps it: a release ships the engine it tested.
        $version = $script:Engine.GetName().Version
        "$($version.Major).$($version.Minor).$($version.Build)" | Should -Be (Get-Module PSPhoenix).Version.ToString()
    }

    It 'is required: a module folder without it does not import, and says how to build it' {
        $copy = Join-Path (Use-TestHome) 'PSPhoenix'
        Copy-Item -LiteralPath $script:ModuleDir -Destination $copy -Recurse
        Remove-Item -LiteralPath (Join-Path $copy 'lib') -Recurse -Force
        $pwsh = (Get-Process -Id $PID).Path
        $output = & $pwsh -NoProfile -NonInteractive -Command "Import-Module '$copy'" 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0
        $output | Should -Match 'PSPhoenix\.Engine\.dll is missing'
        $output | Should -Match 'task build'
    }

    It 'imports again with the same engine from any folder, and refuses another engine in the same session' {
        # .NET keeps the first engine for the session: another one - an update, another working copy
        # - would run on it. The same engine under another path (a junction, a copy) is fine.
        $root = Use-TestHome
        $same = Join-Path $root 'same/PSPhoenix'
        $other = Join-Path $root 'other/PSPhoenix'
        Copy-Item -LiteralPath $script:ModuleDir -Destination (New-Item -ItemType Directory -Path (Split-Path $same)).FullName -Recurse
        Copy-Item -LiteralPath $script:ModuleDir -Destination (New-Item -ItemType Directory -Path (Split-Path $other)).FullName -Recurse
        [IO.File]::AppendAllText((Join-Path $other 'lib/PSPhoenix.Engine.dll'), 'another build')
        $pwsh = (Get-Process -Id $PID).Path
        $command = "Import-Module '$script:ModulePath'; Import-Module '$script:ModulePath' -Force; Import-Module '$same' -Force; 'again'; Import-Module '$other' -Force"
        $output = & $pwsh -NoProfile -NonInteractive -Command $command 2>&1 | Out-String
        $output | Should -Match 'again'
        $output | Should -Match 'this session runs the PSPhoenix engine from .*another one - start a new PowerShell session'
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

    It 'falls back to the known folders when APPDATA and LOCALAPPDATA are not set' -Skip:(-not $IsWindows) {
        # Only computes the paths; nothing is read or written there.
        Use-TestHome | Out-Null
        $env:APPDATA = $null
        $env:LOCALAPPDATA = $null
        $paths = InModuleScope PSPhoenix { @{ Config = Get-PhxConfigDir; State = Get-PhxStateDir } }
        $paths.Config | Should -Be (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'PSPhoenix')
        $paths.State | Should -Be (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PSPhoenix')
    }

    It 'uses the XDG defaults under HOME when the variables are unset or relative' -Skip:$IsWindows {
        # Only computes the paths; nothing is read or written there.
        Use-TestHome | Out-Null
        $env:XDG_CONFIG_HOME = $null
        $env:XDG_STATE_HOME = 'relative/state'
        $paths = InModuleScope PSPhoenix { @{ Config = Get-PhxConfigDir; State = Get-PhxStateDir } }
        $paths.Config | Should -Be (Join-Path $HOME '.config/psphoenix')
        $paths.State | Should -Be (Join-Path $HOME '.local/state/psphoenix')
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
        # A full path on this platform: C:\Repos is not one on Linux, and a root must be.
        $root = Join-Path $TestDrive 'Repos'
        $config = InModuleScope PSPhoenix -Parameters @{ Root = $root } {
            param($Root)
            $c = Read-PhxConfig
            $c.roots = @(@{ path = $Root; depth = 3 })
            $c.accounts['github.com/WizX20'] = 'WizX20'
            Save-PhxConfig $c
            Read-PhxConfig
        }
        $config.roots[0].path | Should -Be $root
        $config.roots[0].depth | Should -Be 3
        $config.accounts['github.com/WizX20'] | Should -Be 'WizX20'
        $dir = Split-Path (InModuleScope PSPhoenix { Get-PhxConfigPath })
        @(Get-ChildItem -LiteralPath $dir -Force).Name | Should -Be @('config.json')
    }

    It 'overwrites an existing config' {
        Use-TestHome | Out-Null
        $config = InModuleScope PSPhoenix {
            $c = Read-PhxConfig
            Save-PhxConfig $c
            $c.interval = '2h'
            Save-PhxConfig $c
            Read-PhxConfig
        }
        $config.interval | Should -Be '2h'
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

    It 'refuses a config that is <Case>, naming the file' -ForEach @(
        @{ Case = 'empty'; Json = ''; Message = '*is empty*' }
        @{ Case = 'whitespace only'; Json = "  `n "; Message = '*is empty*' }
        @{ Case = 'not JSON'; Json = '{ "version": 1,'; Message = '*is not valid JSON*' }
        @{ Case = 'an array'; Json = '[1, 2]'; Message = '*is not a JSON object*' }
        @{ Case = 'null'; Json = 'null'; Message = '*is not a JSON object*' }
        @{ Case = 'without a version'; Json = '{}'; Message = "*no whole-number 'version'*" }
        @{ Case = 'versioned with a string'; Json = '{ "version": "1" }'; Message = "*no whole-number 'version'*" }
        @{ Case = 'version 0'; Json = '{ "version": 0 }'; Message = '*version 0*' }
        @{ Case = 'newer, spelled Version'; Json = '{ "Version": 99 }'; Message = '*version 99*' }
        @{ Case = 'ambiguous in case'; Json = '{ "version": 1, "interval": "1h", "Interval": "2h" }'; Message = "*duplicate key 'Interval'*" }
    ) {
        Use-TestHome | Out-Null
        InModuleScope PSPhoenix -Parameters @{ Json = $Json; Message = $Message } {
            param($Json, $Message)
            $path = Get-PhxConfigPath
            [IO.Directory]::CreateDirectory((Split-Path $path)) | Out-Null
            [IO.File]::WriteAllText($path, $Json)
            { Read-PhxConfig } | Should -Throw $Message
            { Read-PhxConfig } | Should -Throw "*$path*"
        }
    }

    It 'reads keys in any case, like the defaults' {
        Use-TestHome | Out-Null
        $config = InModuleScope PSPhoenix {
            Save-PhxConfig (New-PhxDefaultConfig)
            Read-PhxConfig
        }
        $config.Files.MaxKB | Should -Be 1024
        $config['INTERVAL'] | Should -Be '1h'
    }

    It 'fills in what an older or hand-written config leaves out' {
        Use-TestHome | Out-Null
        $config = InModuleScope PSPhoenix {
            $path = Get-PhxConfigPath
            [IO.Directory]::CreateDirectory((Split-Path $path)) | Out-Null
            [IO.File]::WriteAllText($path, '{ "Version": 1, "Files": { "MaxKB": 5 }, "providers": { "winget": { "enabled": false } } }')
            Read-PhxConfig
        }
        $config.files.maxKB | Should -Be 5
        $config.files.Contains('repos') | Should -BeTrue
        $config.interval | Should -Be '1h'
        $config.providers.winget.enabled | Should -BeFalse
        # The defaults' spelling and order survive: a save writes 'version', never 'Version'.
        @($config.Keys) | Should -Be @('version', 'roots', 'target', 'machine', 'interval', 'providers', 'accounts', 'secrets', 'files')
    }

    It 'refuses a config whose <Case>' -ForEach @(
        @{ Case = 'interval is no duration'; Json = '{ "version": 1, "interval": "hourly" }'; Message = "*interval 'hourly' must be 15m to 31d*" }
        @{ Case = 'interval is too short'; Json = '{ "version": 1, "interval": "5m" }'; Message = "*interval '5m' must be 15m to 31d*" }
        @{ Case = 'provider settings are no object'; Json = '{ "version": 1, "providers": { "winget": true } }'; Message = '*providers.winget must be an object*' }
        @{ Case = 'provider enabled is no boolean'; Json = '{ "version": 1, "providers": { "winget": { "enabled": "no" } } }'; Message = '*providers.winget.enabled must be true or false*' }
        @{ Case = 'provider cadence is no duration'; Json = '{ "version": 1, "providers": { "winget": { "cadence": "daily" } } }'; Message = "*providers.winget.cadence 'daily' must look like 30m, 1h or 1d*" }
        @{ Case = 'target is a relative path'; Json = '{ "version": 1, "target": { "type": "folder", "path": "Backups" } }'; Message = '*target Backups is not a full path*' }
        @{ Case = 'target is no object'; Json = '{ "version": 1, "target": "D:/Backups" }'; Message = '*target must be an object*' }
        @{ Case = 'secrets recipient is no age recipient'; Json = '{ "version": 1, "secrets": { "recipient": "ssh-ed25519 AAAA" } }'; Message = '*secrets.recipient is not an age recipient*' }
        @{ Case = 'secrets recipient is a secret key'; Json = '{ "version": 1, "secrets": { "recipient": "AGE-SECRET-KEY-1QQQQ" } }'; Message = '*secrets.recipient is the secret half of an age key*' }
    ) {
        Use-TestHome | Out-Null
        InModuleScope PSPhoenix -Parameters @{ Json = $Json } {
            param($Json)
            $path = Get-PhxConfigPath
            [IO.Directory]::CreateDirectory((Split-Path $path)) | Out-Null
            [IO.File]::WriteAllText($path, $Json)
        }
        { InModuleScope PSPhoenix { Read-PhxConfig } } | Should -Throw $Message
    }

    It 'gives a hand-written root without a depth the default, and drops an empty entry' {
        Use-TestHome | Out-Null
        $root = (Join-Path $TestDrive 'hand-written') -replace '\\', '/'
        $roots = InModuleScope PSPhoenix -Parameters @{ Root = $root } {
            param($Root)
            $path = Get-PhxConfigPath
            [IO.Directory]::CreateDirectory((Split-Path $path)) | Out-Null
            [IO.File]::WriteAllText($path, (@{ version = 1; roots = @($null, @{ path = $Root }) } | ConvertTo-Json -Depth 5))
            , @((Read-PhxConfig).roots)
        }
        $roots | Should -HaveCount 1
        $roots[0].depth | Should -Be 3
    }

    It 'refuses a machine name that is no folder name' {
        Use-TestHome | Out-Null
        InModuleScope PSPhoenix {
            $path = Get-PhxConfigPath
            [IO.Directory]::CreateDirectory((Split-Path $path)) | Out-Null
            [IO.File]::WriteAllText($path, '{ "version": 1, "machine": { "name": "..\\elsewhere" } }')
        }
        { InModuleScope PSPhoenix { Read-PhxConfig } } | Should -Throw "*machine name '..\elsewhere' is not a folder name*"
    }

    It 'refuses a hand-written root <Case>' -ForEach @(
        @{ Case = 'with depth 0'; Root = @{ path = 'FULL'; depth = 0 }; Message = '*has depth 0 - a whole number from 1 to 10*' }
        @{ Case = 'with a relative path'; Root = @{ path = 'Repos'; depth = 3 }; Message = '*root Repos is not a full path*' }
        @{ Case = 'without a path'; Root = @{ depth = 3 }; Message = '*every root needs a path*' }
    ) {
        Use-TestHome | Out-Null
        if ($Root.path -eq 'FULL') { $Root.path = Join-Path $TestDrive 'full' }
        InModuleScope PSPhoenix -Parameters @{ Root = $Root } {
            param($Root)
            $path = Get-PhxConfigPath
            [IO.Directory]::CreateDirectory((Split-Path $path)) | Out-Null
            [IO.File]::WriteAllText($path, (@{ version = 1; roots = @($Root) } | ConvertTo-Json -Depth 5))
        }
        { InModuleScope PSPhoenix { Read-PhxConfig } } | Should -Throw $Message
    }
}

Describe 'roots' {
    BeforeEach {
        $testHome = Use-TestHome
        $repos = Join-Path $testHome 'Repos'
        New-Item -ItemType Directory -Path (Join-Path $repos 'App') -Force | Out-Null
    }

    It 'adds a root as a full path with the default depth, and lists it' {
        Get-PhxOutput { phx roots add $repos } | Should -Match 'added root'
        $roots = @(InModuleScope PSPhoenix { Get-PhxRoot })
        $roots.Count | Should -Be 1
        $roots[0].path | Should -Be $repos
        $roots[0].depth | Should -Be 3
        Get-PhxOutput { phx roots list } | Should -Match ([regex]::Escape($repos) + '\s+depth 3')
        Get-PhxOutput { phx roots } | Should -Match 'depth 3'
    }

    It 'changes the depth of an existing root with -Depth' {
        phx roots add $repos 6>$null
        Get-PhxOutput { phx roots add $repos -Depth 6 } | Should -Match 'now has depth 6'
        $roots = @(InModuleScope PSPhoenix { Get-PhxRoot })
        $roots.Count | Should -Be 1
        $roots[0].depth | Should -Be 6
    }

    It "stops a caller's script on a failure when the caller asks for Stop" {
        # A script's $ErrorActionPreference = 'Stop' must reach phx's own errors.
        $pwsh = (Get-Process -Id $PID).Path
        $script = "`$ErrorActionPreference = 'Stop'; Import-Module '$script:ModulePath'; try { phx roots add '$(Join-Path $testHome 'nope')' 6>`$null; 'carried on' } catch { 'stopped' }"
        & $pwsh -NoProfile -NonInteractive -Command $script | Should -Be 'stopped'
    }

    It 'stores -Depth' {
        phx roots add $repos -Depth 5 6>$null
        @(InModuleScope PSPhoenix { Get-PhxRoot })[0].depth | Should -Be 5
    }

    It 'refuses a depth outside 1-10' {
        { phx roots add $repos -Depth 11 6>$null } | Should -Throw '*Depth*'
        { phx roots add $repos -Depth 0 6>$null } | Should -Throw '*Depth*'
    }

    It 'stores a relative path with a trailing separator as a clean full path' {
        Push-Location $testHome
        try { phx roots add ('Repos' + [IO.Path]::DirectorySeparatorChar) 6>$null }
        finally { Pop-Location }
        @(InModuleScope PSPhoenix { Get-PhxRoot })[0].path | Should -Be $repos
    }

    It 'refuses <Case>' -ForEach @(
        @{ Case = 'the same root twice'; Second = { $repos }; Message = '*is a root already*' }
        @{ Case = 'a root inside a root'; Second = { Join-Path $repos 'App' }; Message = '*lies inside the root*' }
        @{ Case = 'a root around a root'; Second = { $testHome }; Message = '*contains the root*' }
        @{ Case = 'a folder that does not exist'; Second = { Join-Path $testHome 'nope' }; Message = '*no such folder*' }
    ) {
        if ($Case -ne 'a folder that does not exist') { phx roots add $repos 6>$null }
        $path = & $Second
        { phx roots add $path -ErrorAction Stop 6>$null } | Should -Throw $Message
    }

    It 'treats the same path in another case as the same root on Windows' -Skip:(-not $IsWindows) {
        phx roots add $repos 6>$null
        { phx roots add $repos.ToUpperInvariant() -ErrorAction Stop 6>$null } | Should -Throw '*is a root already*'
    }

    It 'stores a path typed in another case as the folder spells it, on Windows' -Skip:(-not $IsWindows) {
        phx roots add $repos.ToLowerInvariant() 6>$null
        @(InModuleScope PSPhoenix { Get-PhxRoot })[0].path | Should -BeExactly $repos
    }

    It 'does not take a sibling with a longer name for a root inside it' {
        $sibling = "$repos" + '2'
        New-Item -ItemType Directory -Path $sibling | Out-Null
        phx roots add $repos 6>$null
        phx roots add $sibling 6>$null
        @(InModuleScope PSPhoenix { Get-PhxRoot }).Count | Should -Be 2
    }

    It 'removes a root, also one whose folder is gone' {
        phx roots add $repos 6>$null
        Remove-Item -LiteralPath $repos -Recurse -Force
        Get-PhxOutput { phx roots list } | Should -Match 'folder not found'
        Get-PhxOutput { phx roots rm $repos } | Should -Match 'removed root'
        @(InModuleScope PSPhoenix { Get-PhxRoot }).Count | Should -Be 0
    }

    It 'accepts remove for rm' {
        phx roots add $repos 6>$null
        phx roots remove $repos 6>$null
        @(InModuleScope PSPhoenix { Get-PhxRoot }).Count | Should -Be 0
    }

    It 'says how to start when there are no roots' {
        Get-PhxOutput { phx roots list } | Should -Match 'no roots yet.*phx roots add'
    }

    It 'fails <Case> as an error of phx' -ForEach @(
        @{ Case = 'removing a path that is not a root'; Arguments = { 'roots', 'rm', $repos }; Message = '*is not a root*' }
        @{ Case = 'add without a path'; Arguments = { 'roots', 'add' }; Message = '*usage: phx roots add*' }
        @{ Case = 'rm without a path'; Arguments = { 'roots', 'rm' }; Message = '*usage: phx roots rm*' }
        @{ Case = 'an unknown action'; Arguments = { 'roots', 'frob' }; Message = "*unknown action 'frob'*" }
    ) {
        # Positional values only, so splatting binds them as phx <command> <arg> <arg2>.
        $arguments = @(& $Arguments)
        phx @arguments -ErrorAction SilentlyContinue -ErrorVariable failure 6>$null
        $? | Should -BeFalse
        # -ErrorVariable also collects the throw that phx caught; the record callers see is phx's own.
        $record = $failure | Where-Object FullyQualifiedErrorId -Like 'PhxCommandFailed*' | Select-Object -First 1
        $record | Should -Not -BeNullOrEmpty
        $record.Exception.Message | Should -BeLike $Message
        # Shown as "phx: <message>", not as an exception from inside a helper.
        $record.InvocationInfo.MyCommand.Name | Should -Be 'phx'
    }

    It 'expands ~ and keeps a drive or file-system root whole' {
        InModuleScope PSPhoenix {
            ConvertTo-PhxFullPath '~' | Should -Be ($HOME.TrimEnd('\', '/'))
            ConvertTo-PhxFullPath '~/src' | Should -Be (Join-Path $HOME 'src')
            $driveRoot = [IO.Path]::GetPathRoot($TestDrive)
            ConvertTo-PhxFullPath $driveRoot | Should -Be $driveRoot
        }
    }
}

Describe 'repository identity' {
    It 'reads <Url> as <Identity>' -ForEach @(
        @{ Url = 'https://github.com/WizX20/PSPhoenix.git'; Identity = 'github.com/WizX20/PSPhoenix' }
        @{ Url = 'https://github.com/WizX20/PSPhoenix'; Identity = 'github.com/WizX20/PSPhoenix' }
        @{ Url = 'https://someone@GitHub.com/WizX20/PSPhoenix/'; Identity = 'github.com/WizX20/PSPhoenix' }
        @{ Url = 'git@github.com:WizX20/PSPhoenix.git'; Identity = 'github.com/WizX20/PSPhoenix' }
        @{ Url = 'ssh://git@github.com/WizX20/PSPhoenix.git'; Identity = 'github.com/WizX20/PSPhoenix' }
        @{ Url = 'ssh://git@github.com:22/WizX20/PSPhoenix.git'; Identity = 'github.com/WizX20/PSPhoenix' }
        @{ Url = 'git://github.com/WizX20/PSPhoenix.git'; Identity = 'github.com/WizX20/PSPhoenix' }
        @{ Url = 'https://gitlab.example.com/group/sub/name.git'; Identity = 'gitlab.example.com/group/sub/name' }
        @{ Url = 'https://dev.azure.com/org/My%20Project/_git/repo'; Identity = 'dev.azure.com/org/My Project/repo' }
        @{ Url = 'https://org@dev.azure.com/org/proj/_git/repo'; Identity = 'dev.azure.com/org/proj/repo' }
        @{ Url = 'git@ssh.dev.azure.com:v3/org/proj/repo'; Identity = 'dev.azure.com/org/proj/repo' }
        @{ Url = 'https://org.visualstudio.com/DefaultCollection/proj/_git/repo'; Identity = 'dev.azure.com/org/proj/repo' }
        @{ Url = 'https://org.visualstudio.com/proj/_git/repo'; Identity = 'dev.azure.com/org/proj/repo' }
        @{ Url = 'C:\git\origin.git'; Identity = 'file/C/git/origin' }
        @{ Url = 'file:///C:/git/origin.git'; Identity = 'file/C/git/origin' }
        @{ Url = '\\nas\git\origin.git'; Identity = 'file/nas/git/origin' }
        @{ Url = '/srv/git/origin.git'; Identity = 'file/srv/git/origin' }
    ) {
        InModuleScope PSPhoenix -Parameters @{ Url = $Url } { param($Url) ConvertTo-PhxRepoIdentity -Url $Url } | Should -BeExactly $Identity
    }

    It 'removes credentials from <Url>' -ForEach @(
        @{ Url = 'https://user:secret@github.com/o/r.git'; Clean = 'https://user@github.com/o/r.git' }
        @{ Url = 'https://ghp_abcdefghijklmnopqrstuvwxyz0123456789@github.com/o/r.git'; Clean = 'https://github.com/o/r.git' }
        @{ Url = 'https://org@dev.azure.com/org/p/_git/r'; Clean = 'https://org@dev.azure.com/org/p/_git/r' }
        @{ Url = 'ssh://git@github.com/o/r.git'; Clean = 'ssh://git@github.com/o/r.git' }
        @{ Url = 'git@github.com:o/r.git'; Clean = 'git@github.com:o/r.git' }
    ) {
        InModuleScope PSPhoenix -Parameters @{ Url = $Url } { param($Url) Remove-PhxUrlSecret $Url } | Should -BeExactly $Clean
    }

    It 'recognises secrets by content through one detector, the engine' {
        InModuleScope PSPhoenix {
            # Built at run time: nothing token-like is committed.
            $token = 'gh' + 'p_' + ('d4' * 18)
            Test-PhxSecretText "`$env:GH_TOKEN = '$token'" | Should -BeTrue
            Test-PhxSecretText 'Server=db;Password=Winter2024!;' | Should -BeTrue
            Test-PhxSecretText '"token": "${GITHUB_TOKEN}"' | Should -BeFalse
            $finding = @(Get-PhxSecretFinding "line one`n  `"ClientSecret`": `"Zx9Qw3Er7Ty1Ui5Op2As8Df4`"")[0]
            $finding.Line | Should -Be 2
            $finding.Description | Should -Be 'a secret value (ClientSecret)'
            "$finding" | Should -Not -Match 'Zx9'
            Test-PhxTokenLike ('p' * 52) | Should -BeTrue
            Test-PhxTokenLike 'wouter' | Should -BeFalse
        }
    }

    It 'masks credentials in text such as a git error' {
        InModuleScope PSPhoenix {
            Hide-PhxSecret 'git clone https://user:secret@github.com/o/r.git failed' | Should -Be 'git clone https://user:***@github.com/o/r.git failed'
            Hide-PhxSecret 'remote https://ghp_abcdefghijklmnopqrstuvwxyz0123456789@github.com/o/r' | Should -Be 'remote https://***@github.com/o/r'
            Hide-PhxSecret 'https://org@dev.azure.com/org' | Should -Be 'https://org@dev.azure.com/org'
            # A token on its own, by its prefix (built here, so no token-like text is committed).
            Hide-PhxSecret "gh said $('glpat-' + 'x' * 20) is wrong" | Should -Be 'gh said *** is wrong'
            $failure = { Invoke-PhxGit -Repository $TestDrive -Arguments 'ls-remote', 'https://user:secret@invalid.invalid/x.git' } | Should -Throw -PassThru
            $failure.Exception.Message | Should -Not -Match 'secret'
        }
    }

    It 'tells a link from a folder - a cloud placeholder has no link target' {
        $real = Join-Path $TestDrive 'real-folder'
        $link = Join-Path $TestDrive 'link-folder'
        New-Item -ItemType Directory -Path $real | Out-Null
        New-Item -ItemType ($IsWindows ? 'Junction' : 'SymbolicLink') -Path $link -Target $real | Out-Null
        try {
            InModuleScope PSPhoenix -Parameters @{ Real = $real; Link = $link } {
                param($Real, $Link)
                Test-PhxLinkFolder $Link | Should -BeTrue
                Test-PhxLinkFolder $Real | Should -BeFalse
            }
        }
        finally { (Get-Item -LiteralPath $link -Force).Delete() }
    }

    It 'resolves a relative local remote against the repository' {
        $base = Join-Path $TestDrive 'a/b'
        $identity = InModuleScope PSPhoenix -Parameters @{ Base = $base } { param($Base) ConvertTo-PhxRepoIdentity -Url '../origin.git' -BasePath $Base }
        $identity | Should -BeLike 'file/*/a/origin'
    }
}

Describe 'scan' {
    BeforeEach {
        $testHome = Use-TestHome
        $repos = Join-Path $testHome 'Repos'
        New-Item -ItemType Directory -Path $repos | Out-Null

        function Get-TestScan {
            # Scans and returns the records; the summary goes to $script:ScanOutput.
            $script:ScanOutput = InModuleScope PSPhoenix { Invoke-PhxScan -PassThru } 6>&1
            @($script:ScanOutput | Where-Object { $_ -is [System.Collections.IDictionary] })
        }
    }

    It "finds repositories down to the root's depth, and no deeper" {
        New-TestRepository (Join-Path $repos 'One') -Remote 'origin=https://github.com/o/one.git' | Out-Null
        New-TestRepository (Join-Path $repos 'org/Two') -Remote 'origin=https://github.com/o/two.git' | Out-Null
        New-TestRepository (Join-Path $repos 'a/b/Three') -Remote 'origin=https://github.com/o/three.git' | Out-Null
        New-TestRepository (Join-Path $repos 'a/b/c/Four') -Remote 'origin=https://github.com/o/four.git' | Out-Null
        phx roots add $repos 6>$null
        $records = @(Get-TestScan)
        @($records.identity | Sort-Object) | Should -Be @('github.com/o/one', 'github.com/o/three', 'github.com/o/two')
        ($records | Where-Object identity -EQ 'github.com/o/two').path | Should -Be 'org/Two'
    }

    It 'does not enter a repository: one nested inside it is not found' {
        New-TestRepository (Join-Path $repos 'Outer') -Remote 'origin=https://github.com/o/outer.git' | Out-Null
        New-TestRepository (Join-Path $repos 'Outer/vendor/Inner') -Remote 'origin=https://github.com/o/inner.git' | Out-Null
        phx roots add $repos 6>$null
        @((Get-TestScan).identity) | Should -Be @('github.com/o/outer')
    }

    It 'records a linked worktree on its main repository, not as a repository of its own' {
        $main = New-TestRepository (Join-Path $repos 'Main') -Remote 'origin=https://github.com/o/main.git'
        $worktree = Join-Path $repos 'Main-feature'
        git -C $main worktree add -q $worktree -b feature 2>$null
        # A repository inside the worktree folder: found only if the .git file were not respected.
        New-TestRepository (Join-Path $worktree 'nested') -Remote 'origin=https://github.com/o/nested.git' | Out-Null
        phx roots add $repos 6>$null
        $records = @(Get-TestScan)
        @($records.identity) | Should -Be @('github.com/o/main')
        @($records[0].worktrees).Count | Should -Be 1
        $records[0].worktrees[0].path | Should -Be 'Main-feature'
        $records[0].worktrees[0].branch | Should -Be 'feature'
    }

    It 'skips a submodule and build-output folders' {
        $submodule = Join-Path $repos 'Sub'
        New-Item -ItemType Directory -Path $submodule -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $submodule '.git') -Value 'gitdir: ../App/.git/modules/Sub'
        New-TestRepository (Join-Path $submodule 'nested') -Remote 'origin=https://github.com/o/nested.git' | Out-Null
        New-TestRepository (Join-Path $repos 'web/node_modules/pkg') -Remote 'origin=https://github.com/o/pkg.git' | Out-Null
        New-TestRepository (Join-Path $repos 'Real') -Remote 'origin=https://github.com/o/real.git' | Out-Null
        phx roots add $repos 6>$null
        @((Get-TestScan).identity) | Should -Be @('github.com/o/real')
    }

    It 'does not follow a junction or symbolic link' {
        New-TestRepository (Join-Path $repos 'Real') -Remote 'origin=https://github.com/o/real.git' | Out-Null
        $elsewhere = New-TestRepository (Join-Path $testHome 'Elsewhere') -Remote 'origin=https://github.com/o/elsewhere.git'
        $link = Join-Path $repos 'Link'
        New-Item -ItemType ($IsWindows ? 'Junction' : 'SymbolicLink') -Path $link -Target $elsewhere | Out-Null
        try {
            phx roots add $repos 6>$null
            @((Get-TestScan).identity) | Should -Be @('github.com/o/real')
        }
        finally { (Get-Item -LiteralPath $link -Force).Delete() }
    }

    It 'gives a repository without remotes a local identity, and a local-path remote a file one' {
        New-TestRepository (Join-Path $repos 'Lonely') | Out-Null
        $bare = Join-Path $testHome 'origin.git'
        git init -q --bare $bare
        New-TestRepository (Join-Path $repos 'FromDisk') -Remote "origin=$bare" | Out-Null
        phx roots add $repos 6>$null
        $records = @(Get-TestScan)
        ($records | Where-Object path -EQ 'Lonely').identity | Should -Be 'local/Lonely'
        ($records | Where-Object path -EQ 'FromDisk').identity | Should -BeLike 'file/*/origin'
        $script:ScanOutput -join "`n" | Should -Match '2 repositories, 1 without a remote'
    }

    It 'takes origin, else the first remote' {
        New-TestRepository (Join-Path $repos 'Fork') -Remote 'upstream=https://github.com/up/x.git', 'origin=https://github.com/me/x.git' | Out-Null
        New-TestRepository (Join-Path $repos 'Mirror') -Remote 'upstream=https://github.com/up/y.git', 'backup=https://example.com/b/y.git' | Out-Null
        phx roots add $repos 6>$null
        $records = @(Get-TestScan)
        ($records | Where-Object path -EQ 'Fork').identity | Should -Be 'github.com/me/x'
        ($records | Where-Object path -EQ 'Mirror').identity | Should -Be 'github.com/up/y'
        @(($records | Where-Object path -EQ 'Fork').remotes.Keys) | Should -Be @('upstream', 'origin')
    }

    It 'treats a root that is itself a repository as one repository' {
        $single = New-TestRepository (Join-Path $repos 'Single') -Remote 'origin=https://github.com/o/single.git'
        phx roots add $single 6>$null
        $records = @(Get-TestScan)
        @($records.identity) | Should -Be @('github.com/o/single')
        $records[0].path | Should -Be '.'
    }

    It 'saves the scan and says what is new and what is gone' {
        $one = New-TestRepository (Join-Path $repos 'One') -Remote 'origin=https://github.com/o/one.git'
        New-TestRepository (Join-Path $repos 'Two') -Remote 'origin=https://github.com/o/two.git' | Out-Null
        phx roots add $repos 6>$null
        Get-PhxOutput { phx roots list } | Should -Match 'not scanned yet'
        Get-TestScan | Out-Null
        Test-Path -LiteralPath (Join-Path (InModuleScope PSPhoenix { Get-PhxStateDir }) 'repos.json') | Should -BeTrue
        Get-PhxOutput { phx roots list } | Should -Match '2 repositories'

        Remove-Item -LiteralPath $one -Recurse -Force
        New-TestRepository (Join-Path $repos 'Three') -Remote 'origin=https://github.com/o/three.git' | Out-Null
        $output = Get-PhxOutput { phx scan }
        $output | Should -Match 'new:\s+github.com/o/three'
        $output | Should -Match 'gone:\s+github.com/o/one'
    }

    It 'points out the same remote cloned twice' {
        New-TestRepository (Join-Path $repos 'A') -Remote 'origin=https://github.com/o/same.git' | Out-Null
        New-TestRepository (Join-Path $repos 'B') -Remote 'origin=https://github.com/o/same.git' | Out-Null
        phx roots add $repos 6>$null
        Get-PhxOutput { phx scan } | Should -Match 'github.com/o/same is cloned 2 times'
    }

    It 'keeps the repositories of a root whose folder is gone, marked offline' {
        # An unplugged drive must not make a backup forget what lives on it.
        New-TestRepository (Join-Path $repos 'Away') -Remote 'origin=https://github.com/o/away.git' | Out-Null
        phx roots add $repos 6>$null
        Get-TestScan | Out-Null
        Remove-Item -LiteralPath $repos -Recurse -Force
        $records = @(Get-TestScan)
        $script:ScanOutput -join "`n" | Should -Match 'folder not found - kept 1 repositories from the last scan, marked offline'
        $script:ScanOutput -join "`n" | Should -Match '1 repositories, 1 offline'
        $records[0].identity | Should -Be 'github.com/o/away'
        $records[0].offline | Should -BeTrue
        $script:ScanOutput -join "`n" | Should -Not -Match 'gone:'
    }

    It 'keeps the repositories of a root that turned up empty, marked offline' {
        # Linux keeps an unmounted drive's mount point: an empty folder, not a missing one.
        $away = New-TestRepository (Join-Path $repos 'Away') -Remote 'origin=https://github.com/o/away.git'
        phx roots add $repos 6>$null
        Get-TestScan | Out-Null
        Remove-Item -LiteralPath $away -Recurse -Force
        $records = @(Get-TestScan)
        $script:ScanOutput -join "`n" | Should -Match 'no repositories where the last scan found 1 - kept them, marked offline'
        $records[0].offline | Should -BeTrue
        # Gone for good: removing and adding the root again forgets them. Removing a root trims the
        # last scan without pretending it was a new one.
        $scannedAt = (InModuleScope PSPhoenix { Read-PhxRepoCache }).scannedAt
        phx roots rm $repos 6>$null
        $cache = InModuleScope PSPhoenix { Read-PhxRepoCache }
        @($cache.repositories | Where-Object { $_ }) | Should -HaveCount 0
        $cache.scannedAt | Should -Be $scannedAt
        phx roots add $repos 6>$null
        @(Get-TestScan) | Should -HaveCount 0
    }

    It 'treats owners that differ only in case as the same, as GitHub does' {
        New-TestRepository (Join-Path $repos 'A') -Remote 'origin=https://github.com/WizX20/same.git' | Out-Null
        New-TestRepository (Join-Path $repos 'B') -Remote 'origin=https://github.com/wizx20/same.git' | Out-Null
        phx roots add $repos 6>$null
        InModuleScope PSPhoenix { $c = Read-PhxConfig; $c.accounts['github.com/WizX20'] = 'WizX20'; Save-PhxConfig $c }
        Get-PhxOutput { phx scan } | Should -Match '(?i)github.com/wizx20/same is cloned 2 times'
        $accounts = InModuleScope PSPhoenix {
            $config = Read-PhxConfig
            (Read-PhxRepoCache).repositories | ForEach-Object { Get-PhxRepoAccount -Record $_ -Accounts $config.accounts }
        }
        @($accounts) | Should -Be @('WizX20', 'WizX20')
    }

    It 'reads the branches of a repository on the reftable backend' {
        $remote = Join-Path $testHome 'remote.git'
        git -c init.defaultBranch=main init -q --bare $remote
        $seed = New-TestRepository (Join-Path $testHome 'seed')
        git -C $seed push -q $remote main 2>$null
        git clone -q --ref-format=reftable $remote (Join-Path $repos 'Table') 2>$null
        if ($LASTEXITCODE) { Set-ItResult -Skipped -Because 'this git cannot create a reftable repository (git 2.45+)'; return }
        phx roots add $repos 6>$null
        $record = @(Get-TestScan)[0]
        $record.branch | Should -Be 'main'
        $record.defaultBranch | Should -Be 'main'
    }

    It "keeps a repository's last record when git cannot read it, and says so" {
        $broken = New-TestRepository (Join-Path $repos 'Broken') -Remote 'origin=https://github.com/o/broken.git'
        New-TestRepository (Join-Path $repos 'Fine') -Remote 'origin=https://github.com/o/fine.git' | Out-Null
        phx roots add $repos 6>$null
        Get-TestScan | Out-Null
        Add-Content -LiteralPath (Join-Path $broken '.git/config') -Value '[this is not valid'
        $records = @(Get-TestScan)
        $script:ScanOutput -join "`n" | Should -Match 'skipped .*Broken: git config .* failed.* - kept what the last scan recorded'
        @($records.identity | Sort-Object) | Should -Be @('github.com/o/broken', 'github.com/o/fine')
    }

    It 'does not record a repository git cannot read and never could, and scans the rest' {
        $broken = New-TestRepository (Join-Path $repos 'Broken') -Remote 'origin=https://github.com/o/broken.git'
        New-TestRepository (Join-Path $repos 'Fine') -Remote 'origin=https://github.com/o/fine.git' | Out-Null
        Add-Content -LiteralPath (Join-Path $broken '.git/config') -Value '[this is not valid'
        phx roots add $repos 6>$null
        $records = @(Get-TestScan)
        $script:ScanOutput -join "`n" | Should -Match 'skipped .*Broken: .* - not recorded'
        @($records.identity) | Should -Be @('github.com/o/fine')
    }

    It 'ignores a remote without a URL instead of failing the scan' {
        $odd = New-TestRepository (Join-Path $repos 'Odd')
        git -C $odd config remote.pushonly.pushurl 'https://github.com/o/odd.git'
        New-TestRepository (Join-Path $repos 'Fine') -Remote 'origin=https://github.com/o/fine.git' | Out-Null
        phx roots add $repos 6>$null
        $records = @(Get-TestScan)
        ($records | Where-Object path -EQ 'Odd').identity | Should -Be 'local/Odd'
        @($records).Count | Should -Be 2
    }

    It 'records a remote URL without the credentials in it, and says so' {
        $token = 'ghp_' + ('a1' * 18)
        New-TestRepository (Join-Path $repos 'Tok') -Remote "origin=https://x-access-token:$token@github.com/o/tok.git" | Out-Null
        New-TestRepository (Join-Path $repos 'AsUser') -Remote "origin=https://$token@github.com/o/asuser.git" | Out-Null
        phx roots add $repos 6>$null
        $records = @(Get-TestScan)
        @(($records | Where-Object path -EQ 'Tok').remotes.origin.urls) | Should -Be @('https://x-access-token@github.com/o/tok.git')
        @(($records | Where-Object path -EQ 'AsUser').remotes.origin.urls) | Should -Be @('https://github.com/o/asuser.git')
        $script:ScanOutput -join "`n" | Should -Match 'carries credentials in its URL - recorded without them'
        Get-Content -LiteralPath (Join-Path (InModuleScope PSPhoenix { Get-PhxStateDir }) 'repos.json') -Raw | Should -Not -Match $token
        ($script:ScanOutput -join "`n") | Should -Not -Match $token
    }

    It 'masks a token elsewhere in a remote URL, and keeps the rest of it' {
        $token = 'gl' + 'pat-' + ('c3' * 10)
        New-TestRepository (Join-Path $repos 'Query') -Remote 'origin=https://gitlab.example.invalid/o/query.git', "mirror=https://gitlab.example.invalid/o/query.git?private_token=$token" | Out-Null
        phx roots add $repos 6>$null
        $records = @(Get-TestScan)
        @(($records | Where-Object path -EQ 'Query').remotes.mirror.urls) | Should -Be @('https://gitlab.example.invalid/o/query.git?private_token=***')
        $script:ScanOutput -join "`n" | Should -Match 'remote mirror carries credentials in its URL - recorded without them'
        Get-Content -LiteralPath (Join-Path (InModuleScope PSPhoenix { Get-PhxStateDir }) 'repos.json') -Raw | Should -Not -Match $token
    }

    It 'shows a root added after the last scan as not scanned' {
        New-TestRepository (Join-Path $repos 'One') -Remote 'origin=https://github.com/o/one.git' | Out-Null
        $later = Join-Path $testHome 'Later'
        New-Item -ItemType Directory -Path $later | Out-Null
        phx roots add $repos 6>$null
        Get-TestScan | Out-Null
        phx roots add $later 6>$null
        $output = Get-PhxOutput { phx roots list }
        $output | Should -Match ([regex]::Escape($repos) + '\s+depth 3\s+1 repositories')
        $output | Should -Match ([regex]::Escape($later) + '\s+depth 3\s+not scanned yet')
    }

    It 'keeps non-ASCII paths and URLs intact' {
        $e = [char]0x00E9   # spelled as a char code to keep this file ASCII
        New-TestRepository (Join-Path $repos "Caf$e") -Remote "origin=https://example.com/o/caf$e.git" | Out-Null
        phx roots add $repos 6>$null
        $records = @(Get-TestScan)
        $records[0].identity | Should -BeExactly "example.com/o/caf$e"
        $records[0].path | Should -BeExactly "Caf$e"
    }

    It "reports git's own message when git fails" {
        InModuleScope PSPhoenix -Parameters @{ Folder = $repos } {
            param($Folder)
            { Invoke-PhxGit -Repository $Folder -Arguments 'rev-parse', 'HEAD' } | Should -Throw '*git rev-parse HEAD failed in*not a git repository*'
            Invoke-PhxGit -Repository $Folder -Arguments 'rev-parse', 'HEAD' -AllowFailure | Should -BeNullOrEmpty
        }
    }

    It 'refuses to scan without roots' {
        { phx scan -ErrorAction Stop 6>$null } | Should -Throw '*no roots yet*'
    }

    It 'ignores an unreadable cache and rebuilds it' {
        New-TestRepository (Join-Path $repos 'One') -Remote 'origin=https://github.com/o/one.git' | Out-Null
        phx roots add $repos 6>$null
        $cache = Join-Path (InModuleScope PSPhoenix { Get-PhxStateDir }) 'repos.json'
        New-Item -ItemType Directory -Force -Path (Split-Path $cache) | Out-Null
        Set-Content -LiteralPath $cache -Value '{ not json'
        Get-PhxOutput { phx roots list } | Should -Match 'not scanned yet'
        Get-PhxOutput { phx scan } | Should -Match 'ignoring .*repos.json'
        Get-PhxOutput { phx roots list } | Should -Match '1 repositories'
    }
}

Describe 'repos provider' {
    BeforeAll {
        function script:New-TestRemote {
            # A bare repository with a commit on main and one on each -Branch. Returns its path.
            param([Parameter(Mandatory)][string]$Path, [string[]]$Branch = @())
            git -c init.defaultBranch=main init -q --bare $Path
            $seed = Join-Path $TestDrive ('seed-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            git -c init.defaultBranch=main init -q $seed
            git -C $seed -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m init
            git -C $seed push -q $Path main 2>$null
            foreach ($name in $Branch) {
                git -C $seed switch -q -c $name
                git -C $seed -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m $name
                git -C $seed push -q $Path $name 2>$null
            }
            $Path
        }

        function script:Invoke-ReposBackup {
            InModuleScope PSPhoenix -Parameters @{ Staging = $args[0] } {
                param($Staging)
                Backup-PhxRepos -Context (New-PhxContext -Provider repos -Staging $Staging)
            } 6>&1 | Out-String
        }

        function script:Invoke-ReposRestore {
            # The restore's output as one string. When it fails, the output travels in the error
            # message - the per-repository warnings say why.
            param([string]$Staging, [hashtable]$RootMap = @{}, [string[]]$Select = @(), [switch]$DryRun)
            $lines = [Collections.Generic.List[string]]::new()
            try {
                InModuleScope PSPhoenix -Parameters @{ Staging = $Staging; RootMap = $RootMap; Select = $Select; DryRun = [bool]$DryRun } {
                    param($Staging, $RootMap, $Select, $DryRun)
                    Restore-PhxRepos -Context (New-PhxContext -Provider repos -Staging $Staging -RootMap $RootMap -Select $Select -DryRun:$DryRun)
                } 6>&1 | ForEach-Object { $lines.Add("$_") }
            }
            catch { throw "$($_.Exception.Message)`n$($lines -join "`n")" }
            $lines -join "`n"
        }

        function script:Read-TestInventory {
            param([string]$Staging)
            (Get-Content -LiteralPath (Join-Path $Staging 'repos.json') -Raw | ConvertFrom-Json -AsHashtable).repositories
        }

        $remotes = Join-Path $TestDrive 'remotes'
        $script:RemoteOne = New-TestRemote (Join-Path $remotes 'one.git') -Branch 'feature'
        $script:RemoteUp = New-TestRemote (Join-Path $remotes 'one-upstream.git')
        $script:Helper = '!f() { t=$(gh auth token --user WizX20) || return 1; GH_TOKEN=$t gh auth git-credential "$@"; }; f'
    }

    BeforeEach {
        # Machine A: a clone on a feature branch with a second remote, a push URL and the
        # repo-local identity of a WizX20-style .gitconfig include; and a repository without remotes.
        $machineA = Use-TestHome
        $reposA = Join-Path $machineA 'Repos'
        $one = Join-Path $reposA 'One'
        git clone -q $script:RemoteOne $one 2>$null
        git -C $one switch -q feature 2>$null
        git -C $one remote add upstream $script:RemoteUp
        git -C $one remote set-url --push origin 'https://example.invalid/push/one.git'
        git -C $one config user.name 'Test Person'
        git -C $one config user.email 'person@example.invalid'
        git -C $one config include.path '../.gitconfig'
        git -C $one config core.sshCommand 'ssh -i ~/.ssh/id_test'
        git -C $one config --add credential.https://github.com.helper ''
        git -C $one config --add credential.https://github.com.helper $script:Helper
        New-TestRepository (Join-Path $reposA 'Scratch') | Out-Null
        phx roots add $reposA 6>$null
        phx scan 6>$null
        $snapshot = Join-Path $machineA 'snapshot/repos'
        New-Item -ItemType Directory -Force -Path $snapshot | Out-Null
        # A local remote never needs a token; a call would mean a token went somewhere it should not.
        Mock Get-PhxGhToken { throw 'no token expected' } -ModuleName PSPhoenix
        # Restore asks gh which hosts it is logged in to: nowhere, unless a test says otherwise.
        Mock Get-PhxGhAccount -ModuleName PSPhoenix { }
    }

    It 'records remotes, branches, identity settings and the account' {
        Invoke-ReposBackup $snapshot | Should -Match '2 repositories recorded'
        $inventory = @(Read-TestInventory $snapshot)
        $repo = $inventory | Where-Object path -EQ 'One'
        $repo.identity | Should -BeLike 'file/*/remotes/one'
        $repo.branch | Should -Be 'feature'
        $repo.defaultBranch | Should -Be 'main'
        $repo.primaryRemote | Should -Be 'origin'
        @($repo.remotes.Keys) | Should -Be @('origin', 'upstream')
        @($repo.remotes.origin.pushUrls) | Should -Be @('https://example.invalid/push/one.git')
        @($repo.remotes.origin.urls) | Should -Be @($script:RemoteOne)
        $repo.account | Should -Be 'WizX20'
        $repo.accountSource | Should -Be 'credential helper'
        $helper = @($repo.settings | Where-Object key -EQ 'credential.https://github.com.helper' | ForEach-Object value)
        $helper | Should -Be @('', $script:Helper)
        ($repo.settings | Where-Object key -EQ 'core.sshcommand').value | Should -Be 'ssh -i ~/.ssh/id_test'
        ($inventory | Where-Object path -EQ 'Scratch').identity | Should -Be 'local/Scratch'
    }

    It 'restores into another root: clone, remotes, settings and branch' {
        Invoke-ReposBackup $snapshot | Out-Null
        $machineB = Use-TestHome
        $reposB = Join-Path $machineB 'Repos'
        $output = Invoke-ReposRestore $snapshot -RootMap @{ $reposA = $reposB }
        $output | Should -Match '1 cloned, 0 already in place, 1 skipped, 0 failed'
        $output | Should -Match 'local/Scratch: no remote to clone from'
        $restored = Join-Path $reposB 'One'
        git -C $restored branch --show-current | Should -Be 'feature'
        git -C $restored remote get-url origin | Should -Be $script:RemoteOne
        git -C $restored remote get-url --push origin | Should -Be 'https://example.invalid/push/one.git'
        git -C $restored remote get-url upstream | Should -Be $script:RemoteUp
        git -C $restored config --local user.email | Should -Be 'person@example.invalid'
        git -C $restored config --local include.path | Should -Be '../.gitconfig'
        @(git -C $restored config --local --get-all credential.https://github.com.helper) | Should -Be @('', $script:Helper)
        Should -Invoke Get-PhxGhToken -ModuleName PSPhoenix -Times 0
    }

    It 'restores every recorded setting as it was' {
        git -C $one config user.signingkey 'ssh-ed25519 AAAAtest signing@example.invalid'
        git -C $one config gpg.format ssh
        git -C $one config tag.gpgsign true
        git -C $one config includeIf.gitdir:~/work/.path '~/work.gitconfig'
        Invoke-ReposBackup $snapshot | Out-Null
        $reposB = Join-Path (Use-TestHome) 'Repos'
        Invoke-ReposRestore $snapshot -RootMap @{ $reposA = $reposB } | Out-Null
        # Everything PSPhoenix records - identity settings, every URL - per key, in order.
        $pattern = InModuleScope PSPhoenix { $script:PhxRepoSettingPattern }
        $recorded = {
            param($Path)
            @(git -C $Path config --local --list) | Where-Object {
                $key = ($_ -split '=', 2)[0]
                $key -match $pattern -or $key -match '^remote\.[^.]+\.(url|pushurl)$'
            } | Sort-Object -Stable { ($_ -split '=', 2)[0] }
        }
        $expected = @(& $recorded $one)
        $expected.Count | Should -BeGreaterThan 10
        @(& $recorded (Join-Path $reposB 'One')) | Should -Be $expected
    }

    It 'leaves the checked-out branch of a repository in place alone' {
        Invoke-ReposBackup $snapshot | Out-Null
        git -C $one switch -q main
        Invoke-ReposRestore $snapshot | Should -Match '0 cloned, 2 already in place'
        git -C $one branch --show-current | Should -Be 'main'
    }

    It 'records linked worktrees inside and outside the root, detached ones too, and only lists them on restore' {
        git -C $one worktree add -q -b wt-branch (Join-Path $reposA 'One-wt') 2>$null
        $outside = Join-Path $machineA 'elsewhere/wt'
        git -C $one worktree add -q --detach $outside 2>$null
        phx scan 6>$null
        Invoke-ReposBackup $snapshot | Should -Match '2 repositories recorded'
        $worktrees = @((Read-TestInventory $snapshot | Where-Object path -EQ 'One').worktrees)
        $worktrees | Should -HaveCount 2
        ($worktrees | Where-Object path -EQ 'One-wt').branch | Should -Be 'wt-branch'
        $detached = $worktrees | Where-Object path -NE 'One-wt'
        $detached.path | Should -Be ([IO.Path]::GetFullPath($outside))
        $detached.branch | Should -BeNullOrEmpty
        $output = Invoke-ReposRestore $snapshot -RootMap @{ $reposA = (Join-Path (Use-TestHome) 'Repos') }
        $output | Should -Match 'worktree One-wt \(wt-branch\) is not recreated'
        $output | Should -Match ('worktree ' + [regex]::Escape([IO.Path]::GetFullPath($outside)) + ' \(detached\) is not recreated')
    }

    It 'changes nothing on a second restore' {
        Invoke-ReposBackup $snapshot | Out-Null
        $reposB = Join-Path (Use-TestHome) 'Repos'
        Invoke-ReposRestore $snapshot -RootMap @{ $reposA = $reposB } | Out-Null
        $before = git -C (Join-Path $reposB 'One') config --local --list
        Invoke-ReposRestore $snapshot -RootMap @{ $reposA = $reposB } | Should -Match '0 cloned, 1 already in place, 1 skipped, 0 failed'
        git -C (Join-Path $reposB 'One') config --local --list | Should -Be $before
    }

    It "re-applies the recorded settings to a repository that is already there" {
        Invoke-ReposBackup $snapshot | Out-Null
        git -C $one config user.email 'someone-else@example.invalid'
        git -C $one remote remove upstream
        Invoke-ReposRestore $snapshot | Should -Match '0 cloned, 2 already in place, 0 skipped, 0 failed'
        git -C $one config --local user.email | Should -Be 'person@example.invalid'
        git -C $one remote get-url upstream | Should -Be $script:RemoteUp
    }

    It "gives a clone from <HostName> <Account>'s token in <Variable>, and puts the old value back" -ForEach @(
        @{ Account = 'WorkAccount'; HostName = 'github.com'; Variable = 'GH_TOKEN'; Other = 'GH_ENTERPRISE_TOKEN' }
        @{ Account = 'EnterpriseUser'; HostName = 'ghe.example.com'; Variable = 'GH_ENTERPRISE_TOKEN'; Other = 'GH_TOKEN' }
        # GitHub Enterprise Cloud with data residency: gh reads GH_TOKEN there, as for github.com.
        @{ Account = 'CloudUser'; HostName = 'acme.ghe.com'; Variable = 'GH_TOKEN'; Other = 'GH_ENTERPRISE_TOKEN' }
    ) {
        # Both variables set here: what the case before this one left must not decide the outcome.
        [Environment]::SetEnvironmentVariable($Other, $null)
        [Environment]::SetEnvironmentVariable($Variable, 'was-set-before')
        try {
            $seen = InModuleScope PSPhoenix -Parameters @{ Account = $Account; HostName = $HostName; Variable = $Variable; Other = $Other; Target = (Join-Path $TestDrive "clone-$Variable/tok") } {
                param($Account, $HostName, $Variable, $Other, $Target)
                $script:TestSeen = $null
                $script:TestVariables = $Variable, $Other
                Mock Get-PhxGhToken { "token-for-$Account" }
                # What git would get: its arguments and the environment of that moment.
                Mock Invoke-PhxGit {
                    $script:TestSeen = @{
                        Arguments = $Arguments
                        Token     = [Environment]::GetEnvironmentVariable($script:TestVariables[0])
                        Other     = [Environment]::GetEnvironmentVariable($script:TestVariables[1])
                    }
                }
                Invoke-PhxClone -Url "https://$HostName/o/tok.git" -Target $Target -RemoteName origin -Account $Account -TokenHosts 'github.com', 'ghe.example.com', 'acme.ghe.com'
                Should -Invoke Get-PhxGhToken -Times 1 -Exactly
                $script:TestSeen
            }
            [Environment]::GetEnvironmentVariable($Variable) | Should -Be 'was-set-before'
        }
        finally { [Environment]::SetEnvironmentVariable($Variable, $null) }
        $seen.Token | Should -Be "token-for-$Account"
        $seen.Other | Should -BeNullOrEmpty
        $arguments = $seen.Arguments -join ' '
        $arguments | Should -BeLike '-c credential.helper= -c credential.helper=!gh auth git-credential clone --quiet --origin origin -- https://*/o/tok.git *'
    }

    It 'gives the clone the recorded SSH command and credential settings, before the fetch' {
        $arguments = InModuleScope PSPhoenix -Parameters @{ Target = (Join-Path $TestDrive 'clone-ssh/x') } {
            param($Target)
            $script:TestArguments = $null
            Mock Invoke-PhxGit { $script:TestArguments = $Arguments }
            $settings = @(
                @{ key = 'user.email'; value = 'me@example.invalid' }
                @{ key = 'core.sshcommand'; value = 'ssh -i ~/.ssh/id_work' }
                @{ key = 'credential.https://dev.azure.com.usehttppath'; value = $null }
            )
            Invoke-PhxClone -Url 'git@github.com:o/r.git' -Target $Target -RemoteName origin -Settings $settings
            $script:TestArguments
        }
        $arguments -join ' ' | Should -BeLike 'clone --quiet --origin origin --config core.sshcommand=ssh -i ~/.ssh/id_work --config credential.https://dev.azure.com.usehttppath=true -- git@github.com:o/r.git *'
    }

    It 'asks no token for a host gh is not logged in to, nor for a repository without an account' {
        $calls = InModuleScope PSPhoenix -Parameters @{ Target = (Join-Path $TestDrive 'clone-plain/x') } {
            param($Target)
            $script:TestCalls = [Collections.Generic.List[string]]::new()
            Mock Get-PhxGhToken { 'unexpected' }
            Mock Invoke-PhxGit { $script:TestCalls.Add($Arguments -join ' ') }
            Invoke-PhxClone -Url 'https://dev.azure.com/org/proj/_git/ado' -Target $Target -RemoteName origin -Account 'Someone' -TokenHosts 'github.com'
            Invoke-PhxClone -Url 'https://github.com/o/r.git' -Target $Target -RemoteName origin -TokenHosts 'github.com'
            Should -Invoke Get-PhxGhToken -Times 0
            $script:TestCalls
        }
        $calls | Should -HaveCount 2
        $calls | ForEach-Object { $_ | Should -Not -Match 'credential.helper' }
    }

    It 'restores with the account the inventory names, and the hosts gh is logged in to' {
        New-TestRepository (Join-Path $reposA 'Tok') -Remote 'origin=https://github.com/o/tok.git' | Out-Null
        InModuleScope PSPhoenix { $c = Read-PhxConfig; $c.accounts['github.com/o'] = 'WorkAccount'; Save-PhxConfig $c }
        phx scan 6>$null
        Invoke-ReposBackup $snapshot | Out-Null
        Mock Get-PhxGhAccount -ModuleName PSPhoenix { [pscustomobject]@{ Host = 'ghe.example.com'; Login = 'EnterpriseUser'; Active = $true } }
        $script:CloneCall = $null
        Mock Invoke-PhxClone -ModuleName PSPhoenix {
            $script:CloneCall = @{ Url = $Url; Account = $Account; TokenHosts = $TokenHosts; RemoteName = $RemoteName }
            git clone -q $script:RemoteOne $Target 2>$null
        }
        $reposB = Join-Path (Use-TestHome) 'Repos'
        Invoke-ReposRestore $snapshot -RootMap @{ $reposA = $reposB } -Select 'github.com/o/tok' | Should -Match 'cloning github.com/o/tok .* as WorkAccount'
        $script:CloneCall.Url | Should -Be 'https://github.com/o/tok.git'
        $script:CloneCall.Account | Should -Be 'WorkAccount'
        $script:CloneCall.RemoteName | Should -Be 'origin'
        @($script:CloneCall.TokenHosts) | Should -Be @('github.com', 'ghe.example.com')
    }

    It 'restores a lone empty value, a value-less key, a value with a newline and every URL' {
        git -C $one config --unset-all credential.https://github.com.helper
        git -C $one config --add credential.https://github.com.helper ''
        Add-Content -LiteralPath (Join-Path $one '.git/config') -Value "[commit]`n`tgpgsign"
        git -C $one config user.name "Two`nLines"
        git -C $one config --add remote.origin.url 'https://example.invalid/mirror/one.git'
        Invoke-ReposBackup $snapshot | Out-Null
        $repo = Read-TestInventory $snapshot | Where-Object path -EQ 'One'
        ($repo.settings | Where-Object key -EQ 'commit.gpgsign').value | Should -BeNullOrEmpty
        ($repo.settings | Where-Object key -EQ 'user.name').value | Should -Be "Two`nLines"
        $reposB = Join-Path (Use-TestHome) 'Repos'
        Invoke-ReposRestore $snapshot -RootMap @{ $reposA = $reposB } | Out-Null
        $restored = Join-Path $reposB 'One'
        @(git -C $restored config --local --get-all credential.https://github.com.helper) | Should -Be @('')
        git -C $restored config --local --type=bool commit.gpgsign | Should -Be 'true'
        (git -C $restored config --local user.name) -join "`n" | Should -Be "Two`nLines"
        @(git -C $restored config --local --get-all remote.origin.url) | Should -Be @($script:RemoteOne, 'https://example.invalid/mirror/one.git')
        # And a second restore finds nothing to change.
        $before = git -C $restored config --local --list
        Invoke-ReposRestore $snapshot -RootMap @{ $reposA = $reposB } | Out-Null
        git -C $restored config --local --list | Should -Be $before
    }

    It 'finds a remote-less repository below the first level in place' {
        New-TestRepository (Join-Path $reposA 'org/Scratch2') | Out-Null
        phx scan 6>$null
        Invoke-ReposBackup $snapshot | Out-Null
        Invoke-ReposRestore $snapshot -Select 'local/org/Scratch2' | Should -Match '0 cloned, 1 already in place, 0 skipped'
    }

    It 'restores a root that is itself a repository' {
        $single = Join-Path $machineA 'Single'
        git clone -q $script:RemoteOne $single 2>$null
        phx roots add $single 6>$null
        phx scan 6>$null
        Invoke-ReposBackup $snapshot | Out-Null
        $newSingle = Join-Path (Use-TestHome) 'Single'
        Invoke-ReposRestore $snapshot -RootMap @{ $single = $newSingle } -Select ((Read-TestInventory $snapshot | Where-Object path -EQ '.').identity) | Out-Null
        Test-Path -LiteralPath (Join-Path $newSingle '.git') | Should -BeTrue
    }

    It 'skips a root that is not a path on this machine unless it is mapped' {
        $foreign = if ($IsWindows) { '/home/someone/src' } else { 'C:\Repos' }
        $inventory = @{ format = 1; repositories = @(@{ identity = 'github.com/o/x'; root = $foreign; path = 'x'; remotes = @{ origin = @{ urls = @('https://github.com/o/x.git'); pushUrls = @() } }; primaryRemote = 'origin'; settings = @() }) }
        Set-Content -LiteralPath (Join-Path $snapshot 'repos.json') -Value ($inventory | ConvertTo-Json -Depth 10)
        Invoke-ReposRestore $snapshot | Should -Match "github.com/o/x: its root .* is not a path on this machine - map it"
    }

    It 'refuses a tampered inventory: <Case>' -ForEach @(
        @{ Case = 'a setting PSPhoenix does not record'; Tamper = { param($r) $r.settings += @{ key = 'core.hooksPath'; value = 'C:/evil' } }; InPlace = $false; Message = '*core.hooksPath is not a setting PSPhoenix records*' }
        @{ Case = 'a path out of the root'; Tamper = { param($r) $r.path = '../../escaped' }; InPlace = $false; Message = '*leads out of the root*' }
        @{ Case = 'a full path'; Tamper = { param($r) $r.path = (Join-Path $TestDrive 'full-path') }; InPlace = $false; Message = '*is not relative to its root*' }
        @{ Case = 'a URL that reads as an option'; Tamper = { param($r) $r.remotes.upstream.urls = @('--upload-pack=touch pwned') }; InPlace = $true; Message = "*has a URL starting with '-'*" }
    ) {
        Invoke-ReposBackup $snapshot | Out-Null
        $file = Join-Path $snapshot 'repos.json'
        $document = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
        & $Tamper ($document.repositories | Where-Object identity -NotLike 'local/*')
        Set-Content -LiteralPath $file -Value ($document | ConvertTo-Json -Depth 10)
        $reposB = if ($InPlace) { $reposA } else { Join-Path (Use-TestHome) 'Repos' }
        { Invoke-ReposRestore $snapshot -RootMap @{ $reposA = $reposB } } | Should -Throw $Message
        if (-not $InPlace) {
            git -C (Join-Path $reposB 'One') config --local core.hooksPath 2>$null | Should -BeNullOrEmpty
            Test-Path -LiteralPath ([IO.Path]::GetFullPath((Join-Path $reposB '../../escaped'))) | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $TestDrive 'full-path') | Should -BeFalse
        }
        @(git -C $one remote get-url --all upstream) | Should -Be @($script:RemoteUp)
    }

    It 'records from the last scan what this run cannot read: an offline root, an unreadable repository' {
        $broken = New-TestRepository (Join-Path $reposA 'Broken') -Remote 'origin=https://github.com/o/broken.git'
        phx scan 6>$null
        Add-Content -LiteralPath (Join-Path $broken '.git/config') -Value '[not valid'
        Invoke-ReposBackup $snapshot | Should -Match 'could not read .*Broken.* - recorded from the last scan'
        (Read-TestInventory $snapshot | Where-Object path -EQ 'Broken').fromScan | Should -Be 'unreadable'

        $offlineRoot = Join-Path $machineA 'Usb'
        $awayRepo = New-TestRepository (Join-Path $offlineRoot 'Away') -Remote 'origin=https://github.com/o/away.git'
        git -C $awayRepo config user.email 'away@example.invalid'
        git -C $awayRepo remote set-url --push origin 'https://github.com/o/away-push.git'
        phx roots add $offlineRoot 6>$null
        phx scan 6>$null
        Remove-Item -LiteralPath $offlineRoot -Recurse -Force
        phx scan 6>$null
        Invoke-ReposBackup $snapshot | Should -Match 'offline - recorded from the last scan'
        $away = Read-TestInventory $snapshot | Where-Object identity -EQ 'github.com/o/away'
        $away.fromScan | Should -Be 'offline'
        # In full, as the scan saw it: a snapshot written while the drive is out loses nothing.
        @($away.remotes.origin.urls) | Should -Be @('https://github.com/o/away.git')
        @($away.remotes.origin.pushUrls) | Should -Be @('https://github.com/o/away-push.git')
        $away.branch | Should -Be 'main'
        ($away.settings | Where-Object key -EQ 'user.email').value | Should -Be 'away@example.invalid'
    }

    It 'scans a configured root the last scan did not cover before it backs up' {
        $later = Join-Path $machineA 'Later'
        New-TestRepository (Join-Path $later 'New') -Remote 'origin=https://github.com/o/new.git' | Out-Null
        phx roots add $later 6>$null
        Invoke-ReposBackup $snapshot | Should -Match ('not scanned yet: ' + [regex]::Escape($later) + ' - scanning the roots first')
        @(Read-TestInventory $snapshot).identity | Should -Contain 'github.com/o/new'
    }

    It 'scans only in memory on a -DryRun backup without a scan' {
        $cachePath = InModuleScope PSPhoenix { Get-PhxRepoCachePath }
        Remove-Item -LiteralPath $cachePath
        InModuleScope PSPhoenix -Parameters @{ Staging = $snapshot } {
            param($Staging)
            Backup-PhxRepos -Context (New-PhxContext -Provider repos -Staging $Staging -DryRun)
        } 6>&1 | Out-String | Should -Match 'would record 2 repositories'
        Test-Path -LiteralPath $cachePath | Should -BeFalse
    }

    It 'warns about a file a repository includes from outside its work tree' {
        $external = Join-Path $machineA 'work.gitconfig'
        Set-Content -LiteralPath $external -Value "[user]`n`temail = work@example.invalid"
        git -C $one config --add include.path ($external -replace '\\', '/')
        phx scan 6>$null
        $record = InModuleScope PSPhoenix { (Read-PhxRepoCache).repositories } | Where-Object path -EQ 'One'
        @($record.externalIncludes) | Should -Be @([IO.Path]::GetFullPath($external))
        Invoke-ReposBackup $snapshot | Should -Match ('One: includes ' + [regex]::Escape([IO.Path]::GetFullPath($external)) + ' from outside the repository')
    }

    It 'keeps the credentials of a remote in place that the snapshot records without them' {
        git -C $one remote set-url upstream 'https://x-access-token:tok-123@example.invalid/up.git'
        Invoke-ReposBackup $snapshot | Out-Null
        @((Read-TestInventory $snapshot | Where-Object path -EQ 'One').remotes.upstream.urls) | Should -Be @('https://x-access-token@example.invalid/up.git')
        Invoke-ReposRestore $snapshot | Should -Match '0 cloned, 2 already in place'
        git -C $one remote get-url upstream | Should -Be 'https://x-access-token:tok-123@example.invalid/up.git'
    }

    It 'records only the repositories under the configured roots' {
        phx roots rm $reposA 6>$null
        $other = Join-Path $machineA 'Other'
        New-TestRepository (Join-Path $other 'Elsewhere') -Remote 'origin=https://github.com/o/elsewhere.git' | Out-Null
        phx roots add $other 6>$null
        # The cache still holds reposA's repositories, which no longer count; Other it has not seen.
        Invoke-ReposBackup $snapshot | Should -Match '1 repositories recorded'
        @(Read-TestInventory $snapshot).identity | Should -Be @('github.com/o/elsewhere')
    }

    It 'reads <Helper> as the account <Account>' -ForEach @(
        @{ Helper = '!gh auth token --user WizX20'; Account = 'WizX20' }
        @{ Helper = '!gh auth token -u WizX20'; Account = 'WizX20' }
        @{ Helper = '!gh auth token --user=WizX20'; Account = 'WizX20' }
        @{ Helper = '!f() { t=$(gh auth token --user "Work-Acct") || return 1; }; f'; Account = 'Work-Acct' }
        @{ Helper = 'manager'; Account = $null }
        @{ Helper = '!"C:/Program Files/GitHub CLI/gh.exe" auth token --user WizX20'; Account = 'WizX20' }
        @{ Helper = '!f() { my-tool --user alice; }; f'; Account = $null }
    ) {
        InModuleScope PSPhoenix -Parameters @{ Helper = $Helper } {
            param($Helper)
            Get-PhxCredentialAccount @(@{ key = 'credential.helper'; value = $Helper })
        } | Should -Be $Account
    }

    It 'does not record a credential setting that <Case>' -ForEach @(
        # Token-like values are built at run time: nothing token-like is committed.
        @{ Case = 'writes out a password'; Key = 'credential.https://example.invalid.helper'; Value = '!f() { echo password=hunter2; }; f'; Secret = 'hunter2'; Reason = 'holds a password (password)' }
        @{ Case = 'holds a GitLab token'; Key = 'credential.https://gitlab.example.invalid.helper'; Value = "!f() { echo username=x; echo secret=$('glpat-' + 'q' * 20); }; f"; Secret = 'glpat-qqqq'; Reason = 'holds a GitLab token' }
        @{ Case = 'has an Azure DevOps PAT as user name'; Key = 'credential.https://dev.azure.com.username'; Value = ('p' * 52); Secret = ('p' * 52); Reason = 'has a token as its user name' }
        @{ Case = 'is scoped to a URL with a token in it'; Key = "credential.https://x:$('glpat-' + 'r' * 20)@gitlab.example.invalid.helper"; Value = 'store'; Secret = 'glpat-rrrr'; Reason = 'carries credentials in its URL' }
        @{ Case = 'is no credential setting but holds a token'; Key = 'core.sshcommand'; Value = "ssh -o SetEnv=GH_TOKEN=$('gh' + 'p_' + 'b2' * 18)"; Secret = 'b2b2b2'; Reason = 'core.sshcommand holds a GitHub token' }
    ) {
        git -C $one config --add $Key $Value
        phx scan 6>$null
        $output = Invoke-ReposBackup $snapshot
        $output | Should -Match ([regex]::Escape($Reason) + ' - not recorded')
        $output | Should -Not -Match ([regex]::Escape($Secret))
        Get-Content -LiteralPath (Join-Path $snapshot 'repos.json') -Raw | Should -Not -Match ([regex]::Escape($Secret))
        Get-Content -LiteralPath (InModuleScope PSPhoenix { Get-PhxRepoCachePath }) -Raw | Should -Not -Match ([regex]::Escape($Secret))
    }

    It 'leaves a path alone that holds <Case>' -ForEach @(
        @{ Case = 'another repository'; Make = { param($Path) New-TestRepository $Path -Remote 'origin=https://github.com/x/other.git' | Out-Null }; Message = 'holds github.com/x/other' }
        @{ Case = 'other files'; Make = { param($Path) New-Item -ItemType Directory -Force -Path $Path | Out-Null; Set-Content (Join-Path $Path 'notes.txt') 'x' }; Message = 'exists and is not a repository' }
    ) {
        Invoke-ReposBackup $snapshot | Out-Null
        $reposB = Join-Path (Use-TestHome) 'Repos'
        & $Make (Join-Path $reposB 'One')
        Invoke-ReposRestore $snapshot -RootMap @{ $reposA = $reposB } | Should -Match $Message
    }

    It 'restores only the selected repositories, and nothing with -DryRun' {
        Invoke-ReposBackup $snapshot | Out-Null
        $reposB = Join-Path (Use-TestHome) 'Repos'
        $identity = (Read-TestInventory $snapshot | Where-Object path -EQ 'One').identity
        Invoke-ReposRestore $snapshot -RootMap @{ $reposA = $reposB } -Select $identity -DryRun | Should -Match "would clone .* -> $([regex]::Escape((Join-Path $reposB 'One')))"
        Test-Path -LiteralPath $reposB | Should -BeFalse
        Invoke-ReposRestore $snapshot -RootMap @{ $reposA = $reposB } -Select 'local/Scratch' | Should -Match '0 cloned, 0 already in place, 1 skipped, 0 failed'
    }

    It 'says when the recorded branch is not on the remote' {
        git -C $one switch -q -c only-here 2>$null
        Invoke-ReposBackup $snapshot | Out-Null
        $reposB = Join-Path (Use-TestHome) 'Repos'
        Invoke-ReposRestore $snapshot -RootMap @{ $reposA = $reposB } | Should -Match 'branch only-here is not on origin'
        git -C (Join-Path $reposB 'One') branch --show-current | Should -Be 'main'
    }

    It "takes the account from an included .gitconfig, without copying the included settings" {
        # The WizX20 set-up: the helper lives in a .gitconfig tracked in the repository and pulled
        # in by include.path; the clone brings that file back, so only include.path is re-applied.
        $inc = New-TestRepository (Join-Path $reposA 'Included') -Remote 'origin=https://github.com/o/inc.git'
        Set-Content -LiteralPath (Join-Path $inc '.gitconfig') -Value @(
            '[user]', '    name = Included Person',
            '[credential "https://github.com"]', '    helper =', "    helper = `"$($script:Helper)`"")
        git -C $inc config include.path '../.gitconfig'
        phx scan 6>$null
        Invoke-ReposBackup $snapshot | Out-Null
        $repo = Read-TestInventory $snapshot | Where-Object path -EQ 'Included'
        $repo.account | Should -Be 'WizX20'
        $repo.accountSource | Should -Be 'credential helper'
        @($repo.settings.key) | Should -Be @('include.path')
        (InModuleScope PSPhoenix { Read-PhxRepoCache }).repositories | Where-Object path -EQ 'Included' | ForEach-Object helperAccount | Should -Be 'WizX20'
    }

    It 'keeps going when one repository cannot be cloned, and fails at the end' {
        New-TestRepository (Join-Path $reposA 'Locked') -Remote 'origin=https://github.com/o/locked.git' | Out-Null
        InModuleScope PSPhoenix { $c = Read-PhxConfig; $c.accounts['github.com/o'] = 'Missing'; Save-PhxConfig $c }
        phx scan 6>$null
        Invoke-ReposBackup $snapshot | Out-Null
        Mock Get-PhxGhToken { throw 'gh has no token for Missing on github.com - run: gh auth login' } -ModuleName PSPhoenix
        $env:GH_TOKEN = 'left-alone'
        try {
            $reposB = Join-Path (Use-TestHome) 'Repos'
            { Invoke-ReposRestore $snapshot -RootMap @{ $reposA = $reposB } -ErrorAction Stop } | Should -Throw '*1 repositories could not be restored*'
            $env:GH_TOKEN | Should -Be 'left-alone'
        }
        finally { $env:GH_TOKEN = $null }
        Test-Path -LiteralPath (Join-Path $reposB 'One/.git') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $reposB 'Locked') | Should -BeFalse
    }

    It 'flags LFS and submodules' {
        Set-Content -LiteralPath (Join-Path $one '.gitattributes') -Value '*.psd filter=lfs diff=lfs merge=lfs -text'
        Set-Content -LiteralPath (Join-Path $one '.gitmodules') -Value '[submodule "lib"]'
        Invoke-ReposBackup $snapshot | Out-Null
        $repo = Read-TestInventory $snapshot | Where-Object path -EQ 'One'
        $repo.lfs | Should -BeTrue
        $repo.submodules | Should -BeTrue
        (Read-TestInventory $snapshot | Where-Object path -EQ 'Scratch').lfs | Should -BeFalse
    }

    It 'writes nothing on a -DryRun backup' {
        InModuleScope PSPhoenix -Parameters @{ Staging = $snapshot } {
            param($Staging)
            Backup-PhxRepos -Context (New-PhxContext -Provider repos -Staging $Staging -DryRun)
        } 6>&1 | Out-String | Should -Match 'would record 2 repositories'
        Test-Path -LiteralPath (Join-Path $snapshot 'repos.json') | Should -BeFalse
    }

    It 'does not record a repository gone since the last scan' {
        Remove-Item -LiteralPath (Join-Path $reposA 'Scratch') -Recurse -Force
        Invoke-ReposBackup $snapshot | Should -Match 'gone since the last scan'
        @(Read-TestInventory $snapshot).Count | Should -Be 1
    }

    It 'scans first when there is no scan yet' {
        Remove-Item -LiteralPath (Join-Path (InModuleScope PSPhoenix { Get-PhxStateDir }) 'repos.json')
        Invoke-ReposBackup $snapshot | Should -Match 'no scan yet - scanning'
        @(Read-TestInventory $snapshot).Count | Should -Be 2
    }

    It 'refuses an inventory from a newer PSPhoenix' {
        New-Item -ItemType Directory -Force -Path $snapshot | Out-Null
        Set-Content -LiteralPath (Join-Path $snapshot 'repos.json') -Value '{ "format": 99, "repositories": [] }'
        { Invoke-ReposRestore $snapshot } | Should -Throw '*newer PSPhoenix*'
    }

    It 'is a registered provider with status lines per account' {
        # One (a local file/ remote) needs no account; the GitHub ones do.
        New-TestRepository (Join-Path $reposA 'Mine') -Remote 'origin=https://github.com/WizX20/mine.git' | Out-Null
        New-TestRepository (Join-Path $reposA 'Work') -Remote 'origin=https://github.com/summitnl/work.git' | Out-Null
        InModuleScope PSPhoenix { $c = Read-PhxConfig; $c.accounts['github.com/WizX20'] = 'WizX20'; Save-PhxConfig $c }
        phx scan 6>$null
        Get-PhxOutput { phx providers } | Should -Match 'repos\s+Repositories'
        $lines = @(InModuleScope PSPhoenix { & (Get-PhxProvider 'repos').Status (New-PhxContext -Provider repos -Staging $TestDrive) })
        $lines[0] | Should -Be '4 repositories, 1 without a remote'
        $lines | Should -Contain '  WizX20: 1'
        $lines | Should -Contain '  (host default): 1'
    }
}

Describe 'init' {
    BeforeAll {
        function script:Set-TestAnswer {
            # The answers the next phx init gets, in order; '' is Enter (the default).
            foreach ($answer in $args) { $script:Answers.Enqueue([string]$answer) }
        }
        function script:Read-TestConfig { Get-Content -LiteralPath (InModuleScope PSPhoenix { Get-PhxConfigPath }) -Raw }
        # The key step has a Describe of its own ('init secrets'); here it answers itself.
        $script:TestRecipient = [PSPhoenix.Engine.Age]::NewKey().Recipient
    }

    BeforeEach {
        $testHome = Use-TestHome
        $script:InitWork = Join-Path $testHome 'Work'
        $script:InitOther = Join-Path $testHome 'Other'
        New-TestRepository (Join-Path $script:InitWork 'Personal') -Remote 'origin=https://github.com/WizX20/personal.git' | Out-Null
        $helped = New-TestRepository (Join-Path $script:InitWork 'Helped') -Remote 'origin=https://github.com/WizX20/helped.git'
        git -C $helped config --add credential.https://github.com.helper ''
        git -C $helped config --add credential.https://github.com.helper '!f() { gh auth token --user WizX20; }; f'
        New-TestRepository (Join-Path $script:InitWork 'Company') -Remote 'origin=https://github.com/summitnl/app.git' | Out-Null
        New-TestRepository (Join-Path $script:InitOther 'Lab') -Remote 'origin=https://dev.azure.com/org/proj/_git/lab' | Out-Null
        $script:InitEmpty = Join-Path $testHome 'NoRepos'
        New-Item -ItemType Directory -Path $script:InitEmpty | Out-Null
        $script:InitOneDrive = Join-Path $testHome 'OneDrive - Company'
        New-Item -ItemType Directory -Path $script:InitOneDrive | Out-Null
        $env:OneDriveCommercial = $script:InitOneDrive

        $script:Answers = [Collections.Generic.Queue[string]]::new()
        $script:Prompts = [Collections.Generic.List[string]]::new()
        Mock Read-PhxAnswer -ModuleName PSPhoenix {
            $script:Prompts.Add($Prompt)
            $next = $script:Answers.Dequeue()
            if ($next) { $next } else { $Default }
        }
        Mock Get-PhxRootCandidate -ModuleName PSPhoenix { $script:InitWork; $script:InitOther; $script:InitEmpty; (Join-Path $script:InitEmpty 'Missing') }
        Mock Select-PhxInitSecret -ModuleName PSPhoenix { [pscustomobject]@{ Recipient = $script:TestRecipient; Identity = $null; Passphrase = $null; Source = 'yours' } }
        Mock Get-PhxGhAccount -ModuleName PSPhoenix {
            [pscustomobject]@{ Host = 'github.com'; Login = 'wpaap'; Active = $true }
            [pscustomobject]@{ Host = 'github.com'; Login = 'WizX20'; Active = $false }
        }
        # The schedule question as on Windows, on every platform; registering is recorded, not done.
        Mock Test-PhxCanSchedule -ModuleName PSPhoenix { $true }
        $script:Registered = [Collections.Generic.List[object]]::new()
        Mock Register-PhxScheduledTask -ModuleName PSPhoenix { $script:Registered.Add($Definition) }
    }

    It 'sets up roots, accounts, target, machine and interval from the defaults and a few answers' {
        # roots, WizX20 account, summitnl account, target, create it?, machine, interval (bad, good), schedule?, save?
        Set-TestAnswer '' '' '' '' '' '' 'soon' '2h' '' ''
        $output = Get-PhxOutput { phx init }
        $script:Answers.Count | Should -Be 0
        $config = InModuleScope PSPhoenix { Read-PhxConfig }
        @($config.roots.path) | Should -Be @($script:InitWork, $script:InitOther)
        @($config.roots.depth) | Should -Be @(3, 3)
        $config.accounts['github.com/WizX20'] | Should -Be 'WizX20'      # from its credential helper
        $config.accounts['github.com/summitnl'] | Should -Be 'wpaap'    # the active account
        $config.accounts.Contains('dev.azure.com/org') | Should -BeFalse # not a gh host
        $config.target.type | Should -Be 'folder'
        $config.target.path | Should -Be (Join-Path $script:InitOneDrive 'PSPhoenix')
        Test-Path -LiteralPath $config.target.path | Should -BeTrue
        $config.interval | Should -Be '2h'
        $config.machine.name | Should -Be ([Environment]::MachineName)
        [guid]::Parse($config.machine.id) | Should -Not -BeNullOrEmpty
        $output | Should -Match ('machine\s+' + [regex]::Escape([Environment]::MachineName) + '\s+snapshot in')
        $output | Should -Match '1\. .*Work\s+3 repositories'
        $output | Should -Not -Match 'NoRepos'
        $output | Should -Match 'like 30m, 1h or 1d'
        $output | Should -Not -Match 'company storage'
        $output | Should -Match 'saved .*config.json'
        $output | Should -Match 'scheduled: every 2h'
        $script:Registered | Should -HaveCount 1
        $script:Registered[0].Interval | Should -Be ([TimeSpan]::FromHours(2))
        $script:Prompts[-1] | Should -BeExactly "Save to $(InModuleScope PSPhoenix { Get-PhxConfigPath })? (Y/n)"
        # The scan of the chosen roots is saved with the config.
        $cache = InModuleScope PSPhoenix { Read-PhxRepoCache }
        @($cache.roots.path) | Should -Be @($script:InitWork, $script:InitOther)
        @($cache.repositories).Count | Should -Be 4
    }

    It 'changes nothing when run again with Enter all the way' {
        Set-TestAnswer '' '' '' '' '' '' '' '' ''
        phx init 6>$null
        $before = Read-TestConfig
        # roots, two accounts, target (exists now), machine, interval, schedule?, save?
        Set-TestAnswer '' '' '' '' '' '' '' ''
        Get-PhxOutput { phx init } | Should -Match '\(current\)'
        $script:Answers.Count | Should -Be 0
        Read-TestConfig | Should -Be $before
    }

    It 'stops without saving on q at the <Question> question' -ForEach @(
        @{ Question = 'roots'; At = 0 }
        @{ Question = 'first account'; At = 1 }
        @{ Question = 'second account'; At = 2 }
        @{ Question = 'target'; At = 3 }
        @{ Question = 'create-the-target'; At = 4 }
        @{ Question = 'machine'; At = 5 }
        @{ Question = 'interval'; At = 6 }
        @{ Question = 'schedule'; At = 7 }
        @{ Question = 'save'; At = 8 }
    ) {
        $answers = @(@('') * $At) + 'q'
        Set-TestAnswer @answers
        Get-PhxOutput { phx init } | Should -Match 'stopped - nothing saved'
        $? | Should -BeTrue
        $script:Prompts | Should -HaveCount ($At + 1)
        $script:Registered | Should -HaveCount 0
        Test-Path -LiteralPath (InModuleScope PSPhoenix { Get-PhxConfigPath }) | Should -BeFalse
        Test-Path -LiteralPath (InModuleScope PSPhoenix { Get-PhxRepoCachePath }) | Should -BeFalse
    }

    It 'leaves the last scan alone when stopped after scanning other roots' {
        Set-TestAnswer '' '' '' '' '' '' '' '' ''
        phx init 6>$null
        $cachePath = InModuleScope PSPhoenix { Get-PhxRepoCachePath }
        $before = Get-Content -LiteralPath $cachePath -Raw
        # Other holds only an Azure DevOps repository: no account questions, so q answers the target.
        Set-TestAnswer $script:InitOther 'q'
        Get-PhxOutput { phx init } | Should -Match 'Other\s+1 repositories'
        Get-Content -LiteralPath $cachePath -Raw | Should -Be $before
    }

    It 'saves nothing when the last answer is no' {
        Set-TestAnswer '' '' '' '' '' '' '' '' 'n'
        Get-PhxOutput { phx init } | Should -Match 'not confirmed - nothing saved'
        Test-Path -LiteralPath (InModuleScope PSPhoenix { Get-PhxConfigPath }) | Should -BeFalse
    }

    It 'asks again for roots it cannot use, and takes a typed path' {
        $nope = Join-Path $testHome 'nope'
        Set-TestAnswer '7' $nope '1,1' $script:InitOther '' '' '' '' '' ''
        $output = Get-PhxOutput { phx init }
        $output | Should -Match 'there is no number 7 in the list'
        $output | Should -Match ([regex]::Escape("no such folder: $nope"))
        $output | Should -Match 'is a root already'
        @((InModuleScope PSPhoenix { Read-PhxConfig }).roots.path) | Should -Be @($script:InitOther)
    }

    It 'asks again for an account gh does not have, and stores its exact spelling' {
        # WizX20's owner first (two repositories): a login gh lacks, then Enter; summitnl: typed in lower case.
        Set-TestAnswer '1' 'nobody' '' 'wizx20' '' '' '' '' '' ''
        Get-PhxOutput { phx init } | Should -Match 'one of: wpaap, WizX20'
        $script:Answers.Count | Should -Be 0
        (InModuleScope PSPhoenix { Read-PhxConfig }).accounts['github.com/summitnl'] | Should -BeExactly 'WizX20'
    }

    It 'keeps an account that is set when gh is not logged in with it' {
        Set-TestAnswer '' '' '' '' '' '' '' '' ''
        phx init 6>$null
        $before = Read-TestConfig
        # gh now knows only WizX20: summitnl's wpaap stays the default, and Enter keeps it.
        Mock Get-PhxGhAccount -ModuleName PSPhoenix { [pscustomobject]@{ Host = 'github.com'; Login = 'WizX20'; Active = $true } }
        # roots, summitnl account (asked: its account is not logged in), target, machine, interval, schedule?, save?
        Set-TestAnswer '' '' '' '' '' '' ''
        Get-PhxOutput { phx init } | Should -Match 'github.com/summitnl uses wpaap, but gh is not logged in as wpaap'
        $script:Answers.Count | Should -Be 0
        Read-TestConfig | Should -Be $before
    }

    It 'skips the accounts when gh is not logged in' {
        Mock Get-PhxGhAccount -ModuleName PSPhoenix { }
        Set-TestAnswer '' '' '' '' '' '' ''
        Get-PhxOutput { phx init } | Should -Match 'gh is not logged in'
        (InModuleScope PSPhoenix { Read-PhxConfig }).accounts.Count | Should -Be 0
    }

    It 'asks again for a target number that is not in the list' {
        # roots, two accounts, target (5, a number too big for an int, Enter), create it?, machine, interval, save?
        Set-TestAnswer '' '' '' '5' '99999999999' '' '' '' '' '' ''
        $output = Get-PhxOutput { phx init }
        $output | Should -Match 'there is no number 5 in the list'
        $output | Should -Match 'there is no number 99999999999 in the list'
        $script:Answers.Count | Should -Be 0
        (InModuleScope PSPhoenix { Read-PhxConfig }).target.path | Should -Be (Join-Path $script:InitOneDrive 'PSPhoenix')
    }

    It 'takes an interval from 15m to 31d' {
        # roots, two accounts, target, create it?, machine, interval (three refused), save?
        Set-TestAnswer '' '' '' '' '' '' '14m' '99999999999m' '32d' '31d' '' ''
        $output = Get-PhxOutput { phx init }
        [regex]::Matches($output, 'from 15m to 31d').Count | Should -Be 3
        (InModuleScope PSPhoenix { Read-PhxConfig }).interval | Should -Be '31d'
        InModuleScope PSPhoenix {
            foreach ($good in '15m', '1h', '1d', '44640m', '744h') { Test-PhxInterval $good | Should -BeTrue -Because $good }
            foreach ($bad in '', '14m', '0h', '1w', '32d', '1.5h', '99999999999m', ' 1h') { Test-PhxInterval $bad | Should -BeFalse -Because $bad }
        }
    }

    It 'asks again for a machine name that is no folder name, and stores the typed one' {
        # roots, two accounts, target, create it?, machine (bad, good), interval, save?
        Set-TestAnswer '' '' '' '' '' 'my laptop' 'Laptop-2026' '' '' ''
        Get-PhxOutput { phx init } | Should -Match 'letters, digits, dot, dash and underscore, please'
        $script:Answers.Count | Should -Be 0
        (InModuleScope PSPhoenix { Read-PhxConfig }).machine.name | Should -Be 'Laptop-2026'
    }

    It 'does not take a folder that holds files but is no snapshot' {
        $other = Join-Path (Join-Path $script:InitOneDrive 'PSPhoenix') 'Box'
        New-Item -ItemType Directory -Force -Path $other | Out-Null
        Set-Content -LiteralPath (Join-Path $other 'notes.txt') -Value 'mine'
        # roots, two accounts, target, machine (taken, then the suggested free one), interval, schedule?, save?
        Set-TestAnswer '' '' '' '' 'Box' '' '' '' ''
        Get-PhxOutput { phx init } | Should -Match 'holds files but no phoenix.json'
        (InModuleScope PSPhoenix { Read-PhxConfig }).machine.name | Should -Be 'Box-2'
    }

    It 'does not take the folder of another installation of this machine' {
        # A reinstalled machine with the same name: its old snapshot is what a restore needs.
        $other = Join-Path (Join-Path $script:InitOneDrive 'PSPhoenix') 'Box'
        New-Item -ItemType Directory -Force -Path $other | Out-Null
        Set-Content -LiteralPath (Join-Path $other 'phoenix.json') -Value '{ "format": 1, "machine": { "name": "Box", "id": "11111111-1111-1111-1111-111111111111" }, "updatedAt": "2026-10-01T08:00:00Z" }'
        # roots, two accounts, target, machine (taken, then the suggested free one), interval, save?
        Set-TestAnswer '' '' '' '' 'Box' '' '' '' ''
        $output = Get-PhxOutput { phx init }
        $output | Should -Match 'Box holds the snapshot of another installation'
        $script:Answers.Count | Should -Be 0
        (InModuleScope PSPhoenix { Read-PhxConfig }).machine.name | Should -Be 'Box-2'
    }

    It 'leaves a matching task alone on Enter, and removes it on no' {
        Set-TestAnswer '' '' '' '' '' '' '' '' ''
        phx init 6>$null
        $script:Registered | Should -HaveCount 1
        # The task is there now, as init registered it.
        $script:InitTask = InModuleScope PSPhoenix {
            $definition = New-PhxTaskDefinition -Interval ([TimeSpan]::FromHours(1))
            [pscustomobject]@{ Arguments = $definition.Arguments; Interval = $definition.Interval }
        }
        Mock Get-PhxScheduledTask -ModuleName PSPhoenix { $script:InitTask }
        $script:Unregistered = 0
        Mock Unregister-PhxScheduledTask -ModuleName PSPhoenix { $script:Unregistered++ }
        # roots, two accounts, target, machine, interval, schedule? (default yes: it is on), save?
        Set-TestAnswer '' '' '' '' '' '' '' ''
        phx init 6>$null
        $script:Registered | Should -HaveCount 1
        Set-TestAnswer '' '' '' '' '' '' 'n' ''
        phx init 6>$null
        $script:Unregistered | Should -Be 1
    }

    It 'leaves the schedule off when told so' {
        # roots, two accounts, target, create it?, machine, interval, schedule? no, save?
        Set-TestAnswer '' '' '' '' '' '' '' 'n' ''
        $output = Get-PhxOutput { phx init }
        $output | Should -Match 'schedule\s+off - phx schedule on later'
        $script:Registered | Should -HaveCount 0
    }

    It 'takes a typed target folder, and says where company data belongs' {
        $usb = Join-Path $testHome 'USB'
        New-Item -ItemType Directory -Path $usb | Out-Null
        Set-TestAnswer '' '' '' $usb '' '' '' ''
        Get-PhxOutput { phx init } | Should -Match 'company storage'
        (InModuleScope PSPhoenix { Read-PhxConfig }).target.path | Should -Be $usb
    }
}

Describe 'init secrets' {
    # The key step of phx init (docs/design.md -> Secrets): a new age key with a passphrase-protected
    # copy in the target, a recipient of the user's own, or the current one kept.
    BeforeAll {
        # key.age with the work factor of age -p takes a second and 256 MB; a test needs neither.
        InModuleScope PSPhoenix { $script:SavedKeyWorkFactor = $script:PhxKeyWorkFactor; $script:PhxKeyWorkFactor = 10 }
    }
    AfterAll { InModuleScope PSPhoenix { $script:PhxKeyWorkFactor = $script:SavedKeyWorkFactor } }

    BeforeEach {
        $keyHome = Use-TestHome
        $script:KeyRoot = Join-Path $keyHome 'Repos'
        New-TestRepository (Join-Path $script:KeyRoot 'Lab') -Remote 'origin=https://dev.azure.com/org/proj/_git/lab' | Out-Null
        $script:KeyTarget = Join-Path $keyHome 'Target'
        New-Item -ItemType Directory -Path $script:KeyTarget | Out-Null
        $script:KeySnapshot = Join-Path $script:KeyTarget ([Environment]::MachineName)
        $script:Answers = [Collections.Generic.Queue[string]]::new()
        $script:SecretAnswers = [Collections.Generic.Queue[string]]::new()
        Mock Read-PhxAnswer -ModuleName PSPhoenix { $next = $script:Answers.Dequeue(); if ($next) { $next } else { $Default } }
        Mock Read-PhxSecretAnswer -ModuleName PSPhoenix { $script:SecretAnswers.Dequeue() }
        # The new key goes past PowerShell's streams, to the console: kept here instead.
        $script:SecretLines = [Collections.Generic.List[string]]::new()
        Mock Show-PhxSecretLine -ModuleName PSPhoenix { $script:SecretLines.Add($Text) }
        Mock Get-PhxRootCandidate -ModuleName PSPhoenix { $script:KeyRoot }
        Mock Get-PhxGhAccount -ModuleName PSPhoenix { }
        Mock Test-PhxCanSchedule -ModuleName PSPhoenix { $false }
        function Invoke-TestInit {
            # phx init: roots, target, machine, the key step's answers, interval, save. -Secret are
            # the passphrases typed, in order.
            param([string[]]$Key = @(), [string[]]$Secret = @())
            foreach ($answer in @('', $script:KeyTarget, '') + $Key + @('', '')) { $script:Answers.Enqueue($answer) }
            foreach ($answer in $Secret) { $script:SecretAnswers.Enqueue($answer) }
            $output = Get-PhxOutput { phx init }
            $script:Answers.Count | Should -Be 0
            $script:SecretAnswers.Count | Should -Be 0
            $output
        }
        function Get-TestKeyCopy {
            # The key copies in the snapshot folder.
            @(Get-ChildItem -LiteralPath $script:KeySnapshot -Filter 'key-*.age' -ErrorAction SilentlyContinue).Name
        }
    }

    It 'makes a new key, puts a passphrase-protected copy in the target and shows the key once' {
        $output = Invoke-TestInit -Key '' -Secret 'correct horse battery staple', 'correct horse battery staple'
        $recipient = (InModuleScope PSPhoenix { Read-PhxConfig }).secrets.recipient
        [PSPhoenix.Engine.Age]::IsRecipient($recipient) | Should -BeTrue
        $copyName = "key-$($recipient.Substring(4, 12)).age"
        $output | Should -Match "secrets\s+age1\S+\s+a new key, its passphrase copy $copyName in the snapshot"
        # The copy: an age identity file, encrypted with the passphrase, in a claimed snapshot folder.
        Test-Path -LiteralPath (Join-Path $script:KeySnapshot 'phoenix.json') | Should -BeTrue
        Get-TestKeyCopy | Should -Be @($copyName)
        $copy = [Text.Encoding]::UTF8.GetString([PSPhoenix.Engine.Age]::DecryptWithPassphrase([IO.File]::ReadAllBytes((Join-Path $script:KeySnapshot $copyName)), 'correct horse battery staple'))
        $copy | Should -Match "(?m)^# public key: $recipient$"
        $identity = ($copy -split "`n" | Where-Object { $_ -like 'AGE-SECRET-KEY-1*' })
        [PSPhoenix.Engine.Age]::RecipientOf($identity) | Should -Be $recipient
        # Shown once, to the console only - not into a stream a transcript records - and never in the config.
        @($script:SecretLines) | Should -Be @("  $identity")
        $output | Should -Not -Match 'AGE-SECRET-KEY'
        $output | Should -Match "put it in your password manager now.*\s+it, or the passphrase for $copyName in the snapshot"
        Get-Content -LiteralPath (InModuleScope PSPhoenix { Get-PhxConfigPath }) -Raw | Should -Not -Match 'AGE-SECRET-KEY'
        Get-PhxOutput { phx status } | Should -Match "secrets\s+encrypted to age1\S+ - a passphrase-protected copy of the key is $copyName in the snapshot"
    }

    It 'asks for a passphrase of four words or 20 characters, twice the same' {
        $output = Invoke-TestInit -Key '' -Secret 'short', 'Summer2026!!', 'long enough passphrase', 'not the same at all', 'long enough passphrase', 'long enough passphrase'
        ([regex]::Matches($output, 'four words or more, or at least 20 characters')).Count | Should -Be 2
        $output | Should -Match 'not the same - once more'
        Get-TestKeyCopy | Should -HaveCount 1
    }

    It 'shows a new key also when a step after saving fails' {
        Mock Save-PhxRepoCache -ModuleName PSPhoenix { throw 'disk full' }
        foreach ($answer in @('', $script:KeyTarget, '', '', '', '')) { $script:Answers.Enqueue($answer) }
        foreach ($answer in 'correct horse battery staple', 'correct horse battery staple') { $script:SecretAnswers.Enqueue($answer) }
        { phx init -ErrorAction Stop 6>$null } | Should -Throw '*disk full*'
        # The config names the new key now: without it shown, its secrets could never be opened.
        (InModuleScope PSPhoenix { Read-PhxConfig }).secrets.recipient | Should -Not -BeNullOrEmpty
        @($script:SecretLines | Where-Object { $_ -match 'AGE-SECRET-KEY-1' }) | Should -HaveCount 1
    }

    It 'keeps the copy of the old key when the key changes, and refuses a secret key as recipient' {
        Invoke-TestInit -Key '' -Secret 'correct horse battery staple', 'correct horse battery staple' | Out-Null
        $first = (InModuleScope PSPhoenix { Read-PhxConfig }).secrets.recipient
        $secretKey = ($script:SecretLines[0]).Trim()
        # Keep it? no; a secret key pasted; Enter for a new one with a passphrase.
        $output = Invoke-TestInit -Key 'n', $secretKey, '' -Secret 'another long passphrase here', 'another long passphrase here'
        $output | Should -Match 'that is the secret half of the key'
        $output | Should -Match 'the next run encrypts every secret to the new key'
        $second = (InModuleScope PSPhoenix { Read-PhxConfig }).secrets.recipient
        $second | Should -Not -Be $first
        Get-TestKeyCopy | Sort-Object | Should -Be (@("key-$($first.Substring(4, 12)).age", "key-$($second.Substring(4, 12)).age") | Sort-Object)
        Get-PhxOutput { phx status } | Should -Match "key-$($second.Substring(4, 12))\.age in the snapshot"
    }

    It 'makes a new key without a copy in the target only when told so twice' {
        # Enter for a new key; no passphrase; "sure?" no; no passphrase; "sure?" yes.
        $output = Invoke-TestInit -Key '', '', 'y' -Secret '', ''
        $output | Should -Match 'secrets\s+age1\S+\s+a new key, no copy in the snapshot'
        $output | Should -Match 'it is the only way to open your secrets'
        Get-TestKeyCopy | Should -BeNullOrEmpty
        Get-PhxOutput { phx status } | Should -Match 'no copy of the key in the snapshot'
    }

    It 'takes the recipient of a key the user has, and keeps the current key on Enter' {
        $own = [PSPhoenix.Engine.Age]::NewKey()
        $output = Invoke-TestInit -Key 'ssh-ed25519 AAAA', $own.Recipient
        $output | Should -Match 'an age recipient starts with age1'
        $script:SecretLines | Should -BeNullOrEmpty
        (InModuleScope PSPhoenix { Read-PhxConfig }).secrets.recipient | Should -Be $own.Recipient
        Get-TestKeyCopy | Should -BeNullOrEmpty
        # Again: the current key, kept on Enter.
        $output = Invoke-TestInit -Key ''
        $output | Should -Match ("current key: " + [regex]::Escape($own.Recipient))
        (InModuleScope PSPhoenix { Read-PhxConfig }).secrets.recipient | Should -Be $own.Recipient
    }
}

Describe 'status' {
    BeforeEach {
        $testHome = Use-TestHome
        $repos = Join-Path $testHome 'Repos'
        New-TestRepository (Join-Path $repos 'Mine') -Remote 'origin=https://github.com/WizX20/mine.git' | Out-Null
        New-TestRepository (Join-Path $repos 'Work') -Remote 'origin=https://github.com/summitnl/work.git' | Out-Null
        New-TestRepository (Join-Path $repos 'Scratch') | Out-Null
        $target = Join-Path $testHome 'Target'
        New-Item -ItemType Directory -Path $target | Out-Null
        Mock Get-PhxGhAccount -ModuleName PSPhoenix {
            [pscustomobject]@{ Host = 'github.com'; Login = 'wpaap'; Active = $true }
            [pscustomobject]@{ Host = 'github.com'; Login = 'WizX20'; Active = $false }
        }
        # A scheduled task as phx schedule on registers it, every hour.
        Mock Test-PhxCanSchedule -ModuleName PSPhoenix { $true }
        # Built here: a mock's body does not run inside the module, so it cannot call its helpers.
        $script:ScheduledTask = InModuleScope PSPhoenix {
            $definition = New-PhxTaskDefinition -Interval ([TimeSpan]::FromHours(1))
            [pscustomobject]@{ Arguments = $definition.Arguments; Interval = $definition.Interval; LastRunTime = [datetime]'2026-10-12 08:00'; LastResult = 0; NextRunTime = [datetime]'2026-10-12 10:00' }
        }
        Mock Get-PhxScheduledTask -ModuleName PSPhoenix { $script:ScheduledTask }

        function Set-TestConfig {
            param([string]$WorkAccount = 'wpaap', [string]$TargetPath = $target)
            InModuleScope PSPhoenix -Parameters @{ Root = $repos; Target = $TargetPath; Work = $WorkAccount } {
                param($Root, $Target, $Work)
                $c = Read-PhxConfig
                $c.roots = @([ordered]@{ path = $Root; depth = 3 })
                $c.target = [ordered]@{ type = 'folder'; path = $Target }
                $c.accounts['github.com/WizX20'] = 'WizX20'
                $c.accounts['github.com/summitnl'] = $Work
                Save-PhxConfig $c
            }
        }
    }

    It 'says when nothing is set up yet' {
        Get-PhxOutput { phx status } | Should -Match 'not set up yet - run: phx init'
    }

    It 'stops with an error of phx on a config it cannot read' {
        $configPath = InModuleScope PSPhoenix { Get-PhxConfigPath }
        New-Item -ItemType Directory -Force -Path (Split-Path $configPath -Parent) | Out-Null
        Set-Content -LiteralPath $configPath -Value '{ not json'
        phx status -ErrorAction SilentlyContinue -ErrorVariable failure 6>$null
        $? | Should -BeFalse
        $record = $failure | Where-Object FullyQualifiedErrorId -Like 'PhxCommandFailed*' | Select-Object -First 1
        $record.Exception.Message | Should -BeLike '*not valid JSON*'
    }

    It 'shows the set-up, and finds nothing that needs attention' {
        Set-TestConfig
        phx scan 6>$null
        $output = Get-PhxOutput { phx status }
        $output | Should -Match ('target\s+' + [regex]::Escape($target))
        $output | Should -Match ('root\s+' + [regex]::Escape($repos) + '\s+depth 3\s+3 repositories')
        $output | Should -Match 'scan\s+just now'
        $output | Should -Match 'repos\s+3 repositories, 1 without a remote'
        $output | Should -Match 'WizX20: 1'
        $output | Should -Match 'account\s+wpaap on github.com \(1 repositories\) - logged in to gh'
        $output | Should -Match 'last run\s+none yet - phx run'
        $output | Should -Match 'schedule\s+on, every 1h and at logon - next 2026-10-12 10:00'
        $output | Should -Match 'nothing needs attention'
    }

    It 'needs no gh account for a repository cloned over SSH' {
        git -C (Join-Path $repos 'Work') remote set-url origin 'git@github.com:summitnl/work.git'
        Set-TestConfig -WorkAccount 'Ghost'
        phx scan 6>$null
        $output = Get-PhxOutput { phx status }
        $output | Should -Not -Match 'Ghost on github.com'
        $output | Should -Match 'nothing needs attention'
    }

    It 'says when gh could not check an account, without counting it as a problem' {
        Set-TestConfig
        phx scan 6>$null
        Mock Get-PhxGhAccount -ModuleName PSPhoenix {
            [pscustomobject]@{ Host = 'github.com'; Login = 'wpaap'; Active = $true; Verified = $false }
            [pscustomobject]@{ Host = 'github.com'; Login = 'WizX20'; Active = $false; Verified = $true }
        }
        $output = Get-PhxOutput { phx status }
        $output | Should -Match 'wpaap on github.com \(1 repositories\) - logged in to gh, not checked'
        $output | Should -Match 'nothing needs attention'
    }

    It 'warns about an account gh is not logged in with' {
        Set-TestConfig -WorkAccount 'Ghost'
        phx scan 6>$null
        $output = Get-PhxOutput { phx status }
        $output | Should -Match 'Ghost on github.com \(1 repositories\) - not logged in to gh: gh auth login --hostname github.com'
        $output | Should -Match '1 thing\(s\) need attention'
    }

    It 'warns about a missing target, a missing root folder and a missing scan' {
        Set-TestConfig -TargetPath (Join-Path $testHome 'Unplugged')
        Remove-Item -LiteralPath $repos -Recurse -Force
        $output = Get-PhxOutput { phx status }
        $output | Should -Match 'Unplugged - folder not found'
        $output | Should -Match 'depth 3\s+folder not found'
        $output | Should -Match 'not scanned yet - phx scan'
        $output | Should -Match '3 thing\(s\) need attention'
    }

    It "keeps going when a provider's status fails" {
        Set-TestConfig
        InModuleScope PSPhoenix {
            $script:SavedProviders = [ordered]@{}
            foreach ($key in $script:PhxProviders.Keys) { $script:SavedProviders[$key] = $script:PhxProviders[$key] }
            Register-PhxProvider @{ Name = 'broken'; Description = 'b'; Backup = {}; Restore = {}; Status = { throw 'boom' } }
        }
        try { Get-PhxOutput { phx status } | Should -Match 'broken\s+status failed: boom' }
        finally { InModuleScope PSPhoenix { $script:PhxProviders = $script:SavedProviders } }
    }

    It 'says how long ago, in words' {
        InModuleScope PSPhoenix {
            Format-PhxAge ([DateTime]::UtcNow) | Should -Be 'just now'
            Format-PhxAge ([DateTime]::UtcNow.AddSeconds(-90)) | Should -Be '1 minute ago'
            Format-PhxAge ([DateTime]::UtcNow.AddMinutes(-30)) | Should -Be '30 minutes ago'
            Format-PhxAge ([DateTime]::UtcNow.AddMinutes(-61)) | Should -Be '1 hour ago'
            Format-PhxAge ([DateTime]::UtcNow.AddHours(-5)) | Should -Be '5 hours ago'
            Format-PhxAge ([DateTime]::UtcNow.AddDays(-3)) | Should -Be '3 days ago'
        }
    }

    It 'shows its own snapshot folder as fine once something was published' {
        Set-TestConfig
        phx scan 6>$null
        InModuleScope PSPhoenix {
            $c = Read-PhxConfig; $c.machine = [ordered]@{ name = 'Box'; id = 'mine' }; Save-PhxConfig $c
            Publish-PhxSnapshot -Config (Read-PhxConfig) -Provider @() | Out-Null
        }
        $output = Get-PhxOutput { phx status }
        $output | Should -Match 'machine\s+Box\s+snapshot in'
        $output | Should -Match 'nothing needs attention'
    }

    It 'names the snapshot folder, and warns when another installation wrote it' {
        Set-TestConfig
        phx scan 6>$null
        InModuleScope PSPhoenix { $c = Read-PhxConfig; $c.machine = [ordered]@{ name = 'Box'; id = 'mine' }; Save-PhxConfig $c }
        Get-PhxOutput { phx status } | Should -Match ('machine\s+Box\s+snapshot in ' + [regex]::Escape((Join-Path $target 'Box')))
        New-Item -ItemType Directory -Path (Join-Path $target 'Box') | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'Box/phoenix.json') -Value '{ "format": 1, "machine": { "id": "theirs" } }'
        $output = Get-PhxOutput { phx status }
        $output | Should -Match 'holds the snapshot of another installation'
        $output | Should -Match '1 thing\(s\) need attention'
    }

    It 'warns when nothing backs up in the background, or the task runs a module that is gone' {
        Set-TestConfig
        phx scan 6>$null
        Mock Get-PhxScheduledTask -ModuleName PSPhoenix { }
        Get-PhxOutput { phx status } | Should -Match 'schedule\s+off - nothing backs up in the background: phx schedule on'
        Mock Get-PhxScheduledTask -ModuleName PSPhoenix {
            [pscustomobject]@{ Arguments = "--headless `"$((Get-Process -Id $PID).Path)`" -NoProfile -NonInteractive -File `"C:\gone\0.0.1\phx-task.ps1`""; Interval = [TimeSpan]::FromHours(1) }
        }
        $output = Get-PhxOutput { phx status }
        $output | Should -Match 'schedule\s+on, but it runs C:\\gone\\0.0.1\\phx-task.ps1, which is gone'
        $output | Should -Match '1 thing\(s\) need attention'
    }

    It 'warns about a target it cannot write to' {
        Set-TestConfig
        phx scan 6>$null
        Mock Test-PhxWritableFolder -ModuleName PSPhoenix { $false }
        $output = Get-PhxOutput { phx status }
        $output | Should -Match 'cannot write there'
        $output | Should -Match '1 thing\(s\) need attention'
    }

    It 'probes a folder for writing without leaving anything behind' {
        $folder = Join-Path $testHome 'Probe'
        New-Item -ItemType Directory -Path $folder | Out-Null
        InModuleScope PSPhoenix -Parameters @{ Folder = $folder } {
            param($Folder)
            Test-PhxWritableFolder $Folder | Should -BeTrue
            Test-PhxWritableFolder (Join-Path $Folder 'Missing') | Should -BeFalse
        }
        @(Get-ChildItem -LiteralPath $folder -Force).Count | Should -Be 0
    }

    It 'counts only the configured roots, and says which one the last scan did not cover' {
        # Scanned: Repos and Extra. Then Extra is removed and New added - neither scanned that way.
        $extra = Join-Path $testHome 'Extra'
        New-TestRepository (Join-Path $extra 'Gone') -Remote 'origin=https://github.com/summitnl/gone.git' | Out-Null
        $new = Join-Path $testHome 'New'
        New-Item -ItemType Directory -Path $new | Out-Null
        Set-TestConfig
        phx roots add $extra 6>$null
        phx scan 6>$null
        phx roots rm $extra 6>$null
        phx roots add $new 6>$null
        $output = Get-PhxOutput { phx status }
        $output | Should -Match ([regex]::Escape($new) + '\s+depth 3\s+not scanned')
        $output | Should -Match '1 root\(s\) not scanned yet - phx scan'
        $output | Should -Match 'repos\s+3 repositories, 1 without a remote'
        $output | Should -Match 'account\s+wpaap on github.com \(1 repositories\)'
        $output | Should -Not -Match ([regex]::Escape($extra))
    }

    It 'warns about a scan time it cannot read, and says once that it ignores a broken cache' {
        Set-TestConfig
        phx scan 6>$null
        $cachePath = InModuleScope PSPhoenix { Get-PhxRepoCachePath }
        $cache = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json -AsHashtable
        $cache.scannedAt = 'some day'
        Set-Content -LiteralPath $cachePath -Value ($cache | ConvertTo-Json -Depth 10)
        Get-PhxOutput { phx status } | Should -Match 'scan\s+time unknown - phx scan refreshes it'

        Set-Content -LiteralPath $cachePath -Value 'not json'
        $output = Get-PhxOutput { phx status }
        [regex]::Matches($output, 'ignoring ').Count | Should -Be 1
        $output | Should -Match 'not scanned yet - phx scan'
    }
}

Describe 'init without a console' {
    BeforeEach {
        Use-TestHome | Out-Null
        Mock Get-PhxRootCandidate -ModuleName PSPhoenix { }
        Mock Get-PhxGhAccount -ModuleName PSPhoenix { }
    }

    It 'stops at the end of input instead of asking again or taking every default' {
        # Read-Host gives nothing at all once redirected input has run out.
        Mock Read-Host -ModuleName PSPhoenix { }
        Get-PhxOutput { phx init } | Should -Match 'input ended - nothing saved'
        Should -Invoke Read-Host -ModuleName PSPhoenix -Times 1 -Exactly
        Test-Path -LiteralPath (InModuleScope PSPhoenix { Get-PhxConfigPath }) | Should -BeFalse
    }

}

Describe 'snapshot' {
    BeforeEach {
        $testHome = Use-TestHome
        $script:Target = Join-Path $testHome 'Target'
        function Set-TestMachine {
            # A config whose target is $script:Target, as machine $Name with id $Id.
            param([string]$Name, [string]$Id)
            InModuleScope PSPhoenix -Parameters @{ Target = $script:Target; Name = $Name; Id = $Id } {
                param($Target, $Name, $Id)
                $c = Read-PhxConfig
                $c.target = [ordered]@{ type = 'folder'; path = $Target }
                $c.machine = [ordered]@{ name = $Name; id = $Id }
                Save-PhxConfig $c
            }
        }
        function Set-TestStaged {
            # The staged files of a provider: relative path -> content; an empty value removes it.
            param([string]$Provider, [hashtable]$Files)
            $staging = InModuleScope PSPhoenix -Parameters @{ Provider = $Provider } { param($Provider) Get-PhxStagingPath $Provider }
            foreach ($relative in $Files.Keys) {
                $path = Join-Path $staging $relative
                if ($Files[$relative]) {
                    New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
                    [IO.File]::WriteAllText($path, $Files[$relative])
                }
                elseif (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
            }
        }
        function Invoke-TestPublish {
            param([string[]]$Provider)
            InModuleScope PSPhoenix -Parameters @{ Provider = $Provider } { param($Provider) Publish-PhxSnapshot -Config (Read-PhxConfig) -Provider $Provider }
        }
    }

    It 'publishes each provider into its own folder, with phoenix.json and the config' {
        Set-TestMachine 'Box' 'id-1'
        Set-TestStaged repos @{ 'repos.json' = '{ "format": 1 }' }
        Set-TestStaged wip @{ 'github.com/o/r.bundle' = 'bundle' }
        $results = Invoke-TestPublish repos, wip
        $results['repos'].Written | Should -Be 1
        $snapshot = Join-Path $script:Target 'Box'
        Get-Content -LiteralPath (Join-Path $snapshot 'repos/repos.json') -Raw | Should -Be '{ "format": 1 }'
        Test-Path -LiteralPath (Join-Path $snapshot 'wip/github.com/o/r.bundle') | Should -BeTrue
        $info = Get-Content -LiteralPath (Join-Path $snapshot 'phoenix.json') -Raw | ConvertFrom-Json -AsHashtable
        $info.format | Should -Be 1
        $info.machine.name | Should -Be 'Box'
        $info.machine.id | Should -Be 'id-1'
        @($info.providers.Keys) | Should -Be @('repos', 'wip')
        $info.providers.repos.files | Should -Be 1
        (Get-Content -LiteralPath (Join-Path $snapshot 'config.json') -Raw | ConvertFrom-Json -AsHashtable).machine.name | Should -Be 'Box'
    }

    It 'writes nothing when nothing changed' {
        Set-TestMachine 'Box' 'id-1'
        Set-TestStaged repos @{ 'repos.json' = 'one'; 'sub/extra.txt' = 'two' }
        Invoke-TestPublish repos | Out-Null
        $snapshot = Join-Path $script:Target 'Box'
        $before = @(Get-ChildItem -LiteralPath $snapshot -Recurse -File | ForEach-Object { "$($_.FullName)|$($_.LastWriteTimeUtc.Ticks)" })
        Start-Sleep -Milliseconds 50
        $results = Invoke-TestPublish repos
        $results['repos'].Written | Should -Be 0
        $results['repos'].Unchanged | Should -Be 2
        @(Get-ChildItem -LiteralPath $snapshot -Recurse -File | ForEach-Object { "$($_.FullName)|$($_.LastWriteTimeUtc.Ticks)" }) | Should -Be $before
    }

    It 'writes a changed file, removes one no longer staged, and the folders left empty' {
        Set-TestMachine 'Box' 'id-1'
        Set-TestStaged repos @{ 'repos.json' = 'one'; 'deep/er/old.txt' = 'old' }
        Invoke-TestPublish repos | Out-Null
        Set-TestStaged repos @{ 'repos.json' = 'changed'; 'deep/er/old.txt' = '' }
        # A temporary file a crashed run left behind goes too.
        $stale = Join-Path $script:Target 'Box/repos/.repos.json.dead.tmp'
        Set-Content -LiteralPath $stale -Value 'half'
        $result = (Invoke-TestPublish repos)['repos']
        $result.Written | Should -Be 1
        $result.Removed | Should -Be 2
        Get-Content -LiteralPath (Join-Path $script:Target 'Box/repos/repos.json') -Raw | Should -Be 'changed'
        Test-Path -LiteralPath (Join-Path $script:Target 'Box/repos/deep') | Should -BeFalse
        Test-Path -LiteralPath $stale | Should -BeFalse
        $info = Get-Content -LiteralPath (Join-Path $script:Target 'Box/phoenix.json') -Raw | ConvertFrom-Json -AsHashtable
        $info.providers.repos.files | Should -Be 1
    }

    It 'keeps what it published in the state, file by file' {
        # So the next publish need not read the target back - that it does not is the engine's test
        # (FolderPublisherTests: Published_hashes_spare_reading_the_destination_back).
        Set-TestMachine 'Box' 'id-1'
        Set-TestStaged repos @{ 'repos.json' = 'one'; 'gone.txt' = 'soon gone' }
        $state = InModuleScope PSPhoenix { New-PhxState }
        InModuleScope PSPhoenix -Parameters @{ State = $state } { param($State) Publish-PhxSnapshot -Config (Read-PhxConfig) -Provider repos -State $State } | Out-Null
        @($state.published['repos'].Keys | Sort-Object) | Should -Be @('gone.txt', 'repos.json')
        $state.published['repos']['repos.json'] | Should -Be (InModuleScope PSPhoenix { [PSPhoenix.Engine.FileHash]::Sha256Text('one') })
        Set-TestStaged repos @{ 'gone.txt' = '' }
        $result = InModuleScope PSPhoenix -Parameters @{ State = $state } {
            param($State)
            (Publish-PhxSnapshot -Config (Read-PhxConfig) -Provider repos -State $State)['repos']
        }
        $result.Unchanged | Should -Be 1
        $result.Removed | Should -Be 1
        @($state.published['repos'].Keys) | Should -Be @('repos.json')
    }

    It 'does not take hashes published into another snapshot folder for this one' {
        Set-TestMachine 'Box' 'id-1'
        Set-TestStaged repos @{ 'repos.json' = 'new!' }
        $state = InModuleScope PSPhoenix { New-PhxState }
        InModuleScope PSPhoenix -Parameters @{ State = $state } { param($State) Publish-PhxSnapshot -Config (Read-PhxConfig) -Provider repos -State $State } | Out-Null
        # Renamed machine: the new folder holds an older copy of the same length.
        $old = Join-Path $script:Target 'Desk/repos'
        New-Item -ItemType Directory -Force -Path $old | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Target 'Desk/phoenix.json') -Value '{ "format": 1, "machine": { "id": "id-1" } }'
        Set-Content -LiteralPath (Join-Path $old 'repos.json') -Value 'old!' -NoNewline
        Set-TestMachine 'Desk' 'id-1'
        $result = InModuleScope PSPhoenix -Parameters @{ State = $state } { param($State) (Publish-PhxSnapshot -Config (Read-PhxConfig) -Provider repos -State $State)['repos'] }
        $result.Written | Should -Be 1
        Get-Content -LiteralPath (Join-Path $old 'repos.json') -Raw | Should -Match 'new!'
    }

    It 'keeps two machines side by side in one target' {
        Set-TestMachine 'Desk' 'id-desk'
        Set-TestStaged repos @{ 'repos.json' = 'desk' }
        Invoke-TestPublish repos | Out-Null
        Use-TestHome | Out-Null
        Set-TestMachine 'Laptop' 'id-laptop'
        Set-TestStaged repos @{ 'repos.json' = 'laptop' }
        Invoke-TestPublish repos | Out-Null
        Get-Content -LiteralPath (Join-Path $script:Target 'Desk/repos/repos.json') -Raw | Should -Be 'desk'
        Get-Content -LiteralPath (Join-Path $script:Target 'Laptop/repos/repos.json') -Raw | Should -Be 'laptop'
    }

    It 'refuses the folder of another installation, and one of a newer PSPhoenix' {
        Set-TestMachine 'Box' 'id-old'
        Set-TestStaged repos @{ 'repos.json' = 'the old one' }
        Invoke-TestPublish repos | Out-Null
        # Reinstalled under the same name: a new installation, a new id.
        Use-TestHome | Out-Null
        Set-TestMachine 'Box' 'id-new'
        Set-TestStaged repos @{ 'repos.json' = 'empty new machine' }
        { Invoke-TestPublish repos } | Should -Throw '*holds the snapshot of another installation*'
        Get-Content -LiteralPath (Join-Path $script:Target 'Box/repos/repos.json') -Raw | Should -Be 'the old one'

        Set-TestMachine 'Next' 'id-new'
        New-Item -ItemType Directory -Path (Join-Path $script:Target 'Next') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Target 'Next/phoenix.json') -Value '{ "format": 99 }'
        { Invoke-TestPublish repos } | Should -Throw '*written by a newer PSPhoenix*'
    }

    It 'refuses a folder with files but no phoenix.json, which publishing would empty' {
        Set-TestMachine 'Box' 'id-1'
        $folder = Join-Path $script:Target 'Box/repos'
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
        Set-Content -LiteralPath (Join-Path $folder 'precious-notes.txt') -Value 'mine'
        Set-TestStaged repos @{ 'repos.json' = 'x' }
        { Invoke-TestPublish repos } | Should -Throw '*holds files but no phoenix.json - it is not a PSPhoenix snapshot*'
        Get-Content -LiteralPath (Join-Path $folder 'precious-notes.txt') | Should -Be 'mine'
    }

    It 'swaps a file for a folder of the same name, and back' {
        Set-TestMachine 'Box' 'id-1'
        Set-TestStaged repos @{ 'foo' = 'a file' }
        Invoke-TestPublish repos | Out-Null
        Set-TestStaged repos @{ 'foo' = '' }
        Set-TestStaged repos @{ 'foo/bar.txt' = 'in a folder' }
        Invoke-TestPublish repos | Out-Null
        Get-Content -LiteralPath (Join-Path $script:Target 'Box/repos/foo/bar.txt') | Should -Be 'in a folder'
        Set-TestStaged repos @{ 'foo/bar.txt' = '' }
        Remove-Item -LiteralPath (Join-Path (InModuleScope PSPhoenix { Get-PhxStagingPath repos }) 'foo')
        Set-TestStaged repos @{ 'foo' = 'a file again' }
        Invoke-TestPublish repos | Out-Null
        Get-Content -LiteralPath (Join-Path $script:Target 'Box/repos/foo') | Should -Be 'a file again'
    }

    It 'publishes a rename that only changes case' {
        Set-TestMachine 'Box' 'id-1'
        Set-TestStaged repos @{ 'Memory.md' = 'same' }
        Invoke-TestPublish repos | Out-Null
        Set-TestStaged repos @{ 'Memory.md' = '' }
        Set-TestStaged repos @{ 'memory.md' = 'same' }
        Invoke-TestPublish repos | Out-Null
        @(Get-ChildItem -LiteralPath (Join-Path $script:Target 'Box/repos')).Name | Should -BeExactly @('memory.md')
    }

    It 'claims a new folder first, and clears temporary files a dead write left at its top' {
        Set-TestMachine 'Box' 'id-1'
        Invoke-TestPublish @() | Out-Null
        (Get-Content -LiteralPath (Join-Path $script:Target 'Box/phoenix.json') -Raw | ConvertFrom-Json).machine.id | Should -Be 'id-1'
        $stale = Join-Path $script:Target 'Box/.phoenix.json.0123abcd.tmp'
        Set-Content -LiteralPath $stale -Value 'half'
        $mine = Join-Path $script:Target 'Box/.mine.tmp'
        Set-Content -LiteralPath $mine -Value 'not ours'
        Invoke-TestPublish @() | Out-Null
        Test-Path -LiteralPath $stale | Should -BeFalse
        Test-Path -LiteralPath $mine | Should -BeTrue
    }

    It 'needs a machine id' {
        Set-TestMachine 'Box' ''
        { Invoke-TestPublish repos } | Should -Throw '*no id yet - run phx init*'
    }

    It 'accepts only folder-safe machine names' {
        InModuleScope PSPhoenix {
            foreach ($good in 'Box', 'WOUTER-LT', 'box.home', 'a_b') { Test-PhxMachineName $good | Should -BeTrue -Because $good }
            foreach ($bad in '', 'my laptop', '../x', 'a/b', 'trailing.', '-x', ('x' * 64)) { Test-PhxMachineName $bad | Should -BeFalse -Because $bad }
        }
    }
}

Describe 'state and change detection' {
    BeforeEach { $script:StateHome = Use-TestHome }

    It 'reads a duration as a TimeSpan, and nothing else' {
        InModuleScope PSPhoenix {
            (ConvertTo-PhxTimeSpan '30m').TotalMinutes | Should -Be 30
            (ConvertTo-PhxTimeSpan '2h').TotalHours | Should -Be 2
            (ConvertTo-PhxTimeSpan '1d').TotalDays | Should -Be 1
            foreach ($bad in '', '0h', '1w', '1.5h', '1H', ' 1h', '9999999m') { ConvertTo-PhxTimeSpan $bad | Should -BeNullOrEmpty -Because $bad }
        }
    }

    It 'starts from a fresh state when there is none, it is broken, or a newer PSPhoenix wrote it' {
        InModuleScope PSPhoenix {
            (Read-PhxState).version | Should -Be 1
            New-Item -ItemType Directory -Force -Path (Get-PhxStateDir) | Out-Null
            Set-Content -LiteralPath (Get-PhxStatePath) -Value '{ broken'
            (Read-PhxState -Quiet).files.Count | Should -Be 0
            Set-Content -LiteralPath (Get-PhxStatePath) -Value '{ "version": 99, "files": { "x": {} } }'
            (Read-PhxState -Quiet).files.Count | Should -Be 0
        }
    }

    It 'says why it ignores a state it cannot read' {
        InModuleScope PSPhoenix {
            New-Item -ItemType Directory -Force -Path (Get-PhxStateDir) | Out-Null
            Set-Content -LiteralPath (Get-PhxStatePath) -Value '{ "version": 99 }'
            $output = & { $null = Read-PhxState } 6>&1 | Out-String
            $output | Should -Match 'ignoring .*state\.json \(written by a newer PSPhoenix \(version 99\)\) - the next run takes everything as changed'
            & { $null = Read-PhxState -Quiet } 6>&1 | Out-String | Should -BeNullOrEmpty
        }
    }

    It 'reads the state the PowerShell version of PSPhoenix wrote' {
        # state.json as PSPhoenix wrote it before the engine had the state: ordered hashtables
        # through ConvertTo-Json, times as text, and a run in which nothing was due with the
        # providers @($null) - what @($providers.Name) of no providers is.
        $file = Join-Path $script:StateHome 'a.txt'
        Set-Content -LiteralPath $file -Value 'one'
        $item = Get-Item -LiteralPath $file
        InModuleScope PSPhoenix -Parameters @{ File = $file; Size = $item.Length; Mtime = $item.LastWriteTimeUtc.Ticks } {
            param($File, $Size, $Mtime)
            $now = [DateTime]::UtcNow
            $none = @()
            $old = [ordered]@{
                version     = 1
                lastRun     = [ordered]@{ at = $now.ToString('o'); providers = @($none.Name); failed = @(); log = 'C:\logs\run.log' }
                providers   = [ordered]@{ claude = [ordered]@{ lastRun = $now.AddMinutes(-10).ToString('o'); lastResult = 'ok' } }
                files       = [ordered]@{ claude = @{ $File = [ordered]@{ size = $Size; mtime = $Mtime; sha256 = (Get-PhxFileHash $File) } } }
                published   = [ordered]@{ claude = @{ 'a.txt' = 'AB' } }
                publishedTo = 'D:\Target\Box'
                refs        = @{}
            }
            New-Item -ItemType Directory -Force -Path (Get-PhxStateDir) | Out-Null
            Set-Content -LiteralPath (Get-PhxStatePath) -Value ($old | ConvertTo-Json -Depth 10 -Compress)
            $state = Read-PhxState
            @($state.lastRun.providers).Count | Should -Be 0
            $state.lastRun.log | Should -Be 'C:\logs\run.log'
            Test-PhxProviderDue -Provider @{ Name = 'claude'; Cadence = '1h' } -State $state | Should -BeFalse
            Test-PhxFileChanged -Files $state.Tracker('claude') -Path $File | Should -BeFalse
            $state.PublishedHashes('claude')['a.txt'] | Should -Be 'AB'
            $state.publishedTo | Should -Be 'D:\Target\Box'
        }
    }

    It 'saves and reads back providers, files, published hashes and refs' {
        # The engine's tests cover the format (PhxStateTests); this is the PowerShell side of it.
        $file = Join-Path $script:StateHome 'a.txt'
        Set-Content -LiteralPath $file -Value 'one'
        InModuleScope PSPhoenix -Parameters @{ File = $file } {
            param($File)
            $started = [datetime]::Parse('2026-10-09T10:00:00Z').ToUniversalTime()
            $state = New-PhxState
            $tracker = $state.Tracker('claude')
            Test-PhxFileChanged -Files $tracker -Path $File | Should -BeTrue
            $state.Succeeded('claude', $started, $tracker)
            $state.PublishInto('D:\Target\Box')
            $state.PublishedHashes('repos')['repos.json'] = 'CD'
            $state.Refs['C:/r'] = 'EF'
            Save-PhxState $state
            $read = Read-PhxState
            ConvertTo-PhxDateTime $read.providers['claude'].lastRun | Should -Be $started
            $read.providers['claude'].lastResult | Should -Be 'ok'
            $read.files['claude'][$File].sha256 | Should -Be (Get-PhxFileHash $File)
            $read.published['repos']['repos.json'] | Should -Be 'CD'
            $read.publishedTo | Should -Be 'D:\Target\Box'
            $read.refs['C:/r'] | Should -Be 'EF'
        }
    }

    It 'tells a changed file from a touched one, and forgets one that is gone' {
        $file = Join-Path $script:StateHome 'tracked.txt'
        Set-Content -LiteralPath $file -Value 'one'
        InModuleScope PSPhoenix -Parameters @{ File = $file } {
            param($File)
            # Each "run" starts from what the last one saw.
            $run = New-PhxFileTracker
            Test-PhxFileChanged -Files $run -Path $File | Out-Null
            (Get-Item -LiteralPath $File).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(10)
            $run = New-PhxFileTracker -Known $run.Seen
            Test-PhxFileChanged -Files $run -Path $File | Should -BeFalse          # touched, same bytes
            Set-Content -LiteralPath $File -Value 'two'
            $run = New-PhxFileTracker -Known $run.Seen
            Test-PhxFileChanged -Files $run -Path $File | Should -BeTrue           # changed
            Remove-Item -LiteralPath $File
            $run = New-PhxFileTracker -Known $run.Seen
            Test-PhxFileChanged -Files $run -Path $File | Should -BeTrue           # gone
            $run.Seen.ContainsKey($File) | Should -BeFalse
        }
    }

    It 'keeps a file a run no longer looks at out of what it saw, and leaves what the last run saw alone' {
        $kept = Join-Path $script:StateHome 'kept.txt'
        $dropped = Join-Path $script:StateHome 'dropped.txt'
        Set-Content -LiteralPath $kept, $dropped -Value 'x'
        InModuleScope PSPhoenix -Parameters @{ Kept = $kept; Dropped = $dropped } {
            param($Kept, $Dropped)
            $run = New-PhxFileTracker
            Test-PhxFileChanged -Files $run -Path $Kept | Out-Null
            Test-PhxFileChanged -Files $run -Path $Dropped | Out-Null
            $next = New-PhxFileTracker -Known $run.Seen
            Test-PhxFileChanged -Files $next -Path $Kept | Out-Null
            @($next.Seen.Keys) | Should -Be @($Kept)
            $next.Known.Count | Should -Be 2
        }
    }

    It 'gives each provider the files its own last run saw' {
        $file = Join-Path $script:StateHome 'a.txt'
        Set-Content -LiteralPath $file -Value 'one'
        InModuleScope PSPhoenix -Parameters @{ File = $file } {
            param($File)
            $state = New-PhxState
            $tracker = $state.Tracker('claude')
            Test-PhxFileChanged -Files $tracker -Path $File | Out-Null
            $state.Succeeded('claude', [DateTime]::UtcNow, $tracker)
            (New-PhxContext -Provider claude -State $state).Files.Known.Count | Should -Be 1
            (New-PhxContext -Provider repos -State $state).Files.Known.Count | Should -Be 0
        }
    }

    It 'runs a provider when its cadence has passed, a little early included' {
        InModuleScope PSPhoenix {
            $now = [datetime]::Parse('2026-10-09T12:00:00Z').ToUniversalTime()
            $provider = @{ Name = 'slow'; Cadence = '1h' }
            $state = New-PhxState
            Test-PhxProviderDue -Provider $provider -State $state -Now $now | Should -BeTrue            # never ran
            $state.Succeeded('slow', $now.AddMinutes(-30), (New-PhxFileTracker))
            Test-PhxProviderDue -Provider $provider -State $state -Now $now | Should -BeFalse
            $state.Succeeded('slow', $now.AddMinutes(-58), (New-PhxFileTracker))
            Test-PhxProviderDue -Provider $provider -State $state -Now $now | Should -BeTrue             # the hourly run, a bit early
            # The config overrides the provider's cadence; no cadence at all is every run.
            $config = @{ providers = @{ slow = @{ cadence = '1d' } } }
            Test-PhxProviderDue -Provider $provider -State $state -Config $config -Now $now | Should -BeFalse
            Test-PhxProviderDue -Provider @{ Name = 'every'; Cadence = $null } -State $state -Now $now | Should -BeTrue
            # Written before a wrong clock was put right: due, not "in 200 days".
            $state.Succeeded('slow', $now.AddDays(200), (New-PhxFileTracker))
            Test-PhxProviderDue -Provider $provider -State $state -Now $now | Should -BeTrue
            # The slack is a tenth of the cadence, at most five minutes: a day is not due 10 minutes early.
            $daily = @{ Name = 'daily'; Cadence = '1d' }
            $state.Succeeded('daily', $now.AddMinutes(-(24 * 60 - 10)), (New-PhxFileTracker))
            Test-PhxProviderDue -Provider $daily -State $state -Now $now | Should -BeFalse
            $state.Succeeded('daily', $now.AddMinutes(-(24 * 60 - 4)), (New-PhxFileTracker))
            Test-PhxProviderDue -Provider $daily -State $state -Now $now | Should -BeTrue
            # A failure keeps the last successful run: the provider is due again at once.
            $state.Failed('daily', 'boom')
            Test-PhxProviderDue -Provider $daily -State $state -Now $now | Should -BeTrue
        }
    }

    It 'scans when there is no scan, a root is missing from it, or it is a day old' {
        $repos = Join-Path $script:StateHome 'Repos'
        New-TestRepository (Join-Path $repos 'One') -Remote 'origin=https://github.com/o/one.git' | Out-Null
        phx roots add $repos 6>$null
        InModuleScope PSPhoenix { Test-PhxScanDue -Cache (Read-PhxRepoCache) -Config (Read-PhxConfig) } | Should -BeTrue
        phx scan 6>$null
        InModuleScope PSPhoenix { Test-PhxScanDue -Cache (Read-PhxRepoCache) -Config (Read-PhxConfig) } | Should -BeFalse
        InModuleScope PSPhoenix { Test-PhxScanDue -Cache (Read-PhxRepoCache) -Config (Read-PhxConfig) -Now ([DateTime]::UtcNow.AddDays(2)) } | Should -BeTrue
        $other = Join-Path $script:StateHome 'Other'
        New-Item -ItemType Directory -Path $other | Out-Null
        phx roots add $other 6>$null
        InModuleScope PSPhoenix { Test-PhxScanDue -Cache (Read-PhxRepoCache) -Config (Read-PhxConfig) } | Should -BeTrue
    }

    It 'hashes the refs of a repository: the same until a ref moves' {
        $repo = New-TestRepository (Join-Path $script:StateHome 'Refs')
        $first = InModuleScope PSPhoenix -Parameters @{ Path = $repo } { param($Path) Get-PhxRefsHash $Path }
        InModuleScope PSPhoenix -Parameters @{ Path = $repo } { param($Path) Get-PhxRefsHash $Path } | Should -Be $first
        git -C $repo -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m second
        InModuleScope PSPhoenix -Parameters @{ Path = $repo } { param($Path) Get-PhxRefsHash $Path } | Should -Not -Be $first
        git -C $repo switch -q -c side
        InModuleScope PSPhoenix -Parameters @{ Path = $repo } { param($Path) Get-PhxRefsHash $Path } | Should -Not -Be $first
    }

    It 'gives a provider the state store' {
        InModuleScope PSPhoenix {
            (New-PhxContext -Provider repos).State.version | Should -Be 1
            $state = New-PhxState
            [object]::ReferenceEquals((New-PhxContext -Provider repos -State $state).State, $state) | Should -BeTrue
        }
    }
}

Describe 'schedule' {
    BeforeEach {
        Use-TestHome | Out-Null
        Mock Test-PhxCanSchedule -ModuleName PSPhoenix { $true }
        $script:Registered = [Collections.Generic.List[object]]::new()
        $script:Unregistered = 0
        Mock Register-PhxScheduledTask -ModuleName PSPhoenix { $script:Registered.Add($Definition) }
        Mock Unregister-PhxScheduledTask -ModuleName PSPhoenix { $script:Unregistered++ }
        InModuleScope PSPhoenix { $c = Read-PhxConfig; Save-PhxConfig $c }
        function Invoke-TestSchedule {
            # phx schedule with the given words; its output, its error in $script:ScheduleError.
            param([string]$Action, [string]$Every)
            $script:ScheduleError = $null
            $verb, $span = $Action, $Every
            $output = Get-PhxOutput {
                if ($span) { phx schedule $verb -Every $span -ErrorAction SilentlyContinue -ErrorVariable failure }
                else { phx schedule $verb -ErrorAction SilentlyContinue -ErrorVariable failure }
                $script:ScheduleError = @($failure | Where-Object FullyQualifiedErrorId -Like 'PhxCommandFailed*')[0]
            }
            $output
        }
    }

    It 'registers the task with the interval of the config' {
        Invoke-TestSchedule on | Should -Match 'scheduled: every 1h and 5 minutes after logon'
        $script:Registered | Should -HaveCount 1
        $script:Registered[0].Interval | Should -Be ([TimeSpan]::FromHours(1))
    }

    It 'sets the interval with -Every, also without on, and refuses one out of range' {
        Invoke-TestSchedule '' '2h' | Should -Match 'scheduled: every 2h'
        (InModuleScope PSPhoenix { Read-PhxConfig }).interval | Should -Be '2h'
        $script:Registered[0].Interval | Should -Be ([TimeSpan]::FromHours(2))
        Invoke-TestSchedule on '5m' | Out-Null
        $script:ScheduleError.Exception.Message | Should -BeLike '*-Every 5m - give 15m to 31d*'
        (InModuleScope PSPhoenix { Read-PhxConfig }).interval | Should -Be '2h'
        $script:Registered | Should -HaveCount 1
    }

    It 'needs phx init first' {
        Use-TestHome | Out-Null
        Invoke-TestSchedule on | Out-Null
        $script:ScheduleError.Exception.Message | Should -BeLike '*not set up yet*'
        $script:Registered | Should -HaveCount 0
    }

    It 'removes the task, and says when there is none' {
        Invoke-TestSchedule off | Should -Match 'not scheduled - nothing to turn off'
        $script:Unregistered | Should -Be 0
        Mock Get-PhxScheduledTask -ModuleName PSPhoenix { [pscustomobject]@{ Arguments = 'x'; Interval = [TimeSpan]::FromHours(1) } }
        Invoke-TestSchedule off | Should -Match 'turned off'
        $script:Unregistered | Should -Be 1
    }

    It 'shows the task, its last and next run, and what is wrong with it' {
        Invoke-TestSchedule status | Should -Match 'not scheduled - phx schedule on'
        Invoke-TestSchedule | Should -Match 'not scheduled'
        $script:ScheduledTask = InModuleScope PSPhoenix {
            $definition = New-PhxTaskDefinition -Interval ([TimeSpan]::FromHours(4))
            [pscustomobject]@{ Arguments = $definition.Arguments; Interval = $definition.Interval; LastRunTime = [datetime]'2026-10-12 08:00'; LastResult = 1; NextRunTime = [datetime]'2026-10-12 12:00' }
        }
        Mock Get-PhxScheduledTask -ModuleName PSPhoenix { $script:ScheduledTask }
        # How the last run went comes from the state: through conhost the Task Scheduler sees 0.
        InModuleScope PSPhoenix {
            $state = New-PhxState
            $state.LastRun = [PSPhoenix.Engine.RunRecord]::new([DateTime]::UtcNow, [string[]]@('repos'), [string[]]@('repos'), 'C:\logs\run.log')
            Save-PhxState $state
        }
        $output = Invoke-TestSchedule status
        $output | Should -Match 'started\s+2026-10-12 08:00'
        $output | Should -Match 'last run\s+just now, failed: repos - log: C:\\logs\\run.log'
        $output | Should -Match 'next run\s+2026-10-12 12:00'
        $output | Should -Match 'it runs every 4h, the config says 1h - phx schedule on'
    }

    It 'takes -Every only with on, and leaves the config alone when registering fails' {
        Invoke-TestSchedule off '2h' | Out-Null
        $script:ScheduleError.Exception.Message | Should -BeLike '*-Every goes with on*'
        Mock Register-PhxScheduledTask -ModuleName PSPhoenix { throw 'Access is denied' }
        Invoke-TestSchedule on '2h' | Out-Null
        $script:ScheduleError.Exception.Message | Should -BeLike '*Access is denied*'
        (InModuleScope PSPhoenix { Read-PhxConfig }).interval | Should -Be '1h'
    }

    It 'names what is wrong with a task: a PowerShell that is gone, an action it does not know' {
        InModuleScope PSPhoenix {
            $config = Read-PhxConfig
            $good = New-PhxTaskDefinition -Interval ([TimeSpan]::FromHours(1))
            $gone = [pscustomobject]@{ Arguments = $good.Arguments.Replace($good.Pwsh, 'C:\gone\pwsh.exe'); Interval = $good.Interval }
            @(Get-PhxScheduleProblem -Task $gone -Config $config) | Should -Match 'starts C:\\gone\\pwsh.exe, which is gone'
            $other = [pscustomobject]@{ Arguments = 'something else'; Interval = $good.Interval }
            @(Get-PhxScheduleProblem -Task $other -Config $config) | Should -Match 'not the one phx schedule on sets'
            @(Get-PhxScheduleProblem -Task ([pscustomobject]@{ Arguments = $good.Arguments; Interval = $good.Interval }) -Config $config) | Should -HaveCount 0
        }
    }

    It 'starts the PowerShell of this installation, a Store one through its alias' {
        $store = Join-Path $TestDrive 'Program Files/WindowsApps/Microsoft.PowerShell_7.5.0.0_x64__8wekyb3d8bbwe'
        $local = Join-Path $TestDrive 'Local'
        New-Item -ItemType Directory -Force -Path (Join-Path $local 'Microsoft/WindowsApps') | Out-Null
        Set-Content -LiteralPath (Join-Path $local 'Microsoft/WindowsApps/pwsh.exe') -Value ''
        InModuleScope PSPhoenix -Parameters @{ Store = $store; Local = $local } {
            param($Store, $Local)
            $script:OnWindowsSaved = $script:OnWindows
            $script:OnWindows = $true
            try {
                Get-PhxPwshPath -PowerShellHome $Store -LocalAppData $Local | Should -Be ([IO.Path]::Combine($Local, 'Microsoft', 'WindowsApps', 'pwsh.exe'))
                Get-PhxPwshPath -PowerShellHome 'C:\Program Files\PowerShell\7' -LocalAppData $Local | Should -Be ([IO.Path]::Combine('C:\Program Files\PowerShell\7', 'pwsh.exe'))
            }
            finally { $script:OnWindows = $script:OnWindowsSaved }
        }
    }

    It 'reads a registered task into a plain object' {
        InModuleScope PSPhoenix {
            $task = [pscustomobject]@{
                Actions  = @([pscustomobject]@{ Arguments = '--headless "pwsh.exe" -File "x"' })
                Triggers = @([pscustomobject]@{ Repetition = [pscustomobject]@{ Interval = $null } }, [pscustomobject]@{ Repetition = [pscustomobject]@{ Interval = 'PT2H' } })
            }
            $info = [pscustomobject]@{ LastRunTime = [datetime]'2026-10-12 08:00'; NextRunTime = [datetime]'2026-10-12 10:00'; LastTaskResult = 0 }
            $read = ConvertFrom-PhxScheduledTask -Task $task -Info $info
            $read.Arguments | Should -Be '--headless "pwsh.exe" -File "x"'
            $read.Interval | Should -Be ([TimeSpan]::FromHours(2))
            $read.NextRunTime | Should -Be ([datetime]'2026-10-12 10:00')
        }
    }

    It 'builds the task with the triggers, settings and principal of the design' -Skip:(-not $IsWindows) {
        # New-ScheduledTask* only build objects in memory - nothing is registered.
        $task = InModuleScope PSPhoenix { New-PhxScheduledTask (New-PhxTaskDefinition -Interval ([TimeSpan]::FromHours(1)) -ModulePath 'C:\M' -Pwsh 'C:\P\pwsh.exe') }
        $task.Actions[0].Execute | Should -Be 'conhost.exe'
        @($task.Triggers) | Should -HaveCount 2
        $task.Triggers[0].Repetition.Interval | Should -Be 'PT1H'
        $task.Triggers[0].Repetition.Duration | Should -BeNullOrEmpty
        $task.Triggers[1].Delay | Should -Be 'PT5M'
        $task.Settings.StartWhenAvailable | Should -BeTrue
        $task.Settings.MultipleInstances | Should -Be 'IgnoreNew'
        $task.Settings.ExecutionTimeLimit | Should -Be 'PT15M'
        $task.Settings.Priority | Should -Be 7
        $task.Settings.DisallowStartIfOnBatteries | Should -BeFalse
        $task.Principal.LogonType | Should -Be 'Interactive'
        $task.Principal.RunLevel | Should -Be 'Limited'
    }

    It 'says where it does not work yet, and refuses an unknown action' {
        Invoke-TestSchedule frob | Out-Null
        $script:ScheduleError.Exception.Message | Should -BeLike "*unknown action 'frob'*"
        Mock Test-PhxCanSchedule -ModuleName PSPhoenix { $false }
        Invoke-TestSchedule on | Out-Null
        $script:ScheduleError.Exception.Message | Should -BeLike '*runs on Windows for now*#5*'
    }

    It 'defines a headless task that runs phx-task.ps1 of a module folder an update keeps' {
        InModuleScope PSPhoenix {
            $definition = New-PhxTaskDefinition -Interval ([TimeSpan]::FromMinutes(30)) -ModulePath 'C:\Mods\PSPhoenix' -Pwsh 'C:\PS\pwsh.exe'
            $definition.Execute | Should -Be 'conhost.exe'
            $definition.Arguments | Should -Be ('--headless "C:\PS\pwsh.exe" -NoProfile -NonInteractive -File "' + [IO.Path]::Combine('C:\Mods\PSPhoenix', 'phx-task.ps1') + '"')
            $definition.LogonDelay | Should -Be ([TimeSpan]::FromMinutes(5))
            $definition.ExecutionLimit | Should -Be ([TimeSpan]::FromMinutes(15))
            $definition.Priority | Should -Be 7
        }
        $apps = Join-Path $TestDrive 'scoop/apps/psphoenix'
        New-Item -ItemType Directory -Force -Path (Join-Path $apps '0.2.0'), (Join-Path $apps 'current') | Out-Null
        InModuleScope PSPhoenix -Parameters @{ Apps = $apps } {
            param($Apps)
            Get-PhxStableModulePath -ModuleBase (Join-Path $Apps '0.2.0') -Version '0.2.0' | Should -Be (Join-Path $Apps 'current')
            Get-PhxStableModulePath -ModuleBase (Join-Path $Apps '0.2.0') -Version '0.3.0' | Should -Be (Join-Path $Apps '0.2.0')
            Get-PhxStableModulePath -ModuleBase (Join-Path $TestDrive 'modules/PSPhoenix') -Version '0.2.0' | Should -Be (Join-Path $TestDrive 'modules/PSPhoenix')
            Format-PhxSpan ([TimeSpan]::FromMinutes(30)) | Should -Be '30m'
            Format-PhxSpan ([TimeSpan]::FromMinutes(90)) | Should -Be '90m'
            Format-PhxSpan ([TimeSpan]::FromHours(2)) | Should -Be '2h'
            Format-PhxSpan ([TimeSpan]::FromDays(1)) | Should -Be '1d'
        }
    }
}

Describe 'run' {
    BeforeEach {
        $script:RunHome = Use-TestHome
        $script:RunTarget = Join-Path $script:RunHome 'Target'
        $script:RunSnapshot = Join-Path $script:RunTarget 'Box'
        New-Item -ItemType Directory -Path $script:RunTarget | Out-Null
        InModuleScope PSPhoenix -Parameters @{ Target = $script:RunTarget } {
            param($Target)
            $c = Read-PhxConfig
            $c.target = [ordered]@{ type = 'folder'; path = $Target }
            $c.machine = [ordered]@{ name = 'Box'; id = 'id-box' }
            Save-PhxConfig $c
            # Test providers only - the repos provider has tests of its own.
            $script:SavedProviders = $script:PhxProviders
            $script:PhxProviders = [ordered]@{}
            $script:AlphaText = 'alpha 1'
            $script:BrokenFails = $false
            Register-PhxProvider @{ Name = 'alpha'; Description = 'every run'; Restore = {}; Status = {}
                Backup = { param($Context) Set-Content -LiteralPath (Join-Path $Context.Staging 'alpha.txt') -Value $script:AlphaText; & $Context.Log 'alpha wrote its file' }
            }
            Register-PhxProvider @{ Name = 'slow'; Description = 'once a day'; Cadence = '1d'; Restore = {}; Status = {}
                Backup = { param($Context) Set-Content -LiteralPath (Join-Path $Context.Staging 'slow.txt') -Value 'slow' }
            }
        }
        function Invoke-TestRun {
            # phx run with real switches; its output, and its error as $script:RunError.
            param([string]$Provider)
            $script:RunError = $null
            $output = if ($Provider) { Get-PhxOutput { phx run -Provider $Provider -ErrorAction SilentlyContinue -ErrorVariable failure; $script:RunError = $failure } }
            else { Get-PhxOutput { phx run -ErrorAction SilentlyContinue -ErrorVariable failure; $script:RunError = $failure } }
            $script:RunError = @($script:RunError | Where-Object FullyQualifiedErrorId -Like 'PhxCommandFailed*')[0]
            $output
        }
        function Get-TestFileTimes { @(Get-ChildItem -LiteralPath $script:RunSnapshot -Recurse -File | ForEach-Object { "$($_.FullName)|$($_.LastWriteTimeUtc.Ticks)" }) }
        function Register-TestLeakyProvider {
            # A provider that stages a file of every kind of secret the detector knows (#45), one
            # copied in, one written around the writer, and one clean file.
            # One file per kind the detector knows (#45), built at run time: nothing token-like is committed.
            $script:Secrets = [ordered]@{
                'github.txt'     = 'gh' + 'p_' + 'a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8'
                'gitlab.txt'     = 'gl' + 'pat-' + ('q' * 20)
                'slack.txt'      = 'xo' + 'xb-' + '1234567890-abcdefghijklmnopqrstuvwx'
                'aws.txt'        = 'AK' + 'IA' + 'ABCDEFGHIJKLMNOP'
                'npm.txt'        = 'np' + 'm_' + ('a1b2' * 9)
                'apikey.txt'     = 's' + 'k-proj-' + 'a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6'
                'azdo.txt'       = ('a1B2c3D4' * 9) + 'a1B2' + 'AZ' + 'DO' + 'x9Y8'
                'jwt.txt'        = 'ey' + 'JhbGciOiJIUzI1NiJ9.ey' + 'JzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV'
                'key.pem'        = 'MIIEowIBAAKCAQEA' + ('x7Y6' * 12)
                'remote.txt'     = 'hunter2'
                'header.txt'     = 'a1B2c3D4e5F6g7H8'
                'database.txt'   = 'Winter2024!'
                'storage.txt'    = 'a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8=='
                'nuget.config'   = 'pa55word!'
                'profile.ps1'    = 'f3a9c27d81e4b605f3a9c27d81e4b605'
                'appsettings.json' = 'Zx9Qw3Er7Ty1Ui5Op2As8Df4'
            }
            $script:SecretText = @{
                'key.pem'        = { param($v) "-----BEGIN RSA PRIVATE" + " KEY-----`n$v`n-----END RSA PRIVATE KEY-----" }
                'remote.txt'     = { param($v) "url = https://wouter:$v@example.invalid/x.git" }
                'header.txt'     = { param($v) "Authorization: Bearer $v" }
                'database.txt'   = { param($v) "Server=db;User Id=sa;Password=$v;" }
                'storage.txt'    = { param($v) "DefaultEndpointsProtocol=https;AccountName=x;AccountKey=$v;" }
                'nuget.config'   = { param($v) "<add key=`"ClearTextPassword`" value=`"$v`" />" }
                'profile.ps1'    = { param($v) "Set-Location ~`n`$env:MY_API_TOKEN = '$v'" }
                'appsettings.json' = { param($v) "{`n  `"ClientSecret`": `"$v`"`n}" }
            }
            $copySource = Join-Path $script:RunHome 'copied.ps1'
            Set-Content -LiteralPath $copySource -Value "`$env:GH_TOKEN = '$($script:Secrets['github.txt'])'"
            InModuleScope PSPhoenix -Parameters @{ Secrets = $script:Secrets; SecretText = $script:SecretText; CopySource = $copySource } {
                param($Secrets, $SecretText, $CopySource)
                # The provider runs in the module: what it uses goes there.
                $script:Secrets = $Secrets
                $script:SecretText = $SecretText
                $script:CopySource = $CopySource
                Register-PhxProvider @{ Name = 'leaky'; Description = 'stages secrets'; Restore = {}; Status = {}
                    Backup = {
                        param($Context)
                        Write-PhxStagedText -Context $Context -Path 'clean.txt' -Value 'nothing to see'
                        foreach ($name in $script:Secrets.Keys) {
                            $text = if ($script:SecretText.ContainsKey($name)) { & $script:SecretText[$name] $script:Secrets[$name] } else { "token $($script:Secrets[$name])" }
                            Write-PhxStagedText -Context $Context -Path "sub/$name" -Value $text
                        }
                        Copy-PhxStagedFile -Context $Context -Source $script:CopySource -Path 'copied.ps1'
                        # Around the writer: the check before publishing catches it.
                        Set-Content -LiteralPath (Join-Path $Context.Staging 'direct.txt') -Value "token $($script:Secrets['gitlab.txt'])"
                    }
                }
            }
        }
    }
    AfterEach {
        InModuleScope PSPhoenix { $script:PhxProviders = $script:SavedProviders }
    }

    It 'refuses to run before phx init, and without its target folder' {
        Use-TestHome | Out-Null
        Invoke-TestRun | Out-Null
        $script:RunError.Exception.Message | Should -BeLike '*not set up yet - run: phx init*'
        Use-TestHome | Out-Null
        InModuleScope PSPhoenix -Parameters @{ Target = (Join-Path $TestDrive 'unplugged') } {
            param($Target)
            $c = Read-PhxConfig; $c.target = [ordered]@{ type = 'folder'; path = $Target }; Save-PhxConfig $c
        }
        Invoke-TestRun | Out-Null
        $script:RunError.Exception.Message | Should -BeLike '*unplugged not found - a disconnected drive?*'
    }

    It 'runs the providers, publishes them, records the run and logs it' {
        $output = Invoke-TestRun
        $script:RunError | Should -BeNullOrEmpty
        $output | Should -Match 'alpha wrote its file'
        $output | Should -Match 'done in .*2 provider\(s\)'
        Get-Content -LiteralPath (Join-Path $script:RunSnapshot 'alpha/alpha.txt') | Should -Be 'alpha 1'
        Test-Path -LiteralPath (Join-Path $script:RunSnapshot 'slow/slow.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:RunSnapshot 'phoenix.json') | Should -BeTrue
        $state = InModuleScope PSPhoenix { Read-PhxState }
        $state.providers['alpha'].lastResult | Should -Be 'ok'
        @($state.lastRun.providers) | Should -Be @('alpha', 'slow')
        Get-Content -LiteralPath $state.lastRun.log -Raw | Should -Match '\[alpha\] alpha wrote its file'
        Get-PhxOutput { phx status } | Should -Match 'last run\s+just now - 2 provider\(s\), all fine'
    }

    It 'writes nothing when nothing changed, and leaves out a provider that is not due' {
        Invoke-TestRun | Out-Null
        $before = Get-TestFileTimes
        Start-Sleep -Milliseconds 50
        $output = Invoke-TestRun
        $output | Should -Match 'slow: not due yet'
        $output | Should -Match 'alpha: 0 written, 1 unchanged, 0 removed'
        Get-TestFileTimes | Should -Be $before
        # -Provider runs the one named, due or not.
        Invoke-TestRun -Provider slow | Should -Match 'slow: 0 written, 1 unchanged'
    }

    It 'holds back every staged file with a secret in it, and keeps the secret out of the snapshot, staging, log and output' {
        Register-TestLeakyProvider
        $output = Invoke-TestRun
        $script:RunError | Should -BeNullOrEmpty
        $held = $script:Secrets.Count + 2
        $output | Should -Match "leaky: 1 written, 0 unchanged, 0 removed, $held held back \(no age key yet\)"
        $output | Should -Match 'held back sub/github\.txt line 1: a GitHub token - a secret is only stored encrypted, and there is no age key yet: phx init'
        $output | Should -Match 'held back sub/appsettings\.json line 2: a secret value \(ClientSecret\)'
        $output | Should -Match 'held back direct\.txt line 1: a GitLab token'
        # Only the clean file anywhere: in the snapshot and in staging.
        @(Get-ChildItem -LiteralPath (Join-Path $script:RunSnapshot 'leaky') -Recurse -File).Name | Should -Be @('clean.txt')
        $staging = InModuleScope PSPhoenix { Get-PhxStagingPath leaky }
        @(Get-ChildItem -LiteralPath $staging -Recurse -File).Name | Should -Be @('clean.txt')
        $state = InModuleScope PSPhoenix { Read-PhxState }
        @($state.Providers['leaky'].Withheld).Count | Should -Be $held
        $everything = @(
            $output
            Get-Content -LiteralPath $state.lastRun.log -Raw
            Get-Content -LiteralPath (InModuleScope PSPhoenix { Get-PhxStatePath }) -Raw
            Get-ChildItem -LiteralPath $script:RunSnapshot, $staging -Recurse -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }
        ) -join "`n"
        foreach ($secret in $script:Secrets.Values) { $everything.Contains($secret) | Should -BeFalse -Because 'no secret may reach a snapshot, the staging folder, the log or the output' }
        $status = Get-PhxOutput { phx status }
        $status | Should -Match "secrets\s+$held file\(s\) held back, not in the snapshot - a secret is only stored encrypted, and there is no age key yet - phx init"
        $status | Should -Match 'thing\(s\) need attention'
        foreach ($secret in $script:Secrets.Values) { $status.Contains($secret) | Should -BeFalse }
    }

    It 'encrypts every staged file with a secret to the age key, and keeps the ciphertext while nothing changed' {
        $key = [PSPhoenix.Engine.Age]::NewKey()
        InModuleScope PSPhoenix -Parameters @{ Recipient = $key.Recipient } { param($Recipient) $c = Read-PhxConfig; $c.secrets.recipient = $Recipient; Save-PhxConfig $c }
        Register-TestLeakyProvider
        $output = Invoke-TestRun
        $script:RunError | Should -BeNullOrEmpty
        $sealed = $script:Secrets.Count + 2
        $output | Should -Match "leaky: $($sealed + 1) written, 0 unchanged, 0 removed, $sealed encrypted"
        $output | Should -Match 'encrypted sub/appsettings\.json line 2: a secret value \(ClientSecret\)'
        $output | Should -Not -Match 'held back'
        $leaky = Join-Path $script:RunSnapshot 'leaky'
        @(Get-ChildItem -LiteralPath $leaky -Recurse -File | Where-Object Extension -NE '.age').Name | Should -Be @('clean.txt')
        @(Get-ChildItem -LiteralPath $leaky -Recurse -Filter '*.age').Count | Should -Be $sealed
        # The age file opens with the key - and only the secret half of it.
        $opened = [Text.Encoding]::UTF8.GetString([PSPhoenix.Engine.Age]::Decrypt([IO.File]::ReadAllBytes((Join-Path $leaky 'sub/database.txt.age')), $key.Identity))
        $opened | Should -BeExactly "Server=db;User Id=sa;Password=$($script:Secrets['database.txt']);"
        [Text.Encoding]::UTF8.GetString([PSPhoenix.Engine.Age]::Decrypt([IO.File]::ReadAllBytes((Join-Path $leaky 'direct.txt.age')), $key.Identity)) | Should -Match ([regex]::Escape($script:Secrets['gitlab.txt']))
        $staging = InModuleScope PSPhoenix { Get-PhxStagingPath leaky }
        $everything = @(
            $output
            Get-ChildItem -LiteralPath $script:RunSnapshot, $staging -Recurse -File | ForEach-Object { [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($_.FullName)) }
        ) -join "`n"
        foreach ($secret in $script:Secrets.Values) { $everything.Contains($secret) | Should -BeFalse -Because 'only ciphertext reaches staging and the snapshot' }
        # Nothing changed: the same ciphertext, so nothing is written and a sync client uploads nothing.
        $before = @(Get-ChildItem -LiteralPath $leaky -Recurse -File | ForEach-Object { "$($_.FullName)|$($_.LastWriteTimeUtc.Ticks)" })
        Start-Sleep -Milliseconds 50
        Invoke-TestRun | Should -Match "leaky: 0 written, $($sealed + 1) unchanged, 0 removed, $sealed encrypted"
        @(Get-ChildItem -LiteralPath $leaky -Recurse -File | ForEach-Object { "$($_.FullName)|$($_.LastWriteTimeUtc.Ticks)" }) | Should -Be $before
        Get-PhxOutput { phx status } | Should -Match "secrets\s+encrypted to $([regex]::Escape($key.Recipient.Substring(0, 12)))\.\.\..* no copy of the key in the snapshot"
    }

    It 'stages only inside the staging folder, and fails on a secret in a file the snapshot cannot do without' {
        InModuleScope PSPhoenix -Parameters @{ Staging = (Join-Path $script:RunHome 'stage') } {
            param($Staging)
            $context = New-PhxContext -Provider 'x' -Staging $Staging -Config (Read-PhxConfig)
            { Write-PhxStagedText -Context $context -Path '../out.txt' -Value 'x' } | Should -Throw '*leads out of the staging folder*'
            { Write-PhxStagedText -Context $context -Path ([IO.Path]::Combine($Staging, 'a.txt')) -Value 'x' } | Should -Throw '*not a path inside the staging folder*'
            $token = 'gh' + 'p_' + 'a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8'
            { Write-PhxStagedText -Context $context -Path 'repos.json' -Value "{ `"t`": `"$token`" }" -FailOnSecret } | Should -Throw 'repos.json line 1: a GitHub token - not staged'
            [IO.File]::Exists((Join-Path $Staging 'repos.json')) | Should -BeFalse
            $context.Withheld.Count | Should -Be 0
        }
    }

    It 'keeps what a provider held back until its next successful run' {
        InModuleScope PSPhoenix {
            $script:LeakNow = $true
            Register-PhxProvider @{ Name = 'sometimes'; Description = 'a secret, then none'; Restore = {}; Status = {}
                Backup = {
                    param($Context)
                    $value = if ($script:LeakNow) { "Password=$('Winter' + '2024!');" } else { 'Password=$(DbPassword);' }
                    Write-PhxStagedText -Context $Context -Path 'db.txt' -Value $value
                }
            }
        }
        Invoke-TestRun | Out-Null
        Get-PhxOutput { phx status } | Should -Match 'secrets\s+1 file\(s\) held back.*sometimes/db\.txt line 1: a password \(Password\)'
        InModuleScope PSPhoenix { $script:LeakNow = $false }
        Invoke-TestRun -Provider sometimes | Should -Match 'sometimes: 1 written'
        Get-PhxOutput { phx status } | Should -Not -Match 'file\(s\) held back'
        Test-Path -LiteralPath (Join-Path $script:RunSnapshot 'sometimes/db.txt') | Should -BeTrue
    }

    It 'records a run in which nothing was due as one without providers' {
        Invoke-TestRun | Out-Null
        InModuleScope PSPhoenix { $c = Read-PhxConfig; $c.providers = [ordered]@{ alpha = [ordered]@{ enabled = $false } }; Save-PhxConfig $c }
        Invoke-TestRun | Should -Match 'done in .*: 0 provider\(s\)'
        @((InModuleScope PSPhoenix { Read-PhxState }).lastRun.providers).Count | Should -Be 0
        Get-PhxOutput { phx status } | Should -Match 'last run\s+just now - 0 provider\(s\), all fine'
    }

    It 'keeps going when a provider fails, keeps its last snapshot, and fails at the end' {
        InModuleScope PSPhoenix {
            Register-PhxProvider @{ Name = 'flaky'; Description = 'fails on demand'; Restore = {}; Status = {}
                Backup = { param($Context) if ($script:BrokenFails) { throw 'boom' }; Set-Content -LiteralPath (Join-Path $Context.Staging 'flaky.txt') -Value 'good' }
            }
        }
        Invoke-TestRun | Out-Null
        InModuleScope PSPhoenix { $script:BrokenFails = $true; $script:AlphaText = 'alpha 2' }
        $output = Invoke-TestRun
        $output | Should -Match 'flaky failed: boom'
        $script:RunError.Exception.Message | Should -BeLike '*1 provider(s) failed: flaky - log:*'
        Get-Content -LiteralPath (Join-Path $script:RunSnapshot 'flaky/flaky.txt') | Should -Be 'good'
        Get-Content -LiteralPath (Join-Path $script:RunSnapshot 'alpha/alpha.txt') | Should -Be 'alpha 2'
        (InModuleScope PSPhoenix { Read-PhxState }).providers['flaky'].lastResult | Should -Be 'failed: boom'
        Get-PhxOutput { phx status } | Should -Match 'last run\s+just now - failed: flaky'
    }

    It 'leaves out a disabled provider, and refuses one it does not know' {
        InModuleScope PSPhoenix { $c = Read-PhxConfig; $c.providers['alpha'] = [ordered]@{ enabled = $false }; Save-PhxConfig $c }
        Invoke-TestRun | Should -Match 'alpha: disabled in the config'
        Test-Path -LiteralPath (Join-Path $script:RunSnapshot 'alpha') | Should -BeFalse
        Invoke-TestRun -Provider nope | Out-Null
        $script:RunError.Exception.Message | Should -BeLike "*no provider 'nope'*"
    }

    It 'refuses to run while another run holds the lock, and writes nothing then' {
        # A config from before machine ids: a run that does not run must not give it one.
        InModuleScope PSPhoenix { $c = Read-PhxConfig; $c.machine = [ordered]@{ name = 'Box'; id = $null }; Save-PhxConfig $c }
        $before = Get-Content -LiteralPath (InModuleScope PSPhoenix { Get-PhxConfigPath }) -Raw
        $lockPath = Join-Path (InModuleScope PSPhoenix { Get-PhxStateDir }) 'run.lock'
        New-Item -ItemType Directory -Force -Path (Split-Path $lockPath) | Out-Null
        $held = [IO.FileStream]::new($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            Invoke-TestRun | Out-Null
            $script:RunError.Exception.Message | Should -BeLike '*another phx run is in progress*'
            Get-Content -LiteralPath (InModuleScope PSPhoenix { Get-PhxConfigPath }) -Raw | Should -Be $before
        }
        finally { $held.Dispose() }
        Invoke-TestRun | Out-Null
        $script:RunError | Should -BeNullOrEmpty
    }

    It 'gives a config from before machine ids one, and refuses the folder of another installation' {
        InModuleScope PSPhoenix { $c = Read-PhxConfig; $c.machine = [ordered]@{ name = $null; id = $null }; $c.machine.name = 'Box'; Save-PhxConfig $c }
        Invoke-TestRun | Out-Null
        $id = (InModuleScope PSPhoenix { Read-PhxConfig }).machine.id
        [guid]::Parse($id) | Should -Not -BeNullOrEmpty
        InModuleScope PSPhoenix { $c = Read-PhxConfig; $c.machine.id = 'someone-else'; Save-PhxConfig $c }
        Invoke-TestRun | Out-Null
        $script:RunError.Exception.Message | Should -BeLike '*holds the snapshot of another installation*'
    }

    It 'scans first when discovery is due' {
        $repos = Join-Path $script:RunHome 'Repos'
        New-TestRepository (Join-Path $repos 'One') -Remote 'origin=https://github.com/o/one.git' | Out-Null
        phx roots add $repos 6>$null
        Invoke-TestRun | Should -Match 'scan: discovery is due'
        Invoke-TestRun | Should -Not -Match 'scan: discovery is due'
    }

    It 'publishes nothing of a provider that failed half-way, and keeps no file state of it' {
        $tracked = Join-Path $script:RunHome 'tracked.txt'
        Set-Content -LiteralPath $tracked -Value 'v1'
        InModuleScope PSPhoenix -Parameters @{ Tracked = $tracked } {
            param($Tracked)
            $script:TrackedFile = $Tracked
            $script:HalfFails = $false
            $script:SawChange = $null
            Register-PhxProvider @{ Name = 'half'; Description = 'stages, then fails'; Restore = {}; Status = {}
                Backup = {
                    param($Context)
                    $script:SawChange = Test-PhxFileChanged -Files $Context.Files -Path $script:TrackedFile
                    Set-Content -LiteralPath (Join-Path $Context.Staging 'half.txt') -Value 'half'
                    if ($script:HalfFails) { throw 'died half-way' }
                }
            }
        }
        Invoke-TestRun | Out-Null
        Set-Content -LiteralPath $tracked -Value 'v2'
        Remove-Item -LiteralPath (Join-Path $script:RunSnapshot 'half/half.txt')
        InModuleScope PSPhoenix { $script:HalfFails = $true }
        Invoke-TestRun | Out-Null
        InModuleScope PSPhoenix { $script:SawChange } | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:RunSnapshot 'half/half.txt') | Should -BeFalse
        # The failed run did not record v2 as seen: the next run still sees the change.
        InModuleScope PSPhoenix { $script:HalfFails = $false }
        Invoke-TestRun | Out-Null
        InModuleScope PSPhoenix { $script:SawChange } | Should -BeTrue
    }

    It 'keeps tokens out of the log, logs warnings, and counts a written error as a failure' {
        InModuleScope PSPhoenix {
            $script:FakeToken = 'ghp_' + ('a' * 36)
            Register-PhxProvider @{ Name = 'noisy'; Description = 'prints'; Restore = {}; Status = {}
                Backup = {
                    param($Context)
                    & $Context.Log "the token is $script:FakeToken"
                    Write-Warning 'something odd'
                    Write-Error 'something broke'
                }
            }
        }
        $output = Invoke-TestRun
        $output | Should -Match 'noisy failed: 1 error\(s\): something broke'
        $log = Get-Content -LiteralPath (InModuleScope PSPhoenix { Read-PhxState }).lastRun.log -Raw
        $log | Should -Not -Match 'ghp_a'
        $log | Should -Match '\[noisy\] the token is \*\*\*'
        $log | Should -Match '\[noisy\] warning: something odd'
        $log | Should -Match '\[noisy\] error: something broke'
    }

    It 'records the start of the run as the providers'' last run' {
        InModuleScope PSPhoenix {
            Register-PhxProvider @{ Name = 'clock'; Description = 'notes the time'; Restore = {}; Status = {}
                Backup = { $script:ClockRan = [DateTime]::UtcNow }
            }
        }
        Invoke-TestRun | Out-Null
        $lastRun = InModuleScope PSPhoenix { ConvertTo-PhxDateTime (Read-PhxState).providers['clock'].lastRun }
        $lastRun | Should -BeLessOrEqual (InModuleScope PSPhoenix { $script:ClockRan })
    }

    It 'does not probe the target with a file of its own' {
        # Creating and deleting a probe file in OneDrive every hour is an upload every hour.
        Mock Test-PhxWritableFolder -ModuleName PSPhoenix { throw 'probed' }
        Invoke-TestRun | Out-Null
        $script:RunError | Should -BeNullOrEmpty
    }

    It 'publishes the other providers when one cannot be, and records the run' -Skip:(-not $IsWindows) {
        # Windows holds a file open without sharing; Linux lets a rename replace it anyway.
        Invoke-TestRun | Out-Null
        InModuleScope PSPhoenix { $script:AlphaText = 'alpha 2' }
        $held = [IO.File]::Open((Join-Path $script:RunSnapshot 'alpha/alpha.txt'), 'Open', 'Read', 'None')
        try {
            InModuleScope PSPhoenix { $script:SlowNow = $true }
            $output = Invoke-TestRun -Provider alpha
            $output | Should -Match 'alpha failed to publish: alpha.txt:'
            $script:RunError.Exception.Message | Should -BeLike '*1 provider(s) failed: alpha*'
        }
        finally { $held.Dispose() }
        $state = InModuleScope PSPhoenix { Read-PhxState }
        @($state.lastRun.failed) | Should -Be @('alpha')
        $state.providers['alpha'].lastResult | Should -BeLike 'failed: alpha.txt:*'
    }

    It 'goes on with the last scan when the scan fails' {
        $repos = Join-Path $script:RunHome 'Repos'
        New-Item -ItemType Directory -Path $repos | Out-Null
        phx roots add $repos 6>$null
        Mock Invoke-PhxScan -ModuleName PSPhoenix { throw 'the disk went away' }
        Invoke-TestRun | Should -Match 'scan failed: the disk went away - going on with the last scan'
        $script:RunError | Should -BeNullOrEmpty
    }

    It 'copes with a line without a colour, as a host without a console writes it' {
        # On a CI runner a plain Write-Host line carries colour -1, which Write-Host itself refuses.
        InModuleScope PSPhoenix {
            $message = [System.Management.Automation.HostInformationMessage]@{ Message = 'plain'; ForegroundColor = [Enum]::ToObject([ConsoleColor], -1) }
            { Invoke-PhxLogged -Action { Write-Information -MessageData $message -InformationAction Continue } 6>$null } | Should -Not -Throw
        }
    }

    It 'keeps only the newest logs' {
        InModuleScope PSPhoenix { $script:SavedKeep = $script:PhxRunLogKeep; $script:PhxRunLogKeep = 2 }
        try { 1..3 | ForEach-Object { Invoke-TestRun | Out-Null } }
        finally { InModuleScope PSPhoenix { $script:PhxRunLogKeep = $script:SavedKeep } }
        $logs = Join-Path (InModuleScope PSPhoenix { Get-PhxStateDir }) 'logs'
        @(Get-ChildItem -LiteralPath $logs -Filter 'run-*.log') | Should -HaveCount 2
    }
}

Describe 'the scheduled entry point' {
    It 'runs phx run headless and exits with its result' {
        # A process of its own, as the Task Scheduler starts it - with this test's environment, so
        # the config and state stay in $TestDrive.
        $testHome = Use-TestHome
        $task = Join-Path (Split-Path $PSScriptRoot -Parent) 'src/PSPhoenix/phx-task.ps1'
        $pwsh = (Get-Process -Id $PID).Path
        $output = & $pwsh -NoProfile -NonInteractive -File $task 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 1
        $output | Should -Match 'not set up yet'

        $repos = Join-Path $testHome 'Repos'
        New-TestRepository (Join-Path $repos 'One') -Remote 'origin=https://github.com/o/one.git' | Out-Null
        $target = Join-Path $testHome 'Target'
        New-Item -ItemType Directory -Path $target | Out-Null
        phx roots add $repos 6>$null
        InModuleScope PSPhoenix -Parameters @{ Target = $target } {
            param($Target)
            $c = Read-PhxConfig; $c.target = [ordered]@{ type = 'folder'; path = $Target }; $c.machine = [ordered]@{ name = 'Box'; id = 'id-box' }
            # The child runs real providers: every one but repos stays off, so none of them ever
            # reaches this machine's real home (~/.claude, the PowerShell profile, winget, ...).
            foreach ($name in @($script:PhxProviders.Keys | Where-Object { $_ -ne 'repos' })) { $c.providers[$name] = [ordered]@{ enabled = $false } }
            Save-PhxConfig $c
        }
        & $pwsh -NoProfile -NonInteractive -File $task *> $null
        $LASTEXITCODE | Should -Be 0
        Test-Path -LiteralPath (Join-Path $target 'Box/repos/repos.json') | Should -BeTrue
    }
}

Describe 'prompts' {
    It 'reads an answer with its default, and refuses a console without input' {
        InModuleScope PSPhoenix {
            Mock Read-Host { '  typed  ' }
            Read-PhxAnswer -Prompt 'Q' -Default 'd' | Should -Be 'typed'
            Mock Read-Host { '' }
            Read-PhxAnswer -Prompt 'Q' -Default 'd' | Should -Be 'd'
            Mock Read-Host { }
            { Read-PhxAnswer -Prompt 'Q' -Default 'd' } | Should -Throw -ExceptionType ([OperationCanceledException])
            Mock Read-Host { throw [System.Management.Automation.PSInvalidOperationException]::new('NonInteractive mode') }
            { Read-PhxAnswer -Prompt 'Q' } | Should -Throw '*interactive console*'
        }
    }
}

Describe 'gh wrappers' {
    It 'lists the logged-in accounts from gh auth status --json' {
        InModuleScope PSPhoenix {
            Mock Invoke-PhxGh { '{"hosts":{"github.com":[{"state":"success","active":true,"host":"github.com","login":"wpaap"},{"state":"success","active":false,"host":"github.com","login":"WizX20"},{"state":"error","active":false,"host":"github.com","login":"Broken"}]}}' }
            $accounts = @(Get-PhxGhAccount)
            $accounts.Login | Should -Be @('wpaap', 'WizX20')
            ($accounts | Where-Object Login -EQ 'wpaap').Active | Should -BeTrue
        }
    }

    It 'keeps an account gh could not check while offline, as not verified' {
        InModuleScope PSPhoenix {
            Mock Invoke-PhxGh { '{"hosts":{"github.com":[{"state":"timeout","active":true,"host":"github.com","login":"wpaap"}]}}' }
            $account = @(Get-PhxGhAccount)
            $account.Login | Should -Be 'wpaap'
            $account.Verified | Should -BeFalse
        }
    }

    It 'lists nothing when gh says nothing usable' {
        InModuleScope PSPhoenix {
            Mock Invoke-PhxGh { 'not json' }
            @(Get-PhxGhAccount).Count | Should -Be 0
        }
    }

    It "gets one account's token, or says which login to run" {
        InModuleScope PSPhoenix {
            Mock Invoke-PhxGh { $global:LASTEXITCODE = 0; 'secret-token' } -ParameterFilter { $Arguments -contains 'WizX20' }
            Get-PhxGhToken -Account WizX20 | Should -Be 'secret-token'
            Mock Invoke-PhxGh { $global:LASTEXITCODE = 1 } -ParameterFilter { $Arguments -contains 'Nobody' }
            { Get-PhxGhToken -Account Nobody } | Should -Throw '*no token for Nobody*gh auth login*'
        }
    }

    It 'copes with gh not being installed' {
        InModuleScope PSPhoenix {
            Mock Invoke-PhxGh { throw [System.Management.Automation.CommandNotFoundException]::new('gh') }
            @(Get-PhxGhAccount).Count | Should -Be 0
            { Get-PhxGhToken -Account WizX20 } | Should -Throw '*gh is not installed*'
        }
    }
}

Describe 'atomic writes' {
    It 'replaces an existing file and leaves no temporary file behind' {
        $root = Use-TestHome
        $path = Join-Path $root 'a [b] c/file.json'
        InModuleScope PSPhoenix -Parameters @{ Path = $path } {
            param($Path)
            Write-PhxTextFile -Path $Path -Value 'one'
            Write-PhxTextFile -Path $Path -Value 'two'
        }
        Get-Content -LiteralPath $path -Raw | Should -Be 'two'
        @(Get-ChildItem -LiteralPath (Split-Path $path) -Force).Name | Should -Be @('file.json')
    }

    It 'never lets a reader find the file missing while it is replaced' {
        # Move-Item -Force deletes the target before moving: a reader polling in between saw no
        # file in about one check of seven. A rename over the target leaves no such moment.
        $root = Use-TestHome
        $path = Join-Path $root 'config.json'
        $stop = Join-Path $root 'stop'
        InModuleScope PSPhoenix -Parameters @{ Path = $path } { param($Path) Write-PhxTextFile -Path $Path -Value '0' }
        $reader = Start-ThreadJob -ScriptBlock {
            $misses = 0
            while (-not [IO.File]::Exists($using:stop)) { if (-not [IO.File]::Exists($using:path)) { $misses++ } }
            $misses
        }
        try {
            InModuleScope PSPhoenix -Parameters @{ Path = $path } {
                param($Path)
                foreach ($i in 1..300) { Write-PhxTextFile -Path $Path -Value "$i" }
            }
        }
        finally { [IO.File]::WriteAllText($stop, '') }
        $misses = $reader | Wait-Job | Receive-Job
        Remove-Job $reader
        $misses | Should -Be 0
    }

    It 'fails with what the engine says, not wrapped in "Exception calling"' {
        # The message reaches the user (phx status, a failed run).
        { InModuleScope PSPhoenix { Write-PhxTextFile -Path 'relative.json' -Value 'x' } } |
            Should -Throw -ExpectedMessage 'relative.json is not a full path*'
        $missing = Join-Path (Use-TestHome) 'missing.txt'
        { InModuleScope PSPhoenix -Parameters @{ Path = $missing } { param($Path) Get-PhxFileHash -Path $Path } } |
            Should -Throw -ExceptionType ([IO.FileNotFoundException])
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

Describe 'test hygiene' {
    # Last in the file on purpose: it reads what every test before it left behind.
    It 'never reached the real gh' {
        $script:GhLeaks.Count | Should -Be 0 -Because "these calls went to gh: $($script:GhLeaks -join '; ')"
    }

    It 'never reached the real Task Scheduler' {
        $script:SchedulerLeaks.Count | Should -Be 0 -Because "these calls went to the Task Scheduler: $($script:SchedulerLeaks -join '; ')"
    }
}
