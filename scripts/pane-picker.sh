#!/usr/bin/env bash
# Tree picker for tmux, in the shape of choose-tree: sessions, then windows,
# then panes. The real window switches underneath the popup as the selection
# moves. Enter keeps it, Esc goes back to where you started, and a ● marks that
# starting row so it stays findable while you browse.
#
# Agent state comes from agent-scan.sh: ✳ waits on you, ◐ is working, shown on
# the leaf row only. ^T filters to just the ones waiting. A cwd that no longer
# exists is shown in red, which is how dead worktree sessions announce
# themselves.
#
# shift-arrows (or alt-arrows) walk the popup around a 3x3 grid, so it can be
# pushed off whatever you are trying to look at. It cannot be the tmux prefix:
# tmux hands a popup every key it receives, prefix included, so the binding has
# to be one fzf itself sees. tmux also cannot move a popup that is already open
# (-x/-y/-w/-h are ignored on one), so this runs as a driver loop: fzf exits,
# the driver reopens it one step over with the query and selection carried over.
#
# Each row carries three tab-separated fields:
#   1 switch-client target   2 tree label (shown)   3 flat label (shown while typing)
set -uo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
SELF=$DIR/$(basename "$0")
. "$DIR/helpers.sh"

build_rows() {
	"$DIR/agent-scan.sh" \
		| awk -F'\t' -v orig="$1" -v origwin="${1%.*}" -v home="$HOME" \
			-v ignore=" $(opt @agents-ignore-sessions '') " '
		function base(p,   a, k) { k = split(p, a, "/"); return a[k] == "" ? "/" : a[k] }
		function tilde(p) {
			if (p == home) return "~"
			if (index(p, home "/") == 1) return "~" substr(p, length(home) + 1)
			return p
		}
		# a path is informative at the tail, so drop the middle rather than the end
		function shortp(p, n,   b) {
			if (length(p) <= n) return p
			b = "…/" base(p)
			return length(b) <= n ? b : "…" substr(b, length(b) - n + 2)
		}
		# a window auto-renamed from an agent binary is named after a bare
		# version, which tells you nothing. Fall back to the directory.
		function junk(s) { return s ~ /^[0-9]+(\.[0-9]+)+$/ }

		index(ignore, " " $2 " ") { next }
		{
			n++
			S[n]=$2; WI[n]=$3; WN[n]=$4; PI[n]=$5; NP[n]=$6; P[n]=$8; OK[n]=$9; ST[n]=$10
			if (ST[n] == "idle") WAIT[$2]++
			if ($7 == 1) { APATH[$2 SUBSEP $3] = $8; AST[$2 SUBSEP $3] = $10; AOK[$2 SUBSEP $3] = $9 }
		}
		END {
			B="\033[1m"; D="\033[2m"; R="\033[0m"; Y="\033[33m"; RD="\033[31m"
			MARK = sprintf("%s●%s ", "\033[1;33m", R)
			GAP = "  "
			sidx = -1; cs = ""; cw = ""
			for (i = 1; i <= n; i++) {
				if (S[i] != cs) {
					cs = S[i]; cw = ""; sidx++
					tag = WAIT[S[i]] ? sprintf("  %s%d✳%s", Y, WAIT[S[i]], R) : ""
					wtag = WAIT[S[i]] ? sprintf("  %d waiting", WAIT[S[i]]) : ""
					printf "%s\t%s  %s%d%s  %s%s%s%s\t%s%s%s\n", \
						S[i], GAP, D, sidx, R, B, S[i], R, tag, GAP, S[i], wtag
				}
				if (WI[i] != cw) {
					cw = WI[i]
					k = S[i] SUBSEP WI[i]
					# the state belongs on the leaf row: a split window wears it on
					# its panes instead, so it is not shown twice
					leaf = (NP[i] == 1)
					g = (!leaf) ? "  " : (AST[k] == "idle") ? Y "✳ " R : (AST[k] == "busy") ? D "◐ " R : "  "
					sw = (!leaf) ? "" : (AST[k] == "idle") ? "waiting" : (AST[k] == "busy") ? "working" : ""
					wp = shortp(tilde(APATH[k]), 44)
					pc = AOK[k] ? D : RD
					wl = junk(WN[i]) ? base(APATH[k]) : WN[i]
					# only the leaf row for the origin gets the mark, so a single-pane
					# window wears it here and a split one wears it on the pane row
					m = (leaf && S[i] ":" WI[i] == origwin) ? MARK : GAP
					printf "%s:%s\t%s%s  %s%-2s%s %-18s %s%s%s\t%s%s  %s%s%s  %s  %s  %s %s\n", \
						S[i], WI[i], m, g, D, WI[i], R, wl, pc, wp, R, \
						m, S[i], D, WI[i], R, wl, wp, sw, (AOK[k] ? "" : "gone")
				}
				if (NP[i] > 1) {
					g = (ST[i] == "idle") ? Y "✳ " R : (ST[i] == "busy") ? D "◐ " R : "  "
					sw = (ST[i] == "idle") ? "waiting" : (ST[i] == "busy") ? "working" : ""
					pp = shortp(tilde(P[i]), 44)
					pc = OK[i] ? D : RD
					m = (S[i] ":" WI[i] "." PI[i] == orig) ? MARK : GAP
					printf "%s:%s.%s\t%s%s    %s%-2s%s %-17s%s%s%s\t%s%s  %s%s.%s%s  %s  %s  %s %s\n", \
						S[i], WI[i], PI[i], m, g, D, PI[i], R, "", pc, pp, R, \
						m, S[i], D, WI[i], PI[i], R, wl, pp, sw, (OK[i] ? "" : "gone")
				}
			}
		}'
}

