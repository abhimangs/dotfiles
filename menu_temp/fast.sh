#!/usr/bin/env bash
# The menu, without fzf.
#
#   bash fast.sh
#
# fzf was never the slow part — the wiring around it was. Every tick forked a
# callback that re-read the item table with `cut` (seven subshells a row),
# re-rendered the list twice and re-ran the preview: hundreds of processes per
# keystroke. Here nothing forks after startup. The item table is parsed once
# into arrays, a frame is a string built in bash and written with one printf,
# and a keypress redraws in about a millisecond.
#
# Throwaway, like the rest of menu_temp/.

set -uo pipefail

# Character semantics for ${#s} and ${s:0:n}: in the C locale both count bytes,
# which truncates mid-character on any description containing → or ….
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]*) ;;
    *) export LC_ALL=C.UTF-8 ;;
esac

# ── palette ──────────────────────────────────────────────────────────────────
R=$'\033[0m';      B=$'\033[1m'
DIM=$'\033[38;2;127;132;156m'   ; MAUVE=$'\033[38;2;203;166;247m'
TEAL=$'\033[38;2;148;226;213m'  ; GREEN=$'\033[38;2;166;227;161m'
YELLOW=$'\033[38;2;249;226;175m'; TEXT=$'\033[38;2;205;214;244m'
RED=$'\033[38;2;243;139;168m'

# ── items: key | name | description | section | package ──────────────────────
# No group column and no icons. The three menus are the only grouping, and a
# Nerd Font glyph is two cells wide while printf counts it as one character —
# which is exactly why the old name column came out ragged.
ITEMS=(
"zsh|zsh|shell + Zinit plugins|dotfiles|zsh"
"bash|bash|plain rc, aliases, no prompt tooling|dotfiles|bash"
"starship|starship|cross-shell prompt|dotfiles|starship"
"ghostty|ghostty|GPU-accelerated terminal|dotfiles|ghostty"
"kitty|kitty|cross-platform terminal|dotfiles|kitty"
"rofi|rofi|keyboard-driven launcher|dotfiles|rofi"
"ulauncher|ulauncher|app launcher|dotfiles|ulauncher"
"git|git|git config → ~/.gitconfig|dotfiles|git"
"fastfetch|fastfetch|system info display at login|dotfiles|fastfetch"
"protonvpn|protonvpn|ProtonVPN wrapper script|dotfiles|proton-vpn-cli"

"bat|bat|cat with syntax highlighting|tools|bat"
"eza|eza|modern ls → ls ll lt la|tools|eza"
"fd|fd|fast find → fzf integration|tools|fd"
"tree|tree|directory tree listing|tools|tree"
"zoxide|zoxide|smart cd → z|tools|zoxide"
"thefuck|thefuck|corrects the last command → fuck|tools|thefuck"
"lazygit|lazygit|git TUI → lg|tools|lazygit"
"btop|btop|resource monitor|tools|btop"

"brave-stable|Brave Origin Stable|chromium browser, no telemetry|apps|brave-browser"
"brave-beta|Brave Origin Beta|the beta channel of the same|apps|brave-browser-beta"
"vscode|Visual Studio Code|the editor|apps|code"
"vscode-insiders|VS Code Insiders|nightly channel|apps|code-insiders"
"antigravity-ide|Antigravity IDE|agentic IDE|apps|antigravity"
"obsidian|Obsidian|markdown knowledge base|apps|obsidian"
"notion|Notion|workspace|apps|notion-app"
"claude-code|Claude Code CLI|agentic coding in the terminal|apps|claude"
"codex-cli|Codex CLI|OpenAI's coding agent|apps|codex"
"antigravity-cli|Antigravity CLI|the CLI half of Antigravity|apps|antigravity"
"opencode|OpenCode|open-source coding agent|apps|opencode"
"kimi-code|Kimi Code CLI|Moonshot's coding agent|apps|kimi"
"muse|Muse|terminal agent|apps|muse"
"vlc|VLC|plays anything|apps|vlc"
"docker|Docker + Compose|containers, compose, buildx|apps|docker"
"flatpak|Flatpak|sandboxed app runtime + flathub|apps|flatpak"
)

TABS=(dotfiles tools apps selected)

declare -A NAME DESC SECT PKG PSTATE TICK
declare -a ORDER=()

