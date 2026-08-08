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

"brave-stable|Brave Origin Stable|chromium browser, no telemetry|apps|brave-origin-bin"
"brave-beta|Brave Origin Beta|the beta channel of the same|apps|brave-origin-beta-bin"
"vscode|Visual Studio Code|the editor|apps|visual-studio-code-bin"
"vscode-insiders|VS Code Insiders|nightly channel|apps|visual-studio-code-insiders-bin"
"antigravity-ide|Antigravity IDE|agentic IDE|apps|antigravity"
"obsidian|Obsidian|markdown knowledge base|apps|obsidian"
"notion|Notion|workspace|apps|notion-app-electron"
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

# The CLI installers drop binaries into their own directories, which are not
# necessarily on the PATH of the shell running this — install.sh searches these
# explicitly for the same reason.
CURL_APP_PATH="$HOME/.local/bin:$HOME/.opencode/bin:$HOME/.kimi-code/bin"
app_present() { PATH="${CURL_APP_PATH}:$PATH" command -v "$1" &>/dev/null; }

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
        if [ -n "${have[$p]:-}" ] || app_present "$p"; then
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
    build_cells
}

# ── view state ───────────────────────────────────────────────────────────────
TAB=0            # index into TABS
CUR=0            # cursor within the visible rows
TOP=0            # first visible row, for scrolling
FILTER=""
declare -a VIEW=()   # keys currently listed

