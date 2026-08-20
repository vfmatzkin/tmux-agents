#!/usr/bin/env bash
# The only place that decides what a pane is and what state it is in.
# Everything else in this plugin reads this.
#
# Detection: an agent pane is one whose pane_current_command matches
# @agents-command-pattern. Claude Code execs a version-named binary, so the
# default matches a bare version like 2.1.233. State comes from the terminal
# title: it starts with @agents-idle-glyph while the agent waits on you, and
# with something else (an animated spinner) while it works.
#
# Output is one tab separated row per pane:
#   1 target        session:window.pane
#   2 session
#   3 window index
#   4 window name
#   5 pane index
#   6 panes in that window
#   7 pane active     1 | 0
#   8 cwd
#   9 cwd exists      1 | 0
#  10 state           idle | busy | none
#  11 pane title
set -uo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
. "$DIR/helpers.sh"

pattern=$(opt @agents-command-pattern '^[0-9]+(\.[0-9]+)+$')
glyph=$(opt @agents-idle-glyph '✳')

tmux list-panes -a -F \
	'#{session_name}	#{window_index}	#{window_name}	#{pane_index}	#{pane_current_command}	#{window_panes}	#{pane_active}	#{pane_current_path}	#{pane_title}' \
	| while IFS=$'\t' read -r s wi wn pi cmd np active cwd title; do
		# a test builtin per pane, rather than a fork
		if [ -d "$cwd" ]; then ok=1; else ok=0; fi
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$s" "$wi" "$wn" "$pi" "$cmd" "$np" "$active" "$cwd" "$ok" "$title"
	done \
	| awk -F'\t' -v pat="$pattern" -v glyph="$glyph" '
	{
		state = "none"
		if ($5 ~ pat) state = (index($10, glyph) == 1) ? "idle" : "busy"
		printf "%s:%s.%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
			$1, $2, $4, $1, $2, $3, $4, $6, $7, $8, $9, state, $10
	}'