parse_items() {
    local it key name desc sec pkg
    for it in "${ITEMS[@]}"; do
        IFS='|' read -r key name desc sec pkg <<<"$it"
        ORDER+=("$key")
        NAME[$key]=$name; DESC[$key]=$desc; SECT[$key]=$sec; PKG[$key]=$pkg
        PSTATE[$key]=new; TICK[$key]=0
    done
}

# ── install state ────────────────────────────────────────────────────────────
# Two passes, split by how long they take. "What is installed" is a 20ms local
# query, so it happens before the first frame. "What has an update" costs ~170ms
# on pacman and can take seconds on `apt list --upgradable`, so it runs in the
# background and the rows fill in when it lands — the menu is usable
# immediately either way.
UPD_READY=""

scan_installed() {
    local -A have=()
    local name k p
    if command -v pacman &>/dev/null; then
        while read -r name _; do have[$name]=1; done < <(pacman -Q 2>/dev/null)
    elif command -v dpkg-query &>/dev/null; then
        while read -r name _; do have[$name]=1; done \
            < <(dpkg-query -W -f '${Package} ${Status}\n' 2>/dev/null | grep ' installed$')
    fi
    for k in "${ORDER[@]}"; do
        p=${PKG[$k]}
        if [ -n "${have[$p]:-}" ] || command -v "$p" &>/dev/null; then
            PSTATE[$k]=installed
        else
            PSTATE[$k]=new
        fi
    done
}

start_upgrade_scan() {
    local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/fastmenu.XXXXXX")
    UPD_READY="$tmp.ready"
    {
        if command -v pacman &>/dev/null; then
            pacman -Qu 2>/dev/null | cut -d' ' -f1 > "$tmp"
        elif command -v apt &>/dev/null; then
            apt list --upgradable 2>/dev/null | cut -d/ -f1 > "$tmp"
        else
            : > "$tmp"
        fi
        # Renamed only when complete, so a half-written file is never read.
        mv "$tmp" "$UPD_READY"
    } &
}

apply_upgrades() {
    local -A upd=()
    local name k
    while read -r name; do [ -n "$name" ] && upd[$name]=1; done < "$UPD_READY"
    rm -f "$UPD_READY"
    for k in "${ORDER[@]}"; do
        [ "${PSTATE[$k]}" = installed ] && [ -n "${upd[${PKG[$k]}]:-}" ] && PSTATE[$k]=update
    done
}

# ── view state ───────────────────────────────────────────────────────────────
TAB=0            # index into TABS
CUR=0            # cursor within the visible rows
TOP=0            # first visible row, for scrolling
FILTER=""
declare -a VIEW=()   # keys currently listed

