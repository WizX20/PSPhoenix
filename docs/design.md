# PSPhoenix design

Status: **draft**, nothing below is implemented yet beyond the module skeleton. This document is the
contract the milestones in [Roadmap](#roadmap) build towards; change it in the same PR as the code
that deviates from it.

## Problem

When a developer machine dies, the code is fine: it lives in remotes. What is lost is everything
that never left the machine:

- **which repositories you had**, where they lived, with which remotes and which GitHub account;
- **local-only git work**: unpushed commits, branches without an upstream, stashes, worktrees;
- **gitignored hand-written files**: local config, secrets, IDE user files;
- **Claude Code state**: per-project memory, user settings, skills, commands;
- **the machine setup**: winget and Scoop packages, the PowerShell profile and modules, Windows
  Terminal settings, WSL distros, user environment variables, git and SSH config.

PSPhoenix (`phx`) backs up exactly that, periodically and with negligible impact, and rebuilds a new
machine from it with `phx restore`.

## Principles

1. **Back up the delta, not what is already remote.** Tracked files come back with a clone. The
   repository inventory (remotes, identity, branch) is what makes a restore possible.
2. **Inventories over files.** Where a list can reinstall something (`winget export`, the module
   list), store the list, not the binaries.
3. **Never back up big or unknown things silently.** New gitignored files wait for a decision
   (see [Gitignored files](#gitignored-files-filters-and-review)).
4. **Secrets only encrypted, to a public key.** The unattended scheduled run needs no secret; the
   private key is needed only at restore.
5. **No daemon.** The OS scheduler starts a short-lived run; a run with nothing changed costs a few
   hundred `stat` calls.
6. **Restore onto a different layout.** Repositories are keyed by remote identity, not by path.
7. **Readable without the tool.** Plain files, JSON, git bundles and age files: a backup must be
   recoverable by hand if PSPhoenix itself is gone.

## Concepts

- **Root**: a directory that contains repositories, e.g. `C:\Repos`. A user can have several
  (`C:\Repos`, `D:\Work`, `~/src`). Discovery searches each root to a configurable depth (default 3)
  and stops descending at a repository.
- **Repository identity**: the normalised remote URL `host/owner/name` of `origin`, else of the
  first remote. A repository without any remote gets `local/<path relative to its root>` and a full
  bundle, since there is nothing to clone it from.
- **Worktree**: a linked worktree (including Claude Code's `.claude/worktrees/*`) belongs to its
  main repository and is recorded there, never as a repository of its own.
- **Provider**: one unit of backup and restore (`repos`, `claude`, `winget`, ...). See
  [Provider contract](#provider-contract).
- **Target**: where snapshots go. v1 is a folder; a git target follows.
- **Snapshot**: the per-machine folder in the target, see [Snapshot layout](#snapshot-layout).
- **State**: local, never backed up: hashes and timestamps that make change detection cheap.

## Provider contract

Every provider lives in `src/PSPhoenix/Providers/<Name>.ps1` and registers itself:

```powershell
Register-PhxProvider @{
    Name        = 'winget'
    Description = 'Installed winget packages (winget export / import)'
    Platforms   = @('Windows')          # Windows, Linux, macOS
    Cadence     = '1d'                  # minimum time between runs of this provider
    Backup      = { param($Context) ... }
    Restore     = { param($Context) ... }
    Status      = { param($Context) ... }
}
```

`$Context` carries the loaded config, the provider's staging folder in the snapshot, the state
store, a logger, the secret writer (age) and a `DryRun` flag. A provider never writes outside its
staging folder during backup, and every `Restore` is idempotent: a second run skips what exists.

**Every provider ships with its `Restore` and a round-trip test** (backup into `$TestDrive`, restore
into a second `$TestDrive` home, compare). A backup nobody has restored is a hope, not a backup.

## Providers

| Provider | Captures | Restores via | Notes |
|---|---|---|---|
| `repos` | inventory per repository: path relative to its root, **all** remotes, default and current branch, repo-local identity (`user.*`, `include.path`, `credential.*`), worktrees, LFS and submodule flags, the GitHub account | clone (parallel, throttled), remotes, repo-local config | see [GitHub accounts](#github-accounts) |
| `wip` | `git bundle` of local-only work: branches without upstream or ahead of it, stashes; a full bundle for repositories without a remote | `git fetch <bundle>`, stashes re-applied as branches | squash-merged branches are not WIP: reuse the merge detection of PSWorktree's `wt clean` |
| `repo-files` | gitignored files that pass the filters and the review | copy back | secret-classified files only as `.age` |
| `claude` | `~/.claude/projects/*/memory`, `settings.json`, `CLAUDE.md`, `skills/`, `commands/`, `agents/`, `statusline*`, `keybindings.json`; selected keys of `~/.claude.json` (`mcpServers`, with `env` values that look secret encrypted) | copy; memory lands in the folder name Claude Code derives from the **new** path | never `.credentials.json`; session transcripts opt-in |
| `git` | `~/.gitconfig` and the files it includes, `~/.ssh/config`, `known_hosts`; private keys as `.age` | copy | |
| `pwsh` | profile files of PowerShell 7 and Windows PowerShell (all four scopes), installed modules (name, version, repository) | copy profiles, `Install-PSResource` the list | PSReadLine history opt-in: it holds whatever was typed, secrets included |
| `terminal` | Windows Terminal `settings.json` (stable, preview, unpackaged) | copy | |
| `winget` | `winget export` | `winget import` | |
| `scoop` | `scoop export` (apps and buckets) | `scoop import` | |
| `wsl` | distros (name, WSL version, default); optional per-distro dotfiles (`~/.bashrc`, `~/.profile`, `~/.gitconfig`) | prints the `wsl --install -d` commands; copies dotfiles into the new distro | no `wsl --export`: gigabytes, and the distro is reinstallable |
| `env` | user environment variables (`HKCU\Environment`), `PATH` as a list of entries; machine variables recorded read-only | sets user variables, merges `PATH` entries; prints the commands for machine variables (admin) | names matching the secret pattern (`TOKEN`, `SECRET`, `KEY`, `PASSWORD`, `PAT`) are encrypted or skipped |

Later candidates: `dotnet-tools` (`dotnet tool list -g`), `npm-global`, `nvm` (installed Node
versions), fonts. VS Code is left out on purpose: it has Settings Sync.

## Gitignored files: filters and review

Measured on the first machine (25 repositories): **~866,000 gitignored files**. After the built-in
filters 717 candidates remained (12.5 MB); after one review about 60 files that matter (<100 KB).
Including everything is not an option; a pure allowlist misses files nobody thought of. Hence:

1. **List** with `git ls-files --others --ignored --exclude-standard --directory` in the main
   worktree of each repository.
2. **Path-segment denylist**, applied to *every* segment of every file path, not only to the top
   entry git reports (a leftover untracked folder can hide `bin/` and `obj/` deep inside):
   `bin`, `obj`, `node_modules`, `packages`, `.packages`, `.nuget`, `dist`, `out`, `build`,
   `artifacts`, `publish`, `.vs`, `.idea`, `.dart_tool`, `.gradle`, `.venv`, `venv`,
   `__pycache__`, `.terraform`, `.next`, `.nuxt`, `.angular`, `.cache`, `coverage`, `TestResults`,
   `.claude/worktrees`.
3. **Generated code**: `*.g.dart`, `*.freezed.dart`, `*.g.cs`, `GeneratedPluginRegistrant.*`,
   Gradle wrappers, ignored lock files.
4. **Binary extensions and a size cap** (default 1 MB). A larger file needs an explicit include.
5. **Secret classification** by name: `.env`, `.env.*`, `secrets.*`, `*.pfx`, `*.pem`, `*.key`,
   `id_*`, plus per-repository `secret` patterns. Secret files are only ever stored as `.age`.
6. **Review**: a candidate nobody decided on yet is `pending` and is **not** backed up. The wizard
   and `phx review` show pending files per repository; the answer (include, exclude, exclude
   pattern, secret) is stored in the config. `phx status` reports the number of pending files.

Per repository, generated config is excluded once and stays excluded. Example: in a repository
whose `task configure` writes `appsettings.*.local.json` and `.env.local` from `config.local.env`,
only `config.local.env` (and the secret source, encrypted) is worth keeping.

Later: a **repository hint file** committed by the project itself (for example `.phoenix.json`)
listing which local files matter, so every developer of that project gets sensible defaults.

## GitHub accounts

One machine often talks to one host with several accounts: a personal account for personal
repositories, a work account for work. A wrong account at restore means a failed clone of a private
repository, or commits authored with the wrong identity.

**Backup** records per repository:

- every remote URL (the owner is visible in it);
- the repo-local identity: `user.name`, `user.email`, `include.path`, `credential.<url>.helper`;
- `account`: detected from the credential helper (`gh auth token --user <x>`), else taken from the
  `accounts` map in the config, which the wizard fills per owner
  (`"github.com/WizX20": "WizX20"`, `"github.com/summitnl": "wpaap"`), else the host's default.

**Restore**:

1. **Preflight**: `gh auth status` must list every account the selected repositories need. A
   missing account stops the restore with the exact `gh auth login` to run.
2. **Clone with that account's token** for the clone process only:
   `GH_TOKEN = gh auth token --user <account>`. Never `gh auth switch`, never a token on disk.
3. **Re-apply the repo-local config** (`include.path`, `user.*`, credential helper) right after the
   clone, before any fetch or push.

Other hosts (Azure DevOps, GitLab, self-hosted) authenticate through Git Credential Manager; they are
cloned one at a time because GCM may prompt.

## Secrets

Encryption uses [age](https://age-encryption.org):

- `phx init` generates an X25519 identity or takes an existing recipient. The **public recipient**
  goes into the config; backups encrypt to it, so the scheduled run needs no secret at all.
- The **private identity** is shown once and kept where the user chooses (a password manager). It
  can additionally be stored in the target passphrase-encrypted (`age -p`), so a restore needs only
  that passphrase.
- **Not DPAPI**: it is bound to the machine and the Windows account, so after a crash the data
  would be unreadable - exactly the case this tool exists for.
- `age` is an external binary (`scoop install age`, `winget install FiloSottile.age`). Without it,
  secret-classified items are skipped and `phx status` says so.

## Targets

- **Folder** (v1): any path - OneDrive, Dropbox, a NAS share, a USB disk. The sync client does
  transport and file versioning. Every file is written to a temporary name and renamed into place,
  so a sync client never uploads half a file.
- **Git** (later): the snapshot folder is a git repository; one commit per run, only when something
  changed, then push. Gives a real history of memory edits.

**Data location**: a snapshot contains whatever the memory and local files contain, company data
included. The target belongs inside the boundary that data belongs to (the company OneDrive, an
organisation-private repository), not a personal account.

## Snapshot layout

```
<target>/<machine>/
  phoenix.json                      format version, machine, user, timestamps, per-provider summary
  config.json                       the PSPhoenix config (roots, accounts, review decisions)
  repos.json                        the repository inventory
  repos/<host>/<owner>/<name>/
    files/<relative path>           gitignored files
    files/<relative path>.age       secret-classified ones
    wip.bundle
  claude/home/                      selection from ~/.claude
  claude/projects/<repo id>/memory/ memory keyed by repository identity, not by encoded path
  git/  pwsh/  terminal/  wsl/
  env.json  env.secret.json.age  winget.json  scoop.json
```

Claude Code names a project's folder after its path (`C:\Repos\Org\App` becomes
`C--Repos-Org-App`), and that encoding loses information (a `-` in a name is indistinguishable from
a separator). The snapshot therefore keys memory by repository identity and records the mapping;
restore derives the folder name from the repository's **new** path. Projects without a repository
are keyed by their path.

One target can hold several machines side by side; restore picks one.

## Change detection and resource use

- Local state (`%LOCALAPPDATA%\PSPhoenix\state.json`, `$XDG_STATE_HOME/psphoenix` elsewhere): per
  source file its size, mtime and SHA-256.
- A run compares size and mtime first, hashes only on a difference, copies only on a changed hash.
- Repository discovery is cached and refreshed daily or by `phx scan`.
- Git-heavy work (`wip` bundles) runs only for repositories whose refs changed: one
  `git for-each-ref` per repository, hashed, compared with the last run.
- Slow inventories (`winget export`, `scoop export`, the module list) have their own cadence
  (default daily) instead of running every hour.
- The process runs at below-normal priority.

## Scheduling

Windows: a per-user Task Scheduler task `\PSPhoenix\Backup`.

- Triggers: every `interval` (default `1h`, set with `phx schedule --every 2h`), and at logon after a
  5-minute delay.
- Settings: `StartWhenAvailable` (a run missed during sleep or shutdown happens right after),
  `MultipleInstances IgnoreNew` (never overlapping runs), `ExecutionTimeLimit` 15 minutes,
  priority 7 (below normal), optionally AC power only.
- Action: `conhost.exe --headless pwsh.exe -NoProfile -NonInteractive -File <module>\phx-task.ps1`.
  Without `conhost --headless` a console window flashes up every run, `-WindowStyle Hidden`
  included.

Rejected alternatives:

- **Windows service**: runs in session 0 as a service account, so it has no access to the user's
  credential store and `gh` keyring (no `git push`, no user profile without storing a password);
  needs admin and a wrapper; stays resident.
- **cron**: not native on Windows (only through WSL or a third-party daemon, which do not see the
  Windows credentials). Task Scheduler is Windows' cron, and catches up missed runs.

macOS and Linux (later): a launchd agent with `StartInterval`, a systemd `--user` timer.

## Commands

```
phx init                          wizard: roots, discovery, accounts, target, interval, secrets,
                                  review of gitignored candidates, schedule on
phx run [-Provider <name>]        one backup run now (what the scheduled task calls)
phx status                        last run, changes, pending review items, local-only work, warnings
phx review                        decide on pending gitignored candidates
phx scan                          re-discover repositories under the roots
phx roots add|rm|list             manage roots
phx schedule on|off|status        manage the scheduled task; -Every <n>h sets the interval
phx restore                       rebuild this machine from a snapshot (see below)
phx help                          usage
```

## Restore sequence

0. Install PSPhoenix, git, `gh` and age (or let step 2 do the rest).
1. `phx restore -From <target>`: pick the machine snapshot.
2. Machine providers first, each confirmed: `winget import`, `scoop import`.
3. `git` provider: `~/.gitconfig` and includes, SSH config and keys (decrypted).
4. Account preflight (see [GitHub accounts](#github-accounts)).
5. Map roots (old to new, default unchanged) and pick repositories from a checklist.
6. Clone, three at a time, each with its account; remotes and repo-local config.
7. `wip` bundles: branches and stashes back.
8. `repo-files`, secrets decrypted.
9. `claude`: home selection, memory into the folder derived from the new path.
10. `pwsh`, `terminal`, `env`, `wsl`.
11. Report the manual steps left: logins (`gh`, MCP servers), project setup (`task configure`,
    `npm ci`, `nvm use`).

Every step is idempotent; a re-run skips what is already there.

## Config

`%APPDATA%\PSPhoenix\config.json` (`$XDG_CONFIG_HOME/psphoenix/config.json` elsewhere). The config
itself is part of every snapshot.

```json
{
  "version": 1,
  "roots": [ { "path": "C:\\Repos", "depth": 3 } ],
  "target": { "type": "folder", "path": "C:\\Users\\me\\OneDrive - Company\\PSPhoenix" },
  "interval": "1h",
  "providers": { "winget": { "enabled": true, "cadence": "1d" } },
  "accounts": { "github.com/WizX20": "WizX20", "github.com/summitnl": "wpaap" },
  "secrets": { "recipient": "age1..." },
  "files": {
    "maxKB": 1024,
    "exclude": [],
    "repos": {
      "github.com/summitnl/HippoCampus": {
        "include": [ "config.local.env", ".claude/settings.local.json" ],
        "secret":  [ "secrets.local.env" ],
        "exclude": [ "docker/services.local.env", "**/appsettings*.local.json" ]
      }
    }
  }
}
```

## Roadmap

| Milestone | Scope |
|---|---|
| **M0** | Scaffold: module skeleton, `phx help`, config paths, provider registry, CI, this design |
| **M1** | Config and `phx init` (roots, target, interval), `phx scan`, `repos` provider, `phx status` |
| **M2** | Folder target, state and change detection, `phx run`, `phx schedule` (Task Scheduler) |
| **M3** | `claude` and `repo-files` (filters, review), age secrets |
| **M4** | `wip` bundles, squash-merge aware |
| **M5** | Machine providers: `git`, `pwsh`, `terminal`, `winget`, `scoop`, `env`, `wsl` |
| **M6** | `phx restore` orchestration (providers bring their own `Restore` from M1 on) |
| Later | Git target, launchd and systemd, repository hint file, `dotnet-tools`, `npm-global`, `nvm` |

## Open questions

1. **Worktree-local files**: linked worktrees have their own gitignored files (generated per
   worktree by the project's tooling). v1 skips them: worktrees are transient, and restore recreates
   them where the project's tooling regenerates those files.
2. **Several machines, one memory**: each machine has its own snapshot; merging Claude memory from
   two machines is out of scope.
3. **Hard dependency on age** versus built-in AES-GCM with a passphrase: age keeps backups readable
   without PSPhoenix and lets the scheduled run work without any secret. Leaning age.
4. **Repository visibility**: Scoop downloads release assets anonymously, so the repository must be
   public for `scoop install`, as with PSWorktree and PSVsCommand.
