# zap-history.plugin.zsh
# Fast history cleanup for zsh:
# - single delete (current suggestion / line)
# - bulk fuzzy delete with fzf
# - last-N delete
# - prefix and exact delete

if (( ${+__ZAP_HISTORY_PLUGIN_LOADED} )); then
  return 0
fi
typeset -g __ZAP_HISTORY_PLUGIN_LOADED=1

typeset -g __ZAP_INDEX_BUILD_PID
typeset -ga _ZAP_HISTORY_BLOCKLIST_RAW
typeset -ga _ZAP_HISTORY_BLOCKLIST_NORM

: ${ZAP_HISTORY_BINDKEY_DELETE:='^Zk'}
: ${ZAP_HISTORY_BINDKEY_BULK:='^Zb'}
: ${ZAP_HISTORY_BINDKEY_LAST:='^Zl'}
: ${ZAP_HISTORY_ENABLE_KEYBINDINGS:=1}

function _normalize_history_item_text() {
  emulate -L zsh
  local text="$1"

  text=${text//$'\r'/}
  while [[ $text == *$'\\\n'* ]]; do
    text=${text//$'\\\n'/ }
  done
  text=${text//$'\n'/ }
  text=${text//$'\t'/ }
  while [[ $text == *"  "* ]]; do
    text=${text//  / }
  done
  text=${text## }
  text=${text%% }
  print -r -- "$text"
}

function _zap_status_msg() {
  emulate -L zsh
  local msg="$1"
  if [[ -n "${WIDGET-}" ]]; then
    zle -M "$msg" 2>/dev/null
  fi
}

function _zap_blocklist_add() {
  emulate -L zsh
  local raw="$1"
  local norm="$2"
  local v

  for v in "${_ZAP_HISTORY_BLOCKLIST_RAW[@]}"; do
    [[ "$v" == "$raw" ]] && return 0
  done
  _ZAP_HISTORY_BLOCKLIST_RAW+=("$raw")

  for v in "${_ZAP_HISTORY_BLOCKLIST_NORM[@]}"; do
    [[ "$v" == "$norm" ]] && return 0
  done
  _ZAP_HISTORY_BLOCKLIST_NORM+=("$norm")
}

function _zap_blocklist_remove() {
  emulate -L zsh
  local raw="$1"
  local norm="$2"
  local -a keep_raw=() keep_norm=()
  local v

  for v in "${_ZAP_HISTORY_BLOCKLIST_RAW[@]}"; do
    [[ "$v" == "$raw" ]] || keep_raw+=("$v")
  done
  _ZAP_HISTORY_BLOCKLIST_RAW=("${keep_raw[@]}")

  for v in "${_ZAP_HISTORY_BLOCKLIST_NORM[@]}"; do
    [[ "$v" == "$norm" ]] || keep_norm+=("$v")
  done
  _ZAP_HISTORY_BLOCKLIST_NORM=("${keep_norm[@]}")
}

function _zap_is_blocked() {
  emulate -L zsh
  local entry="$1"
  local entry_norm="$2"
  local v

  for v in "${_ZAP_HISTORY_BLOCKLIST_RAW[@]}"; do
    [[ "$entry" == "$v" ]] && return 0
  done
  for v in "${_ZAP_HISTORY_BLOCKLIST_NORM[@]}"; do
    [[ "$entry_norm" == "$v" ]] && return 0
  done
  return 1
}

function _zap_refresh_autosuggest_state() {
  emulate -L zsh

  if typeset -f _zsh_autosuggest_clear >/dev/null; then
    _zsh_autosuggest_clear 2>/dev/null
  fi

  if (( ${+_ZSH_AUTOSUGGEST_ASYNC_FD} )); then
    local fd="${_ZSH_AUTOSUGGEST_ASYNC_FD}"
    if [[ "$fd" == <-> ]]; then
      if eval "true <&$fd" 2>/dev/null; then
        eval "exec $fd<&-" 2>/dev/null
      fi
    fi
    unset _ZSH_AUTOSUGGEST_ASYNC_FD
  fi
}

function _zap_extract_history_command() {
  emulate -L zsh
  local entry="$1"
  if [[ $entry == ': '*';'* ]]; then
    print -r -- "${entry#*;}"
  else
    print -r -- "$entry"
  fi
}

function _zap_stream_history_commands() {
  emulate -L zsh
  local histfile="${1:-$HISTFILE}"
  [[ -n "$histfile" && -f "$histfile" ]] || return 1

  local entry="" line cmd norm
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$entry" ]]; then
      entry+=$'\n'"$line"
    else
      entry="$line"
    fi

    [[ $line == *\\ ]] && continue

    cmd="$(_zap_extract_history_command "$entry")"
    norm="$(_normalize_history_item_text "$cmd")"
    [[ -n "$norm" ]] && print -r -- "$norm"
    entry=""
  done < "$histfile"

  if [[ -n "$entry" ]]; then
    cmd="$(_zap_extract_history_command "$entry")"
    norm="$(_normalize_history_item_text "$cmd")"
    [[ -n "$norm" ]] && print -r -- "$norm"
  fi
}

function _zap_histfile_signature() {
  emulate -L zsh
  local histfile="${1:-$HISTFILE}"
  [[ -n "$histfile" && -f "$histfile" ]] || return 1

  if stat -f '%m:%z' "$histfile" >/dev/null 2>&1; then
    stat -f '%m:%z' "$histfile"
  else
    stat -c '%Y:%s' "$histfile"
  fi
}

function _zap_cache_paths() {
  emulate -L zsh
  local histfile="${1:-$HISTFILE}"
  local cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/zap-history"
  mkdir -p "$cache_root" || return 1

  local tag="${histfile//\//_}"
  tag="${tag//[^A-Za-z0-9._-]/_}"
  print -r -- "$cache_root/$tag.index.tsv"
  print -r -- "$cache_root/$tag.index.sig"
}

function _zap_generate_bulk_index() {
  emulate -L zsh
  local histfile="${1:-$HISTFILE}"
  local index_file="$2"
  local tmpfile
  tmpfile="$(mktemp "${index_file}.tmp.XXXXXX")" || return 1

  if ! _zap_stream_history_commands "$histfile" \
    | LC_ALL=C sort \
    | uniq -c \
    | awk '{c=$1; $1=""; sub(/^ +/,""); print c "\t" $0}' \
    | LC_ALL=C sort -t$'\t' -k1,1nr > "$tmpfile"; then
    command rm -f "$tmpfile" 2>/dev/null
    return 1
  fi

  mv -f "$tmpfile" "$index_file"
}

function _zap_ensure_bulk_index() {
  emulate -L zsh
  local histfile="${1:-$HISTFILE}"
  [[ -n "$histfile" && -f "$histfile" ]] || return 1

  local paths index_file sig_file
  paths="$(_zap_cache_paths "$histfile")" || return 1
  index_file="${paths%%$'\n'*}"
  sig_file="${paths##*$'\n'}"

  local current_sig saved_sig
  current_sig="$(_zap_histfile_signature "$histfile")" || return 1
  saved_sig="$(cat "$sig_file" 2>/dev/null)"

  if [[ ! -f "$index_file" ]]; then
    _zap_status_msg "zap: indexing history..."
    _zap_generate_bulk_index "$histfile" "$index_file" || return 1
    print -r -- "$current_sig" >| "$sig_file" 2>/dev/null || true
  elif [[ "$saved_sig" != "$current_sig" ]]; then
    _zap_status_msg "zap: refreshing index..."
    if [[ -z "${__ZAP_INDEX_BUILD_PID-}" ]] || ! kill -0 "$__ZAP_INDEX_BUILD_PID" 2>/dev/null; then
      (
        _zap_generate_bulk_index "$histfile" "$index_file" &&
          print -r -- "$current_sig" >| "$sig_file" 2>/dev/null
      ) &!
      __ZAP_INDEX_BUILD_PID=$!
    fi
  fi

  print -r -- "$index_file"
}

function _zap_norm_in_list() {
  emulate -L zsh
  local needle="$1"
  shift
  local v
  for v in "$@"; do
    [[ "$needle" == "$v" ]] && return 0
  done
  return 1
}

function _zap_rewrite_history_without_norms() {
  emulate -L zsh

  local histfile="$1"
  local tmpfile="$2"
  shift 2
  local -a target_norms=("$@")
  target_norms=("${(@u)target_norms}")

  (( ${#target_norms} > 0 )) || return 1
  [[ -f "$histfile" ]] || return 1
  : >| "$tmpfile" || return 1

  local entry="" line cmd cmd_norm
  local found=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$entry" ]]; then
      entry+=$'\n'"$line"
    else
      entry="$line"
    fi

    [[ $line == *\\ ]] && continue

    cmd="$(_zap_extract_history_command "$entry")"
    cmd_norm="$(_normalize_history_item_text "$cmd")"

    if _zap_norm_in_list "$cmd_norm" "${target_norms[@]}"; then
      found=1
    else
      print -r -- "$entry" >> "$tmpfile" || return 1
    fi
    entry=""
  done < "$histfile"

  if [[ -n "$entry" ]]; then
    cmd="$(_zap_extract_history_command "$entry")"
    cmd_norm="$(_normalize_history_item_text "$cmd")"
    if _zap_norm_in_list "$cmd_norm" "${target_norms[@]}"; then
      found=1
    else
      print -r -- "$entry" >> "$tmpfile" || return 1
    fi
  fi

  (( found ))
}

function _zap_delete_norms_from_history() {
  emulate -L zsh
  local histfile="$HISTFILE"
  local tmpfile="${histfile}.zap.$$"

  if _zap_rewrite_history_without_norms "$histfile" "$tmpfile" "$@"; then
    mv -f "$tmpfile" "$histfile"
    return 0
  fi

  command rm -f "$tmpfile" 2>/dev/null
  return 1
}

function _zap_delete_commands() {
  emulate -L zsh
  local -a cmds=("$@")
  local -a norms=()
  local cmd norm

  for cmd in "${cmds[@]}"; do
    norm="$(_normalize_history_item_text "$cmd")"
    [[ -n "$norm" ]] || continue
    norms+=("$norm")
    _zap_blocklist_add "$cmd" "$norm"
  done

  (( ${#norms} > 0 )) || return 1
  _zap_delete_norms_from_history "${norms[@]}"
  local rewrote=$?
  _zap_refresh_autosuggest_state
  return $rewrote
}

function _zap_collect_last_commands() {
  emulate -L zsh
  local count="$1"
  local -a selected=()
  local pass
  local key entry norm

  for pass in 1 2; do
    selected=()
    for key in ${(Onk)history}; do
      entry="${history[$key]}"
      norm="$(_normalize_history_item_text "$entry")"
      [[ -n "$norm" ]] || continue

      case "$norm" in
        zap|zap\ *|remove_history_item|remove_history_item\ *|remove_history_items_fuzzy|remove_history_items_fuzzy\ *|remove_last_history_item|remove_last_history_item\ *)
          continue
          ;;
      esac

      selected+=("$entry")
      (( ${#selected} >= count )) && break
    done

    (( ${#selected} > 0 )) && break
    [[ -n "$HISTFILE" && -f "$HISTFILE" ]] && fc -R "$HISTFILE" 2>/dev/null
  done

  (( ${#selected} > 0 )) || return 1
  print -rl -- "${selected[@]}"
}

function _zap_choose_bulk_commands() {
  emulate -L zsh
  local initial_query="$1"

  if ! command -v fzf >/dev/null; then
    print -u2 -- "zap: fzf is required for bulk mode."
    return 1
  fi

  local index_file
  index_file="$(_zap_ensure_bulk_index "$HISTFILE")" || return 1
  [[ -s "$index_file" ]] || return 1

  local selected
  selected="$(
    cat "$index_file" | \
      fzf \
        --multi \
        --reverse \
        --height=70% \
        --delimiter=$'\t' \
        --with-nth=2.. \
        --prompt='zap bulk> ' \
        --query "$initial_query" \
        --bind 'ctrl-a:toggle-all' \
        --header='Type to fuzzy filter, TAB to mark, CTRL-A select all shown, ENTER to delete'
  )"
  local rc=$?
  _zap_status_msg ""
  if (( rc != 0 )) || [[ -z "$selected" ]]; then
    return 2
  fi

  local -a selected_cmds=()
  local line
  for line in ${(f)selected}; do
    selected_cmds+=("${line#*$'\t'}")
  done

  print -rl -- "${selected_cmds[@]}"
  return 0
}

function _zap_collect_commands_by_prefix() {
  emulate -L zsh
  local prefix="$1"
  [[ -n "$prefix" ]] || return 1

  local index_file
  index_file="$(_zap_ensure_bulk_index "$HISTFILE")" || return 1
  [[ -s "$index_file" ]] || return 1

  local out
  out="$(awk -F '\t' -v p="$prefix" 'index($2, p) == 1 {print $2}' "$index_file")"
  [[ -n "$out" ]] || return 1
  print -r -- "$out"
}

function _zsh_autosuggest_strategy_zap_history() {
  emulate -L zsh
  setopt EXTENDED_GLOB

  local prefix="${1//(#m)[\\*?[\]<>()|^~#]/\\$MATCH}"
  local pattern="$prefix*"
  local key entry entry_norm

  if [[ -n $ZSH_AUTOSUGGEST_HISTORY_IGNORE ]]; then
    pattern="($pattern)~($ZSH_AUTOSUGGEST_HISTORY_IGNORE)"
  fi

  for key in ${(Onk)history}; do
    entry="${history[$key]}"
    [[ "$entry" == ${~pattern} ]] || continue
    entry_norm="$(_normalize_history_item_text "$entry")"
    _zap_is_blocked "$entry" "$entry_norm" && continue
    typeset -g suggestion="$entry"
    return
  done

  unset suggestion
}

function remove_history_item() {
  emulate -L zsh
  local item="$BUFFER$POSTDISPLAY"
  [[ -n "$item" ]] || return 0

  _zap_delete_commands "$item"
  local rewrote=$?

  BUFFER=""
  zle reset-prompt
  if (( rewrote == 0 )); then
    echo -e "\n\033[0;31mDeleted from history: \033[1;37m$item\033[0m"
  else
    echo -e "\n\033[0;33mSuppressed from suggestions (already absent on disk): \033[1;37m$item\033[0m"
  fi
}

function remove_history_items_fuzzy() {
  emulate -L zsh
  _zap_status_msg "zap: preparing bulk selector..."
  local initial_query="$(_normalize_history_item_text "$BUFFER$POSTDISPLAY")"
  local selected
  selected="$(_zap_choose_bulk_commands "$initial_query")"
  local rc=$?

  if (( rc == 2 )); then
    zle reset-prompt
    return 0
  fi
  if (( rc != 0 )); then
    _zap_status_msg "zap: bulk selection failed."
    return 1
  fi

  local -a cmds=("${(@f)selected}")
  _zap_delete_commands "${cmds[@]}"
  local rewrote=$?

  BUFFER=""
  zle reset-prompt
  if (( rewrote == 0 )); then
    echo -e "\n\033[0;31mDeleted ${#cmds} command pattern(s) from history.\033[0m"
  else
    echo -e "\n\033[0;33mSuppressed ${#cmds} command pattern(s) from suggestions.\033[0m"
  fi
}

function remove_last_history_item() {
  emulate -L zsh
  local count="${NUMERIC:-1}"
  (( count < 1 )) && count=1

  local selected
  selected="$(_zap_collect_last_commands "$count")" || {
    _zap_status_msg "zap: no previous command found."
    return 1
  }
  local -a cmds=("${(@f)selected}")

  _zap_delete_commands "${cmds[@]}"
  local rewrote=$?

  BUFFER=""
  zle reset-prompt
  if (( rewrote == 0 )); then
    echo -e "\n\033[0;31mDeleted last ${#cmds} history entr$( (( ${#cmds} == 1 )) && print -n y || print -n ies ).\033[0m"
  else
    echo -e "\n\033[0;33mSuppressed last ${#cmds} history entr$( (( ${#cmds} == 1 )) && print -n y || print -n ies ) from suggestions.\033[0m"
  fi
}

function _zap_print_help() {
  cat <<'EOF'
zap: history deletion utility

Usage:
  zap                     Open fuzzy multi-select bulk delete.
  zap <query>             Open bulk selector with initial query.
  zap --bulk [query]      Same as above.
  zap --last [count]      Delete the last command(s) from history.
  zap --prefix <text>     Delete all commands that start with text.
  zap --exact <command>   Delete one exact command pattern.
  zap --help              Show this help.

Keybindings:
  Ctrl-Z then k           Delete current suggestion/current line.
  Ctrl-Z then b           Fuzzy multi-select bulk delete.
  Ctrl-Z then l           Delete last history entry.
EOF
}

function zap() {
  emulate -L zsh
  local mode="$1"

  case "$mode" in
    --help|-h)
      _zap_print_help
      ;;
    --last|-l)
      shift
      local count="${1:-1}"
      if ! [[ "$count" == <-> ]]; then
        print -u2 -- "zap: --last expects a positive integer."
        return 1
      fi
      local selected
      selected="$(_zap_collect_last_commands "$count")" || {
        print -u2 -- "zap: no previous command found."
        return 1
      }
      local -a cmds=("${(@f)selected}")
      _zap_delete_commands "${cmds[@]}"
      if (( $? == 0 )); then
        print -r -- "Deleted last ${#cmds} history entr$( (( ${#cmds} == 1 )) && print -n y || print -n ies )."
      else
        print -r -- "Suppressed last ${#cmds} history entr$( (( ${#cmds} == 1 )) && print -n y || print -n ies ) from suggestions."
      fi
      ;;
    --exact|-x)
      shift
      [[ $# -gt 0 ]] || {
        print -u2 -- "zap: --exact requires command text."
        return 1
      }
      local item="$*"
      _zap_delete_commands "$item"
      if (( $? == 0 )); then
        print -r -- "Deleted from history: $item"
      else
        print -r -- "Suppressed from suggestions (already absent on disk): $item"
      fi
      ;;
    --prefix|-p)
      shift
      [[ $# -gt 0 ]] || {
        print -u2 -- "zap: --prefix requires text."
        return 1
      }
      local prefix="$*"
      local matched
      matched="$(_zap_collect_commands_by_prefix "$prefix")" || {
        print -u2 -- "zap: no history entries found for prefix: $prefix"
        return 1
      }
      local -a cmds=("${(@f)matched}")
      _zap_delete_commands "${cmds[@]}"
      if (( $? == 0 )); then
        print -r -- "Deleted ${#cmds} command pattern(s) starting with: $prefix"
      else
        print -r -- "Suppressed ${#cmds} command pattern(s) starting with: $prefix"
      fi
      ;;
    --bulk|-b)
      shift
      ;&
    "")
      local selected
      selected="$(_zap_choose_bulk_commands "$*")"
      local rc=$?
      if (( rc == 2 )); then
        return 0
      fi
      if (( rc != 0 )); then
        return $rc
      fi
      local -a cmds=("${(@f)selected}")
      _zap_delete_commands "${cmds[@]}"
      if (( $? == 0 )); then
        print -r -- "Deleted ${#cmds} command pattern(s) from history."
      else
        print -r -- "Suppressed ${#cmds} command pattern(s) from suggestions."
      fi
      ;;
    *)
      local selected
      selected="$(_zap_choose_bulk_commands "$*")"
      local rc=$?
      if (( rc == 2 )); then
        return 0
      fi
      if (( rc != 0 )); then
        return $rc
      fi
      local -a cmds=("${(@f)selected}")
      _zap_delete_commands "${cmds[@]}"
      if (( $? == 0 )); then
        print -r -- "Deleted ${#cmds} command pattern(s) from history."
      else
        print -r -- "Suppressed ${#cmds} command pattern(s) from suggestions."
      fi
      ;;
  esac
}

function _zap_preexec_unblock() {
  emulate -L zsh
  local line="$1"
  [[ -n "$line" ]] || return 0
  _zap_blocklist_remove "$line" "$(_normalize_history_item_text "$line")"
}

if whence -w add-zsh-hook >/dev/null 2>&1; then
  autoload -Uz add-zsh-hook
  add-zsh-hook preexec _zap_preexec_unblock
fi

if [[ -o interactive ]]; then
  zle -N remove_history_item
  zle -N remove_history_items_fuzzy
  zle -N remove_last_history_item

  if (( ZAP_HISTORY_ENABLE_KEYBINDINGS )); then
    if [[ -t 0 ]]; then
      stty susp undef 2>/dev/null
    fi
    bindkey "$ZAP_HISTORY_BINDKEY_DELETE" remove_history_item
    bindkey "$ZAP_HISTORY_BINDKEY_BULK" remove_history_items_fuzzy
    bindkey "$ZAP_HISTORY_BINDKEY_LAST" remove_last_history_item
    bindkey -M viins "$ZAP_HISTORY_BINDKEY_DELETE" remove_history_item 2>/dev/null
    bindkey -M viins "$ZAP_HISTORY_BINDKEY_BULK" remove_history_items_fuzzy 2>/dev/null
    bindkey -M viins "$ZAP_HISTORY_BINDKEY_LAST" remove_last_history_item 2>/dev/null
  fi
fi

if (( ${+functions[_zsh_autosuggest_strategy_zap_history]} )); then
  if (( ${+ZSH_AUTOSUGGEST_STRATEGY} )); then
    ZSH_AUTOSUGGEST_STRATEGY=(zap_history ${ZSH_AUTOSUGGEST_STRATEGY:#zap_history})
  else
    ZSH_AUTOSUGGEST_STRATEGY=(zap_history history)
  fi
fi
