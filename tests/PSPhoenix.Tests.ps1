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
    foreach ($name in 'APPDATA', 'LOCALAPPDATA', 'XDG_CONFIG_HOME', 'XDG_STATE_HOME') {
        $script:SavedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
    }
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
        @($config.Keys) | Should -Be @('version', 'roots', 'target', 'interval', 'providers', 'accounts', 'secrets', 'files')
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
        git -C $main worktree add -q (Join-Path $repos 'Main-feature') -b feature 2>$null
        phx roots add $repos 6>$null
        $records = @(Get-TestScan)
        @($records.identity) | Should -Be @('github.com/o/main')
        @($records[0].worktrees).Count | Should -Be 1
        $records[0].worktrees[0] | Should -Match 'Main-feature$'
    }

    It 'skips a submodule and build-output folders' {
        $submodule = Join-Path $repos 'App/../Sub'
        New-Item -ItemType Directory -Path $submodule -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $submodule '.git') -Value 'gitdir: ../App/.git/modules/Sub'
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

    It 'skips a root whose folder is gone' {
        phx roots add $repos 6>$null
        Remove-Item -LiteralPath $repos -Recurse -Force
        Get-PhxOutput { phx scan } | Should -Match 'folder not found - skipped'
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
