#!/usr/bin/env bash
# Designs 6 + 10 + 1 + 2 merged into one look, shown three ways.
#
#   bash combo.sh 1     one by one   — three full-screen steps
#   bash combo.sh 2     one screen   — all three sections in a single list
#   bash combo.sh 3     tabs         — one screen, a key per section
#   bash combo.sh       menu of the three
#
# The look (all three share it):
#   6  full screen, every section boxed, step counter on the list border
#   1  border labels, keys pinned to the footer, live count on the input line
#   2  details for the row you are on, in the right-hand pane
#  10  what you have selected so far, by name, under the details
#
# Throwaway. Delete menu_temp/ once you have picked one.

set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/combo.sh"
export SELF

# ── Catppuccin Mocha ─────────────────────────────────────────────────────────
FZF_CLR="bg+:#313244,bg:-1,fg:#cdd6f4,fg+:#cdd6f4,hl:#f38ba8,hl+:#f38ba8,prompt:#cba6f7,pointer:#f5e0dc,marker:#a6e3a1,border:#585b70,header:#94e2d5,info:#cba6f7,spinner:#f5e0dc,separator:#585b70,gutter:-1,label:#cba6f7,preview-border:#585b70,preview-label:#94e2d5"

R=$'\033[0m';     B=$'\033[1m'
DIM=$'\033[38;2;127;132;156m'   ; MAUVE=$'\033[38;2;203;166;247m'
TEAL=$'\033[38;2;148;226;213m'  ; GREEN=$'\033[38;2;166;227;161m'
YELLOW=$'\033[38;2;249;226;175m'; TEXT=$'\033[38;2;205;214;244m'

# ── data ─────────────────────────────────────────────────────────────────────
# key | icon | display name | description | section | group | package
#
# Order is the order things appear — deliberate, not alphabetical: within a
# section the groups run shells → terminals → desktop → tools, and inside a
# group the one you are most likely to want comes first.
ITEMS=(
# dotfiles
"zsh||zsh|shell + Zinit plugins|dotfiles|shells|zsh"
"bash||bash|plain rc, aliases, no prompt tooling|dotfiles|shells|bash"
"starship|󱐋|starship|cross-shell prompt|dotfiles|shells|starship"
"ghostty||ghostty|GPU-accelerated terminal|dotfiles|terminals|ghostty"
"kitty||kitty|cross-platform terminal|dotfiles|terminals|kitty"
"rofi|󰍉|rofi|keyboard-driven launcher|dotfiles|desktop|rofi"
"ulauncher|󰀻|ulauncher|app launcher|dotfiles|desktop|ulauncher"
"git||git|git config → ~/.gitconfig|dotfiles|utilities|git"
"fastfetch|󰋼|fastfetch|system info display at login|dotfiles|utilities|fastfetch"
"protonvpn|󰖂|protonvpn|ProtonVPN wrapper script|dotfiles|utilities|proton-vpn-cli"
# tools
"bat||bat|cat with syntax highlighting|tools|files|bat"
"eza|󰉋|eza|modern ls → ls ll lt la|tools|files|eza"
"fd|󰈞|fd|fast find → fzf integration|tools|files|fd"
"tree|󰙅|tree|directory tree listing|tools|files|tree"
"zoxide|󱋿|zoxide|smart cd → z|tools|navigation|zoxide"
"thefuck|󰅔|thefuck|corrects the last command → fuck|tools|navigation|thefuck"
"lazygit||lazygit|git TUI → lg|tools|git|lazygit"
"btop|󰍛|btop|resource monitor|tools|system|btop"
# apps
"brave-stable|󰖟|Brave Origin Stable|chromium browser, no telemetry|apps|browsers|brave-browser"
"brave-beta|󰖟|Brave Origin Beta|the beta channel of the same|apps|browsers|brave-browser-beta"
"vscode|󰨞|Visual Studio Code|the editor|apps|editors|code"
"vscode-insiders|󰨞|VS Code Insiders|nightly channel|apps|editors|code-insiders"
"antigravity-ide||Antigravity IDE|agentic IDE|apps|editors|antigravity"
"obsidian|󰎚|Obsidian|markdown knowledge base|apps|editors|obsidian"
"notion||Notion|workspace|apps|editors|notion-app"
"claude-code||Claude Code CLI|agentic coding in the terminal|apps|clis|claude"
"codex-cli||Codex CLI|OpenAI's coding agent|apps|clis|codex"
"antigravity-cli||Antigravity CLI|the CLI half of Antigravity|apps|clis|antigravity"
"opencode||OpenCode|open-source coding agent|apps|clis|opencode"
"kimi-code||Kimi Code CLI|Moonshot's coding agent|apps|clis|kimi"
"muse||Muse|terminal agent|apps|clis|muse"
"vlc|󰕼|VLC|plays anything|apps|desktop|vlc"
"docker||Docker + Compose|containers, compose, buildx|apps|system|docker"
"flatpak||Flatpak|sandboxed app runtime + flathub|apps|system|flatpak"
)

