#!/usr/bin/env bash
# Copy a piece of context about a pane to the clipboard and to a tmux buffer.
# Usage: yank.sh path|branch|address|title <pane-id>
set -uo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
. "$DIR/helpers.sh"

what=${1:-path}
pane=${2:-}

get() { tmux display-message -p ${pane:+-t "$pane"} "$1"; }

case $what in
	path) value=$(get '#{pane_current_path}') ;;
	address) value=$(get '#{session_name}:#{window_index}.#{pane_index}') ;;
	title) value=$(get '#{pane_title}') ;;
	branch)
		dir=$(get '#{pane_current_path}')
		value=$(git -C "$dir" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null || true)
		[ -z "$value" ] && { tmux display-message "no branch: not a git repo"; exit 0; }
		;;
	*)
		tmux display-message "yank: unknown field '$what'"
		exit 1
		;;
esac

copy=$(opt @agents-copy-command '')
if [ -z "$copy" ]; then
	if command -v pbcopy >/dev/null 2>&1; then copy=pbcopy
	elif command -v wl-copy >/dev/null 2>&1; then copy=wl-copy
	elif command -v xclip >/dev/null 2>&1; then copy='xclip -selection clipboard'
	fi
fi

[ -n "$copy" ] && printf '%s' "$value" | sh -c "$copy" 2>/dev/null
tmux set-buffer -- "$value"
tmux display-message "copied $what: $value"
