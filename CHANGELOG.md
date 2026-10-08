# Changelog

All notable changes to PSPhoenix (`phx`) are listed here, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions are [semantic](https://semver.org/).
New entries go in [changelog.d/](changelog.d/README.md), one file per pull request - the Release workflow folds them in here under the new version and date.

## [Unreleased]

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
