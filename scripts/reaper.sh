#!/usr/bin/env bash
# Kills sessions whose directories are gone and prunes the git metadata left
# behind. Removing a worktree does not remove the tmux session that lived in
# it, and a session restorer like tmux-resurrect will then bring the corpse
# back on every restart.
#
# Only sessions where EVERY pane's cwd is missing are offered for killing. A
# session with any surviving pane is reported but never listed, and the session
# you are attached to is never offered at all. Pick with tab, kill with enter.
set -uo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
here=$(tmux display-message -p '#{session_name}')

pause() { printf '\nPress enter to close.'; read -r _; }

scan=$("$DIR/agent-scan.sh")

# session -> total panes, missing panes, one example path
summary=$(printf '%s\n' "$scan" | awk -F'\t' -v here="$here" '
	{
		s = $2
		total[s]++
		if ($9 == 0) { gone[s]++; if (!(s in ex)) ex[s] = $8 }
		if (!(s in seen)) { seen[s] = ++n; ord[n] = s }
	}
	END {
		for (i = 1; i <= n; i++) {
			s = ord[i]
			if (!gone[s]) continue
			kind = (gone[s] == total[s]) ? (s == here ? "current" : "dead") : "partial"
			printf "%s\t%s\t%d\t%d\t%s\n", kind, s, gone[s], total[s], ex[s]
		}
	}')

if [ -z "$summary" ]; then
	printf 'Nothing to reap. Every pane is sitting in a directory that exists.\n'
	pause
	exit 0
fi

rows=$(printf '%s\n' "$summary" | awk -F'\t' '
	$1 == "dead" { printf "%s\t%-30s %d/%d panes gone   %s\n", $2, $2, $3, $4, $5 }')

# anything not offered still deserves a mention
note=$(printf '%s\n' "$summary" | awk -F'\t' '
	$1 == "partial" { p++ }
	$1 == "current" { c++ }
	END {
		if (p) printf "%d partially dead session(s) left alone. ", p
		if (c) printf "the session you are in is dead but never offered. "
	}')

if [ -z "$rows" ]; then
	printf 'No fully dead sessions to kill.\n'
	[ -n "$note" ] && printf '%s\n' "$note"
	pause
	exit 0
fi

chosen=$(printf '%s\n' "$rows" | fzf \
	--multi --reverse --no-sort --info=inline \
	--delimiter='\t' --with-nth=2 \
	--prompt='reap > ' \
	--header="tab select   ^A all   enter kill selected   esc cancel
${note:-nothing else is affected}" \
	--bind 'ctrl-a:select-all' \
	--bind 'ctrl-d:deselect-all')
# capture fzf's own status before piping, or $? would come from cut
rc=$?
picked=$(printf '%s' "$chosen" | cut -f1)

if [ $rc -ne 0 ]; then
	printf 'Cancelled. Nothing was killed.\n'
	pause
	exit 0
fi

if [ -n "$picked" ]; then
	printf 'Killing:\n'
	printf '%s\n' "$picked" | while read -r s; do
		[ -z "$s" ] && continue
		if tmux kill-session -t "=$s" 2>/dev/null; then
			printf '  killed %s\n' "$s"
		else
			printf '  failed  %s\n' "$s"
		fi
	done
else
	printf 'Nothing selected.\n'
fi

# prune worktree metadata, but only in repos we can still reach from a live pane
printf '\nPruning worktree metadata:\n'
printf '%s\n' "$scan" | awk -F'\t' '$9 == 1 { print $8 }' | sort -u | while read -r d; do
	git -C "$d" rev-parse --show-toplevel 2>/dev/null || true
done | sort -u | while read -r repo; do
	[ -z "$repo" ] && continue
	out=$(git -C "$repo" worktree prune -v 2>&1)
	printf '  %s: %s\n' "${repo##*/}" "${out:-nothing to prune}"
done

pause
