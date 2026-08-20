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
	# $1 = origin target, $2 = file listing expanded "session:window" keys,
	# $3 = file to write the elided common path prefix into
	local expanded=""
	[ -n "${2:-}" ] && [ -f "$2" ] && expanded=$(tr '\n' ' ' <"$2")

	"$DIR/agent-scan.sh" \
		| awk -F'\t' -v orig="$1" -v origwin="${1%.*}" -v home="$HOME" \
			-v ignore=" $(opt @agents-ignore-sessions '') " \
			-v expanded=" $expanded " -v pfile="${3:-/dev/null}" '
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
		# What is worth showing of a path. A directory named after its own
		# session says nothing the header did not already say, and the prefix
		# every row shares is printed once in the prompt instead.
		function relp(p, s, keep,   b) {
			b = base(p)
			# a missing directory always stays on screen, in red: that is the
			# whole tell for a session whose worktree was deleted
			if (b == s && !keep) return ""
			if (usepfx) {
				if (p == prefix) return keep ? p : ""
				if (index(p, prefix "/") == 1) return substr(p, length(prefix) + 2)
			}
			return p
		}
		# a window auto-renamed from an agent binary is named after a bare
		# version, which tells you nothing. Fall back to the directory.
		function junk(s) { return s ~ /^[0-9]+(\.[0-9]+)+$/ }

		index(ignore, " " $2 " ") { next }
		{
			n++
			S[n]=$2; WI[n]=$3; WN[n]=$4; PI[n]=$5; NP[n]=$6; P[n]=tilde($8); OK[n]=$9; ST[n]=$10
			k = $2 SUBSEP $3
			if (!(k in SEENW)) { SEENW[k] = 1; WCOUNT[$2]++ }
			if ($10 == "idle") { WAIT[$2]++; WIDLE[k]++ }
			if ($10 == "busy") WBUSY[k]++
			if ($7 == 1) { APATH[k] = tilde($8); AOK[k] = $9 }
		}
		END {
			D="\033[2m"; R="\033[0m"; Y="\033[33m"; RD="\033[31m"; C="\033[36m"
			MARK = sprintf("%s●%s ", "\033[1;33m", R)
			GAP = "  "

			# the longest directory prefix every path shares, printed once
			cpn = split(P[1], cp, "/")
			for (i = 2; i <= n; i++) {
				m = split(P[i], q, "/"); k = 0
				while (k < cpn && k < m && cp[k + 1] == q[k + 1]) k++
				cpn = k
			}
			prefix = ""
			for (j = 1; j <= cpn; j++) prefix = (j == 1 ? cp[j] : prefix "/" cp[j])
			usepfx = (cpn >= 2 && length(prefix) >= 6)
			printf("%s", usepfx ? prefix : "") > pfile

			sidx = -1; cs = ""; cw = ""
			for (i = 1; i <= n; i++) {
				if (S[i] != cs) {
					cs = S[i]; cw = ""; sidx++
					tag = WAIT[S[i]] ? sprintf("  %s%d✳%s", Y, WAIT[S[i]], R) : ""
					wtag = WAIT[S[i]] ? sprintf("  %d waiting", WAIT[S[i]]) : ""
					# one window means the header would only repeat what the row
					# below it says, so the two are printed as a single line
					if (WCOUNT[S[i]] == 1) tag = ""
					# a session is a header, not a target: up/down skip it, so it
					# is coloured to recede rather than compete with its windows
					if (WCOUNT[S[i]] > 1)
						printf "%s\t%s  %s%-2d%s %s%s%s%s\t%s%s%s\n", \
							S[i], GAP, D, sidx, R, C, S[i], R, tag, GAP, S[i], wtag
				}
				if (WI[i] != cw) {
					cw = WI[i]
					k = S[i] SUBSEP WI[i]
					multi = (NP[i] > 1)
					open = (multi && index(expanded, " " S[i] ":" WI[i] " ") > 0)
					# ▸ says right will drill in, ▾ says left will fold it back up
					ind = !multi ? "  " : (open ? D "▾ " R : D "▸ " R)
					# a folded window is the leaf, so it wears the state of whatever
					# is inside it and the origin mark for any of its panes
					leaf = !open
					agg = WIDLE[k] ? "idle" : (WBUSY[k] ? "busy" : "none")
					g = (!leaf) ? "  " : (agg == "idle") ? Y "✳ " R : (agg == "busy") ? D "◐ " R : "  "
					sw = (!leaf) ? "" : (agg == "idle") ? "waiting" : (agg == "busy") ? "working" : ""
					wp = shortp(relp(APATH[k], S[i], !AOK[k]), 46)
					pc = AOK[k] ? D : RD
					wl = junk(WN[i]) ? base(APATH[k]) : WN[i]
					m = (leaf && S[i] ":" WI[i] == origwin) ? MARK : GAP
					if (WCOUNT[S[i]] == 1) {
						# This row stands in for its whole session, so it sits at the
						# session indent. The fold marker moves to the end of the
						# label rather than taking the column that indent needs.
						lbl = sprintf("%s%s%s  %s%s%s", C, S[i], R, D, wl, R)
						if (multi) lbl = lbl sprintf(" %s%s%s", D, (open ? "▾" : "▸"), R)
						if (wp != "") {
							pad = 20 - length(S[i]) - length(wl)
							if (pad < 1) pad = 1
							lbl = lbl sprintf("%*s%s%s%s", pad, "", pc, wp, R)
						}
						printf "%s:%s\t%s%s%s%-2d%s %s\t%s%s  %s%s%s  %s  %s  %s %s\n", \
							S[i], WI[i], m, g, D, sidx, R, lbl, \
							m, S[i], D, WI[i], R, wl, APATH[k], sw, (AOK[k] ? "" : "gone")
					} else
						printf "%s:%s\t%s%s%s%s%-2s%s %-18s %s%s%s\t%s%s  %s%s%s  %s  %s  %s %s\n", \
							S[i], WI[i], m, g, ind, D, WI[i], R, wl, pc, wp, R, \
							m, S[i], D, WI[i], R, wl, APATH[k], sw, (AOK[k] ? "" : "gone")
				}
				if (NP[i] > 1 && index(expanded, " " S[i] ":" WI[i] " ") > 0) {
					g = (ST[i] == "idle") ? Y "✳ " R : (ST[i] == "busy") ? D "◐ " R : "  "
					sw = (ST[i] == "idle") ? "waiting" : (ST[i] == "busy") ? "working" : ""
					pp = shortp(relp(P[i], S[i], !OK[i]), 46)
					pc = OK[i] ? D : RD
					m = (S[i] ":" WI[i] "." PI[i] == orig) ? MARK : GAP
					printf "%s:%s.%s\t%s%s    %s%-2s%s %-17s%s%s%s\t%s%s  %s%s.%s%s  %s  %s  %s %s\n", \
						S[i], WI[i], PI[i], m, g, D, PI[i], R, "", pc, pp, R, \
						m, S[i], D, WI[i], PI[i], R, wl, P[i], sw, (OK[i] ? "" : "gone")
				}
			}
		}'
}