# ---------------------------------------------------------------- picker mode
# Runs inside the popup. Reports back what the user did so the driver can
# either finish, restore, or reopen the popup somewhere else.
if [ "${1:-}" = "--pick" ]; then
	rowsfile=$2 resultfile=$3 anchor=$4 query=$5

	pos=$(cut -f1 "$rowsfile" | grep -nxF -- "$anchor" | head -1 | cut -d: -f1)
	[ -z "$pos" ] && pos=$(cut -f1 "$rowsfile" | grep -nxF -- "${anchor%.*}" | head -1 | cut -d: -f1)
	: "${pos:=1}"

	# Swapping the tree for flat searchable rows while you type needs
	# change-with-nth, which landed in fzf 0.70. On anything older, keep the
	# tree and let the query match the tree text only.
	flip=$(fzf --version | awk '{ split($1, v, "."); print (v[1] > 0 || v[2] >= 70) ? "yes" : "no" }')

	# a restored query means the flat view is already the right one to open with
	withnth=2
	[ "$flip" = yes ] && [ -n "$query" ] && withnth=3

	if [ "$flip" = yes ]; then
		set -- --bind 'change:transform:[ -n "$FZF_QUERY" ] && echo "change-with-nth(3)" || echo "change-with-nth(2)"'
	else
		set --
	fi

	out=$(fzf \
		--ansi --reverse --sync --cycle --no-multi --info=inline \
		--delimiter='\t' --with-nth=$withnth \
		--prompt='jump > ' \
		--header='● where you were    ✳ waiting on you
^T only waiting   ⇧arrows move   ⏎ stay   esc back' \
		--query="$query" --print-query \
		--expect=shift-up,shift-down,shift-left,shift-right,alt-up,alt-down,alt-left,alt-right \
		--bind "start:pos($pos)" \
		--bind 'focus:execute-silent(tmux switch-client -t {1})' \
		--bind 'ctrl-t:transform:[ "$FZF_QUERY" = waiting ] && echo clear-query || echo "change-query(waiting)"' \
		"$@" \
		< "$rowsfile")
	rc=$?

	q=$(printf '%s' "$out" | sed -n 1p)
	key=$(printf '%s' "$out" | sed -n 2p)
	sel=$(printf '%s' "$out" | sed -n 3p | cut -f1)

	if [ $rc -ne 0 ]; then
		printf 'cancel\n' >"$resultfile"
	elif [ -n "$key" ]; then
		printf 'move\t%s\t%s\t%s\n' "$sel" "$q" "$key" >"$resultfile"
	else
		printf 'stay\n' >"$resultfile"
	fi
	exit 0
fi

# --------------------------------------------------------------- driver mode
# Runs outside the popup, because -x/-y/-w/-h are ignored on a popup that is
# already open.
orig=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}')
client=$(tmux display-message -p '#{client_tty}')

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rowsfile=$tmp/rows resultfile=$tmp/result

# popup position on a 3x3 grid: 0 1 2 = left centre right / top middle bottom
gx=1 gy=1
anchor=$orig
query=""

while true; do
	build_rows "$orig" >"$rowsfile"

	read -r cw ch < <(tmux display-message -p -t "$client" '#{client_width} #{client_height}')
	# size on the tree column only; the flat column shown while typing is wider,
	# and fzf scrolls it horizontally to keep the match in view
	read -r rows width < <(awk -F'\t' '
		{ n++; s = $2; gsub(/\033\[[0-9;]*m/, "", s); if (length(s) > w) w = length(s) }
		END { print n, w }' "$rowsfile")

	# fzf chrome with --info=inline: prompt line + two header lines, plus two
	# borders. A longer list than this just scrolls inside fzf. tmux refuses to
	# draw a popup larger than the client or smaller than its borders, so clamp
	# both ends: the floors keep it legible, the client caps keep it drawable.
	h=$((rows + 5))
	[ "$h" -gt $((ch - 4)) ] && h=$((ch - 4))
	[ "$h" -lt 6 ] && h=6
	[ "$h" -gt "$ch" ] && h=$ch

	w=$((width + 6))
	[ "$w" -lt 56 ] && w=56 # else the header ellipsises on a short list
	[ "$w" -gt $((cw - 4)) ] && w=$((cw - 4))
	[ "$w" -lt 10 ] && w=10
	[ "$w" -gt "$cw" ] && w=$cw

	case $gx in 0) x=0 ;; 2) x=R ;; *) x=C ;; esac
	# -y anchors the bottom row of the popup; keep the bottom row clear of the
	# status line, and 0 pins it to the top
	case $gy in 0) y=0 ;; 2) y=$((ch - 1)) ;; *) y=C ;; esac

	# stale result + a popup that refuses to open would loop forever
	: >"$resultfile"
	tmux display-popup -E -c "$client" -w "$w" -h "$h" -x "$x" -y "$y" -T " jump " \
		"$SELF --pick $rowsfile $resultfile $(printf '%q' "$anchor") $(printf '%q' "$query")" || break

	action=$(cut -f1 "$resultfile" 2>/dev/null)
	case "$action" in
		move)
			anchor=$(cut -f2 "$resultfile")
			query=$(cut -f3 "$resultfile")
			case $(cut -f4 "$resultfile") in
				*-up)    [ $gy -gt 0 ] && gy=$((gy - 1)) ;;
				*-down)  [ $gy -lt 2 ] && gy=$((gy + 1)) ;;
				*-left)  [ $gx -gt 0 ] && gx=$((gx - 1)) ;;
				*-right) [ $gx -lt 2 ] && gx=$((gx + 1)) ;;
			esac
			;;
		cancel)
			tmux switch-client -t "$orig"
			break
			;;
		*)
			break
			;;
	esac
done
