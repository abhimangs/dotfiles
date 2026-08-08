# menu_temp — throwaway menu gallery

## combo.sh — 6 + 10 + 1 + 2, tabbed

```bash
bash ~/dotfiles/menu_temp/combo.sh      # the tabbed one
bash ~/dotfiles/menu_temp/combo.sh 1    # same look as three separate steps
bash ~/dotfiles/menu_temp/combo.sh 2    # same look as one flat list
```

Three sections — **dotfiles · tools · apps** — drawn as tabs at the top, one on
screen at a time, never all of them. Opens on dotfiles.

| key | |
|---|---|
| `←` `→` | previous / next section (wraps, and `tab` / `shift-tab` do the same) |
| `f1` `f2` `f3` | jump straight to dotfiles / tools / apps |
| `enter` | tick the row |
| `ctrl-a` | tick everything in this section — again to untick |
| `ctrl-j` | confirm |
| `esc` | cancel, selecting nothing |

Selections survive switching sections, and what you have picked is listed by
name — grouped by section — under the details pane, and again after you
confirm.

The look: full screen with every section boxed and the section name on the list
border (6), border labels, footer keys and a live count (1), details for the row
you are on (2), running list of what is selected (10).

Rows are ordered deliberately, not alphabetically — `--no-sort` keeps that order
even while a section filter is active. Group names (shells, terminals, browsers…)
are a left-hand column printed on the first row of each group rather than heading
rows: fzf has no inert rows, so a heading would be selectable and would land
under the cursor.

**Search is scoped.** The box searches the section you are on, nothing else —
typing `notion` in dotfiles finds nothing. Switching sections clears it.

**How it works.** The tab and the ticks are ours, not fzf's: the current section
and the selected keys live in a temp dir, a switch reloads the list from them,
and the `[✔]` in each row is drawn from that file. fzf's own marks cannot
survive a reload, and the other way to filter — putting the section in the query
— is exactly what collided with typing. `esc` still returns nothing: the wrapper
reads fzf's exit code, not the state file.

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