SECTIONS=(dotfiles tools apps)
declare -A SEC_TITLE=( [dotfiles]="dotfiles" [tools]="tools" [apps]="apps" )
declare -A SEC_BLURB=(
    [dotfiles]="shell, terminal and tool configs — these get stowed into your home"
    [tools]="the CLI tools the zsh config's aliases expect"
    [apps]="browsers, editors, agents and desktop apps"
)

fld() { cut -d'|' -f"$2" <<<"$1"; }
installed() { command -v "$1" &>/dev/null; }

# key → any field, for the preview callbacks
lookup() {                      # lookup <key> <field-number>
    local it
    for it in "${ITEMS[@]}"; do
        [ "${it%%|*}" = "$1" ] && { fld "$it" "$2"; return 0; }
    done
    return 1
}

# ── rows ─────────────────────────────────────────────────────────────────────
# Tab-delimited: key <TAB> section <TAB> what is drawn. fzf shows field 3 only,
# so the key never has to be parsed back out of the pretty text — and the icon,
# whose width varies by font, is never inside a padded field.
#
# The group name is a column, printed on the first row of each group, rather
# than a heading row: fzf has no inert rows, so a heading would be selectable,
# would land under the cursor, and would need filtering back out of ctrl-a.
#
# The tick is ours, not fzf's marker: selection lives in a state file so that
# switching sections can reload the list without losing anything.
row() {                         # row <item> <group-label-or-empty>
    local mark=""
    if [ -n "$STATE" ]; then
        is_selected "$(fld "$1" 1)" && mark="${GREEN}[✔]${R}" || mark="${DIM}[ ]${R}"
    fi
    printf '%s\t%s\t%s %s%-10s%s %s  %s%-20s%s %s%s%s\n' \
        "$(fld "$1" 1)" "$(fld "$1" 5)" "$mark" \
        "$TEAL" "$2" "$R" "$(fld "$1" 2)" \
        "${B}${TEXT}" "$(fld "$1" 3)" "$R" \
        "$DIM" "$(fld "$1" 4)" "$R"
}

rows_for() {                    # rows_for <section|all>
    local it sec grp last=""
    for it in "${ITEMS[@]}"; do
        sec=$(fld "$it" 5)
        [ "$1" = "all" ] || [ "$sec" = "$1" ] || continue
        grp="$(fld "$it" 6)"
        if [ "${sec}/${grp}" != "$last" ]; then
            row "$it" "$grp"
            last="${sec}/${grp}"
        else
            row "$it" ""
        fi
    done
}

# ── selection state ──────────────────────────────────────────────────────────
# fzf's own marks cannot survive the reload that a section switch needs, and
# putting the section in the query — the other way to filter — collides with
# whatever the user types. So the tab and the ticks are ours, and the search box
# is left alone: typing only ever searches inside the section on screen.
STATE="${COMBO_STATE:-}"
SEL="$STATE/selected"
CUR="$STATE/section"

is_selected() { [ -n "$STATE" ] && grep -qxF "$1" "$SEL" 2>/dev/null; }
cur_section() { cat "$CUR" 2>/dev/null || echo dotfiles; }

toggle_key() {                  # toggle_key <key>
    [ -n "$1" ] || return 0
    if is_selected "$1"; then
        grep -vxF "$1" "$SEL" > "$SEL.tmp" 2>/dev/null || :
        mv "$SEL.tmp" "$SEL"
    else
        printf '%s\n' "$1" >> "$SEL"
    fi
}

section_keys() {                # section_keys <section>
    local it
    for it in "${ITEMS[@]}"; do
        [ "$(fld "$it" 5)" = "$1" ] && printf '%s\n' "$(fld "$it" 1)"
    done
}

