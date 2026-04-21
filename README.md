# zap-history-zsh-plugin

Fast history cleanup for zsh with single-delete, bulk fuzzy delete, and last-entry cleanup.

## Features

- Delete current autosuggestion/current line (`Ctrl-Z` then `k`)
- Bulk fuzzy-select delete with `fzf` (`Ctrl-Z` then `b`)
- Delete last history entry (`Ctrl-Z` then `l`)
- CLI commands:
  - `zap --bulk [query]`
  - `zap --last [count]`
  - `zap --prefix <text>`
  - `zap --exact "<command>"`
- Works with `zsh-autosuggestions` to suppress deleted suggestions immediately
- Uses a cached index for fast bulk open times

## Requirements

- zsh
- `fzf` (for bulk mode)

## Install

### Antidote

1. Add this repo to your plugin list (after `zsh-users/zsh-autosuggestions` is recommended):

```txt
your-org-or-user/zap-history-zsh-plugin
```

2. Regenerate/source your antidote bundle as you normally do.

### Plain zsh

```zsh
source /path/to/zap-history-zsh-plugin/zap-history.plugin.zsh
```

## Usage

### Hotkeys

- `Ctrl-Z` then `k`: delete current suggestion/current line
- `Ctrl-Z` then `b`: open bulk fuzzy delete
- `Ctrl-Z` then `l`: delete last history entry

### Command mode

```zsh
zap
zap --bulk
zap --bulk "curl -L"
zap --last
zap --last 3
zap --prefix "curl -L"
zap --exact "curl -L -o \"file.mp4\" \"https://example.com/file.mp4\""
```

## Optional config

Set before sourcing the plugin:

```zsh
ZAP_HISTORY_ENABLE_KEYBINDINGS=1
ZAP_HISTORY_BINDKEY_DELETE='^Zk'
ZAP_HISTORY_BINDKEY_BULK='^Zb'
ZAP_HISTORY_BINDKEY_LAST='^Zl'
```

## Notes

- Bulk index cache is stored under `${XDG_CACHE_HOME:-$HOME/.cache}/zap-history`.
- If you intentionally run a previously zapped command again, it becomes eligible for suggestions again.

## License

MIT
