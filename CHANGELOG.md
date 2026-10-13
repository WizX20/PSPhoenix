# Changelog

All notable changes to PSPhoenix (`phx`) are listed here, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions are [semantic](https://semver.org/).
New entries go in [changelog.d/](changelog.d/README.md), one file per pull request - the Release workflow folds them in here under the new version and date.

## [Unreleased]

## [0.2.0] - 2026-10-13

### Added

- feat: `phx init` - the setup wizard: roots (the usual folders, with their repository counts), the GitHub account per owner (from the repositories' credential helpers and `gh auth status`), the target folder (OneDrive for Business suggested) and the interval (15m to 31d); saves nothing - not even the scan - before the last question, `q` or the end of input stops, a second run starts from the current values
- feat: the `repos` provider - records every repository's remotes, branch, repo-local identity and GitHub account (from its credential helper, an included `.gitconfig`, or the `accounts` map), and restores them: clones into the same or a new root with that account's token for the clone only, re-applies remotes and settings, checks out the recorded branch; credentials in a URL or a credential helper are never recorded; idempotent, and one failing repository does not stop the others
- feat: `phx roots add|rm|list` - the folders that hold your repositories, each with a discovery depth (`-Depth`, default 3); overlapping roots are refused
- feat: `phx run [-Provider <name>]` - one backup run: checks the target, never overlaps another run, scans when discovery is due, runs the providers that are enabled and due, and publishes the ones that succeeded into the snapshot; a failing provider keeps its last snapshot and fails the run at the end. Every run has a log in the state folder, and `phx status` shows the last run
- feat: `phx-task.ps1` - the headless entry point the scheduled task runs, at below-normal priority, exiting 1 when the run failed
- feat: `phx scan` - discovers the repositories under the roots, knows each by its remote (`host/owner/name`; https, ssh and Azure DevOps forms agree), records linked worktrees on their main repository, and says what is new or gone since the last scan; `phx roots list` shows the count per root
- feat: `phx schedule on|off|status [-Every 30m|1h|1d]` - the per-user Task Scheduler task `\PSPhoenix\Backup` runs `phx-task.ps1` every interval and 5 minutes after logon, headless and below normal priority; `status` (and `phx status`) say when it last ran and warn when it names a PowerShell or module that is gone or another interval than the config's. `phx init` asks to turn it on
- feat: snapshot layout - one folder per provider under `<target>/<machine>/`, published from a local staging folder: only changed files are written (temporary name + rename), files a provider no longer produces are removed, and a run with nothing changed writes nothing; `phoenix.json` records the machine, its installation id and when each provider last changed
- feat: `phx init` asks for the machine name (the computer name by default) and will not take a target folder another installation wrote; `phx status` names the snapshot folder and warns when it belongs to another installation
- feat: `phx status` - config, target (found and writable), interval, roots with their repository counts (or "not scanned" for a root added since), the age of the last scan, each provider's status, and every GitHub account the repositories need checked against `gh auth status`; a problem is a warning line and counted; only an unreadable config is an error

### Changed

- refactor: engine - publishing the snapshot runs in the engine. A file in the snapshot that cannot be removed is named in the error too, and a rename that only changes case is recorded under its new spelling
- refactor: engine - the state (`state.json`, same format) and change detection run in the engine. A state that cannot be read is ignored with the reason it gives
- refactor: engine - the module ships a compiled engine, `lib/PSPhoenix.Engine.dll` (.NET 8, loads in PowerShell 7.4 and later); writing, copying and hashing files run there. It is loaded from its bytes, so no session holds the file open and an update replaces it while PowerShell runs; a session keeps the engine it loaded first, so importing an updated PSPhoenix into it is refused - start a new session

### Fixed

- fix: repos - a repository on an offline root, or one git cannot read, is recorded in full from the last scan (settings, push URLs, branch) instead of with its remote only
- fix: repos - a backup scans first when a configured root is missing from the last scan, instead of leaving its repositories out; a `-DryRun` backup scans only in memory
- fix: repos - restoring a repository in place keeps the credentials of a remote URL that the snapshot records without them
- fix: repos - a file a repository includes from outside its work tree (`~/.gitconfig-work`) is named in the scan, and a backup warns that it does not hold it
- fix: `phx init` keeps an account set for an owner when `gh` is not logged in with it, instead of replacing it with the only login `gh` has
- fix: a run in which no provider was due was recorded as one with a provider - `phx status` said "1 provider(s)"
- fix: repos - a clone gets the recorded `core.sshCommand` and credential settings before its first fetch, so a repository reachable only with its own SSH key comes back
- fix: repos - the branch of a repository on the reftable backend is read correctly instead of as `.invalid`
- fix: scan - a root that turns up empty where the last scan found repositories (an unmounted drive on Linux) keeps them, marked offline; `phx roots rm` makes the last scan forget its root
- fix: config - a hand-written root without `depth` gets the default; one with a depth outside 1-10 or without a full path is an error instead of a root that finds nothing
- fix: `phx status` needs no `gh` account for a repository cloned over SSH, and says "not checked" instead of "not logged in" for an account gh could not verify offline
- fix: an account is taken only from a credential helper that runs `gh auth`, not from another tool's `--user`
- fix: repos - a clone from a `*.ghe.com` host gets its token in `GH_TOKEN`, where gh reads it, not in `GH_ENTERPRISE_TOKEN`
- fix: config - an `interval`, a provider's `enabled` or `cadence` that is not valid makes the config invalid, with the key named, instead of being used as it is
- fix: repos - a recorded setting that starts with `~` (such as `include.path=~/.gitconfig-work`) is restored as written; PowerShell on Windows rewrote it into the old home folder

### Security

- security: repos - a credential setting is not recorded when its user name is a token (an Azure DevOps PAT) or the URL it is scoped to carries credentials, and GitLab, Slack and AWS tokens are recognised next to GitHub's; log lines mask any token with a known prefix
- security: repos - restore refuses a repository path from the inventory that is absolute or leads out of its root

## [0.1.1] - 2026-10-08

### Changed

- docs: the README explains installing, updating and removing with Scoop, and a manual zip install; the Scoop notes point at `phx help` instead of the not-yet-built `phx init`

### Fixed

- fix: config - saving replaces the file in one rename, so a reader never finds it missing; reading refuses an empty, corrupt or unversioned config with a message naming the file, reads keys in any case and fills in missing sections from the defaults; `phx` works without `APPDATA`/`LOCALAPPDATA` and ignores a relative `XDG_*` directory
- fix: an unknown or not-yet-built command (`phx frobnicate`, `phx run` before M2) is an error now - `$?` is false, `-ErrorAction Stop` throws and `pwsh -Command` exits with 1 - instead of a yellow line and success
- fix: release pipeline - releases exactly the commit CI verified; pushes the release commit and tag atomically; drafts the GitHub Release before the push and publishes it after, so `main` never points Scoop at a missing zip; refuses to release when CI's verdict is unknown; keeps the release token out of every step but the push; a missing or expiring release token fails CI, also in a weekly run

## [0.1.0] - 2026-10-07

### Added

- feat: project scaffold (milestone M0) - the `phx` command with help, version and `phx providers`; config and state paths per platform; config read/save with a format version; the provider registry and its contract checks; the design in `docs/design.md`
