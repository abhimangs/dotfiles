# menu_temp — throwaway menu gallery

## combo.sh — 6 + 10 + 1 + 2, tabbed

```bash
bash ~/dotfiles/menu_temp/combo.sh      # the tabbed one
bash ~/dotfiles/menu_temp/combo.sh 1    # same look as three separate steps
bash ~/dotfiles/menu_temp/combo.sh 2    # same look as one flat list
```

Four tabs — **dotfiles · tools · apps · selected** — one on screen at a time,
never all of them. Opens on dotfiles. Each tab carries its own count, so a
section you are not looking at can still tell you it has something in it.

| key | |
|---|---|
| `←` `→` | previous / next tab (wraps; `tab` / `shift-tab` do the same) |
| `f1` `f2` `f3` `f4` | jump to dotfiles / tools / apps / selected (`ctrl-s` also opens selected) |
| `enter` | tick the row, and move to the next one |
| `ctrl-a` | tick everything in this section — again to untick |
| `ctrl-j` | confirm |
| `esc` | cancel, selecting nothing |

`ctrl-1`…`ctrl-4` are not bindable — terminals cannot send them distinctly — so
the number keys are F-keys.

**The tick is loud.** A ticked row turns green end to end — box, name and
description — not just a small mark. The **selected** tab lists everything
ticked across all three sections, grouped, and unticking works there too.

**Every row says what it will do**: `○ new`, `● installed`, or `↑ update` when
the package is installed but the local package db has a newer version. Two
dumps at startup (`pacman -Q` / `-Qu`, or dpkg/apt) rather than a query per row
— 35 rows would otherwise be 70 forks before the menu can draw. No sync, no
network: it is exactly as fresh as your last `-Sy`.

**Search is scoped.** The box searches the section you are on, nothing else —
typing `notion` in dotfiles finds nothing. Switching tabs clears it.

**How it works.** The tab and the ticks are ours, not fzf's: the current section
and the ticked keys live in a temp dir, a switch reloads the list from them, and
the `[✔]` in each row is drawn from that file. fzf's own marks cannot survive a
reload, and the other way to filter — putting the section in the query — is
exactly what collided with typing. `esc` still returns nothing: the wrapper
reads fzf's exit code, not the state file.

Two things that had to be right for ticking to feel normal: `reload-sync`, not
`reload` — the async one let `pos()` run against the old list, which is why the
cursor snapped back to row 1 — and clamping that position to the list about to
be loaded, or ticking the last row left fzf with no current item at all and
confirmed nothing.

Set `COMBO_STATE=/some/dir` to keep the state dir after the run instead of
having it cleaned up.

---

## The original ten

Ten designs for the installer's config picker. Nothing here is wired into
`install.sh`; delete the folder when you have picked one.

```bash
bash ~/dotfiles/menu_temp/demo.sh        # gallery — pick, try, come back
bash ~/dotfiles/menu_temp/demo.sh 6      # jump straight to one
bash ~/dotfiles/menu_temp/demo.sh all    # all ten in a row
```

Inside a design: `enter` toggles, `ctrl-a` selects all, `ctrl-j` confirms,
`esc` skips. What you picked is printed after it closes.

| # | Design | Idea |
|---|--------|------|
| 1 | classic+ | today's menu tightened — border label, footer keys, inline count |
| 2 | preview | details pane on the right: package, stow target, state, files |
| 3 | grouped | headings — terminals / shells / desktop / tools |
| 4 | cards | two-line entries with a divider between them |
| 5 | state | right-hand column: already installed vs new |
| 6 | wizard | full screen, every section boxed, "step 1 of 3" |
| 7 | minimal | no boxes, one rule, ghost text, air |
| 8 | plan pane | bottom pane showing the steps that config will run |
| 9 | banner | ASCII wordmark inside the frame, above the list |
| 10 | live cart | selections collect in a pane on the right as you toggle |

They combine — 2+3, or 5+6, or 9 on top of anything.

## Before adopting one

`--footer`, `--style`, `--list-label`, `--ghost` and `--gap-line` are fzf 0.6x+.
This machine has 0.74, but Debian 12 ships 0.38 and Ubuntu 22.04 ships 0.29, so
whatever wins needs a version check in `fzf_pick` with the plain flags as the
fallback — the installer already installs fzf, it just cannot guarantee a recent
one from apt.