build_view() {
    VIEW=()
    local sec=${TABS[$TAB]} k f=${FILTER,,} hay
    for k in "${ORDER[@]}"; do
        if [ "$sec" = selected ]; then
            [ "${TICK[$k]}" = 1 ] || continue
        else
            [ "${SECT[$k]}" = "$sec" ] || continue
        fi
        if [ -n "$f" ]; then
            hay="${NAME[$k]} ${DESC[$k]}"
            [[ "${hay,,}" == *"$f"* ]] || continue
        fi
        VIEW+=("$k")
    done
    (( CUR >= ${#VIEW[@]} )) && CUR=$(( ${#VIEW[@]} - 1 ))
    (( CUR < 0 )) && CUR=0
}

# Counts for every tab in one pass, into globals — a frame asks for these a
# dozen times and $( ) would fork for each one.
declare -A CNT=()
recount() {
    local k s
    for s in "${TABS[@]}"; do CNT[$s]=0; done
    CNT[total]=0
    for k in "${ORDER[@]}"; do
        [ "${TICK[$k]}" = 1 ] || continue
        s=${SECT[$k]}
        CNT[$s]=$(( ${CNT[$s]} + 1 ))
        CNT[selected]=$(( ${CNT[selected]} + 1 ))
        CNT[total]=$(( ${CNT[total]} + 1 ))
    done
}

# ── drawing ──────────────────────────────────────────────────────────────────
# Every cell is a fixed width of plain characters, so columns line up: no glyph
# whose display width printf cannot see, and colour is only ever wrapped around
# an already-padded string.
#
# Nothing below runs a command substitution. A frame touches ~35 rows and the
# old fzf wiring forked seven times per row; here a frame is pure string
# building and one write.
NAMEW=20
STATEW=10

# Locals here are prefixed because these write into a variable the caller names:
# a local with the same name as the target shadows it, printf -v fills the local
# instead, and the caller reads an unset variable.
pad() {                         # pad <var> <text> <width>
    local _p_t=$2 _p_w=$3
    (( ${#_p_t} > _p_w )) && _p_t="${_p_t:0:_p_w-1}…"
    printf -v "$1" '%-*s' "$_p_w" "$_p_t"
}

# Words, not symbols. printf pads %s by *bytes*, so "● installed" (13 bytes,
# 11 columns) and "○ new" (7 bytes, 5 columns) came out at different widths and
# the description column stepped in and out by two. Every padded cell in this
# file is ASCII for that reason; colour carries the meaning the dot used to.
state_cell() {                  # state_cell <var> <key>
    local _s_c=""
    case "${PSTATE[$2]}" in
        installed) pad _s_c 'installed' $STATEW; printf -v "$1" '%s%s%s' "$GREEN"  "$_s_c" "$R" ;;
        update)    pad _s_c 'update'    $STATEW; printf -v "$1" '%s%s%s' "$YELLOW" "$_s_c" "$R" ;;
        *)         pad _s_c 'new'       $STATEW; printf -v "$1" '%s%s%s' "$DIM"    "$_s_c" "$R" ;;
    esac
}

tab_bar() {                     # tab_bar <var>
    local _t_i _t_t _t_n out=""
    for _t_i in "${!TABS[@]}"; do
        _t_t=${TABS[$_t_i]}; _t_n=${CNT[$_t_t]:-0}
        [ "$_t_n" = 0 ] && _t_n="" || _t_n=" $_t_n"
        if [ "$_t_i" = "$TAB" ]; then out+="${MAUVE}${B} ▌ ${_t_t}${_t_n} ${R}"
        else                          out+="${DIM}   ${_t_t}${_t_n} ${R}"
        fi
    done
    printf -v "$1" '%s' "$out"
}

# Right-hand pane: what the cursor is on, then everything ticked.
detail_lines() {
    local key=${1:-} k s
    OUT=()
    if [ -n "$key" ]; then
        OUT+=("${MAUVE}${B}${NAME[$key]}${R}")
        OUT+=("${DIM}${DESC[$key]}${R}")
        OUT+=("")
        OUT+=("${DIM}menu    ${R}${SECT[$key]}")
        OUT+=("${DIM}package ${R}${PKG[$key]}")
        case "$key" in
            zsh)       OUT+=("${DIM}stows   ${R}~/.zshrc")
                       OUT+=("${DIM}pulls   ${R}starship + every tool") ;;
            bash)      OUT+=("${DIM}stows   ${R}~/.bashrc") ;;
            git)       OUT+=("${DIM}stows   ${R}~/.gitconfig") ;;
            starship)  OUT+=("${DIM}stows   ${R}~/.config/starship.toml") ;;
            protonvpn) OUT+=("${DIM}stows   ${R}~/scripts/pvpn/pvpn.zsh") ;;
            *) [ "${SECT[$key]}" = dotfiles ] && OUT+=("${DIM}stows   ${R}~/.config/${key}/") ;;
        esac
        case "${PSTATE[$key]}" in
            installed) OUT+=("${DIM}state   ${R}${GREEN}● already installed${R}") ;;
            update)    OUT+=("${DIM}state   ${R}${YELLOW}↑ installed, update available${R}") ;;
            *)         OUT+=("${DIM}state   ${R}${DIM}○ will be installed${R}") ;;
        esac
    else
        OUT+=("${DIM}nothing here${R}")
    fi
    OUT+=("")
    OUT+=("${GREEN}${B}TICKED  ${CNT[total]}${R}")
    OUT+=("")
    if [ "${CNT[total]}" = 0 ]; then
        OUT+=("${DIM}space ticks the row you are on${R}")
        return
    fi
    for s in dotfiles tools apps; do
        [ "${CNT[$s]}" = 0 ] && continue
        OUT+=("${TEAL}${s}${R} ${DIM}${CNT[$s]}${R}")
        for k in "${ORDER[@]}"; do
            [ "${TICK[$k]}" = 1 ] && [ "${SECT[$k]}" = "$s" ] \
                && OUT+=("  ${GREEN}✔ ${NAME[$k]}${R}")
        done
    done
}

COLS=100; ROWS=30
measure() { COLS=$(tput cols 2>/dev/null || echo 100); ROWS=$(tput lines 2>/dev/null || echo 30); }

