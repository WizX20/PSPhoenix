# Changelog fragments

A pull request with a user-visible change adds **one file here** instead of editing
`CHANGELOG.md`. Each pull request has its own file, so no pull request ever conflicts with
another over the changelog. The Release workflow folds the files into `CHANGELOG.md` under the
new version and deletes them (`scripts/cut-changelog.ps1`).

**Name:** `<anything>.<section>.md` — the branch name works well: `config-robustness.fixed.md`.
The section is one of Keep a Changelog's:

| Section | For |
|---|---|
| `added` | new commands, providers, options |
| `changed` | changes in existing behaviour, docs |
| `deprecated` | soon-to-be removed features |
| `removed` | removed features |
| `fixed` | bug fixes |
| `security` | vulnerabilities |

**Content:** one or more bullets, written like the entries in `CHANGELOG.md`:

```markdown
- fix: config - saving replaces the file in one rename, so a reader never finds it missing
```

Two kinds of change in one pull request: two files (`x.added.md`, `x.fixed.md`).
`task test` checks every file here (`scripts/cut-changelog.ps1 -Check`).