# --------------------------------------------------------------- toggle mode
# Called from the right/left bindings inside fzf. Folds or unfolds the window
# under the cursor, rewrites the rows file, and prints the fzf actions that
# swap the list in and put the cursor back where it was. Everything it needs
# beyond the target comes from the environment fzf inherited.
if [ "${1:-}" = "--toggle" ]; then
	target=${2:-} dir=${3:-expand}
	expandfile=$PICKER_EXPAND rowsfile=$PICKER_ROWS orig=$PICKER_ORIG

	case $target in
		*.*) key=${target%.*} ;;   # a pane row folds its parent window
		*:*) key=$target ;;        # a window row
		*)   key="" ;;             # a session row has nothing to fold
	esac

	if [ -n "$key" ]; then
		current=$(grep -vxF -- "$key" "$expandfile" 2>/dev/null || true)
		if [ "$dir" = expand ]; then
			printf '%s\n' "$current" | grep -v '^$' >"$expandfile.tmp" 2>/dev/null || true
			printf '%s\n' "$key" >>"$expandfile.tmp"
			anchor=$target
		else
			printf '%s\n' "$current" | grep -v '^$' >"$expandfile.tmp" 2>/dev/null || true
			anchor=$key
		fi
		mv "$expandfile.tmp" "$expandfile"
	else
		anchor=$target
	fi

	build_rows "$orig" "$expandfile" "$PICKER_PFX" >"$rowsfile"

	pos=$(cut -f1 "$rowsfile" | grep -nxF -- "$anchor" | head -1 | cut -d: -f1)
	[ -z "$pos" ] && pos=$(cut -f1 "$rowsfile" | grep -nxF -- "${anchor%.*}" | head -1 | cut -d: -f1)
	: "${pos:=1}"

	prefix=$(cat "$PICKER_PFX" 2>/dev/null || true)
	prompt=${prefix:+$prefix }
	prompt="${prompt:-jump }> "

	# reload-sync, so pos lands after the new list is in place rather than racing it
	printf 'reload-sync(cat %s)+pos(%s)+change-prompt(%s)' "$rowsfile" "$pos" "$prompt"
	exit 0
fi