draw() {
    local lw=$(( COLS * 58 / 100 ))
    (( lw < 46 )) && { lw=46; (( COLS < 46 )) && lw=$COLS; }
    local descw=$(( lw - 4 - NAMEW - 1 - STATEW - 2 ))
    (( descw < 6 )) && descw=6

    local body=$(( ROWS - 8 ))
    (( body < 3 )) && body=3
    (( CUR < TOP )) && TOP=$CUR
    (( CUR >= TOP + body )) && TOP=$(( CUR - body + 1 ))
    (( TOP < 0 )) && TOP=0

    recount
    detail_lines "${VIEW[$CUR]:-}"

    local bar; tab_bar bar
    local -a out=()
    out+=("")
    out+=("  ${MAUVE}${B}dotfiles installer${R}")
    out+=("  $bar")
    out+=("")

    local i k row name cell desc tint mark
    for (( i = TOP; i < TOP + body; i++ )); do
        if (( i >= ${#VIEW[@]} )); then
            row=""
        else
            k=${VIEW[$i]}
            if [ "${TICK[$k]}" = 1 ]; then
                mark="${GREEN}${B}[✔]${R}"; tint="$GREEN"
            else
                mark="${DIM}[ ]${R}"; tint="$DIM"
            fi
            pad name "${NAME[$k]}" $NAMEW
            if [ "${TICK[$k]}" = 1 ]; then name="${GREEN}${B}${name}${R}"
            else                           name="${TEXT}${name}${R}"; fi
            state_cell cell "$k"
            desc=${DESC[$k]}
            (( ${#desc} > descw )) && desc="${desc:0:descw-1}…"
            if (( i == CUR )); then row="${MAUVE}❯${R} "; else row="  "; fi
            row+="${mark} ${name} ${cell} ${tint}${desc}${R}"
        fi
        # \033[K wipes whatever the previous frame left between here and the
        # end of the line; \033[<n>G then puts the pane at a fixed column, so
        # however much colour the left row carries it cannot shove it sideways.
        printf -v row '%s\033[K\033[%dG%s%s' "$row" "$(( lw + 2 ))" "${DIM}│${R}  " "${OUT[$(( i - TOP ))]:-}"
        out+=("$row")
    done

    out+=("")
    if [ -n "$FILTER" ]; then
        out+=("  ${DIM}search${R} ${TEXT}${FILTER}${R}${DIM}▏   ${#VIEW[@]} shown · esc clears${R}")
    else
        out+=("  ${DIM}type to search this menu${R}")
    fi
    out+=("  ${DIM}← → menu   ↑ ↓ move   space tick   ctrl-a all   enter confirm   esc cancel${R}")

    # One write per frame: no flicker, nothing half-drawn.
    local frame=$'\033[H'
    for row in "${out[@]}"; do frame+="${row}"$'\033[K\n'; done
    frame+=$'\033[J'
    printf '%s' "$frame"
}

# ── input ────────────────────────────────────────────────────────────────────
switch_tab() {                  # switch_tab <+1|-1|index>
    case "$1" in
        +1) TAB=$(( (TAB + 1) % ${#TABS[@]} )) ;;
        -1) TAB=$(( (TAB - 1 + ${#TABS[@]}) % ${#TABS[@]} )) ;;
        *)  TAB=$1 ;;
    esac
    FILTER=""; CUR=0; TOP=0
    build_view
}

toggle_cur() {
    local k=${VIEW[$CUR]:-}
    [ -n "$k" ] || return
    [ "${TICK[$k]}" = 1 ] && TICK[$k]=0 || TICK[$k]=1
    if [ "${TABS[$TAB]}" = selected ]; then
        build_view                      # the row just left this list
    else
        (( CUR < ${#VIEW[@]} - 1 )) && CUR=$(( CUR + 1 ))
    fi
}

toggle_all() {
    local k all=1
    for k in "${VIEW[@]}"; do [ "${TICK[$k]}" = 1 ] || { all=0; break; }; done
    for k in "${VIEW[@]}"; do [ "$all" = 1 ] && TICK[$k]=0 || TICK[$k]=1; done
    [ "${TABS[$TAB]}" = selected ] && build_view
}

CONFIRMED=0
loop() {
    local key rest rc pending=1
    draw
    while true; do
        # -d '' matters: with the default delimiter, `read -n1` on a newline
        # hands back an empty string, and Enter would never arrive.
        if [ "$pending" = 1 ]; then
            IFS= read -rsn1 -d '' -t 0.2 key; rc=$?
            if [ "$rc" -gt 128 ]; then          # nothing typed — check the scan
                if [ -f "$UPD_READY" ]; then apply_upgrades; pending=0; draw; fi
                continue
            fi
            [ "$rc" -ne 0 ] && break
        else
            IFS= read -rsn1 -d '' key || break
        fi
        case "$key" in
            $'\033')
                rest=""
                IFS= read -rsn2 -d '' -t 0.05 rest
                case "$rest" in
                    '[A') (( CUR > 0 )) && CUR=$(( CUR - 1 )) ;;
                    '[B') (( CUR < ${#VIEW[@]} - 1 )) && CUR=$(( CUR + 1 )) ;;
                    '[C') switch_tab +1 ;;
                    '[D') switch_tab -1 ;;
                    'OP') switch_tab 0 ;;
                    'OQ') switch_tab 1 ;;
                    'OR') switch_tab 2 ;;
                    'OS') switch_tab 3 ;;
                    '[5') IFS= read -rsn1 -d '' -t 0.05 rest
                          CUR=$(( CUR - 10 )); (( CUR < 0 )) && CUR=0 ;;
                    '[6') IFS= read -rsn1 -d '' -t 0.05 rest
                          CUR=$(( CUR + 10 ))
                          (( CUR > ${#VIEW[@]} - 1 )) && CUR=$(( ${#VIEW[@]} - 1 )) ;;
                    '[1'|'[2') IFS= read -rsn3 -d '' -t 0.05 rest ;;
                    '')  if [ -n "$FILTER" ]; then FILTER=""; CUR=0; build_view
                         else return 1; fi ;;
                esac ;;
            # Space ticks and Enter confirms, the usual checkbox-list split. It
            # also sidesteps CR/LF: depending on the terminal's icrnl, Enter
            # arrives as \r or as \n, so no other key can safely own either.
            ' ')          toggle_cur ;;
            $'\r'|$'\n') CONFIRMED=1; return 0 ;;
            $'\001')      toggle_all ;;                            # ctrl-a
            $'\023')      switch_tab 3 ;;                          # ctrl-s
            $'\011')      switch_tab +1 ;;                         # tab
            $'\177'|$'\010') FILTER="${FILTER%?}"; CUR=0; build_view ;;
            $'\003')      return 1 ;;                              # ctrl-c
            [[:print:]])  FILTER+="$key"; CUR=0; build_view ;;
        esac
        draw
    done
    return 1
}

