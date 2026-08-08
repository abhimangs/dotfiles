#!/usr/bin/env bash
# Ten menu designs for install.sh's config picker — throwaway, not wired into
# anything. Run ./demo.sh to flip through them.
#
# Every design gets the same data and the same job: multi-select from the real
# config list. Only the presentation differs.

set -uo pipefail

# ── Catppuccin Mocha ─────────────────────────────────────────────────────────
FZF_CLR="bg+:#313244,bg:-1,fg:#cdd6f4,fg+:#cdd6f4,hl:#f38ba8,hl+:#f38ba8,prompt:#cba6f7,pointer:#f5e0dc,marker:#a6e3a1,border:#585b70,header:#94e2d5,info:#cba6f7,spinner:#f5e0dc,separator:#585b70,gutter:-1,label:#cba6f7,preview-border:#585b70"

R=$'\033[0m'; DIM=$'\033[38;2;127;132;156m'; MAUVE=$'\033[38;2;203;166;247m'
TEAL=$'\033[38;2;148;226;213m'; GREEN=$'\033[38;2;166;227;161m'
YELLOW=$'\033[38;2;249;226;175m'; BLUE=$'\033[38;2;137;180;250m'
PINK=$'\033[38;2;245;194;231m'; TEXT=$'\033[38;2;205;214;244m'; B=$'\033[1m'

# ── data: key | icon | description | group | package ─────────────────────────
ITEMS=(
"fastfetch|󰋼|system info display at login|tools|fastfetch"
"ghostty||GPU-accelerated terminal|terminals|ghostty"
"kitty||cross-platform terminal|terminals|kitty"
"bash||plain rc, aliases, no prompt tooling|shells|bash"
"zsh||shell + Zinit plugins|shells|zsh"
"starship|󱐋|cross-shell prompt|shells|starship"
"rofi|󰍉|keyboard-driven launcher|desktop|rofi"
"ulauncher|󰀻|app launcher|desktop|ulauncher"
"protonvpn|󰖂|ProtonVPN wrapper script|tools|proton-vpn-cli"
"git||git config  →  ~/.gitconfig|tools|git"
)
GROUPS=(terminals shells desktop tools)

f() { cut -d'|' -f"$2" <<<"$1"; }          # field
installed() { command -v "$1" &>/dev/null; }

# ── preview payloads (called back by fzf) ────────────────────────────────────
detail() {
    local key="$1" it
    for it in "${ITEMS[@]}"; do
        [ "$(f "$it" 1)" = "$key" ] || continue
        local icon desc grp pkg target
        icon=$(f "$it" 2); desc=$(f "$it" 3); grp=$(f "$it" 4); pkg=$(f "$it" 5)
        case "$key" in
            zsh)       target="~/.zshrc" ;;
            bash)      target="~/.bashrc" ;;
            git)       target="~/.gitconfig" ;;
            starship)  target="~/.config/starship.toml" ;;
            protonvpn) target="~/scripts/pvpn/pvpn.zsh" ;;
            *)         target="~/.config/${key}/" ;;
        esac
        printf '%s\n\n' "${MAUVE}${B}${icon}  ${key}${R}"
        printf '%s\n' "${DIM}${desc}${R}"
        printf '\n%s %s\n' "${DIM}group  ${R}" "$grp"
        printf '%s %s\n'   "${DIM}pkg    ${R}" "$pkg"
        printf '%s %s\n'   "${DIM}stows  ${R}" "$target"
        if installed "$pkg"; then
            printf '%s %s\n' "${DIM}state  ${R}" "${GREEN}● installed${R}"
        else
            printf '%s %s\n' "${DIM}state  ${R}" "${YELLOW}○ will install${R}"
        fi
        case "$key" in
            ghostty|kitty|rofi)
                printf '%s %s\n' "${DIM}font   ${R}" "JetBrainsMono Nerd Font" ;;
        esac
        [ -d "$HOME/dotfiles/$key" ] && {
            printf '\n%s\n' "${DIM}files${R}"
            find "$HOME/dotfiles/$key" -maxdepth 2 -mindepth 1 -printf '  %P\n' 2>/dev/null | head -8
        }
        return
    done
}

