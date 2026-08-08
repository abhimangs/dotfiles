# menu_temp — throwaway menu gallery

## fast.sh — the one to look at

```bash
bash ~/dotfiles/menu_temp/fast.sh
```

No fzf. fzf was never the slow part — the wiring around it was: every tick
forked a callback that re-read the item table with `cut` (seven subshells a
row), re-rendered the list twice and re-ran the preview. Hundreds of processes
per keystroke.

Here **nothing forks after startup**. The table is parsed once into arrays, the
padded name and state cells are built once per state change, and a frame is a
string assembled in bash and written with one `printf` — **~3 ms a redraw**.
First frame is up in ~60 ms: "what is installed" is a 20 ms local query, and the
slower "what has an update" runs in the background and fills the rows in when it
lands, which matters most on Debian where `apt list --upgradable` takes seconds.

| key | |
|---|---|
| `←` `→` | previous / next menu (wraps; `tab` too) |
| `↑` `↓` `PgUp` `PgDn` | move |
| `f1`–`f4` | jump to dotfiles / tools / apps / selected (`ctrl-s` also) |
| `space` or `enter` | tick the row, and move to the next |
| `ctrl-a` | tick everything in this menu — again to untick |
| type | search this menu only; `esc` clears it |
| `ctrl-d` | confirm |
| `esc` | cancel |

Confirm is `ctrl-d` rather than Enter because Enter arrives as `\r` or as `\n`
depending on the terminal's `icrnl`, and ctrl-j is `\n` either way — so no other
key can safely own either byte, and both of them tick.

Three menus — **dotfiles · tools · apps** — plus **selected**, which lists what
is ticked across all three and unticks from there. No sub-groups and no icons:
plain names. A ticked row goes green end to end, and every row says what it will
do — `new`, `installed`, or `update`.

### Why it looks right at any size

- **Size comes from `stty size`, not `tput`.** tput needs a terminfo entry for
  `$TERM` and simply fails on a terminal it has not heard of; a frame drawn to
  the wrong size wraps every line and scrolls the screen to pieces.
- **Every padded cell is ASCII.** `printf` pads `%s` by bytes, so `● installed`
  (13 bytes, 11 columns) and `○ new` (7 bytes, 5) came out different widths — and
  a Nerd Font glyph is two columns wide while `printf` counts it as one, which is
  what made the name column ragged. Colour carries what the symbols did.
- **Colour is wrapped around already-padded plain text**, never inside it, and
  the boxes are drawn from known plain lengths — so a coloured row cannot shove a
  border sideways.
- **The tab bar sizes its own separators** to the box, so it can never overflow.
- Pane lines are stored as plain text plus a colour and truncated before the
  colour is applied, so a narrow terminal cannot cut an escape sequence in half.

---

## combo.sh — the fzf version, kept for comparison

```bash
bash ~/dotfiles/menu_temp/combo.sh    # tabs, via fzf
bash ~/dotfiles/menu_temp/combo.sh 1  # three separate steps
bash ~/dotfiles/menu_temp/combo.sh 2  # one flat list
```

Same four tabs and the same information, built on fzf. It is the slow one, and
it is here only to compare the look against `fast.sh`.

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
