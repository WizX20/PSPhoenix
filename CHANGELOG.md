# Changelog

All notable changes to PSPhoenix (`phx`) are listed here, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions are [semantic](https://semver.org/).
New entries go in [changelog.d/](changelog.d/README.md), one file per pull request - the Release workflow folds them in here under the new version and date.

## [Unreleased]

## [0.3.0] - 2026-10-15

### Added

- feat: secrets encrypted with age (#25):
  - `phx init` makes an age key. The public half goes into the config. The secret half is shown once, to the console, past any transcript.
  - A copy of the key, protected by a passphrase of four words or 20 characters, goes into the snapshot as `key-<id>.age`, so a restore needs only the passphrase.
  - A file with a secret is staged and published as `<name>.age`. An unchanged secret keeps its ciphertext, so nothing is uploaded again.
  - `phx run` counts the encrypted files, and `phx status` shows the key.
  - Without a key, files with a secret are held back as before
- feat: the `claude` provider backs up Claude Code (#28):
  - Per-project memory, keyed by the repository it belongs to. A restore puts it in the folder Claude Code derives from the repository's new path, so a clone to `D:\src` instead of `C:\Repos` still finds its memory.
  - `settings.json`, `CLAUDE.md`, `keybindings.json`, `statusline*`, `skills/`, `commands/`, `agents/`.
  - The MCP servers from `~/.claude.json`: the user's own and each project's. Encrypted when one holds a secret, such as an API key in `env`.
  - Never `.credentials.json`, history or caches. Session transcripts only with `providers.claude.transcripts`.
  - Restore adds what is missing and leaves what is there, with a warning when it differs.
- feat: the `repo-files` provider backs up the gitignored files that matter (#26):
  - Git lists each repository's gitignored files; build output, package caches, nested repositories and virtual environments are never even looked at, on every path segment.
  - Generated code, lock files, logs, binaries and files over `files.maxKB` (1 MB) are left out unless included by name.
  - A file nobody decided on is pending and not backed up; `phx status` counts them. The decisions are patterns in `files.repos[<identity>]` (`include`, `secret`, `exclude`) and `files.exclude`.
  - A file secret by its name (`.env`, `*.pfx`, `*.pem`, `id_*`, ...) or its content is stored only as `<name>.age`.
  - Restore puts the files back into the repository's new place, decrypts the secrets, and never overwrites a file that differs.
- feat: `phx review` decides which gitignored files to back up (#27):
  - Per repository, the pending files, grouped by folder (`o` opens one), with why a file is secret: by its name, or by what is in it - never the value.
  - `i` include, `s` secret, `x` exclude: by number, range, `*`, or a pattern (`x *.log`). Each answer is saved at once; a second review shows only what is left.
  - `n` "not a secret" overrules the secret scan for one file (#45): the findings it showed are accepted, and any other secret in the file still gets it encrypted.
  - `phx init` ends with the review, and `phx status` warns about files that wait for a decision.

### Changed

- changed: secrets need no age tool. PSPhoenix encrypts and decrypts the age format itself, so the [age](https://age-encryption.org) tool is no longer a requirement. A snapshot's secrets still open with it, without PSPhoenix (#25)
- changed: `phx scan` and `phx init` find repositories through the engine - the same rules, a faster walk of large roots (#75)
- changed: a backup run with nothing changed reads next to nothing (#73):
  - the staging folder stays between runs; a file whose source did not change is not read, scanned, encrypted or hashed again, and `phx run` says how many
  - the repository inventory asks git only for a repository whose `.git/config`, `HEAD`, refs or included files changed since the scan
- changed: 0.3.0 - M3 complete: gitignored files (`phx review`), Claude Code, age secrets; the README says what is built, what is not yet, and how to try it out

### Fixed

- fix: claude - the MCP servers of `~/.claude.json` are read and restored by the engine: two projects whose paths differ only in case keep their own servers, and a restore adds what is missing without changing the rest of the file (dates, numbers, formatting) or writing over a change Claude Code made meanwhile (#72)
- fix: gitignored files (#70):
  - an ignored folder with more than 5,000 files (a Rust `target/`, `Pods/`) is one entry, left out, and the listing goes on - it no longer cut the list short and removed later files, included ones too, from the snapshot; a list that is still cut short keeps the last backup
  - the denylist applies to ignored folders, not to the tracked folders a file lies in: `packages/web/.env.local` in a workspace is listed; a folder the review excluded is not walked at all
  - a folder or wildcard include no longer pulls in large, binary or generated files; only a pattern naming one file does
  - skills named `build` or `publish` in `~/.claude` are backed up
- fix: a root or target on a drive that is not there (an unplugged USB disk, a disconnected share) no longer fails `phx scan`, `phx run`, `phx status` or `phx init` - its repositories are kept from the last scan, also when the drive goes between two scans, and a restore goes on with the other repositories (#67)
- fix: secrets - keystores (`*.jks`, `*.keystore`), PuTTY keys (`*.ppk`), `.netrc`, `.pgpass` and KeePass databases are secret by their name, and UTF-16 text without a byte order mark is scanned instead of passed over as binary (#69)
- fix: a provider whose source is gone - no Claude Code folder for the run, no scan - fails and keeps its last backup in the snapshot instead of publishing an empty folder over it (#69)
- fix: a file the review called "not a secret" stays plain through `phx run` - the last secret check before publishing no longer encrypts it again, and `files.json` always names the file the snapshot holds (#68)

### Security

- security: secrets are recognised by content, in one detector in the engine (#45):
  - tokens of GitHub, GitLab, Slack, AWS, npm and Azure DevOps, `sk-` API keys and JSON web tokens;
  - private keys, credentials in URLs and authorization headers;
  - passwords, and random-looking values under secret-like keys.
  The run log and error messages mask whatever it finds. The repository inventory leaves out a setting that holds a secret, and records a remote URL without the secret in it
- security: every file a provider stages is scanned for secrets first (#45). A file with a secret in it is held back: it is not written to staging and not published. Without age (#25) a secret is never stored. The warning, the run log and `phx status` name the file, the line and the kind of secret, never the value, and `phx run` adds the count to the provider's line. A last check before publishing catches a file that reached staging another way. If a secret slips into the repository inventory, its provider fails, so the last published copy stays

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
