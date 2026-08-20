# tmux-agents

A tmux plugin for people running several coding agents at once.

I kept losing track of which pane was working and which one had finished and
was waiting for me. `choose-tree` shows you a list, but it cannot preview, and
it knows nothing about what is running inside a pane. This adds a jump picker
that switches the real window live as you move, reads each agent's state from
its terminal title, tells you when one goes idle, and cleans up the sessions
left behind when a worktree gets deleted.

It opens folded to the window level, because panes are usually too granular to
navigate by. Sessions are headers: they stay visible for grouping, but up and
down step straight over them so you move window to window.

```
~/code >
  0  api                2✳
  ✳   0  server
  ✳   1  migrations
  1  web                1✳
  ◐ ▸ 0  dev
● ✳   1  storybook          web/packages/ui
  2  notes
      0  archive            notes-old
```

A session with a single window is printed as one line rather than a header and
a lone child, since the header would only repeat the row under it.

Paths earn their place or they are not shown. The prefix every row shares moves
into the prompt, and a directory named after its own session is left blank,
because the header above it already said that. What is left is the part that
actually differs.

`→` unfolds a window into its panes, `←` folds it back:

```
  1  web                1✳
    ▾ 0  dev
  ◐     0
  ✳     1                    web/packages/ui
```

`✳` waits on you, `◐` is working, `▸` means the window has panes to unfold,
`●` is where you were when you opened the picker, and a red path means the
directory no longer exists. A missing directory is always shown, even when it
would otherwise be blanked as redundant, since that is the whole tell for a
session whose worktree was deleted. A folded window shows the state of whatever is
inside it, so nothing waiting is ever hidden behind a fold.

## Keys

| Key | What it does |
| --- | --- |
| `prefix + w` | Jump picker. Arrows preview live, `enter` stays, `esc` returns you. |
| `prefix + k` | Reap sessions whose directory was deleted. |
| `prefix + g` | Copy the pane's path, branch, address or title. |

Inside the picker:

| Key | What it does |
| --- | --- |
| up / down | Move window to window, stepping over the session headers |
| right / left | Unfold a window into its panes, or fold it back. With a query typed they move the text cursor instead. |
| type | Filter. Rows flatten so a window still matches its session name. |
| `^T` | Show only agents waiting on you |
| shift-arrows | Nudge the popup out of the way, to uncover what is behind it |
| `enter` | Keep where you landed |
| `esc` | Go back to the pane you started from |

## Install

With [TPM](https://github.com/tmux-plugins/tpm), add to `~/.tmux.conf`:

```tmux
set -g @plugin 'vfmatzkin/tmux-agents'
```

Then `prefix + I`. Without TPM, clone it and add:

```tmux
run-shell ~/path/to/tmux-agents/agents.tmux
```

## Options

Set these before the plugin line.

| Option | Default | Meaning |
| --- | --- | --- |
| `@agents-jump-key` | `w` | Picker key. `off` to skip the binding. |
| `@agents-reap-key` | `k` | Reaper key. `off` to skip. |
| `@agents-yank-key` | `g` | Copy menu key. `off` to skip. |
| `@agents-ignore-sessions` | empty | Space separated session names to hide from the picker and the watcher. |
| `@agents-notify` | `on` | Run the watcher that tells you when an agent goes idle. |
| `@agents-notify-command` | empty | Shell command that receives the message on stdin. Use it to reach your phone. |
| `@agents-notify-desktop` | `on` | Desktop notification through `osascript` on macOS. |
| `@agents-watch-interval` | `3` | Seconds between scans. |
| `@agents-watch-settle` | `3` | Scans a pane must stay idle before it counts. |
| `@agents-move-step` | `4` | Columns the popup moves per shift-arrow. Vertical steps are half this, since cells are about twice as tall as wide. |
| `@agents-status` | `off` | Prepend a git and agent-count segment to `status-right`. |
| `@agents-command-pattern` | `^[0-9]+(\.[0-9]+)+$` | Which panes count as agents, matched against `pane_current_command`. |
| `@agents-idle-glyph` | `✳` | Title prefix meaning "waiting on you". |
| `@agents-copy-command` | auto | Clipboard command. Falls back to `pbcopy`, `wl-copy` or `xclip`. |

Example:

```tmux
set -g @agents-ignore-sessions 'scratch background'
set -g @agents-notify-command 'ntfy publish mytopic'
set -g @agents-status on
set -g @plugin 'vfmatzkin/tmux-agents'
```

## How it decides a pane is an agent

Claude Code execs a version-named binary, so `pane_current_command` on one of
its panes is a bare version like `2.1.233`. That is the default detection rule,
and it is more reliable than matching on a process name. State then comes from
the terminal title, which starts with `✳` while the agent waits on you and with
an animated glyph while it works.

For a different agent CLI, point `@agents-command-pattern` at whatever its
panes report and set `@agents-idle-glyph` to whatever its title uses. Check
what yours looks like with:

```sh
tmux list-panes -a -F '#{pane_current_command}  #{pane_title}'
```

All of this lives in `scripts/agent-scan.sh`, which is the only file that
classifies panes. Everything else reads its output.

## The reaper

Deleting a git worktree does not delete the tmux session that lived in it, and
a session restorer like tmux-resurrect will faithfully bring the corpse back on
every restart. `prefix + k` lists sessions where every pane's directory is
missing, lets you pick with `tab`, and kills only what you selected. Sessions
with any surviving pane are reported but never offered, and neither is the
session you are attached to. It then runs `git worktree prune` in repos it can
still reach from a live pane.

## Requirements

- tmux with `display-popup`. Developed and tested on 3.6a.
- fzf. Tested on 0.71. On fzf older than 0.70 the picker still works, but the
  rows do not flatten while you type, because that needs `change-with-nth`.
- git, for the branch and worktree parts.

## Notes

- The picker reopens itself to move, because tmux ignores `-x`, `-y`, `-w` and
  `-h` on a popup that is already open. Your query and selection carry over.
- The move key cannot be the tmux prefix. tmux hands a popup every key it
  receives, prefix included, so it has to be a key fzf itself sees.
- Clearing a query keeps the cursor's row position rather than the row it was
  on. That is how fzf behaves, and the `●` marker is the reliable way back.
- Moving the popup reopens it, so it does not rescan panes on a move. Pressing
  shift-arrow repeatedly is safe: keys arriving during the reopen are not lost.
- Folds reset every time you open the picker, and survive moving the popup.
  Unfolding a window can push the list past the popup height, which scrolls,
  because tmux cannot resize a popup that is already open.
- The watcher skips the pane you are currently looking at, and seeds panes that
  are already idle at startup, so launching it does not announce everything at
  once.

## License

MIT
