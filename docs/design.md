# PSPhoenix design

Status: **draft**. M1 and M2 are built - `phx init`, `phx roots`, `phx scan`, `phx status`, the
`repos` provider, the snapshot, `phx run` and `phx schedule` - and M3: the age secrets, the
`repo-files` and `claude` providers and `phx review`; the rest is not yet (see
[Roadmap](#roadmap)). This document is the contract the milestones
build towards; change it in the same PR as the code that deviates from it.

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
  first remote: host lower-cased, no `.git`; https, ssh and scp-style URLs agree; Azure DevOps folds
  into `dev.azure.com/org/project/repo`. A remote that is a local path, `file://` URL or UNC share
  gives `file/<path>` - still clonable where that path exists. A repository without any remote gets
  `local/<path relative to its root>` and a full bundle, since there is nothing to clone it from.
  The same remote cloned twice keeps one identity in two places; `phx scan` points it out.
- **Discovery cache**: `phx scan` writes what it found - per repository everything the `repos`
  provider records (root, relative path, identity, remotes, branches, repo-local settings, linked
  worktrees with their branch) - to `repos.json` in the state folder. Links and junctions are
  not followed - a cloud-sync placeholder (OneDrive, Dropbox) is not a link and is searched - and
  build-output folders (`node_modules`, `bin`, `obj`, ...) are not entered. Nothing a scan cannot
  see is dropped: a root whose folder is gone keeps the last scan's repositories, marked offline,
  and so does a root that turns up empty where the last scan found repositories (Linux keeps an
  unmounted drive's mount point as an empty folder); a repository git cannot read keeps its last
  record, with a warning - in full, so a backup taken while a drive is out still records their
  settings. A root that goes away between two scans counts as offline at once: a backup records its
repositories from the last scan instead of dropping them. A root or target on a drive letter that
is not there at all (an unplugged USB disk, a disconnected share) is the same case: PSPhoenix
handles such paths as text and never asks the drive. `phx roots rm` forgets a root's repositories
too. A backup scans first when there is
  no scan yet or a configured root is missing from it. Remote URLs are recorded without
  credentials (`user:password@`, or a token as user name).
- **Worktree**: a linked worktree (including Claude Code's `.claude/worktrees/*`) belongs to its
  main repository and is recorded there, never as a repository of its own.
- **Provider**: one unit of backup and restore (`repos`, `claude`, `winget`, ...). See
  [Provider contract](#provider-contract).
- **Target**: where snapshots go. v1 is a folder; a git target follows.
- **Snapshot**: the per-machine folder in the target, see [Snapshot layout](#snapshot-layout).
- **Machine**: the name of this machine's folder in the target (the computer name unless `phx init`
  is told otherwise) and the id of this installation, which `phx init` makes. The id guards the
  folder: see [Snapshot layout](#snapshot-layout).
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

Registration is strict, so a mistake fails at import instead of yielding a provider that quietly
never runs: `Name`, `Description`, `Backup`, `Restore` and `Status` are required; the name is
lowercase letters, digits and dashes (it becomes a snapshot folder and a `-Provider` value);
unknown keys are refused (a `Platform` typo would otherwise run the provider everywhere);
`Platforms` defaults to all three but may not be empty; `Cadence` is absent or a whole number of
minutes, hours or days (`30m`, `1h`, `1d`).

`$Context` carries:

- the loaded config;
- the provider's staging folder, in the state folder;
- the state store, and from it the change detection (`$Context.Files`);
- a logger;
- what the secret check held back;
- a `DryRun` flag;
- on restore, also the root map (an old root to its new path), the repositories selected, and the
  age key that opens the snapshot's secrets (none: they are skipped, with a warning).

A provider whose source is not there - no Claude Code folder, no scan - fails when the snapshot
holds a last backup of it, so publishing an empty folder does not remove that backup; where there
never was one it is quiet. A provider never writes outside its staging folder during backup, and stages every file through
`Write-PhxStagedText` or `Copy-PhxStagedFile`. They refuse a path that leads out of staging, and
scan the file for secrets first (see [Secrets](#secrets)). Every `Restore` is idempotent: a second
run skips what exists.

**Every provider ships with its `Restore` and a round-trip test** (backup into `$TestDrive`, restore
into a second `$TestDrive` home, compare). A backup nobody has restored is a hope, not a backup.

## Providers

| Provider | Captures | Restores via | Notes |
|---|---|---|---|
| `repos` | inventory per repository: path relative to its root, **all** remotes, default and current branch, repo-local identity (`user.*`, `include.path`, `credential.*`), worktrees, LFS and submodule flags, the GitHub account | clone (one at a time in M1; parallel and throttled once `phx restore` runs it, M6), remotes, repo-local config | see [GitHub accounts](#github-accounts) |
| `wip` | `git bundle` of local-only work: branches without upstream or ahead of it, stashes; a full bundle for repositories without a remote | `git fetch <bundle>`, stashes re-applied as branches | squash-merged branches are not WIP: reuse the merge detection of PSWorktree's `wt clean` |
| `repo-files` | gitignored files that pass the filters and the review | copy back | secret-classified files only as `.age` |
| `claude` | `~/.claude/projects/*/memory`, `settings.json`, `CLAUDE.md`, `skills/`, `commands/`, `agents/`, `statusline*`, `keybindings.json`; from `~/.claude.json` only the MCP servers - the user's (`mcpServers`) and each project's (`projects.<path>.mcpServers`) - encrypted as a whole when one holds a secret | copy; memory lands in the folder name Claude Code derives from the **new** path, a project's MCP servers under its new path | never `.credentials.json`; session transcripts opt-in (`providers.claude.transcripts`) |
| `git` | `~/.gitconfig` and the files it includes, files that repositories include from outside their work tree, `~/.ssh/config`, `known_hosts`; private keys as `.age` | copy | |
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
   worktree of each repository. An ignored folder is one entry; the engine (`IgnoredFiles`) walks
   it, without following links and without entering a folder the review excluded as a whole.
   - A folder git reports with more than 5,000 files becomes one entry and is left out (a Rust
     `target/`, `Pods/`); the walk goes on with the rest.
   - At 50,000 files in all the walk stops, and the repository keeps its last backup, with a
     warning: a list cut short must not remove what it did not get to.
2. **Denylist**, by folder name, on every ignored folder and every folder below it (a leftover
   untracked folder can hide `bin/` and `obj/` deep inside) - not on the tracked folders a file git
   reports lies in, so `packages/web/.env.local` in an npm workspace is listed:
   `bin`, `obj`, `node_modules`, `packages`, `.packages`, `.nuget`, `dist`, `out`, `build`,
   `artifacts`, `publish`, `.vs`, `.idea`, `.dart_tool`, `.gradle`, `.venv`, `venv`,
   `__pycache__`, `.terraform`, `.next`, `.nuxt`, `.angular`, `.cache`, `coverage`, `TestResults`,
   `.git`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `.tox`, `.eggs`, `.claude/worktrees`,
   ignoring case. A folder that is a repository or a worktree of its
   own (a `.git` in it), or a Python virtual environment (a `pyvenv.cfg` in it), is not entered
   either. None of these is even listed - unless a decision names a file in it from the top
   (`/bin/special.json`): then that file, and only what decisions name there, is listed. An
   oversized folder a decision points into is walked whole.
3. **Generated code**: `*.g.dart`, `*.freezed.dart`, `*.mocks.dart`, `*.g.cs`, `*.g.i.cs`,
   `GeneratedPluginRegistrant.*`, Gradle wrappers, ignored lock files (`package-lock.json`,
   `yarn.lock`, `pubspec.lock`, `go.sum`, ...), Flutter's generated plugin lists and Xcode
   config. **Noise**: logs, temporary and swap files, lock and pid files, `.DS_Store`,
   `Thumbs.db`, `desktop.ini`, `*.suo`, `*.cache`.
4. **Binary extensions and a size cap** (`files.maxKB`, default 1 MB). Filtered files from steps
   3 and 4 are left out unless the review includes them by name: a folder or wildcard pattern
   does not pull in the large, binary or generated files the review never showed. A file whose
   name Windows cannot hold (`:`, `?`, a trailing dot, ... - possible on Linux) is left out with a
   warning: it could not be published to such a target, nor restored there.
5. **Secret classification** by name: `.env`, `.env.*`, `secrets.*`, `*.pfx`, `*.p12`, `*.pem`,
   `*.key`, `id_*`, keystores (`*.jks`, `*.keystore`), PuTTY keys (`*.ppk`), `.netrc`/`_netrc`,
   `.pgpass`, KeePass databases (`*.kdbx`) (the file name, not a folder), plus per-repository `secret` patterns - and by
   content: a text file the [detector](#secrets) finds a secret in is secret as a whole. Secret
   files are only ever stored as `.age`; a binary one too.
6. **Review**: a candidate nobody decided on yet is `pending` and is **not** backed up. The wizard
   and `phx review` show pending files per repository; the answer (include, exclude, exclude
   pattern, secret, not a secret) is stored in the config. `phx status` warns about the number of
   pending files, which each backup and each review record in the state folder
   (`repo-files.json`).

**`phx review`** lists, per repository, the pending files grouped by their first folder: a folder of
several files is one line (`leftover/   12 files, 40 KB, 1 secret`) and `o <n>` opens it. Each
line says why a file is secret - by its name, or by what the [detector](#secrets) finds in it
(the kind and the line, never the value). An answer is a letter and what it is for:

- `i` include, `s` secret (always encrypted), `x` exclude - with numbers (`1,3-5`, `*` for all),
  or with a pattern (`x *.log`, `i src/**/local.json`);
- `n` "not a secret": the detector's findings in that file are accepted, and it is backed up as it
  is (see below);
- Enter moves on to the next repository, the rest staying pending; `q` stops.

A number becomes a pattern from the repository's top (`/notes.md`, `/leftover/`), so it does not
also catch a file of that name deeper down. Every answer is saved in the config at once, a new one
for the same pattern replacing the old; a second review shows only what is still pending.

**Not a secret.** `n` stores the file's pattern with the
[signature](#secrets) of each finding the review showed - its kind and key, not its place:
`"plain": { "/appsettings.json": [ "SecretValue:ClientSecret" ] }`. Those findings no longer make
the file secret; any other - a new kind of secret, or one under another key - still does, and the
file is encrypted again. A file secret by its name cannot be called no secret: it is included as a
secret, or excluded.

**Decisions** are patterns in `files.repos[<identity>]` (`include`, `secret`, `exclude`, and
`plain` for "not a secret") and in `files.exclude` for every repository. A pattern is a path
relative to the repository, with `/`:

- `*` matches within a segment, `?` one character, `**` any number of segments;
- a pattern without a `/` matches that name at any depth, as in a `.gitignore`; one with a `/` -
  a leading one included, `/notes.md` - matches from the repository's top;
- a pattern ending in `/` is a folder, and a pattern that matches a folder matches every file in
  it;
- case is ignored, on every platform.

`secret` wins over `include`, and `include` over `exclude`: a folder excluded as a whole can still
have one file in it included by name. An included file with a secret name is a secret. Only a
pattern that names one file - no wildcard, not a folder - overrides a built-in filter (step 3 and 4).

**Backup and restore.** The decided files go to `repo-files/<identity>/<path>`, a secret as
`<path>.age`; `repo-files/files.json` records per repository its identity, root, path, folder and
files, so a restore needs nothing else. The same remote cloned twice gets a second folder,
`<identity>~2`. A repository this run cannot read (an offline root) keeps the files of the last
backup. Restore copies each file back into the repository's place on the new machine (root
mapped), after the clone: it decrypts a secret with the age key it is given, skips one without a
key, leaves a file that is the same alone, and never overwrites one that differs - it says so.
The manifest is not trusted blindly - see [A snapshot is trusted input](#github-accounts): a
path that is not plain and relative, leads into `.git` or into a repository of its own, or out of
the repository or the snapshot is refused, as is a link on the way.

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

- every remote URL and push URL (the owner is visible in it);
- the repo-local identity, in order and with repeated keys: `user.name`, `user.email`,
  `user.signingkey`, `include.path`, `credential.*` (a reset `helper =` followed by the real one;
  a credential setting that carries a password or token - in its value, as its user name, or in
  the URL it is scoped to - is not recorded, with a warning),
  `core.sshCommand` (a per-repository SSH key), and the signing settings (`commit.gpgsign`,
  `tag.gpgsign`, `gpg.format`, `gpg.ssh.allowedSignersFile`). Values from a file the local config
  includes (a `.gitconfig` tracked in the repository) are not copied - the clone brings that file
  back - but they count for the account. A file included from outside the work tree
  (`include.path = ~/.gitconfig-work`) does not come back with a clone: the scan lists it, a backup
  warns about it, and the `git` provider backs it up;
- `account`: detected from a credential helper (`gh auth token --user <x>`), in the local config or
  an included file, else taken from the `accounts` map in the config, which the wizard fills per
  owner (`"github.com/WizX20": "WizX20"`, `"github.com/summitnl": "wpaap"`), else the host's default.

**Restore**:

1. **Preflight** (`phx restore`, M6): `gh auth status` must list every account the selected
   repositories need. A missing account stops the restore before anything is cloned, with the exact
   `gh auth login` to run. The `repos` provider has no preflight of its own; `phx status` warns
   about a missing account ahead of time. Only a repository cloned over https needs one - over SSH
   the key decides, and the recorded `core.sshCommand` goes into the clone itself. An account `gh`
   could not check because the host was out of reach counts as logged in.
2. **Clone with that account's token** for the clone process only:
   `GH_TOKEN = gh auth token --user <account>` (`GH_TOKEN` for github.com and `*.ghe.com`,
   `GH_ENTERPRISE_TOKEN` for a GitHub Enterprise Server host `gh` is logged in to). Never
   `gh auth switch`, never a token on disk. Clones that run side by side, each with its own
   account, need the token in each child process's environment, not in the shared process
   environment.
3. **Re-apply the repo-local config** (`include.path`, `user.*`, credential helper) right after the
   clone, before any fetch or push; then check out the recorded branch when the remote has it.
   A repository already in place gets the same re-apply and nothing else. Linked worktrees are
   listed, not recreated. A repository that fails (no token, a remote that is gone) does not stop
   the others: the run reports it and fails at the end.

Other hosts (Azure DevOps, GitLab, self-hosted) authenticate through Git Credential Manager; they are
cloned one at a time because GCM may prompt.

**A snapshot is trusted input.** It is the user's own backup, but what it re-applies can run code:
a credential helper starting with `!`, `core.sshCommand`, and an `include.path` that pulls in more
config. Restore therefore refuses whatever PSPhoenix itself would never have written - a setting
key outside the recorded set (`core.hooksPath`, `core.fsmonitor`), a URL git could read as an
option, a repository path that is absolute or leads out of its root - and `phx restore` (M6) shows
the helpers, SSH commands and include paths it is about to apply before it applies them.

Files come back through the engine (`RestoreManifest`, `RestorePlanner`), the same way for every
provider that restores files:

- **A manifest is read strictly**: every value of its type, a format this version knows. One that
  is not what PSPhoenix writes is refused as a whole.
- **A path is refused** when it is not plain and relative (rooted, `..`, `\`, and on Windows a
  stream `:`, a device name, a trailing dot or space), when any segment is `.git` - in any case,
  and on Windows also as `.git.` or its short name `GIT~1` - and when it lies outside what its
  provider backs up: of `~/.claude` only the selection the claude provider reads (never
  `.credentials.json`), of a project only its memory and transcripts. A stored name is the path or
  the path with `.age`, inside the snapshot.
- **Writing** refuses a link on the way and a folder that is a repository of its own inside the
  repository, and creates a file only when nothing is there: written to a temporary name and moved
  into place without overwrite, so a file that appears in the meantime is compared, never
  replaced.

## Secrets

Encryption uses [age](https://age-encryption.org):

- **One key per installation, made by `phx init`**: an X25519 key pair, or the recipient of a key
  the user already has.
  - The **public recipient** goes into the config (`secrets.recipient`). Backups encrypt to it, so
    the scheduled run needs no secret at all.
  - The **private identity** is shown once, after saving, for a password manager. It is never in
    the config, the state or a log.
  - **`key-<id>.age`** in the snapshot folder holds the identity file, encrypted with a passphrase
    the user chooses, so a restore needs only that passphrase.
    - The name carries 12 characters of the key's recipient, so `phx status` checks the copy that
      belongs to the current key.
    - The encryption is scrypt, as `age -p` uses. The passphrase needs four different words of
      three letters or more (15 letters in all) or 20 characters of which eight differ, typed
      twice: whoever can read the target can try passphrases at leisure.
    - Without PSPhoenix it opens the same way: `age -d -i key-<id>.age file.age` asks for the
      passphrase.
    - A key without that copy is possible, but `phx init` asks twice: the shown key is then the
      only way back.
  - **The key is shown once**, after saving, even when a later step fails. It goes straight to the
    console, past PowerShell's streams, so a transcript does not record it.
  - Run again, `phx init` keeps the current key on Enter.
  - **A new key:**
    - The next run encrypts every secret to it.
    - Older versions of the snapshot that a sync client keeps stay encrypted to the old key.
    - The old key's copy stays next to the new one.
- **Not DPAPI**: it is bound to the machine and the Windows account, so after a crash the data
  would be unreadable - exactly the case this tool exists for.
- **Built in, nothing to install.** The engine implements the age format itself (`Age`):
  - X25519 recipients and scrypt passphrases;
  - the header and its MAC;
  - the STREAM payload.

  .NET has no X25519 and no scrypt, and no maintained .NET library for age exists, so the engine
  carries its own: a port of TweetNaCl's Curve25519 ladder, scrypt per RFC 7914 on .NET's PBKDF2,
  and bech32 for the keys. ChaCha20-Poly1305 and HKDF come from .NET.
- **Checked against age itself.** The official age test vectors (C2SP CCTV) run with the engine's
  tests, and in CI the real `age` tool decrypts what the engine encrypts and the other way round.
  So a snapshot stays readable without PSPhoenix: `age -d -i key.txt file.age` opens it. The ASCII
  armor, plugins and the post-quantum hybrid keys are not built, because PSPhoenix writes none of
  them.
- **Until a key is set up** (`phx init`), secret-classified items are held back and `phx status`
  says so.

**Detection.** A file is secret by its name (see [Gitignored files](#gitignored-files-filters-and-review))
or by its content. One detector in the engine, `SecretScanner`, reads content. It finds:

- **Tokens, by their published formats:**
  - GitHub (`ghp_` and the other `gh?_` prefixes, `github_pat_`), GitLab (`glpat-`), Slack (`xox?-`);
  - AWS access keys, npm tokens, `sk-` API keys;
  - Azure DevOps PATs, classic and current;
  - JSON web tokens.
- **Private key blocks** (`-----BEGIN … PRIVATE KEY-----`).
- **Credentials in URLs** (`user:password@`, or a token as the user name) and **authorization headers**.
- **Values assigned to a key that names a password or a secret**, in JSON, XML, YAML, INI, `.env`,
  connection strings and PowerShell (`$env:X = '…'`):
  - Under a password key (`Password`, `pwd`, `ClearTextPassword`), any real value counts: a human
    password has little entropy.
  - Under a secret key (`token`, `apiKey`, `clientSecret`, `AccountKey`, `_authToken`), a value
    counts when it looks random: 12 or more characters, no whitespace, at least 3 bits of entropy
    per character.
  - The key's last word decides. `accessToken` names a token, `tokenType` a type.

Text is read as UTF-8, or as UTF-16 when a byte order mark says so or when the bytes look like it
(a NUL in every other byte): a file is only passed over as binary when it is neither.

These are not secrets:

- references (`${TOKEN}`, `$(Token)`, `%PASSWORD%`, Key Vault references);
- placeholders (`<your-key>`, `changeme`, `xxxx`);
- paths and URLs;
- GUIDs, hashes and base64 data under keys that name no secret.

When in doubt the detector says "secret": the cost is a file stored encrypted, and the review can
overrule it per file ("not a secret", see [Gitignored files](#gitignored-files-filters-and-review)).
A finding's **signature** - its kind and its key, `SecretValue:ClientSecret` - is what such an
overrule records.

A finding carries the kind, the line, the column and the key, never the value. A log, a warning
or `phx status` can name it as it is: `appsettings.json line 12: a secret value (ClientSecret)`.

**Staging.** Every file a provider stages goes through the writer, which scans it before
anything is written:

- A text with a secret in it is secret as a whole. It is staged and published only as
  `<name>.age`, encrypted to the recipient. The plaintext never reaches the disk.
- **Same plaintext, same file.** age output differs every time, so encrypting an unchanged secret
  again would give a new file every run, and the sync client would upload every secret every hour.
  The writer keeps the last ciphertext of each staged file in the state folder (`sealed/`). As long
  as the plaintext and the recipient are the same, it stages that file again. A provider's run
  removes the ciphertexts of files it no longer stages encrypted.
- **Without a key** the file is **held back**: never written to staging and not published, so a
  file already in the snapshot is removed there.
- The warning, the run log and `phx status` name the file, the line and the kind, never the value:
  `encrypted appsettings.json line 12: a secret value (ClientSecret)`.
- A stager (`Stager` in the engine) stages each provider's files and records what each became:
  plain, encrypted or held back. A provider's manifest (`files.json`, `claude-files.json`) comes
  from that record, never from what is on disk.
- Before publishing, the run scans the files in the staging folder the stager did not write itself.
  Whatever reached it another way is encrypted, or held back. What the stager wrote is not scanned
  again: a decision of the review ("not a secret") stands.
- The state records per provider what its last successful run held back. `phx status` shows them
  as a warning, and `phx run` adds both counts to the provider's line (`3 encrypted`, `2 held back`).
- A file the snapshot cannot do without fails its provider instead, so the last published copy
  stays. This is the repository inventory, which is kept free of secrets value by value.

The same detector does three more things:

- it masks every log line and error message;
- it keeps secrets out of the repository inventory: a setting that holds one is not recorded, and
  a remote URL is recorded without it;
- it is the check behind `Test-PhxSecretText`.

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

One folder per provider, which that provider alone fills:

```
<target>/<machine>/
  phoenix.json                      format, machine name and id, user, platform, PSPhoenix version,
                                    created/updated, per provider when its files last changed
  config.json                       the PSPhoenix config (roots, accounts, review decisions, the
                                    age recipient)
  key-<id>.age                      the age key, passphrase-encrypted (phx init; optional; one per
                                    key, named after its recipient)
  repos/repos.json                  the repository inventory
  repo-files/files.json             which repository each folder is (identity, root, path), and
                                    its files
  repo-files/<host>/<owner>/<name>/
    <relative path>                 gitignored files
    <relative path>.age             secret-classified ones - in any provider's folder, a file with
                                    a secret is <name>.age
  wip/<host>/<owner>/<name>.bundle  local-only work
  claude/claude-files.json          what is where: the home files, each project's repository
                                    (identity, root, path) or folder name, and its files
  claude/home/                      selection from ~/.claude
  claude/projects/<repo id>/memory/ memory keyed by repository identity, not by encoded path
  claude/projects/path/<folder>/    a project without a repository, under Claude Code's name
  claude/claude.json                the MCP servers of ~/.claude.json (.age with a secret in it)
  git/  pwsh/  terminal/  wsl/  env/  winget/  scoop/
```

**Publishing.** A provider writes into a staging folder of its own in the state folder - never into
the target - and the run then publishes it into the provider's folder of the snapshot: a new or
changed file is copied in under a temporary name and renamed into place, an identical one is left
alone, a file the provider no longer produced is removed (a stale temporary one too), and so are the
folders left empty. A sync client never sees half a file, and a run with nothing changed writes
nothing - not even `phoenix.json`, which is rewritten only when something changed. Owning one folder
each is what makes the removal safe: no provider can remove another's files. The removal comes
before the copy, so a file that became a folder (or the reverse) is out of the way first; which
files to keep is decided ignoring case on every platform - a NAS or USB disk may be case-insensitive
under Linux too - and a file staged under another spelling is removed and copied again, so a rename
that only changes case arrives as well.

**Machine id.** `phx init` names the machine (the computer name by default) and makes an id for this
installation; `phoenix.json` carries both. A run refuses to write into a folder whose `phoenix.json`
names another id - a machine reinstalled under the same name must not overwrite the snapshot it is
about to be restored from - into one of a newer format, and into a folder that holds files but no
`phoenix.json` (somebody's folder, which publishing would empty). A new folder is claimed - its
`phoenix.json` written - before anything else goes in. `phx init` does not offer a folder it may
not write, and `phx status` warns about one. A restore (M6) takes over the old id. The machine name
is a folder name: letters, digits, dot, dash, underscore.

Claude Code names a project's folder after its path (`C:\Repos\Org\App` becomes
`C--Repos-Org-App`), and that encoding loses information (a `-` in a name is indistinguishable from
a separator). The snapshot therefore keys memory by repository identity and records the mapping;
restore derives the folder name from the repository's **new** path. Projects without a repository
are keyed by their path.

The `claude` provider reads Claude Code's folder where Claude Code does: `CLAUDE_CONFIG_DIR` when
set (with `.claude.json` inside it), else `~/.claude` and `~/.claude.json`. A project's folder is
matched to a scanned repository by the name Claude Code derives from the repository's path - every
character but a letter or digit made a dash - compared as paths are on the platform: ignoring
case on Windows, since the drive letter comes either way, exactly elsewhere. Restore adds what is missing and leaves what is there, also when it differs (with a
warning): a settings file, a memory file, an MCP server. Of `~/.claude.json` it only adds MCP
servers; the rest of the file stays as Claude Code wrote it. The engine (`ClaudeMcp`) reads and
merges the file as JSON nodes: keys compared exactly - two projects whose paths differ only in case
stay two - strings and numbers as they were, no depth limit, and no write when nothing is added or
when Claude Code wrote the file in the meantime.

One target can hold several machines side by side; restore picks one.

## Change detection and resource use

- Local state (`%LOCALAPPDATA%\PSPhoenix\state.json`, `$XDG_STATE_HOME/psphoenix` elsewhere), never
  backed up and never needed for correctness - a missing, broken or newer state means "everything
  changed", not an error: per provider when it last ran; per provider and source file its size,
  mtime and SHA-256 - kept only when the provider's run succeeded, so a run that failed half-way
  cannot make a change look handled; per published snapshot file the SHA-256 it was published with,
  and into which snapshot folder; per repository a hash of its refs.
- A run compares size and mtime first, hashes only on a difference, copies only on a changed hash.
  A file touched but not changed is hashed once and does not count as changed.
- **The staging folder stays between runs.** Each provider's stager records, per staged file, its
  source (size and mtime, or a text's hash), how it was staged (secret, accepted findings, the age
  recipient) and the staged file as it left it (size, mtime, SHA-256); the state keeps that record
  when the provider's run succeeded. A file whose source, options and staged copy are all unchanged
  is left as it is - not read, scanned, encrypted or hashed again - and publishing takes its hash
  from the record. What a run no longer stages is pruned from the folder before publishing, so it
  still holds exactly what that run produced. `phx run` says how many files it did not read again.
- **The repository inventory** asks git only for a repository whose record could have changed: the
  scan stamps each record with the size and mtime of what it was read from - `.git/config`, `HEAD`,
  `packed-refs`, the primary remote's `HEAD`, each worktree's `HEAD`, `.gitattributes`,
  `.gitmodules` and every file the config includes. The same stamp means the same record; a
  repository on the reftable backend is always read. The warnings reading it gave are repeated.
- Publishing compares a staged file's hash with the one the state recorded at the last publish,
  so the target is not read back - in a OneDrive folder, reading can mean downloading. Those
  hashes count only for the snapshot folder they were published into: after a new target or a
  renamed machine, the first publish compares with what is there. The same goes for the config
  the snapshot carries (`config.json`), and a run reads `phoenix.json` once.
- git runs with a time limit (5 minutes, a clone an hour) and never asks on a terminal
  (`GIT_TERMINAL_PROMPT=0`): a hung share or a credential prompt nobody sees must not hold the
  run.
- Repository discovery is cached and refreshed daily, when a configured root is missing from the
  scan, or by `phx scan`.
- Git-heavy work (`wip` bundles) runs only for repositories whose refs changed: one
  `git for-each-ref` per repository, hashed, compared with the last run.
- Slow inventories (`winget export`, `scoop export`, the module list) have their own cadence
  (default daily) instead of running every hour; `providers.<name>.cadence` in the config overrides
  it. A provider is due when its cadence has passed since it last ran, a tenth of the cadence (at
  most five minutes) early included - a scheduled run never starts on the second, and an hourly
  provider must not slip to every other hour. A last run in the future (a clock put right) counts
  as due.
- The process runs at below-normal priority.

## Scheduling

Windows: a per-user Task Scheduler task `\PSPhoenix\Backup`.

- Triggers: every `interval` (default `1h`, 15m to 31d, set with `phx schedule -Every 2h`), and at
  logon after a 5-minute delay.
- Settings: `StartWhenAvailable` (a run missed during sleep or shutdown happens right after),
  `MultipleInstances IgnoreNew` (never overlapping runs), `ExecutionTimeLimit` 15 minutes,
  priority 7 (below normal); it runs on battery too. The principal is the user, logged on
  (`Interactive`): the run needs the user's credential store and `gh` keyring.
- Action: `conhost.exe --headless "<pwsh>" -NoProfile -NonInteractive -File "<module>\phx-task.ps1"`,
  naming the PowerShell of the installation that ran `phx schedule on` - a Microsoft Store one
  through its execution alias, which outlives the versioned folder it lives in. Without
  `conhost --headless` a console window flashes up every run, `-WindowStyle Hidden` included. The
  Task Scheduler sees only conhost's exit code, always 0: how a run went is read from the state.
- The module folder it names is one an update leaves in place: imported through Scoop's modules
  folder it already is one (a junction to `apps\psphoenix\current`); imported from a version folder
  with a `current` next to it, `current` is named instead.
- `phx schedule status` and `phx status` check the registered task against what `phx schedule on`
  would register now - a PowerShell or module that is gone, another module than this one, another
  interval than the config's - and say `phx schedule on` fixes it. `phx init` asks whether to run in
  the background, defaulting to what is so now (on for a first init): Enter leaves a matching task
  alone, no removes it. `-Every` goes with `on` only, and the interval is saved once the task is
  registered, so a failed registration leaves config and task agreeing.

Rejected alternatives:

- **Windows service**: runs in session 0 as a service account, so it has no access to the user's
  credential store and `gh` keyring (no `git push`, no user profile without storing a password);
  needs admin and a wrapper; stays resident.
- **cron**: not native on Windows (only through WSL or a third-party daemon, which do not see the
  Windows credentials). Task Scheduler is Windows' cron, and catches up missed runs.

macOS and Linux (later): a launchd agent with `StartInterval`, a systemd `--user` timer.

## Commands

```
phx init                          wizard: roots, discovery, accounts, target, machine, secrets,
                                  interval, schedule on; then the review of gitignored candidates
phx run [-Provider <name>]        one backup run now (what the scheduled task calls)
phx status                        last run, changes, pending review items, local-only work, warnings
phx review                        decide on pending gitignored candidates (see Gitignored files)
phx scan                          re-discover repositories under the roots
phx roots add|rm|list             manage roots; add takes -Depth <n> (1-10, default 3); roots
                                  may not overlap - discovery would see repositories twice
phx schedule on|off|status        manage the scheduled task; -Every 30m|1h|1d sets the interval
phx restore                       rebuild this machine from a snapshot (see below)
phx providers                     the providers registered for this platform
phx version                       module version
phx help                          usage
```

An unknown command, or one whose milestone has not arrived yet, is an error - `$?` is false and
`pwsh -Command` exits with 1 - so a scheduled task that calls it fails visibly.

`phx init` saves nothing before its last question - neither the config nor the scan of the roots it
offers; `q` at any prompt, Ctrl+C or the end of input stops without saving - and starts from the
current values when run again. A choice from a list - the roots (several), the account per owner,
the target, the interval - is made with the arrow keys on a console: space ticks a row, Enter
accepts, `q` or Esc stops, and a last row takes a typed path or interval. Without one (input
redirected, `-NonInteractive`, another host) the same lists are numbered and answered by typing
numbers, a label or a path. It offers the current roots and the usual folders that hold
repositories (`~/source/repos`, `C:\Repos`, `~/src`, ...) with their repository counts; asks, per
owner on a host `gh` is logged in to, which account its repositories use - defaulting to the account
set before (kept, with a warning, when `gh` is not logged in with it), else what their credential
helpers say, else the active account; suggests the OneDrive for Business folder as target, with a
note on where company data belongs when another folder is chosen; names the machine (the computer
name, not a folder another installation wrote); sets up the age key secrets are encrypted to (see
[Secrets](#secrets)); takes an interval from 15 minutes to 31 days (Task Scheduler's longest
repetition); and, on Windows, asks to turn the schedule on. Once saved, it shows how many
gitignored files wait for a decision and offers the review (`phx review`), which saves each
answer itself - `q` there leaves the saved set-up as it is. Each later milestone adds its step.

`phx run` is one backup run, and what the scheduled task calls (through `phx-task.ps1` next to the
module, headless and at below-normal priority). It needs the set-up from `phx init` and the target
folder - a missing target fails the run rather than creating a folder in its place; whether the
target can be written shows when publishing does (a probe file every run would be an upload every
run). It takes a lock before it writes anything, so two runs never overlap: a second one says so and
stops. It scans first when discovery is due (a failed scan leaves the last one in place), then runs
every provider that applies to this platform, is not disabled in the config and is due
(`-Provider` runs the one named, whatever its cadence), each into a fresh staging folder, and
publishes the ones that succeeded - each on its own, so one that cannot be published (a file held
open in the target) does not hold up the others. A provider fails when it throws, writes an error,
or cannot be published; it keeps its last snapshot and its file state, and runs again next time.
The run goes on with the others and fails at the end, naming them. A provider's last run is the
start of the run, so a long run does not push its next turn past the cadence's slack. Everything a
run prints, warnings and errors included, also goes to its log in the state folder
(`logs/run-<time>.log`, the newest 30 kept), with any token masked; the state records the run
even when it fails half-way, and `phx status` shows when it was, whether it failed, and where its
log is. `phx-task.ps1` exits 1 when the run failed, but under `conhost --headless` the Task
Scheduler only sees conhost's own result - the state is where the outcome is read.

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
  "machine": { "name": "WOUTER-LT", "id": "6f0e8c1a-..." },
  "interval": "1h",
  "providers": { "winget": { "enabled": true, "cadence": "1d" }, "claude": { "transcripts": false } },
  "accounts": { "github.com/WizX20": "WizX20", "github.com/summitnl": "wpaap" },
  "secrets": { "recipient": "age1..." },
  "files": {
    "maxKB": 1024,
    "exclude": [],
    "repos": {
      "github.com/summitnl/HippoCampus": {
        "include": [ "/config.local.env", ".claude/settings.local.json" ],
        "secret":  [ "/secrets.local.env" ],
        "exclude": [ "docker/services.local.env", "**/appsettings*.local.json", "/tmp/" ],
        "plain":   { "/appsettings.json": [ "SecretValue:ClientSecret" ] }
      }
    }
  }
}
```

A root needs a full path; a hand-written one without `depth` gets 3, and a depth outside 1-10 is an
error, like any other invalid config: an `interval` that is not 15m to 31d, a `providers.<name>` that
is not an object, an `enabled` that is not true or false, a `cadence` that is not a duration.

## Engine

`phx`, the wizard, the commands and the providers are PowerShell: they talk to the user and to
tools - git, gh, winget, the Task Scheduler. What moves many files or keeps the books is a C#
library that ships inside the module, `lib/PSPhoenix.Engine.dll` (`engine/` in the repository,
with its own xUnit tests):

- writing a file through a temporary name and one rename, copying, hashing (SHA-256);
- publishing the staged files into the snapshot;
- the state (`state.json`) and change detection - a provider's `$Context.Files`;
- the secret scan (`SecretScanner`, #45): what is a secret, by content - see [Secrets](#secrets);
- age encryption (`Age`, #25), built in - see [Secrets](#secrets);
- the discovery walk under each root (`RepositoryFinder`) - see [Concepts](#concepts);
- the gitignored files of a repository through the built-in filters (`IgnoredFiles`), and the
  review's patterns and decisions (`PathPattern`, `FileRules`) - see
  [Gitignored files](#gitignored-files-filters-and-review);
- restoring files: the manifests and what a restore may write where (`RestoreManifest`,
  `RestorePlanner`) - see [A snapshot is trusted input](#github-accounts).

It targets .NET 8, what PowerShell 7.4 runs on, and depends on nothing but .NET: PowerShell calls
its public classes, and an exception it throws reaches the user as its own message. The module
does not import without it. It is loaded from its bytes, so no session holds the file open: an
update or an uninstall replaces it while PowerShell runs. .NET keeps the engine a session loaded
first, so importing a module with another engine (an update, another working copy) into that
session is refused - a new session loads it.

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
5. **Machine id and roaming profiles**: the id lives in the config, in the roaming `%APPDATA%`. With
   roaming profiles or folder redirection two machines could share it and write one folder. A
   machine-bound copy in the local state folder would catch that, but losing the state would then
   lock a machine out of its own snapshot - left open until someone needs it.
