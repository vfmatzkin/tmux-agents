#!/usr/bin/env bash
# Right-hand status segment: git branch and dirty state for the active pane's
# directory, plus how many agents are waiting on you across the whole server.
# Takes the pane path as $1 so tmux can hand us the active pane's cwd.
set -uo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)

cwd=${1:-}
out=""

if [ -n "$cwd" ] && [ ! -d "$cwd" ]; then
	# the directory was deleted underneath a live pane, usually a removed worktree
	out="#[fg=red]✗ gone#[default]"
elif [ -n "$cwd" ]; then
	branch=$(git -C "$cwd" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null || true)
	if [ -n "$branch" ]; then
		dirty=""
		[ -n "$(git -C "$cwd" --no-optional-locks status --porcelain --untracked-files=no 2>/dev/null | head -1)" ] && dirty="*"
		out="#[fg=cyan]${branch}#[fg=yellow]${dirty}#[default]"
	fi
fi

waiting=$("$DIR/agent-scan.sh" 2>/dev/null | awk -F'\t' '$10 == "idle" { n++ } END { print n + 0 }')
if [ "${waiting:-0}" -gt 0 ]; then
	[ -n "$out" ] && out="$out  "
	out="$out#[fg=yellow]${waiting}✳#[default]"
fi

printf '%s' "$out"