# ctrl-a: everything in this section, or nothing if it is already everything.
toggle_section() {
    local sec k all=1
    sec=$(cur_section)
    while read -r k; do is_selected "$k" || { all=0; break; }; done < <(section_keys "$sec")
    while read -r k; do
        if [ "$all" -eq 1 ]; then is_selected "$k" && toggle_key "$k"
        else is_selected "$k" || toggle_key "$k"; fi
    done < <(section_keys "$sec")
}

# Selections in the order they are declared, not the order they were clicked.
selected_keys() {
    local it
    for it in "${ITEMS[@]}"; do
        is_selected "$(fld "$it" 1)" && printf '%s\n' "$(fld "$it" 1)"
    done
}

# ── preview: details (design 2) over the cart (design 10) ────────────────────
pv() {                          # pv <current-key> [selected keys...]
    local key="${1:-}"; shift || true
    local w="${FZF_PREVIEW_COLUMNS:-40}"
    local -a sel=()
    local rule; rule=$(printf '─%.0s' $(seq 1 "$w"))

    if [ -n "$key" ]; then
        local icon name desc sec grp pkg target
        icon=$(lookup "$key" 2); name=$(lookup "$key" 3); desc=$(lookup "$key" 4)
        sec=$(lookup  "$key" 5); grp=$(lookup  "$key" 6); pkg=$(lookup  "$key" 7)
        printf '\n %s\n' "${MAUVE}${B}${icon}  ${name}${R}"
        printf ' %s\n\n' "${DIM}${desc}${R}"
        printf ' %s %s\n' "${DIM}section${R}" "$sec"
        printf ' %s %s\n' "${DIM}group  ${R}" "$grp"
        printf ' %s %s\n' "${DIM}package${R}" "$pkg"
        if [ "$sec" = "dotfiles" ]; then
            case "$key" in
                zsh)       target="~/.zshrc" ;;
                bash)      target="~/.bashrc" ;;
                git)       target="~/.gitconfig" ;;
                starship)  target="~/.config/starship.toml" ;;
                protonvpn) target="~/scripts/pvpn/pvpn.zsh" ;;
                *)         target="~/.config/${key}/" ;;
            esac
            printf ' %s %s\n' "${DIM}stows  ${R}" "$target"
        fi
        if installed "$pkg"; then
            printf ' %s %s\n' "${DIM}state  ${R}" "${GREEN}● already installed${R}"
        else
            printf ' %s %s\n' "${DIM}state  ${R}" "${YELLOW}○ will be installed${R}"
        fi
        case "$key" in
            ghostty|kitty|rofi) printf ' %s %s\n' "${DIM}font   ${R}" "JetBrainsMono Nerd Font" ;;
            zsh)                printf ' %s %s\n' "${DIM}pulls  ${R}" "starship + every tool" ;;
        esac
    else
        printf '\n %s\n' "${DIM}a heading — nothing to install${R}"
    fi

    if [ -n "$STATE" ]; then
        mapfile -t sel < <(selected_keys)
    else
        # arrangements 1 and 2 still use fzf's own marks, handed in as {+1}
        local a; sel=()
        for a in "$@"; do [ -n "$a" ] && sel+=("$a"); done
    fi
    set -- "${sel[@]}"

    printf '\n%s\n' "${DIM}${rule}${R}"
    if [ "$#" -eq 0 ]; then
        printf ' %s\n' "${DIM}nothing selected yet${R}"
        printf ' %s\n' "${DIM}enter adds the row you are on${R}"
        return
    fi
    printf ' %s\n\n' "${GREEN}${B}selected (${#})${R}"
    local k s
    for s in "${SECTIONS[@]}"; do
        local first=1
        for k in "$@"; do
            [ "$(lookup "$k" 5)" = "$s" ] || continue
            [ "$first" -eq 1 ] && { printf ' %s\n' "${DIM}${s}${R}"; first=0; }
            printf '   %s %s\n' "${GREEN}✔${R}" "$(lookup "$k" 3)"
        done
    done
}

# ── section switching (arrangement 3) ────────────────────────────────────────
# Ghostty (and most terminals) bind alt+1..9 to "go to tab N" and swallow them
# before fzf ever sees the key, so tab/shift-tab and F1-F4 are the real
# controls; alt-1/2/3 stay bound for terminals that do pass them through.
#
# Called back by fzf's `transform`: prints the action to run, given the query
# that is on screen now.
TABS=(dotfiles tools apps)