plan() {   # the "what happens" preview, bottom-pane variant
    local key="$1" pkg
    for it in "${ITEMS[@]}"; do
        [ "$(f "$it" 1)" = "$key" ] || continue
        pkg=$(f "$it" 5)
        installed "$pkg" \
            && printf '  %s %s\n' "${DIM}1${R}" "${DIM}${pkg} already installed${R}" \
            || printf '  %s %s\n' "${DIM}1${R}" "${YELLOW}install ${pkg}${R}"
        printf '  %s %s\n' "${DIM}2${R}" "${YELLOW}back up any existing config → .bak${R}"
        printf '  %s %s\n' "${DIM}3${R}" "${GREEN}stow it into place${R}"
        return
    done
}

state_tag() {
    installed "$1" && printf '%s' "${GREEN}● installed${R}" || printf '%s' "${DIM}○ new${R}"
}

# ─────────────────────────────────────────────────────────────────────────────
# 1 — classic+     what ships today, tightened: label, footer, no header clutter
# ─────────────────────────────────────────────────────────────────────────────
d1_classic() {
    local it
    for it in "${ITEMS[@]}"; do
        printf '%-11s %s %s\n' "$(f "$it" 1)" "${DIM}·${R}" "${DIM}$(f "$it" 3)${R}"
    done | fzf --multi --ansi --height=60% --reverse \
        --border=rounded --border-label=" configs " --border-label-pos=3 \
        --color="$FZF_CLR" \
        --prompt="  " --pointer="❯" --marker="✔" \
        --info=inline-right \
        --footer="enter select · ctrl-j confirm · ctrl-a all · esc skip" \
        --bind='enter:toggle+down' --bind='ctrl-j:accept' --bind='ctrl-a:select-all'
}

# ─────────────────────────────────────────────────────────────────────────────
# 2 — preview      details pane on the right: package, target, state, files
# ─────────────────────────────────────────────────────────────────────────────
d2_preview() {
    local it
    for it in "${ITEMS[@]}"; do
        printf '%s %-11s %s %s\n' "$(f "$it" 2)" "$(f "$it" 1)" "${DIM}·${R}" "${DIM}$(f "$it" 3)${R}"
    done | fzf --multi --ansi --height=80% --reverse \
        --border=rounded --border-label=" configs " --border-label-pos=3 \
        --color="$FZF_CLR" \
        --prompt="  " --pointer="❯" --marker="✔" --info=inline-right \
        --preview="$SELF --detail {2}" \
        --preview-window='right,46%,border-left' \
        --footer="enter select · ctrl-j confirm · ctrl-a all · esc skip" \
        --bind='enter:toggle+down' --bind='ctrl-j:accept' --bind='ctrl-a:select-all'
}

# ─────────────────────────────────────────────────────────────────────────────
# 3 — grouped      category headings, blank line between groups
# ─────────────────────────────────────────────────────────────────────────────
d3_grouped() {
    local g it first=1
    {
        for g in "${GROUPS[@]}"; do
            [ "$first" -eq 1 ] || echo " "
            first=0
            printf '%s\n' "  ${TEAL}${B}${g}${R}"
            for it in "${ITEMS[@]}"; do
                [ "$(f "$it" 4)" = "$g" ] || continue
                printf '%s %-11s %s\n' "$(f "$it" 2)" "$(f "$it" 1)" "${DIM}$(f "$it" 3)${R}"
            done
        done
    } | fzf --multi --ansi --height=80% --reverse \
        --border=rounded --border-label=" configs " --border-label-pos=3 \
        --color="$FZF_CLR" --highlight-line \
        --prompt="  " --pointer="❯" --marker="✔" --info=inline-right \
        --footer="enter select · ctrl-j confirm · ctrl-a all · esc skip" \
        --bind='enter:toggle+down' --bind='ctrl-j:accept' --bind='ctrl-a:select-all'
}

