#!/usr/bin/env bash
# tmux-agents entry point. TPM runs this on tmux start.
set -uo pipefail

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPTS=$DIR/scripts
. "$SCRIPTS/helpers.sh"

jump_key=$(opt @agents-jump-key w)
reap_key=$(opt @agents-reap-key k)
yank_key=$(opt @agents-yank-key g)

if [ "$jump_key" != off ]; then
	# run-shell, not display-popup: the picker opens its own popup and has to
	# reopen it to move it, which only works from outside a popup
	tmux bind-key "$jump_key" run-shell -b "$SCRIPTS/pane-picker.sh"
fi

if [ "$reap_key" != off ]; then
	tmux bind-key "$reap_key" display-popup -E -w 90 -h 20 -T " reap " "$SCRIPTS/reaper.sh"
fi

if [ "$yank_key" != off ]; then
	tmux bind-key "$yank_key" display-menu -T "#[align=centre] copy " -x C -y C \
		"path     #{b:pane_current_path}" p "run-shell -b '$SCRIPTS/yank.sh path #{pane_id}'" \
		"branch" b "run-shell -b '$SCRIPTS/yank.sh branch #{pane_id}'" \
		"address  #{session_name}:#{window_index}.#{pane_index}" a "run-shell -b '$SCRIPTS/yank.sh address #{pane_id}'" \
		"title" t "run-shell -b '$SCRIPTS/yank.sh title #{pane_id}'"
fi

if [ "$(opt @agents-notify on)" = on ]; then
	tmux run-shell -b "$SCRIPTS/agent-watch.sh"
fi

# Opt-in, because it rewrites status-right. Prepending is safe even when
# another plugin owns that string: tmux-continuum only needs its script to be
# present somewhere in it, not first.
if [ "$(opt @agents-status off)" = on ]; then
	current=$(tmux show -gv status-right 2>/dev/null || true)
	case $current in
		*status-context.sh*) ;; # already installed, keep reloads idempotent
		*)
			tmux set -g status-right "#($SCRIPTS/status-context.sh '#{pane_current_path}')  $current"
			if [ "$(tmux show -gv status-right-length)" -lt 100 ] 2>/dev/null; then
				tmux set -g status-right-length 100
			fi
			;;
	esac
fi

# a trailing test that happens to be false must not look like a failed plugin
exit 0