# ---------------------------------------------------------------- picker mode
# Runs inside the popup. Reports back what the user did so the driver can
# either finish, restore, or reopen the popup somewhere else.
if [ "${1:-}" = "--pick" ]; then
	rowsfile=$2 resultfile=$3 anchor=$4 query=$5 expandfile=$6 origin=$7 pfxfile=$8

	# the toggle mode reruns from inside fzf and needs all of this
	export PICKER_SELF=$SELF PICKER_EXPAND=$expandfile PICKER_ROWS=$rowsfile PICKER_ORIG=$origin PICKER_PFX=$pfxfile

	# the prefix every path shares is said once here instead of on every row
	prefix=$(cat "$pfxfile" 2>/dev/null || true)
	prompt=${prefix:+$prefix }
	prompt="${prompt:-jump }> "

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
		--prompt="$prompt" \
		--header='● you are here   ✳ waiting   ▸ has panes
→← unfold  ^T waiting  ⇧arrows move  ⏎ stay  esc back' \
		--query="$query" --print-query \
		--expect=shift-up,shift-down,shift-left,shift-right,alt-up,alt-down,alt-left,alt-right \
		--bind "start:pos($pos)" \
		--bind 'focus:execute-silent(case {1} in *:*) tmux switch-client -t {1} ;; esac)' \
		--bind 'down:down+transform:case {1} in *:*) ;; *) echo down ;; esac' \
		--bind 'up:up+transform:case {1} in *:*) ;; *) echo up ;; esac' \
		--bind 'ctrl-t:transform:[ "$FZF_QUERY" = waiting ] && echo clear-query || echo "change-query(waiting)"' \
		--bind 'right:transform:[ -n "$FZF_QUERY" ] && echo forward-char || "$PICKER_SELF" --toggle {1} expand' \
		--bind 'left:transform:[ -n "$FZF_QUERY" ] && echo backward-char || "$PICKER_SELF" --toggle {1} collapse' \
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
rowsfile=$tmp/rows resultfile=$tmp/result expandfile=$tmp/expanded pfxfile=$tmp/prefix
: >"$expandfile"   # every window starts folded

# Popup position in terminal cells rather than snapped to a grid, so a press
# nudges it instead of throwing it across the screen. -1 means "not placed
# yet", which centres it on the first open. Cells are about twice as tall as
# they are wide, so a half step vertically covers the same visual distance.
hstep=$(opt @agents-move-step 4)
vstep=$((hstep / 2))
[ "$vstep" -lt 1 ] && vstep=1
px=-1 py=-1
anchor=$orig
query=""
reuse=0

while true; do
	# A move reopens the popup, and rescanning every pane in that gap is what
	# you would feel as lag while nudging it around. The rows cannot have
	# changed from moving, so reuse them.
	[ "$reuse" = 1 ] || build_rows "$orig" "$expandfile" "$pfxfile" >"$rowsfile"
	reuse=0

	read -r cw ch < <(tmux display-message -p -t "$client" '#{client_width} #{client_height}')
	# size on the tree column only; the flat column shown while typing is wider,
	# and fzf scrolls it horizontally to keep the match in view
	read -r rows width < <(awk -F'\t' '
		{ n++; s = $2; gsub(/\033\[[0-9;]*m/, "", s); sub(/[[:space:]]+$/, "", s)
		  if (length(s) > w) w = length(s) }
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
	[ "$w" -lt 58 ] && w=58 # else the header ellipsises on a short list
	[ "$w" -gt $((cw - 4)) ] && w=$((cw - 4))
	[ "$w" -lt 10 ] && w=10
	[ "$w" -gt "$cw" ] && w=$cw

	# -x is the left column, -y the BOTTOM row, both zero based against the
	# client. Keep the bottom clear of the status line.
	maxx=$((cw - w)); [ "$maxx" -lt 0 ] && maxx=0
	miny=$h; maxy=$((ch - 1)); [ "$maxy" -lt "$miny" ] && maxy=$miny

	[ "$px" -lt 0 ] && px=$(((cw - w) / 2))
	[ "$py" -lt 0 ] && py=$(((ch - h) / 2 + h - 1))

	[ "$px" -gt "$maxx" ] && px=$maxx
	[ "$px" -lt 0 ] && px=0
	[ "$py" -gt "$maxy" ] && py=$maxy
	[ "$py" -lt "$miny" ] && py=$miny
	x=$px y=$py

	# stale result + a popup that refuses to open would loop forever
	: >"$resultfile"
	tmux display-popup -E -c "$client" -w "$w" -h "$h" -x "$x" -y "$y" -T " jump " \
		"$SELF --pick $rowsfile $resultfile $(printf '%q' "$anchor") $(printf '%q' "$query") $expandfile $(printf '%q' "$orig") $pfxfile" || break

	action=$(cut -f1 "$resultfile" 2>/dev/null)
	case "$action" in
		move)
			anchor=$(cut -f2 "$resultfile")
			query=$(cut -f3 "$resultfile")
			reuse=1
			# clamped on the next pass, once the new size is known
			case $(cut -f4 "$resultfile") in
				*-up)    py=$((py - vstep)) ;;
				*-down)  py=$((py + vstep)) ;;
				*-left)  px=$((px - hstep)) ;;
				*-right) px=$((px + hstep)) ;;
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