SEC_TOTAL=0
build_view() {
    VIEW=()
    SEC_TOTAL=0
    local sec=${TABS[$TAB]} k f=${FILTER,,} hay
    for k in "${ORDER[@]}"; do
        if [ "$sec" = selected ]; then
            [ "${TICK[$k]}" = 1 ] || continue
        else
            [ "${SECT[$k]}" = "$sec" ] || continue
        fi
        SEC_TOTAL=$(( SEC_TOTAL + 1 ))
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
# Boxes, labels and a details pane — the same frame the fzf version drew, but
# every line is assembled here, so the widths are exact rather than negotiated.
#
# Two rules make the columns hold:
#   · anything that gets padded is ASCII. printf pads %s by bytes, so a cell
#     containing ● or ↑ comes out a different width than one that does not.
#   · colour is wrapped around an already-padded plain string, never inside it.
#
# Nothing below forks. A frame is string building plus one write.
NAMEW=20
STATEW=10

pad() {                         # pad <var> <text> <width>
    local _p_t=$2 _p_w=$3
    (( ${#_p_t} > _p_w )) && _p_t="${_p_t:0:_p_w-1}…"
    printf -v "$1" '%-*s' "$_p_w" "$_p_t"
}

# Padded, coloured cells are built once per state change rather than per frame:
# the name and the state column are the same 35 strings every redraw.
declare -A CELL NPAD_ON NPAD_OFF
build_cells() {
    local k c
    for k in "${ORDER[@]}"; do
        case "${PSTATE[$k]}" in
            installed) pad c 'installed' $STATEW; CELL[$k]="${GREEN}${c}${R}"  ;;
            update)    pad c 'update'    $STATEW; CELL[$k]="${YELLOW}${c}${R}" ;;
            *)         pad c 'new'       $STATEW; CELL[$k]="${DIM}${c}${R}"    ;;
        esac
        pad c "${NAME[$k]}" $NAMEW
        NPAD_ON[$k]="${GREEN}${B}${c}${R}"
        NPAD_OFF[$k]="${TEXT}${c}${R}"
    done
}

# ── box drawing ──────────────────────────────────────────────────────────────
# printf pads in C, a bash loop pads one character at a time — at ~35 rows a
# frame that difference was most of the frame time.
rep() {                         # rep <var> <char> <n>
    local _r_o
    (( $3 <= 0 )) && { printf -v "$1" '%s' ""; return; }
    printf -v _r_o '%*s' "$3" ''
    [ "$2" = ' ' ] || _r_o=${_r_o// /$2}
    printf -v "$1" '%s' "$_r_o"
}

box_top() {                     # box_top <var> <width> <label>
    local _b_l=$3 _b_w=$2 _b_f
    if [ -n "$_b_l" ]; then
        rep _b_f '─' $(( _b_w - 6 - ${#_b_l} ))
        printf -v "$1" '%s╭─ %s%s%s ─%s╮%s' "$DIM" "$TEAL" "$_b_l" "$DIM" "$_b_f" "$R"
    else
        rep _b_f '─' $(( _b_w - 2 ))
        printf -v "$1" '%s╭%s╮%s' "$DIM" "$_b_f" "$R"
    fi
}

box_bottom() {                  # box_bottom <var> <width>
    local _b_f; rep _b_f '─' $(( $2 - 2 ))
    printf -v "$1" '%s╰%s╯%s' "$DIM" "$_b_f" "$R"
}

# A content row: │ + one space + body + padding + one space + │. The body is
# handed in already coloured, with its *plain* length so the padding is right.
box_row() {                     # box_row <var> <width> <body> <plain-length>
    local _b_p="" _b_n=$(( $2 - 4 - $4 ))
    (( _b_n > 0 )) && printf -v _b_p '%*s' "$_b_n" ''
    printf -v "$1" '%s│%s %s%s %s│%s' "$DIM" "$R" "$3" "$_b_p" "$DIM" "$R"
}

# ── right pane content ───────────────────────────────────────────────────────
# Lines are kept as plain text plus a colour, so they can be truncated to the
# pane width without cutting an escape sequence in half.
declare -a PTXT=() PCLR=() PLBL=()
pane_add() {                    # pane_add <text> <colour> [dim-prefix-length]
    PTXT+=("$1"); PCLR+=("$2"); PLBL+=("${3:-0}")
}

pane_build() {                  # pane_build <key>
    local key=${1:-} k s
    PTXT=(); PCLR=(); PLBL=()
    if [ -n "$key" ]; then
        pane_add "${NAME[$key]}" "${MAUVE}${B}"
        pane_add "${DESC[$key]}" "$DIM"
        pane_add "" "$R"
        pane_add "menu     ${SECT[$key]}" "$R" 9
        pane_add "package  ${PKG[$key]}"  "$R" 9
        case "$key" in
            zsh)       pane_add "stows    ~/.zshrc" "$R" 9
                       pane_add "pulls    starship + every tool" "$R" 9 ;;
            bash)      pane_add "stows    ~/.bashrc" "$R" 9 ;;
            git)       pane_add "stows    ~/.gitconfig" "$R" 9 ;;
            starship)  pane_add "stows    ~/.config/starship.toml" "$R" 9 ;;
            protonvpn) pane_add "stows    ~/scripts/pvpn/pvpn.zsh" "$R" 9 ;;
            *) [ "${SECT[$key]}" = dotfiles ] && pane_add "stows    ~/.config/${key}/" "$R" 9 ;;
        esac
        case "${PSTATE[$key]}" in
            installed) pane_add "state    already installed"          "$GREEN"  9 ;;
            update)    pane_add "state    installed, update waiting"  "$YELLOW" 9 ;;
            *)         pane_add "state    will be installed"          "$DIM"    9 ;;
        esac
    else
        pane_add "nothing here" "$DIM"
    fi
    pane_add "" "$R"
    pane_add "TICKED  ${CNT[total]}" "${GREEN}${B}"
    pane_add "" "$R"
    if [ "${CNT[total]}" = 0 ]; then
        pane_add "space or enter ticks a row" "$DIM"
        return
    fi
    for s in dotfiles tools apps; do
        [ "${CNT[$s]}" = 0 ] && continue
        pane_add "${s} ${CNT[$s]}" "$TEAL"
        for k in "${ORDER[@]}"; do
            [ "${TICK[$k]}" = 1 ] && [ "${SECT[$k]}" = "$s" ] \
                && pane_add "  ✔ ${NAME[$k]}" "$GREEN"
        done
    done
}