# ── run ──────────────────────────────────────────────────────────────────────
cleanup() {
    printf '\033[?25h\033[?1049l'
    stty "$STTY_SAVE" 2>/dev/null
    [ -n "$UPD_READY" ] && rm -f "$UPD_READY" "${UPD_READY%.ready}"
}

main() {
    parse_items
    scan_installed
    start_upgrade_scan
    build_view
    measure

    STTY_SAVE=$(stty -g 2>/dev/null)
    trap cleanup EXIT INT TERM
    # -echo so typed filter characters do not also land on screen, -icanon so a
    # keypress arrives without waiting for a newline, -icrnl so Enter stays CR
    # and stays distinguishable from ctrl-j (with the default translation both
    # arrive as \n and Enter would confirm instead of tick), -ixon so ctrl-s is
    # a key and not flow control.
    stty -echo -icanon -icrnl -ixon min 1 time 0 2>/dev/null
    printf '\033[?1049h\033[?25l'
    trap 'measure' WINCH
    loop
    local rc=$?
    cleanup; trap - EXIT INT TERM

    if [ "$rc" -ne 0 ] || [ "$CONFIRMED" -ne 1 ]; then
        printf '\n  %s\n\n' "${RED}cancelled${R}"
        return 1
    fi
    printf '\n  %s\n\n' "${MAUVE}${B}selected${R}"
    local s k first n=0
    for s in dotfiles tools apps; do
        first=1
        for k in "${ORDER[@]}"; do
            [ "${TICK[$k]}" = 1 ] && [ "${SECT[$k]}" = "$s" ] || continue
            [ "$first" = 1 ] && { printf '  %s\n' "${TEAL}${s}${R}"; first=0; }
            printf '    %s %-22s %s%s%s\n' "${GREEN}✔${R}" "${NAME[$k]}" \
                "$DIM" "${DESC[$k]}" "$R"
            n=$((n + 1))
        done
        [ "$first" = 0 ] && echo
    done
    [ "$n" = 0 ] && printf '   %s\n\n' "${DIM}nothing${R}"
    return 0
}

main "$@"