# ─────────────────────────────────────────────────────────────────────────────
# 4 — cards        two lines per item with a gap rule between them
# ─────────────────────────────────────────────────────────────────────────────
d4_cards() {
    local it
    for it in "${ITEMS[@]}"; do
        printf '%s  %s%s%s\n     %s%s%s\n\0' \
            "$(f "$it" 2)" "${B}${TEXT}" "$(f "$it" 1)" "$R" \
            "$DIM" "$(f "$it" 3)" "$R"
    done | fzf --multi --ansi --read0 --height=80% --reverse \
        --border=rounded --border-label=" configs " --border-label-pos=3 \
        --color="$FZF_CLR" --highlight-line \
        --gap=1 --gap-line="·" \
        --prompt="  " --pointer="❯" --marker="✔" --marker-multi-line="╻┃╹" \
        --info=inline-right \
        --footer="enter select · ctrl-j confirm · ctrl-a all · esc skip" \
        --bind='enter:toggle+down' --bind='ctrl-j:accept' --bind='ctrl-a:select-all'
}

# ─────────────────────────────────────────────────────────────────────────────
# 5 — state        right-aligned installed / new column
# ─────────────────────────────────────────────────────────────────────────────
d5_state() {
    local it
    for it in "${ITEMS[@]}"; do
        printf '%-11s %s%-38s%s %s\n' \
            "$(f "$it" 1)" "$DIM" "$(f "$it" 3)" "$R" "$(state_tag "$(f "$it" 5)")"
    done | fzf --multi --ansi --height=60% --reverse \
        --border=rounded --border-label=" configs " --border-label-pos=3 \
        --color="$FZF_CLR" --highlight-line \
        --prompt="  " --pointer="❯" --marker="✔" --info=inline-right \
        --header=$'● already on this machine   ○ will be installed\n' \
        --footer="enter select · ctrl-j confirm · ctrl-a all · esc skip" \
        --bind='enter:toggle+down' --bind='ctrl-j:accept' --bind='ctrl-a:select-all'
}

# ─────────────────────────────────────────────────────────────────────────────
# 6 — wizard       full screen, every section boxed, step counter
# ─────────────────────────────────────────────────────────────────────────────
d6_wizard() {
    local it
    for it in "${ITEMS[@]}"; do
        printf '%s %-11s %s %s\n' "$(f "$it" 2)" "$(f "$it" 1)" "${DIM}·${R}" "${DIM}$(f "$it" 3)${R}"
    done | fzf --multi --ansi --height=100% --reverse \
        --style=full:rounded --color="$FZF_CLR" \
        --border-label=" dotfiles installer " --border-label-pos=3 \
        --list-label=" step 1 of 3 · configs " --list-label-pos=3 \
        --input-label=" filter " --input-label-pos=3 \
        --header-label=" what these are " \
        --header=$'the shell, terminal and tool configs from this repo.\nnothing is written until you confirm the plan.' \
        --footer-label=" keys " \
        --footer=$'enter toggle   ctrl-a all   ctrl-j next step   esc skip' \
        --prompt="  " --pointer="❯" --marker="✔" --info=inline-right \
        --bind='enter:toggle+down' --bind='ctrl-j:accept' --bind='ctrl-a:select-all'
}

# ─────────────────────────────────────────────────────────────────────────────
# 7 — minimal      no boxes at all, one rule, lots of air
# ─────────────────────────────────────────────────────────────────────────────
d7_minimal() {
    local it
    for it in "${ITEMS[@]}"; do
        printf '%-11s %s\n' "$(f "$it" 1)" "${DIM}$(f "$it" 3)${R}"
    done | fzf --multi --ansi --height=70% --reverse \
        --border=none --color="$FZF_CLR" --highlight-line \
        --prompt="configs  " --pointer=" " --marker="✔" \
        --ghost="type to filter" \
        --info=inline-right --separator="─" \
        --header=$'\n' \
        --footer=$'\nenter select · ctrl-j confirm · esc skip' --footer-border=top \
        --bind='enter:toggle+down' --bind='ctrl-j:accept' --bind='ctrl-a:select-all'
}

