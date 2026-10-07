# Changelog

All notable changes to PSPhoenix (`phx`) are listed here, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions are [semantic](https://semver.org/).
Write new entries under **Unreleased** — the Release workflow stamps the version and date.

## [Unreleased]

### Fixed

- fix: config - saving replaces the file in one rename, so a reader never finds it missing; reading refuses an empty, corrupt or unversioned config with a message naming the file, reads keys in any case and fills in missing sections from the defaults; `phx` works without `APPDATA`/`LOCALAPPDATA` and ignores a relative `XDG_*` directory

## [0.1.0] - 2026-10-07

### Added

- feat: project scaffold (milestone M0) - the `phx` command with help, version and `phx providers`; config and state paths per platform; config read/save with a format version; the provider registry and its contract checks; the design in `docs/design.md`