# The separator is whatever is left over, so the bar fills the box exactly and
# can never overflow it — a bar one column too wide pushed the right border out.
tab_bar() {                     # tab_bar <var> <plain-length var> <inner width>
    local _t_i _t_t _t_n out="" base=0 sep gap label
    local -a labels=()
    for _t_i in "${!TABS[@]}"; do
        _t_t=${TABS[$_t_i]}; _t_n=${CNT[$_t_t]:-0}
        [ "$_t_n" = 0 ] && _t_n="" || _t_n=" $_t_n"
        labels+=("${_t_t}${_t_n}")
        base=$(( base + 2 + ${#_t_t} + ${#_t_n} ))
    done
    sep=$(( ($3 - base) / ${#TABS[@]} ))
    (( sep < 1 )) && sep=1
    (( sep > 5 )) && sep=5
    rep gap ' ' "$sep"
    for _t_i in "${!TABS[@]}"; do
        label=${labels[$_t_i]}
        if [ "$_t_i" = "$TAB" ]; then out+="${MAUVE}${B}▌ ${label}${R}${gap}"
        else                          out+="${DIM}  ${label}${R}${gap}"
        fi
    done
    printf -v "$1" '%s' "$out"
    printf -v "$2" '%s' "$(( base + sep * ${#TABS[@]} ))"
}

# ── geometry ─────────────────────────────────────────────────────────────────
COLS=80; ROWS=24
measure() {
    local sz=""
    # stty, not tput: tput needs a terminfo entry for $TERM and simply fails on
    # a terminal it has never heard of, and a frame drawn to the wrong size
    # wraps every line and scrolls the screen to pieces.
    sz=$(stty size 2>/dev/null </dev/tty) || sz=""
    if [[ "$sz" =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]]; then
        ROWS=${BASH_REMATCH[1]}; COLS=${BASH_REMATCH[2]}
    else
        ROWS=$(tput lines 2>/dev/null) || ROWS=24
        COLS=$(tput cols  2>/dev/null) || COLS=80
    fi
    [[ "$ROWS" =~ ^[0-9]+$ ]] || ROWS=24
    [[ "$COLS" =~ ^[0-9]+$ ]] || COLS=80
    (( ROWS < 14 )) && ROWS=14
    (( COLS < 60 )) && COLS=60
}

draw() {
    local lw=$(( COLS * 60 / 100 ))
    local rw=$(( COLS - lw - 1 ))
    (( rw > 46 )) && { rw=46; lw=$(( COLS - rw - 1 )); }
    (( rw < 24 )) && { rw=24; lw=$(( COLS - rw - 1 )); }
    local liw=$(( lw - 4 ))          # inner text width, list box
    local riw=$(( rw - 4 ))          # inner text width, pane
    local descw=$(( liw - 2 - 3 - 1 - NAMEW - 1 - STATEW - 1 ))
    (( descw < 6 )) && descw=6

    # 3 boxes stacked on the left: search (3), sections (3), list. Plus one
    # footer line and one blank. The list box gets whatever is left.
    local body=$(( ROWS - 10 ))
    (( body < 3 )) && body=3
    (( CUR < TOP )) && TOP=$CUR
    (( CUR >= TOP + body )) && TOP=$(( CUR - body + 1 ))
    (( TOP < 0 )) && TOP=0

    recount
    pane_build "${VIEW[$CUR]:-}"

    local -a L=() Rr=()
    local t bar barlen line plain n

    # ── left: search box ──
    box_top t "$lw" "search"; L+=("$t")
    if [ -n "$FILTER" ]; then
        plain="${FILTER}▏"
        printf -v line '%s%s%s' "$TEXT" "$plain" "$R"
    else
        plain="type to search this menu"
        printf -v line '%s%s%s' "$DIM" "$plain" "$R"
    fi
    n="${#VIEW[@]}/${SEC_TOTAL}"
    local gap=$(( liw - ${#plain} - ${#n} ))
    (( gap < 1 )) && gap=1
    local sp; rep sp ' ' "$gap"
    box_row t "$lw" "${line}${sp}${DIM}${n}${R}" $(( ${#plain} + gap + ${#n} )); L+=("$t")
    box_bottom t "$lw"; L+=("$t")

    # ── left: sections box ──
    box_top t "$lw" "sections"; L+=("$t")
    tab_bar bar barlen "$liw"
    box_row t "$lw" "$bar" "$barlen"; L+=("$t")
    box_bottom t "$lw"; L+=("$t")

    # ── left: the list ──
    box_top t "$lw" "${TABS[$TAB]}"; L+=("$t")
    local i k mark name cell desc tint cursor
    for (( i = TOP; i < TOP + body; i++ )); do
        if (( i >= ${#VIEW[@]} )); then
            box_row t "$lw" "" 0
        else
            k=${VIEW[$i]}
            if [ "${TICK[$k]}" = 1 ]; then
                mark="${GREEN}${B}[✔]${R}"; tint="$GREEN"
            else
                mark="${DIM}[ ]${R}"; tint="$DIM"
            fi
            if [ "${TICK[$k]}" = 1 ]; then name=${NPAD_ON[$k]}; else name=${NPAD_OFF[$k]}; fi
            cell=${CELL[$k]}
            desc=${DESC[$k]}
            (( ${#desc} > descw )) && desc="${desc:0:descw-1}…"
            if (( i == CUR )); then cursor="${MAUVE}❯${R} "; else cursor="  "; fi
            box_row t "$lw" "${cursor}${mark} ${name} ${cell} ${tint}${desc}${R}" \
                $(( 2 + 3 + 1 + NAMEW + 1 + STATEW + 1 + ${#desc} ))
        fi
        L+=("$t")
    done
    box_bottom t "$lw"; L+=("$t")

    # ── right: the pane, same height as everything on the left ──
    local pane_h=$(( ${#L[@]} ))
    box_top t "$rw" "details"; Rr+=("$t")
    for (( i = 0; i < pane_h - 2; i++ )); do
        plain="${PTXT[$i]:-}"
        (( ${#plain} > riw )) && plain="${plain:0:riw-1}…"
        if (( ${PLBL[$i]:-0} > 0 )); then
            box_row t "$rw" "${DIM}${plain:0:${PLBL[$i]}}${R}${PCLR[$i]}${plain:${PLBL[$i]}}${R}" "${#plain}"
        else
            box_row t "$rw" "${PCLR[$i]:-}${plain}${R}" "${#plain}"
        fi
        Rr+=("$t")
    done
    box_bottom t "$rw"; Rr+=("$t")

    # ── one write ──
    local frame=$'\033[H'
    for (( i = 0; i < ${#L[@]}; i++ )); do
        frame+="${L[$i]} ${Rr[$i]:-}"$'\033[K\n'
    done
    frame+="  ${DIM}← → menu   ↑ ↓ move   space / enter tick   ctrl-a all   ctrl-d review, then run   esc cancel${R}"
    frame+=$'\033[K\033[J'
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
            # Space and Enter both tick. Enter arrives as \r or as \n depending
            # on the terminal's icrnl, and ctrl-j is \n either way, so nothing
            # else can own either byte — confirm gets its own key.
            ' '|$'\r'|$'\n') toggle_cur ;;
            # ctrl-d from a menu goes to `selected` first — one look at the
            # whole list before anything runs. ctrl-d again, from there, runs it.
            $'\004')         if [ "${TABS[$TAB]}" = selected ]; then
                              CONFIRMED=1; return 0
                          else switch_tab 3; fi ;;
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
    build_cells
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
