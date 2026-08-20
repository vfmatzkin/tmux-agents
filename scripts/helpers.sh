#!/usr/bin/env bash
# Shared option reading. The rule that decides what an agent pane is lives in
# agent-scan.sh, which is the only thing that classifies panes.

# Read a tmux user option, falling back to a default.
opt() {
	local value
	value=$(tmux show -gqv "$1" 2>/dev/null || true)
	if [ -n "$value" ]; then printf '%s' "$value"; else printf '%s' "$2"; fi
}

# True when a session should be hidden from the picker and the watcher.
agents_ignored() {
	case " $(opt @agents-ignore-sessions '') " in
		*" $1 "*) return 0 ;;
		*) return 1 ;;
	esac
}
