#!/usr/bin/env bash
# Tells you when an agent stops working and starts waiting on you, so a long
# run does not need babysitting. Started from the plugin entry point with
# run-shell -b; the pidfile stops a config reload from stacking watchers.
#
# Options:
#   @agents-watch-interval  seconds between scans (default 3)
#   @agents-watch-settle    scans a pane must stay idle before it counts
#                           (default 3). Agents look idle for a moment between
#                           tool calls, and this is what keeps a single run
#                           from firing a dozen times.
#   @agents-notify-command  shell command receiving the message on stdin, for
#                           phone or desktop delivery. Empty disables it.
#   @agents-notify-desktop  'on' (default) uses osascript on macOS
set -uo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
. "$DIR/helpers.sh"

interval=$(opt @agents-watch-interval 3)
settle=$(opt @agents-watch-settle 3)
notify_cmd=$(opt @agents-notify-command '')
notify_desktop=$(opt @agents-notify-desktop on)

dir=${TMPDIR:-/tmp}
pidfile=$dir/tmux-agents-watch.pid
state=$dir/tmux-agents-watch.state
scan=$dir/tmux-agents-watch.scan
next=$dir/tmux-agents-watch.next

if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
	exit 0
fi
printf '%s\n' "$$" >"$pidfile"
trap 'rm -f "$pidfile"' EXIT

: >"$state"
first=1

while tmux has-session 2>/dev/null; do
	# whatever a client is looking at right now needs no announcing
	focus=$(tmux list-panes -a -F \
		'#{?#{&&:#{pane_active},#{&&:#{window_active},#{session_attached}}},#{session_name}:#{window_index}.#{pane_index},}' \
		2>/dev/null | grep -v '^$' | tr '\n' ' ')
	ignore=" $(opt @agents-ignore-sessions '') "

	if "$DIR/agent-scan.sh" >"$scan" 2>/dev/null; then
		awk -F'\t' -v settle="$settle" -v first="$first" -v focus=" $focus" \
			-v out="$next" -v prev="$state" -v ignore="$ignore" '
			# previous state: target, state, idle-scan count. Keyed on FILENAME,
			# not NR==FNR, which breaks when the state file is empty
			FILENAME == prev { was[$1] = $3; next }
			index(ignore, " " $2 " ") { next }
			{
				c = ($10 == "idle") ? was[$1] + 1 : 0
				# seed every already-idle pane past the threshold, so starting the
				# watcher does not announce a screenful of agents at once
				if (first && $10 == "idle") c = settle + 1
				# parentheses matter: bare "> out" parses as a comparison
				printf("%s\t%s\t%s\n", $1, $10, c) > out
				if (c == settle && index(focus, " " $1 " ") == 0) printf "%s\t%s\n", $1, $11
			}' "$state" "$scan" \
			| while IFS=$'\t' read -r target title; do
				body=$(printf '%s' "$title" | sed 's/^[^[:alnum:]]*[[:space:]]*//')
				tmux display-message "✳ $target is waiting: $body" 2>/dev/null
				if [ -n "$notify_cmd" ]; then
					printf '✳ %s is waiting\n%s\n' "$target" "$body" | sh -c "$notify_cmd" >/dev/null 2>&1 &
				fi
				if [ "$notify_desktop" = on ] && command -v osascript >/dev/null 2>&1; then
					osascript -e "display notification \"${body//\"/}\" with title \"✳ $target is waiting\"" >/dev/null 2>&1 &
				fi
			done
		[ -f "$next" ] && mv "$next" "$state"
	fi

	first=0
	sleep "$interval"
done