# ─────────────────────────────────────────────────────────────────────────────
# 8 — plan pane    preview at the bottom showing the steps for that config
# ─────────────────────────────────────────────────────────────────────────────
d8_planpane() {
    local it
    for it in "${ITEMS[@]}"; do
        printf '%-11s %s %s\n' "$(f "$it" 1)" "${DIM}·${R}" "${DIM}$(f "$it" 3)${R}"
    done | fzf --multi --ansi --height=80% --reverse \
        --border=rounded --border-label=" configs " --border-label-pos=3 \
        --color="$FZF_CLR" --highlight-line \
        --prompt="  " --pointer="❯" --marker="✔" --info=inline-right \
        --preview="$SELF --plan {1}" \
        --preview-window='down,5,border-top' --preview-label=" what this does " \
        --footer="enter select · ctrl-j confirm · ctrl-a all · esc skip" \
        --bind='enter:toggle+down' --bind='ctrl-j:accept' --bind='ctrl-a:select-all'
}

# ─────────────────────────────────────────────────────────────────────────────
# 9 — banner       ASCII wordmark above the list, inside the frame
# ─────────────────────────────────────────────────────────────────────────────
d9_banner() {
    local it
    local art
    art=$(printf '%s\n' \
        "${MAUVE}    ╔╦╗╔═╗╔╦╗╔═╗╦╦  ╔═╗╔═╗${R}" \
        "${MAUVE}     ║║║ ║ ║ ╠╣ ║║  ║╣ ╚═╗${R}" \
        "${MAUVE}    ═╩╝╚═╝ ╩ ╚  ╩╩═╝╚═╝╚═╝${R}" \
        "${DIM}      arch · stow · mocha${R}")
    for it in "${ITEMS[@]}"; do
        printf '%s %-11s %s %s\n' "$(f "$it" 2)" "$(f "$it" 1)" "${DIM}·${R}" "${DIM}$(f "$it" 3)${R}"
    done | fzf --multi --ansi --height=90% --reverse \
        --border=rounded --color="$FZF_CLR" --highlight-line \
        --header="$art" --header-border=bottom --header-first \
        --prompt="  " --pointer="❯" --marker="✔" --info=inline-right \
        --footer="enter select · ctrl-j confirm · ctrl-a all · esc skip" \
        --bind='enter:toggle+down' --bind='ctrl-j:accept' --bind='ctrl-a:select-all'
}

# ─────────────────────────────────────────────────────────────────────────────
# 10 — live cart   selected items collect in a pane on the right as you go
# ─────────────────────────────────────────────────────────────────────────────
d10_cart() {
    local it
    for it in "${ITEMS[@]}"; do
        printf '%s %-11s %s %s\n' "$(f "$it" 2)" "$(f "$it" 1)" "${DIM}·${R}" "${DIM}$(f "$it" 3)${R}"
    done | fzf --multi --ansi --height=80% --reverse \
        --border=rounded --border-label=" configs " --border-label-pos=3 \
        --color="$FZF_CLR" --highlight-line \
        --prompt="  " --pointer="❯" --marker="✔" --info=inline-right \
        --preview="$SELF --cart {+2}" \
        --preview-window='right,34%,border-left' --preview-label=" selected " \
        --footer="enter select · ctrl-j confirm · ctrl-a all · esc skip" \
        --bind='enter:toggle+down' --bind='ctrl-j:accept' --bind='ctrl-a:select-all'
}

cart() {   # {+2} hands us every selected key
    if [ "$#" -eq 0 ]; then
        printf '%s\n' "${DIM}nothing selected yet${R}"
        printf '%s\n' "${DIM}enter adds the row you are on${R}"
        return
    fi
    printf '%s\n\n' "${GREEN}${#} selected${R}"
    local k
    for k in "$@"; do printf '  %s %s\n' "${GREEN}✔${R}" "$k"; done
    printf '\n%s\n' "${DIM}zsh also pulls in starship${R}"
    printf '%s\n' "${DIM}and the dep toolchain${R}"
}

# ── result parsing ───────────────────────────────────────────────────────────
# Rows are coloured and some designs put an icon first, so the key is found by
# name rather than by column. --ansi shows colours but hands the raw line back.
KEY_RE="^($(printf '%s|' "${ITEMS[@]%%|*}" | sed 's/|$//'))$"
keys_of() {
    sed -e 's/\x1b\[[0-9;]*m//g' \
    | awk -v re="$KEY_RE" '{for(i=1;i<=NF;i++) if ($i ~ re) {print $i; break}}'
}