# The three sections drawn as a bar, the current one lit. This is the header,
# redrawn on every switch — there is no "everything" stop, so the bar always
# says exactly what the list is showing.
tab_bar() {                     # tab_bar <active>
    local t out=""
    for t in "${TABS[@]}"; do
        if [ "$t" = "$1" ]; then
            out+="${MAUVE}${B} ▌ ${t} ${R}"
        else
            out+="${DIM}   ${t} ${R}"
        fi
    done
    printf '%s' "$out"
}

tab_index() {                   # tab_index <section>
    local i
    for i in "${!TABS[@]}"; do
        [ "${TABS[$i]}" = "$1" ] && { echo "$i"; return; }
    done
    echo 0
}

# Called back by fzf's `transform`: prints the actions to run, given the query
# on screen now. Wraps around — three sections, no fourth state.
tab_step() {                    # tab_step <+1|-1>
    local cur n
    cur=$(tab_index "$(cur_section)")
    n=$(( (cur + $1 + ${#TABS[@]}) % ${#TABS[@]} ))
    tab_to "${TABS[$n]}"
}

tab_to() {                      # tab_to <section>
    printf '%s\n' "$1" > "$CUR"
    # The query is cleared because it belongs to the user, not to us: a search
    # typed in one section should not follow them into the next.
    # `first` lands the cursor on the top row; change-header: swallows the rest
    # of the line, so it goes last.
    printf "change-query()+reload(%s --rows-cur)+first+change-list-label( %s )+change-header:%s\n" \
        "$SELF" "$1" "$(tab_bar "$1")"
}

case "${1:-}" in
    --preview)  shift; pv "$@"; exit 0 ;;
    --next-tab) tab_step  1; exit 0 ;;
    --prev-tab) tab_step -1; exit 0 ;;
    --tab-to)   tab_to  "${2:-dotfiles}"; exit 0 ;;
    --tab-bar)  tab_bar "${2:-dotfiles}"; echo; exit 0 ;;
    --rows)     rows_for "${2:-all}"; exit 0 ;;
    --rows-cur) rows_for "$(cur_section)"; exit 0 ;;
    --toggle)   # <key> <0-based row index>
        toggle_key "${2:-}"
        printf 'reload(%s --rows-cur)+pos(%d)+refresh-preview\n' "$SELF" "$(( ${3:-0} + 2 ))"
        exit 0 ;;
    --toggle-all)
        toggle_section
        printf 'reload(%s --rows-cur)+pos(%d)+refresh-preview\n' "$SELF" "$(( ${2:-0} + 1 ))"
        exit 0 ;;
    --selected) selected_keys; exit 0 ;;
esac

# ── the shared look ──────────────────────────────────────────────────────────
# One place, so the three arrangements below differ only in their labels and
# the rows they are handed.
pick() {                        # pick <list-label> <header> [extra fzf args...]
    local list_label="$1" header="$2"; shift 2
    fzf --multi --ansi --height=100% --reverse \
        --style=full:rounded --color="$FZF_CLR" --highlight-line \
        --delimiter=$'\t' --with-nth=3 \
        --border-label=" dotfiles installer " --border-label-pos=3 \
        --list-label=" ${list_label} " --list-label-pos=3 \
        --input-label=" filter " --input-label-pos=3 \
        --header-label=" what this is " --header="$header" \
        --footer-label=" keys " \
        --preview="$SELF --preview {1} {+1}" \
        --preview-window='right,42%,border-left' --preview-label=" details · selected " \
        --prompt="  " --pointer="❯" --marker="✔" --info=inline-right \
        --no-sort --cycle --scroll-off=3 --no-hscroll --ellipsis='' \
        --bind='enter:toggle+down' --bind='ctrl-j:accept' --bind='ctrl-a:select-all' \
        "$@" \
    | cut -f1 | grep -v '^$'
}

