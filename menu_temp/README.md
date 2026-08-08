# menu_temp — throwaway menu gallery

## combo.sh — 6 + 10 + 1 + 2, arranged three ways

```bash
bash ~/dotfiles/menu_temp/combo.sh      # asks which arrangement
bash ~/dotfiles/menu_temp/combo.sh 1    # one by one  — three full-screen steps
bash ~/dotfiles/menu_temp/combo.sh 2    # one screen  — all three in a single list
bash ~/dotfiles/menu_temp/combo.sh 3    # tabs        — alt-1/2/3 switches section
```

Same look in all three: full screen with every section boxed (6), border labels
and footer keys and a live count (1), details for the row you are on (2), and
everything you have selected so far listed by name underneath (10).

The three sections are **dotfiles**, **tools**, **apps**, in that order, and
inside each one the rows are grouped (shells → terminals → desktop → tools;
files → navigation → git → system; browsers → editors → CLIs → desktop →
system) with the likeliest pick first. Group headings are rows with no key, so
selecting one — or hitting `ctrl-a` — never puts a heading in your cart.

In arrangement 3 the tabs are fzf's own filter driven by a hidden field, so
switching sections never reloads the list and never drops a mark.

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
