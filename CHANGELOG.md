# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- `--dry-run` mode for previewing bulk matches before deletion.
- `zap --undo` to restore the most recently deleted command set.
- Time-scoped cleanup flags such as `--since` and `--before`.
- Repo-aware and directory-aware filtering for safer bulk operations.
- Protected-pattern rules so sensitive/important commands are never deleted by accident.
- `zap stats` summary view for quick history-cleanup insights.
- Optional background index pre-warm on shell startup.
- Dedicated tests/fixtures for multiline and extended-history edge cases.
- Optional per-user config file support (for defaults and keybind overrides).

## [1.0.0] - 2026-04-21

### Added
- Initial public release of `zap-history-zsh-plugin`.
- `zap --bulk` multi-select fuzzy deletion flow.
- `zap --last` for fast removal of the most recent history entry.
- Pattern-based deletion modes (`--prefix`, `--exact`).
- Built-in keybindings (`Ctrl-Z` then `k`, `b`, or `l`).
- Cached history index for fast bulk selection.
- Autosuggestion refresh and cache handling after deletes.
- Safe handling around widget-only calls and autosuggest async FD behavior.