# ── 1 · one by one ───────────────────────────────────────────────────────────
variant_steps() {
    local -a chosen=()
    local i=0 sec
    for sec in "${SECTIONS[@]}"; do
        i=$((i + 1))
        mapfile -t got < <(
            rows_for "$sec" \
            | pick "step ${i} of 3 · ${SEC_TITLE[$sec]}" "${SEC_BLURB[$sec]}" \
                   --footer="enter toggle   ctrl-a all   ctrl-j next step   esc skip this step"
        )
        chosen+=("${got[@]}")
    done
    summary "${chosen[@]}"
}

# ── 2 · one screen ───────────────────────────────────────────────────────────
variant_single() {
    mapfile -t chosen < <(
        rows_for all \
        | pick "everything · dotfiles, tools, apps" \
               "one pass over all three sections — type to filter, headings are just labels" \
               --footer="enter toggle   ctrl-a all   ctrl-j confirm   esc skip everything"
    )
    summary "${chosen[@]}"
}

# ── 3 · tabs ─────────────────────────────────────────────────────────────────
# One list, one pass, one section on screen at a time — there is no "show
# everything" state. Switching reloads the list; the ticks live in a state file,
# so nothing is lost, and the search box stays the user's: typing filters inside
# the current section only.
variant_tabs() {
    COMBO_STATE="$(mktemp -d "${TMPDIR:-/tmp}/combo-menu.XXXXXX")"
    export COMBO_STATE
    STATE="$COMBO_STATE"; SEL="$STATE/selected"; CUR="$STATE/section"
    : > "$SEL"; printf 'dotfiles\n' > "$CUR"
    trap 'rm -rf "$COMBO_STATE"' EXIT

    # Accept vs abort is the whole reason this reads fzf's exit code rather than
    # its output: esc must return nothing even though the state file is full.
    rows_for dotfiles \
    | fzf --ansi --height=100% --reverse \
        --style=full:rounded --color="$FZF_CLR" --highlight-line \
        --delimiter=$'\t' --with-nth=3 \
        --no-sort --cycle --scroll-off=3 \
        --border-label=" dotfiles installer " --border-label-pos=3 \
        --list-label=" dotfiles " --list-label-pos=3 \
        --input-label=" search this section " --input-label-pos=3 \
        --header-label=" sections " --header="$(tab_bar dotfiles)" \
        --footer-label=" keys " \
        --footer="← → section   enter tick   ctrl-a all in section   ctrl-j confirm   esc cancel" \
        --preview="$SELF --preview {1}" \
        --preview-window='right,42%,border-left' --preview-label=" details · selected " \
        --prompt="  " --pointer="❯" --ghost="type to filter this section" \
        --info=inline-right \
        --bind="enter:transform:$SELF --toggle {1} {n}" \
        --bind="ctrl-a:transform:$SELF --toggle-all {n}" \
        --bind="right:transform:$SELF --next-tab" \
        --bind="left:transform:$SELF --prev-tab" \
        --bind="tab:transform:$SELF --next-tab" \
        --bind="shift-tab:transform:$SELF --prev-tab" \
        --bind="f1:transform:$SELF --tab-to dotfiles" \
        --bind="f2:transform:$SELF --tab-to tools" \
        --bind="f3:transform:$SELF --tab-to apps" \
        --bind='ctrl-j:accept' \
        >/dev/null
    local rc=$?

    local -a chosen=()
    [ "$rc" -eq 0 ] && mapfile -t chosen < <(selected_keys)
    summary "${chosen[@]}"
}

# ── result ───────────────────────────────────────────────────────────────────
summary() {
    printf '\n  %s\n\n' "${MAUVE}${B}selected${R}"
    if [ "$#" -eq 0 ]; then
        printf '   %s\n\n' "${DIM}nothing${R}"
        return
    fi
    local s k first
    for s in "${SECTIONS[@]}"; do
        first=1
        for k in "$@"; do
            [ "$(lookup "$k" 5)" = "$s" ] || continue
            [ "$first" -eq 1 ] && { printf '  %s\n' "${TEAL}${s}${R}"; first=0; }
            printf '    %s %-22s %s%s%s\n' \
                "${GREEN}✔${R}" "$(lookup "$k" 3)" "$DIM" "$(lookup "$k" 4)" "$R"
        done
        [ "$first" -eq 0 ] && echo
    done
}

case "${1:-}" in
    1) variant_steps  ;;
    2) variant_single ;;
    3) variant_tabs   ;;
    "")  variant_tabs ;;
    *) echo "usage: bash combo.sh [1|2|3]" ;;
esac
