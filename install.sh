#!/usr/bin/env bash

# ── Interpreter guard ─────────────────────────────────────────────────────────
# Must stay POSIX until the re-exec below. On Debian and Ubuntu /bin/sh is dash,
# so 'sh install.sh' ignores the shebang and dies on the first array — which
# looks exactly like "the installer does not run on servers". Re-exec instead.
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi
# Namerefs (declare -n) need 4.3+; every supported distro ships 5.x.
if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 3 ]; }; then
    echo "This installer needs bash 4.3 or newer (found ${BASH_VERSION})." >&2
    exit 1
fi

# ── Arguments ─────────────────────────────────────────────────────────────────
# Parsed before distro detection, so --help answers on a machine this installer
# does not support rather than being pre-empted by the "Arch, Debian and Ubuntu
# only" exit.
#
# A case, not a list of tests. Unrecognised flags used to be ignored in silence,
# which meant `--dryrun` — or any other near miss — ran a real install, and a
# real install can delete existing configs. Anything unknown is now an error.
DRY_RUN=0
FORCE_GUI=0
RESTORE_BASH=0
OPT_ASCII=0
OPT_NO_COLOR=0
PICK_CONFIGS=""
PICK_TOOLS=""
PICK_APPS=""

usage() {
    cat <<'USAGE'
Dotfiles installer — Arch Linux, Debian and Ubuntu.

  bash install.sh [options]

Options:
  --dry-run        Print the plan and exit without changing anything.
  --gui            Offer the GUI configs and apps even with no display server.
  --restore-bash   Undo the zsh setup: the rc files, the .bashrc hand-off hook
                   and the login shell. Runs alone and skips every menu.
  --ascii          Plain ASCII instead of Nerd Font glyphs.
  --no-color       No colour. NO_COLOR is honoured too.
  --configs=LIST   Skip the menu and take these configs. Comma-separated,
                   or "all". --tools=LIST and --apps=LIST do the same for the
                   dep tools and the applications. Any of the three may be
                   left out, which means "none of those".
  -h, --help       This text.

Reached through the hosted bootstrap there is no argv to put a flag in, so each
one also has an environment variable:

  DOTFILES_DRY_RUN   DOTFILES_GUI     DOTFILES_RESTORE_BASH
  DOTFILES_ASCII     DOTFILES_NO_COLOR
  DOTFILES_CONFIGS   DOTFILES_TOOLS   DOTFILES_APPS

  DOTFILES_GUI=1 curl -fsSL https://abhiman.io/linux.sh | bash
USAGE
}

for _arg in "$@"; do
    case "$_arg" in
        --dry-run)      DRY_RUN=1 ;;
        --gui)          FORCE_GUI=1 ;;
        --restore-bash) RESTORE_BASH=1 ;;
        --ascii)        OPT_ASCII=1 ;;
        --no-color)     OPT_NO_COLOR=1 ;;
        --configs=*)    PICK_CONFIGS="${_arg#*=}" ;;
        --tools=*)      PICK_TOOLS="${_arg#*=}" ;;
        --apps=*)       PICK_APPS="${_arg#*=}" ;;
        -h|--help)      usage; exit 0 ;;
        *)
            echo "Unknown option: $_arg" >&2
            echo "" >&2
            usage >&2
            exit 2 ;;
    esac
done
unset _arg

# The environment is the only channel that survives `curl … | bash`.
# (Verified against the hosted copy, which is deployed by hand and can lag.)
[ -n "${DOTFILES_DRY_RUN:-}" ]      && DRY_RUN=1
[ -n "${DOTFILES_GUI:-}" ]          && FORCE_GUI=1
[ -n "${DOTFILES_RESTORE_BASH:-}" ] && RESTORE_BASH=1
[ -n "${DOTFILES_ASCII:-}" ]        && OPT_ASCII=1
[ -n "${DOTFILES_NO_COLOR:-}" ]     && OPT_NO_COLOR=1
[ -n "${DOTFILES_CONFIGS:-}" ]      && PICK_CONFIGS="$DOTFILES_CONFIGS"
[ -n "${DOTFILES_TOOLS:-}" ]        && PICK_TOOLS="$DOTFILES_TOOLS"
[ -n "${DOTFILES_APPS:-}" ]         && PICK_APPS="$DOTFILES_APPS"

# ── Distro detection ──────────────────────────────────────────────────────────
DISTRO=""
IS_UBUNTU=0

if [ -f /etc/arch-release ]; then
    DISTRO="arch"
else
    # Read in subshells: sourcing os-release directly dumps NAME, VERSION,
    # PRETTY_NAME and a dozen more variables into this script's namespace.
    _os_id="" _os_id_like=""
    if [ -f /etc/os-release ]; then
        _os_id="$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}")"
        _os_id_like="$(. /etc/os-release 2>/dev/null && printf '%s' "${ID_LIKE:-}")"
    fi
    if [[ "$_os_id" == "arch" || "$_os_id_like" == *arch* ]]; then
        DISTRO="arch"
    elif [[ "$_os_id" == "ubuntu" || "$_os_id_like" == *ubuntu* ]]; then
        DISTRO="debian"; IS_UBUNTU=1
    elif [[ "$_os_id" == "debian" || "$_os_id_like" == *debian* ]]; then
        DISTRO="debian"
    fi
    unset _os_id _os_id_like
fi

if [ -z "$DISTRO" ]; then
    echo "This installer supports Arch Linux, Debian, and Ubuntu only." >&2
    exit 1
fi

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
START_TS=$SECONDS

# ── Headless detection ────────────────────────────────────────────────────────
# On a cloud VPS or a container there is no display server, so terminal
# emulators, the launchers and every GUI app are unusable — and pull hundreds of
# MB of X/GTK libraries to sit unused. Detect it and drop them from the menus.
# --gui forces the full desktop menus (e.g. provisioning a box before its DE).
# WSL runs a real Ubuntu/Debian userland under Windows. Package installs behave
# normally; what differs is that the terminal is a Windows program, so fonts
# have to be installed on the Windows side to have any effect.
IS_WSL=0
if [ -n "${WSL_DISTRO_NAME:-}" ] || [ -d /run/WSL ] \
   || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
    IS_WSL=1
fi

IS_HEADLESS=0
detect_headless() {
    # A live display server is conclusive
    [ -n "${DISPLAY:-}" ]         && return 1
    [ -n "${WAYLAND_DISPLAY:-}" ] && return 1

    # Installed session files are the only other trustworthy signal.
    #
    # The systemd default target is not, and used to be checked here: Ubuntu
    # server images ship graphical.target with no desktop installed at all, so
    # every such VPS looked like a workstation — GUI configs offered, and both
    # Nerd Fonts downloaded onto a machine with nothing to render them.
    local _d
    for _d in /usr/share/xsessions /usr/share/wayland-sessions; do
        [ -d "$_d" ] && find "$_d" -name '*.desktop' -print -quit 2>/dev/null | grep -q . && return 1
    done
    return 0
}
detect_headless && IS_HEADLESS=1
[ "$FORCE_GUI" -eq 1 ] && IS_HEADLESS=0

# Remove every listed item from the named array (headless GUI filtering)
strip_items() {
    local -n _target="$1"; shift
    local _keep=() _item _drop _skip
    for _item in "${_target[@]}"; do
        _skip=0
        for _drop in "$@"; do [[ "$_item" == "$_drop" ]] && { _skip=1; break; }; done
        [ "$_skip" -eq 0 ] && _keep+=("$_item")
    done
    _target=("${_keep[@]}")
}

GUI_CONFIGS=(ghostty kitty rofi ulauncher)
GUI_APPS=(brave-beta brave-stable vscode vscode-insiders antigravity-ide antigravity notion obsidian claude-desktop alacritty wezterm vicinae vlc obs-studio zoom)

# No fallback to a shared /tmp. Everything below writes here — the bashrc
# rewrite, downloaded keyrings that get sudo-installed into /etc — and in a
# world-writable directory those become predictable paths an attacker can
# pre-plant a symlink at. If a private temp dir cannot be made, stop.
RUN_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-install_XXXXXX" 2>/dev/null)" || {
    echo "Could not create a private temporary directory — refusing to run." >&2
    exit 1
}

# Everything the run downloads goes under RUN_TMPDIR, so an interrupt mid-install
# does not leave .deb files and unpacked tarballs behind in /tmp.
_cleanup() {
    # Kill the sleep the keepalive forked before the loop itself: killing only
    # the subshell reparents a live sleep to init, where it sits for up to four
    # minutes after we are gone.
    # First, so an interrupt inside the menu leaves a terminal that still echoes.
    tui_cleanup 2>/dev/null
    if [ -n "${_SUDO_KEEPALIVE:-}" ]; then
        pkill -P "$_SUDO_KEEPALIVE" 2>/dev/null
        kill "$_SUDO_KEEPALIVE" 2>/dev/null
    fi
    [ "${RUN_TMPDIR:-/tmp}" != "/tmp" ] && rm -rf "$RUN_TMPDIR"
    echo -ne "\033[0m"
}

# A trap that only cleans up does not stop anything: bash runs the handler and
# then carries on with the next command, so Ctrl-C during a wait printed the
# cleanup and went straight back to waiting. Interrupt has to exit — the EXIT
# trap then does the cleanup exactly once.
_interrupt() {
    trap - INT TERM
    echo -e "\n${C_MAIN:-}${C_BOLD:-} ${G_END:-} ${C_RED:-}${G_FAIL:-} ${C_RESET:-}Interrupted — nothing further was changed.\n"
    exit 130
}
trap _cleanup EXIT
trap _interrupt INT TERM

# ── Interactive input source ──────────────────────────────────────────────────
# Every prompt must read from the terminal, never stdin: reached through
# `curl … | bash` (the documented bootstrap path) stdin is the download stream,
# so a plain `read` silently eats script text instead of waiting for input.
# The permission test is not enough: with no controlling terminal (setsid, a
# detached session, some CI runners) /dev/tty exists and is mode 0666, so
# [ -r /dev/tty ] passes while every open fails with ENXIO. Each prompt then
# returns instantly with an empty answer and the run charges through the menus
# on garbage. Actually open it.
if { : < /dev/tty; } 2>/dev/null; then
    TTY_IN=/dev/tty
elif [ -t 0 ]; then
    TTY_IN=/dev/stdin
else
    echo "This installer is interactive and needs a terminal." >&2
    echo "Clone the repo and run it directly:  bash install.sh" >&2
    exit 1
fi

# ── Terminal capabilities ─────────────────────────────────────────────────────
# A server console is not a desktop terminal. The Linux VT ignores 24-bit
# colour, a non-UTF-8 locale turns every box-drawing character into garbage,
# and no server has a Nerd Font installed — which is why this UI arrives as a
# wall of tofu over SSH. Detect the cases that are actually detectable and fall
# back to plain ASCII. --ascii and --no-color force it; NO_COLOR is honoured.
USE_COLOR=1
USE_GLYPHS=1
[ "$OPT_ASCII" -eq 1 ]    && USE_GLYPHS=0
[ "$OPT_NO_COLOR" -eq 1 ] && USE_COLOR=0
[ -n "${NO_COLOR:-}" ] && USE_COLOR=0
case "${TERM:-}" in
    dumb|linux|vt*|"") USE_COLOR=0; USE_GLYPHS=0 ;;
esac
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8*|*utf-8*|*UTF8*|*utf8*) : ;;
    *) USE_GLYPHS=0 ;;
esac
[ -t 1 ] || { USE_COLOR=0; USE_GLYPHS=0; }

if [ "$USE_GLYPHS" -eq 1 ]; then
    G_TOP='╭─' ; G_MID='│'  ; G_END='╰─'
    G_ARROW='❯'; G_OK='✔'   ; G_FAIL='✘'
    G_INFO='󰓅' ; G_SUM='󰄴'  ; G_RULE='─' ; G_DOT='·' ; G_PICK='●'
    # Menu-only glyphs. Every one of these is a single column wide, which the
    # menu's padding depends on — G_OK is not reused for the checkbox because
    # its ASCII form is '[ok]', four columns inside a three-column box.
    G_BTL='╭'  ; G_BTR='╮' ; G_BBL='╰' ; G_BBR='╯' ; G_BH='─' ; G_BV='│'
    G_TAB='▌'  ; G_TICK='✔'; G_ELLIPSIS='…'
    G_LEFT='←' ; G_RIGHT='→' ; G_UP='↑' ; G_DOWN='↓'
else
    G_TOP='+-' ; G_MID='|'  ; G_END='+-'
    G_ARROW='>'; G_OK='[ok]'; G_FAIL='[!]'
    G_INFO='*' ; G_SUM='='  ; G_RULE='-' ; G_DOT='.' ; G_PICK='x'
    G_BTL='+'  ; G_BTR='+' ; G_BBL='+' ; G_BBR='+' ; G_BH='-' ; G_BV='|'
    G_TAB='>'  ; G_TICK='x'; G_ELLIPSIS='~'
    G_LEFT='<' ; G_RIGHT='>' ; G_UP='^' ; G_DOWN='v'
fi

# ── Palette ───────────────────────────────────────────────────────────────────
# $'…', so these hold a real escape character rather than the four letters
# \033 waiting for an `echo -e` to expand them. Every `echo -e` here is unchanged
# by that — it passes a real escape straight through — and the menu, which
# builds a whole frame and writes it with one `printf '%s'`, would otherwise
# print the escapes as visible text.
C_MAIN=$'\033[38;2;202;169;224m'
C_ACCENT=$'\033[38;2;145;177;240m'
C_DIM=$'\033[38;2;129;122;150m'
C_GREEN=$'\033[38;2;166;209;137m'
C_YELLOW=$'\033[38;2;229;200;144m'
C_RED=$'\033[38;2;231;130;132m'
C_TEAL=$'\033[38;2;148;226;213m'
C_BOLD=$'\033[1m'
C_RESET=$'\033[0m'

if [ "$USE_COLOR" -eq 0 ]; then
    C_MAIN='' C_ACCENT='' C_DIM='' C_GREEN='' C_YELLOW='' C_RED='' C_TEAL='' C_BOLD='' C_RESET=''
fi

# ── UI helpers ────────────────────────────────────────────────────────────────
header() {
    [ "$USE_COLOR" -eq 1 ] && clear
    local _rule=""; local _i
    for ((_i = 0; _i < 54; _i++)); do _rule+="$G_RULE"; done
    echo ""
    echo -e "${C_MAIN}  ${_rule}${C_RESET}"
    echo -e "        ${C_ACCENT}${C_BOLD}${G_SUM}  D O T F I L E S${C_RESET}  ${C_DIM}${G_DOT}${C_RESET}  ${C_TEAL}${C_BOLD}I N S T A L L E R${C_RESET}"
    echo -e "${C_MAIN}  ${_rule}${C_RESET}"
    echo ""
    local _distro_label
    case "$DISTRO" in
        arch)   _distro_label="Arch Linux" ;;
        debian) [ "$IS_UBUNTU" -eq 1 ] && _distro_label="Ubuntu" || _distro_label="Debian" ;;
    esac
    [ "$IS_WSL" -eq 1 ] && _distro_label="${_distro_label} on WSL"
    echo -e "      ${C_DIM}${_distro_label}  ${G_DOT}  GNU Stow  ${G_DOT}  Catppuccin Mocha${C_RESET}"
    if [ "$IS_HEADLESS" -eq 1 ]; then
        echo ""
        echo -e "      ${C_YELLOW}headless — no display server detected${C_RESET}"
        echo -e "      ${C_DIM}GUI configs and apps hidden  ${G_DOT}  pass --gui to show them${C_RESET}"
    fi
    echo ""
}

info()    { echo -e "${C_MAIN}${C_BOLD} ${G_TOP} ${G_INFO} $1${C_RESET}"; }
substep() { echo -e "${C_MAIN}${C_BOLD} ${G_MID}  ${C_DIM}${G_ARROW} ${C_RESET}$1"; }
success() { echo -e "${C_MAIN}${C_BOLD} ${G_END} ${C_GREEN}${G_OK} ${C_RESET}$1\n"; }
error()   { echo -e "${C_MAIN}${C_BOLD} ${G_END} ${C_RED}${G_FAIL} ${C_RESET}$1\n"; }

# ── The menu ─────────────────────────────────────────────────────────────────
# One screen with four tabs — dotfiles, tools, apps, and what you have ticked.
# It replaces three separate fzf multi-selects, and it is drawn here rather than
# shelled out to because the shelling out was the slow part: a redraw is string
# building plus one write, with no process started after the first frame.
#
# Two rules keep the columns straight, and both were bugs first:
#   · anything that gets padded is ASCII. printf pads %s by bytes, so a cell
#     holding ● or a Nerd Font glyph comes out a different width than one that
#     does not, and every column after it steps sideways.
#   · colour wraps an already-padded plain string, never goes inside one.
TUI_ROWS=24; TUI_COLS=80
TUI_NAMEW=20; TUI_STATEW=10

# stty, not tput: tput needs a terminfo entry for $TERM and fails outright on a
# terminal it has never heard of, and a frame drawn to the wrong size wraps
# every line and scrolls the screen to pieces.
tui_size() {
    local sz=""
    sz=$(stty size <"$TTY_IN" 2>/dev/null) || sz=""
    if [[ "$sz" =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]]; then
        TUI_ROWS=${BASH_REMATCH[1]}; TUI_COLS=${BASH_REMATCH[2]}
    else
        TUI_ROWS=$(tput lines 2>/dev/null) || return 1
        TUI_COLS=$(tput cols  2>/dev/null) || return 1
    fi
    [[ "$TUI_ROWS" =~ ^[0-9]+$ ]] && [[ "$TUI_COLS" =~ ^[0-9]+$ ]] || return 1
    (( TUI_ROWS >= 14 )) && (( TUI_COLS >= 60 ))
}

# Deliberately hard to fail into the fallback: colour and glyphs are adapted
# rather than bailed on, so only a terminal that genuinely cannot show this —
# no tty, no size, or one that says outright that it cannot draw — gets the
# numbered list instead.
tui_available() {
    [ -r "$TTY_IN" ] || return 1
    case "${TERM:-}" in ''|dumb|unknown) return 1 ;; esac
    tui_size
}

# ── item table ───────────────────────────────────────────────────────────────
# Built once from the same arrays and maps the rest of the script uses, so a new
# config or app shows up here by being added there.
declare -a T_KEY=() T_NAME=() T_DESC=() T_SEC=() T_PKG=() T_TICK=()
declare -a T_STATE=() T_CELL=() T_NPAD_ON=() T_NPAD_OFF=()

tui_add() {                     # tui_add <key> <name> <desc> <section> <package>
    T_KEY+=("$1"); T_NAME+=("$2"); T_DESC+=("$3"); T_SEC+=("$4"); T_PKG+=("$5")
    T_TICK+=(0);   T_STATE+=(new)
}

tui_build_items() {
    local k
    for k in "${CONFIGS[@]}";   do tui_add "$k" "$k" "${CONFIG_DESC[$k]}" dotfiles "${PKG_MAP[$k]}"; done
    for k in "${DEPS_LIST[@]}"; do tui_add "$k" "$k" "${DEP_DESC[$k]}"    tools    "$(dep_pkg_name "$k")"; done
    for k in "${APPS_LIST[@]}"; do
        local _p
        if [[ "$(app_type_resolved "$k")" == "curl" ]]; then
            _p="${APP_BIN[$k]:-$k}"
        else
            _p="$(app_pkg_name "$k")"
        fi
        tui_add "$k" "${APP_LABEL[$k]}" "${APP_DESC[$k]:-}" apps "$_p"
    done
}

# ── install state ────────────────────────────────────────────────────────────
# Split by cost. "What is installed" is a single local dump and happens before
# the first frame; "what has an update" costs ~170ms on pacman and seconds on
# `apt list --upgradable`, so it runs in the background and the rows fill in
# when it lands. The menu is usable immediately either way.
TUI_UPD_READY=""
TUI_UPD_PID=""

tui_scan_installed() {
    local -A have=()
    local name i p
    if [[ "$DISTRO" == "arch" ]]; then
        while read -r name _; do have[$name]=1; done < <(pacman -Q 2>/dev/null)
    else
        while read -r name _; do have[$name]=1; done \
            < <(dpkg-query -W -f '${Package} ${Status}\n' 2>/dev/null | grep ' installed$')
    fi
    for i in "${!T_KEY[@]}"; do
        p="${T_PKG[$i]}"
        if [ -n "${have[$p]:-}" ] || curl_app_installed "$p" \
           || { [ -n "${PKG_BIN[$p]:-}" ] && command -v "${PKG_BIN[$p]}" &>/dev/null; }; then
            T_STATE[$i]=installed
        else
            T_STATE[$i]=new
        fi
    done
}

tui_start_upgrade_scan() {
    local tmp; tmp=$(mktemp -p "$RUN_TMPDIR" upd_XXXXXX)
    TUI_UPD_READY="${tmp}.ready"
    # The redirect is on the whole block, not just the scan inside it: when
    # tui_cleanup kills this, bash announces the dead job from in here
    # ("Terminated  apt list --upgradable | ...") and the mv below can lose its
    # race with cleanup's rm and complain about a file that is already gone.
    # Both would land on the terminal we have just put back.
    {
        if [[ "$DISTRO" == "arch" ]]; then
            pacman -Qu 2>/dev/null | cut -d' ' -f1 > "$tmp"
        else
            apt list --upgradable 2>/dev/null | cut -d/ -f1 > "$tmp"
        fi
        # Renamed only once complete, so a half-written file is never read.
        mv "$tmp" "$TUI_UPD_READY"
    } 2>/dev/null &
    TUI_UPD_PID=$!
}

tui_apply_upgrades() {
    local -A upd=()
    local name i
    while read -r name; do [ -n "$name" ] && upd[$name]=1; done < "$TUI_UPD_READY"
    rm -f "$TUI_UPD_READY"
    for i in "${!T_KEY[@]}"; do
        [ "${T_STATE[$i]}" = installed ] && [ -n "${upd[${T_PKG[$i]}]:-}" ] && T_STATE[$i]=update
    done
    tui_build_cells
}

# ── cells ────────────────────────────────────────────────────────────────────
# The padded name and the state column are the same strings every redraw, so
# they are built once per state change instead of once per frame.
tui_pad() {                     # tui_pad <var> <text> <width>
    local _p_t=$2 _p_w=$3
    (( ${#_p_t} > _p_w )) && _p_t="${_p_t:0:_p_w-1}$G_ELLIPSIS"
    printf -v "$1" '%-*s' "$_p_w" "$_p_t"
}

tui_build_cells() {
    local i c
    T_CELL=(); T_NPAD_ON=(); T_NPAD_OFF=()
    for i in "${!T_KEY[@]}"; do
        case "${T_STATE[$i]}" in
            installed) tui_pad c 'installed' $TUI_STATEW; T_CELL+=("${C_GREEN}${c}${C_RESET}")  ;;
            update)    tui_pad c 'update'    $TUI_STATEW; T_CELL+=("${C_YELLOW}${c}${C_RESET}") ;;
            *)         tui_pad c 'new'       $TUI_STATEW; T_CELL+=("${C_DIM}${c}${C_RESET}")    ;;
        esac
        tui_pad c "${T_NAME[$i]}" $TUI_NAMEW
        T_NPAD_ON+=("${C_GREEN}${C_BOLD}${c}${C_RESET}")
        T_NPAD_OFF+=("${c}")
    done
}

# ── view ─────────────────────────────────────────────────────────────────────
TUI_TABS=(dotfiles tools apps selected)
TUI_TAB=0; TUI_CUR=0; TUI_TOP=0; TUI_FILTER=""; TUI_TOTAL=0
declare -a TUI_VIEW=()
declare -A TUI_CNT=()

tui_build_view() {
    TUI_VIEW=(); TUI_TOTAL=0
    local sec=${TUI_TABS[$TUI_TAB]} i f=${TUI_FILTER,,} hay
    for i in "${!T_KEY[@]}"; do
        if [ "$sec" = selected ]; then
            [ "${T_TICK[$i]}" = 1 ] || continue
        else
            [ "${T_SEC[$i]}" = "$sec" ] || continue
        fi
        TUI_TOTAL=$(( TUI_TOTAL + 1 ))
        if [ -n "$f" ]; then
            hay="${T_NAME[$i]} ${T_DESC[$i]}"
            [[ "${hay,,}" == *"$f"* ]] || continue
        fi
        TUI_VIEW+=("$i")
    done
    (( TUI_CUR >= ${#TUI_VIEW[@]} )) && TUI_CUR=$(( ${#TUI_VIEW[@]} - 1 ))
    (( TUI_CUR < 0 )) && TUI_CUR=0
}

tui_recount() {
    local i s
    for s in "${TUI_TABS[@]}"; do TUI_CNT[$s]=0; done
    TUI_CNT[total]=0
    for i in "${!T_KEY[@]}"; do
        [ "${T_TICK[$i]}" = 1 ] || continue
        s=${T_SEC[$i]}
        TUI_CNT[$s]=$(( ${TUI_CNT[$s]} + 1 ))
        TUI_CNT[selected]=$(( ${TUI_CNT[selected]} + 1 ))
        TUI_CNT[total]=$(( ${TUI_CNT[total]} + 1 ))
    done
}

# ── boxes ────────────────────────────────────────────────────────────────────
tui_rep() {                     # tui_rep <var> <char> <n>
    local _r_o
    (( $3 <= 0 )) && { printf -v "$1" '%s' ""; return; }
    printf -v _r_o '%*s' "$3" ''
    [ "$2" = ' ' ] || _r_o=${_r_o// /$2}
    printf -v "$1" '%s' "$_r_o"
}

tui_box_top() {                 # tui_box_top <var> <width> <label>
    local _b_f
    if [ -n "$3" ]; then
        tui_rep _b_f "$G_BH" $(( $2 - 6 - ${#3} ))
        printf -v "$1" '%s%s%s %s%s%s %s%s%s%s' \
            "$C_DIM" "$G_BTL" "$G_BH" "$C_TEAL" "$3" "$C_DIM" "$G_BH" "$_b_f" "$G_BTR" "$C_RESET"
    else
        tui_rep _b_f "$G_BH" $(( $2 - 2 ))
        printf -v "$1" '%s%s%s%s%s' "$C_DIM" "$G_BTL" "$_b_f" "$G_BTR" "$C_RESET"
    fi
}

tui_box_bottom() {              # tui_box_bottom <var> <width>
    local _b_f; tui_rep _b_f "$G_BH" $(( $2 - 2 ))
    printf -v "$1" '%s%s%s%s%s' "$C_DIM" "$G_BBL" "$_b_f" "$G_BBR" "$C_RESET"
}

# A content row: border, space, body, padding, space, border. The body arrives
# already coloured, with its *plain* length, which is what the padding uses.
tui_box_row() {                 # tui_box_row <var> <width> <body> <plain-length>
    local _b_p="" _b_n=$(( $2 - 4 - $4 ))
    (( _b_n > 0 )) && printf -v _b_p '%*s' "$_b_n" ''
    printf -v "$1" '%s%s%s %s%s %s%s%s' \
        "$C_DIM" "$G_BV" "$C_RESET" "$3" "$_b_p" "$C_DIM" "$G_BV" "$C_RESET"
}

# ── right pane ───────────────────────────────────────────────────────────────
# Kept as plain text plus a colour so it can be truncated to the pane width
# without cutting an escape sequence in half.
declare -a TUI_PTXT=() TUI_PCLR=() TUI_PLBL=()
tui_pane_add() { TUI_PTXT+=("$1"); TUI_PCLR+=("$2"); TUI_PLBL+=("${3:-0}"); }

tui_pane_build() {              # tui_pane_build <item index or empty>
    local idx=${1:-} i s key
    TUI_PTXT=(); TUI_PCLR=(); TUI_PLBL=()
    if [ -n "$idx" ]; then
        key="${T_KEY[$idx]}"
        tui_pane_add "${T_NAME[$idx]}" "${C_ACCENT}${C_BOLD}"
        [ -n "${T_DESC[$idx]}" ] && tui_pane_add "${T_DESC[$idx]}" "$C_DIM"
        tui_pane_add "" "$C_RESET"
        tui_pane_add "menu     ${T_SEC[$idx]}" "$C_RESET" 9
        tui_pane_add "package  ${T_PKG[$idx]}" "$C_RESET" 9
        if [ "${T_SEC[$idx]}" = dotfiles ]; then
            local _t
            case "$key" in
                zsh)       _t="~/.zshrc" ;;
                bash)      _t="~/.bashrc" ;;
                git)       _t="~/.gitconfig" ;;
                starship)  _t="~/.config/starship.toml" ;;
                protonvpn) _t="~/scripts/pvpn/pvpn.zsh" ;;
                *)         _t="~/.config/${key}/" ;;
            esac
            tui_pane_add "stows    ${_t}" "$C_RESET" 9
            [ "$key" = zsh ] && tui_pane_add "pulls    starship + the tools" "$C_RESET" 9
            [ "$key" = ccstatusline ] && tui_pane_add "pulls    bun (renders it)" "$C_RESET" 9
        fi
        case "${T_STATE[$idx]}" in
            installed) tui_pane_add "state    already installed"         "$C_GREEN"  9 ;;
            update)    tui_pane_add "state    installed, update waiting" "$C_YELLOW" 9 ;;
            *)         tui_pane_add "state    will be installed"         "$C_DIM"    9 ;;
        esac
    fi
    tui_pane_add "" "$C_RESET"
    tui_pane_add "TICKED  ${TUI_CNT[total]}" "${C_GREEN}${C_BOLD}"
    tui_pane_add "" "$C_RESET"
    if [ "${TUI_CNT[total]}" = 0 ]; then
        tui_pane_add "space or enter ticks a row" "$C_DIM"
        return
    fi
    for s in dotfiles tools apps; do
        [ "${TUI_CNT[$s]}" = 0 ] && continue
        tui_pane_add "${s} ${TUI_CNT[$s]}" "$C_TEAL"
        for i in "${!T_KEY[@]}"; do
            [ "${T_TICK[$i]}" = 1 ] && [ "${T_SEC[$i]}" = "$s" ] \
                && tui_pane_add "  ${G_TICK} ${T_NAME[$i]}" "$C_GREEN"
        done
    done
}

# The separator is whatever is left over, so the bar fills its box exactly and
# can never overflow it and push the border out.
tui_tab_bar() {                 # tui_tab_bar <var> <plain-length var> <inner width>
    local i t n out="" base=0 sep gap label
    local -a labels=()
    for i in "${!TUI_TABS[@]}"; do
        t=${TUI_TABS[$i]}; n=${TUI_CNT[$t]:-0}
        [ "$n" = 0 ] && n="" || n=" $n"
        labels+=("${t}${n}")
        base=$(( base + 2 + ${#t} + ${#n} ))
    done
    sep=$(( ($3 - base) / ${#TUI_TABS[@]} ))
    (( sep < 1 )) && sep=1
    (( sep > 5 )) && sep=5
    tui_rep gap ' ' "$sep"
    for i in "${!TUI_TABS[@]}"; do
        label=${labels[$i]}
        if [ "$i" = "$TUI_TAB" ]; then out+="${C_ACCENT}${C_BOLD}${G_TAB} ${label}${C_RESET}${gap}"
        else                           out+="${C_DIM}  ${label}${C_RESET}${gap}"
        fi
    done
    printf -v "$1" '%s' "$out"
    printf -v "$2" '%s' "$(( base + sep * ${#TUI_TABS[@]} ))"
}

tui_draw() {
    local lw=$(( TUI_COLS * 60 / 100 ))
    local rw=$(( TUI_COLS - lw - 1 ))
    (( rw > 46 )) && { rw=46; lw=$(( TUI_COLS - rw - 1 )); }
    (( rw < 24 )) && { rw=24; lw=$(( TUI_COLS - rw - 1 )); }
    local liw=$(( lw - 4 )) riw=$(( rw - 4 ))
    local descw=$(( liw - 2 - 3 - 1 - TUI_NAMEW - 1 - TUI_STATEW - 1 ))
    (( descw < 6 )) && descw=6

    local body=$(( TUI_ROWS - 10 ))
    (( body < 3 )) && body=3
    (( TUI_CUR < TUI_TOP )) && TUI_TOP=$TUI_CUR
    (( TUI_CUR >= TUI_TOP + body )) && TUI_TOP=$(( TUI_CUR - body + 1 ))
    (( TUI_TOP < 0 )) && TUI_TOP=0

    tui_recount
    tui_pane_build "${TUI_VIEW[$TUI_CUR]:-}"

    local -a LFT=() RGT=()
    local t bar barlen line plain n gap sp i idx mark name cell desc tint cursor

    tui_box_top t "$lw" "search"; LFT+=("$t")
    if [ -n "$TUI_FILTER" ]; then
        plain="${TUI_FILTER}"; printf -v line '%s%s%s' "$C_RESET" "$plain" "$C_RESET"
    else
        plain="type to search this menu"; printf -v line '%s%s%s' "$C_DIM" "$plain" "$C_RESET"
    fi
    n="${#TUI_VIEW[@]}/${TUI_TOTAL}"
    gap=$(( liw - ${#plain} - ${#n} )); (( gap < 1 )) && gap=1
    tui_rep sp ' ' "$gap"
    tui_box_row t "$lw" "${line}${sp}${C_DIM}${n}${C_RESET}" $(( ${#plain} + gap + ${#n} )); LFT+=("$t")
    tui_box_bottom t "$lw"; LFT+=("$t")

    tui_box_top t "$lw" "menus"; LFT+=("$t")
    tui_tab_bar bar barlen "$liw"
    tui_box_row t "$lw" "$bar" "$barlen"; LFT+=("$t")
    tui_box_bottom t "$lw"; LFT+=("$t")

    tui_box_top t "$lw" "${TUI_TABS[$TUI_TAB]}"; LFT+=("$t")
    for (( i = TUI_TOP; i < TUI_TOP + body; i++ )); do
        if (( i >= ${#TUI_VIEW[@]} )); then
            tui_box_row t "$lw" "" 0
        else
            idx=${TUI_VIEW[$i]}
            if [ "${T_TICK[$idx]}" = 1 ]; then
                mark="${C_GREEN}${C_BOLD}[${G_TICK}]${C_RESET}"; tint="$C_GREEN"; name=${T_NPAD_ON[$idx]}
            else
                mark="${C_DIM}[ ]${C_RESET}"; tint="$C_DIM"; name=${T_NPAD_OFF[$idx]}
            fi
            cell=${T_CELL[$idx]}
            desc=${T_DESC[$idx]}
            (( ${#desc} > descw )) && desc="${desc:0:descw-1}$G_ELLIPSIS"
            if (( i == TUI_CUR )); then cursor="${C_ACCENT}${G_ARROW}${C_RESET} "; else cursor="  "; fi
            tui_box_row t "$lw" "${cursor}${mark} ${name} ${cell} ${tint}${desc}${C_RESET}" \
                $(( 2 + 3 + 1 + TUI_NAMEW + 1 + TUI_STATEW + 1 + ${#desc} ))
        fi
        LFT+=("$t")
    done
    tui_box_bottom t "$lw"; LFT+=("$t")

    tui_box_top t "$rw" "details"; RGT+=("$t")
    for (( i = 0; i < ${#LFT[@]} - 2; i++ )); do
        plain="${TUI_PTXT[$i]:-}"
        (( ${#plain} > riw )) && plain="${plain:0:riw-1}$G_ELLIPSIS"
        if (( ${TUI_PLBL[$i]:-0} > 0 )); then
            tui_box_row t "$rw" \
                "${C_DIM}${plain:0:${TUI_PLBL[$i]}}${C_RESET}${TUI_PCLR[$i]}${plain:${TUI_PLBL[$i]}}${C_RESET}" \
                "${#plain}"
        else
            tui_box_row t "$rw" "${TUI_PCLR[$i]:-}${plain}${C_RESET}" "${#plain}"
        fi
        RGT+=("$t")
    done
    tui_box_bottom t "$rw"; RGT+=("$t")

    # One write per frame: no flicker, nothing half-drawn.
    local frame=$'\033[H'
    for (( i = 0; i < ${#LFT[@]}; i++ )); do
        frame+="${LFT[$i]} ${RGT[$i]:-}"$'\033[K\n'
    done
    frame+="  ${C_DIM}${G_LEFT} ${G_RIGHT} menu   ${G_UP} ${G_DOWN} move   space tick   ctrl-a all   ctrl-d review, then install   esc cancel${C_RESET}"
    frame+=$'\033[K\033[J'
    printf '%s' "$frame"
}

# ── input ────────────────────────────────────────────────────────────────────
tui_switch_tab() {              # tui_switch_tab <+1|-1|index>
    case "$1" in
        +1) TUI_TAB=$(( (TUI_TAB + 1) % ${#TUI_TABS[@]} )) ;;
        -1) TUI_TAB=$(( (TUI_TAB - 1 + ${#TUI_TABS[@]}) % ${#TUI_TABS[@]} )) ;;
        *)  TUI_TAB=$1 ;;
    esac
    TUI_FILTER=""; TUI_CUR=0; TUI_TOP=0
    tui_build_view
}

# Ticking zsh ticks what zsh cannot work without, in the menu, where it can be
# seen and undone — rather than silently after it closes. starship draws the
# whole prompt and the tools are what its aliases call.
tui_tick_index() {              # tui_tick_index <index> <0|1>
    T_TICK[$1]=$2
}
tui_tick_key() {                # tui_tick_key <key> <0|1>
    local i
    for i in "${!T_KEY[@]}"; do
        [ "${T_KEY[$i]}" = "$1" ] && { T_TICK[$i]=$2; return; }
    done
}
tui_implied_pull() {            # tui_implied_pull <index just ticked>
    local i
    case "${T_KEY[$1]}" in
      zsh)
        tui_tick_key starship 1
        for i in "${!T_KEY[@]}"; do
            [ "${T_SEC[$i]}" = tools ] && T_TICK[$i]=1
        done
        ;;
      # The statusline is rendered by `bunx`, so without bun the config installs
      # cleanly and then renders nothing at all — Claude Code blanks the line for
      # a command it cannot run. Ticking it here rather than warning later.
      ccstatusline) tui_tick_key bun 1 ;;
    esac
}

tui_toggle_cur() {
    local idx=${TUI_VIEW[$TUI_CUR]:-}
    [ -n "$idx" ] || return
    if [ "${T_TICK[$idx]}" = 1 ]; then
        T_TICK[$idx]=0
    else
        T_TICK[$idx]=1
        tui_implied_pull "$idx"
    fi
    if [ "${TUI_TABS[$TUI_TAB]}" = selected ]; then
        tui_build_view          # the row just left this list
    else
        (( TUI_CUR < ${#TUI_VIEW[@]} - 1 )) && TUI_CUR=$(( TUI_CUR + 1 ))
    fi
}

tui_toggle_all() {
    local idx all=1
    for idx in "${TUI_VIEW[@]}"; do [ "${T_TICK[$idx]}" = 1 ] || { all=0; break; }; done
    for idx in "${TUI_VIEW[@]}"; do
        if [ "$all" = 1 ]; then T_TICK[$idx]=0
        else T_TICK[$idx]=1; tui_implied_pull "$idx"; fi
    done
    [ "${TUI_TABS[$TUI_TAB]}" = selected ] && tui_build_view
    return 0
}

TUI_CONFIRMED=0
tui_loop() {
    local key rest rc pending=1
    tui_draw
    while true; do
        # -d '' matters: with the default delimiter, `read -n1` on a newline
        # hands back an empty string, and Enter would never arrive at all.
        if [ "$pending" = 1 ]; then
            IFS= read -rsn1 -d '' -t 0.2 key <"$TTY_IN"; rc=$?
            if [ "$rc" -gt 128 ]; then
                if [ -f "$TUI_UPD_READY" ]; then tui_apply_upgrades; pending=0; tui_draw; fi
                continue
            fi
            [ "$rc" -ne 0 ] && break
        else
            IFS= read -rsn1 -d '' key <"$TTY_IN" || break
        fi
        case "$key" in
            $'\033')
                rest=""
                IFS= read -rsn2 -d '' -t 0.05 rest <"$TTY_IN"
                case "$rest" in
                    '[A') (( TUI_CUR > 0 )) && TUI_CUR=$(( TUI_CUR - 1 )) ;;
                    '[B') (( TUI_CUR < ${#TUI_VIEW[@]} - 1 )) && TUI_CUR=$(( TUI_CUR + 1 )) ;;
                    '[C') tui_switch_tab +1 ;;
                    '[D') tui_switch_tab -1 ;;
                    'OP') tui_switch_tab 0 ;;
                    'OQ') tui_switch_tab 1 ;;
                    'OR') tui_switch_tab 2 ;;
                    'OS') tui_switch_tab 3 ;;
                    '[5') IFS= read -rsn1 -d '' -t 0.05 rest <"$TTY_IN"
                          TUI_CUR=$(( TUI_CUR - 10 )); (( TUI_CUR < 0 )) && TUI_CUR=0 ;;
                    '[6') IFS= read -rsn1 -d '' -t 0.05 rest <"$TTY_IN"
                          TUI_CUR=$(( TUI_CUR + 10 ))
                          (( TUI_CUR > ${#TUI_VIEW[@]} - 1 )) && TUI_CUR=$(( ${#TUI_VIEW[@]} - 1 )) ;;
                    '[1'|'[2') IFS= read -rsn3 -d '' -t 0.05 rest <"$TTY_IN" ;;
                    '')  if [ -n "$TUI_FILTER" ]; then TUI_FILTER=""; TUI_CUR=0; tui_build_view
                         else return 1; fi ;;
                esac ;;
            # Space and Enter both tick. Enter arrives as \r or as \n depending
            # on the terminal's icrnl and ctrl-j is \n either way, so neither
            # byte can safely mean anything else — confirm gets its own key.
            ' '|$'\r'|$'\n') tui_toggle_cur ;;
            $'\004')  # ctrl-d: review first, install second
                if [ "${TUI_TABS[$TUI_TAB]}" = selected ]; then
                    TUI_CONFIRMED=1; return 0
                else
                    tui_switch_tab 3
                fi ;;
            $'\001')   tui_toggle_all ;;
            $'\011')   tui_switch_tab +1 ;;
            $'\177'|$'\010') TUI_FILTER="${TUI_FILTER%?}"; TUI_CUR=0; tui_build_view ;;
            $'\003')   return 1 ;;
            [[:print:]]) TUI_FILTER+="$key"; TUI_CUR=0; tui_build_view ;;
        esac
        tui_draw
    done
    return 1
}

# Called from _cleanup as well as from tui_pick, so an interrupt in the middle
# of the menu still puts the terminal back. It must not install a trap of its
# own to do that: this script already traps EXIT and INT for the sudo keepalive
# and the temp dir, and replacing those — then clearing them on the way out —
# left the rest of the run with no cleanup at all.
TUI_ACTIVE=0
tui_cleanup() {
    [ "$TUI_ACTIVE" = 1 ] || return 0
    TUI_ACTIVE=0
    printf '\033[?25h\033[?1049l'
    [ -n "${TUI_STTY_SAVE:-}" ] && stty "$TUI_STTY_SAVE" <"$TTY_IN" 2>/dev/null
    # Nothing ever waited on the upgrade scan, so quitting with esc or ctrl-c
    # left `apt list --upgradable` running detached — seconds of pointless work
    # on a slow VPS after the installer is gone, and still able to rename its
    # file into the directory _cleanup is about to remove. The child goes first
    # for the same reason the sudo keepalive's does: kill the subshell alone and
    # apt is reparented to init and runs to completion anyway. Silent when the
    # scan has already finished, which is the usual case.
    if [ -n "$TUI_UPD_PID" ]; then
        pkill -P "$TUI_UPD_PID" 2>/dev/null
        kill "$TUI_UPD_PID" 2>/dev/null
    fi
    # After the kill, so a mv that squeezed through still loses to this rm.
    [ -n "$TUI_UPD_READY" ] && rm -f "$TUI_UPD_READY" "${TUI_UPD_READY%.ready}"
    return 0
}

# Fills SELECTED, DEPS and APPS. Returns 1 if the run was cancelled.
tui_pick() {
    tui_build_items
    tui_scan_installed
    tui_build_cells
    tui_start_upgrade_scan
    tui_build_view

    TUI_STTY_SAVE=$(stty -g <"$TTY_IN" 2>/dev/null)
    TUI_ACTIVE=1
    # -echo so typed filter characters do not also land on screen, -icanon so a
    # keypress arrives without waiting for a newline, -ixon so ctrl-s is a key.
    stty -echo -icanon -ixon min 1 time 0 <"$TTY_IN" 2>/dev/null
    printf '\033[?1049h\033[?25l'
    trap 'TUI_ROWS=0; tui_size || true' WINCH
    tui_loop
    local rc=$?
    tui_cleanup
    trap - WINCH

    [ "$rc" -ne 0 ] || [ "$TUI_CONFIRMED" -ne 1 ] && return 1

    local i
    for i in "${!T_KEY[@]}"; do
        [ "${T_TICK[$i]}" = 1 ] || continue
        case "${T_SEC[$i]}" in
            dotfiles) SELECTED+=("${T_KEY[$i]}") ;;
            tools)    DEPS+=("${T_KEY[$i]}") ;;
            apps)     APPS+=("${T_KEY[$i]}") ;;
        esac
    done
    return 0
}

# ── Two-option picker ────────────────────────────────────────────────────────
# Both of the questions asked before the menus — privacy, and what happens to
# existing configs — are the same widget: two rows, arrows or the label's first
# letter to move, Enter to confirm. The cursor *is* the selection; there is
# nothing to toggle, which is why space is only a redraw.
# Answer lands in PICK2 as 0 or 1.
#   pick2 <label0> <desc0> <colour0> <label1> <desc1> <colour1>
PICK2=0
_pick2_draw() {
    local m0="( )" m1="( )" a0="  " a1="  "
    if [ "$1" -eq 0 ]; then
        m0="(${G_PICK})"; a0="${_P2_C0}${G_ARROW}${C_RESET} "
    else
        m1="(${G_PICK})"; a1="${_P2_C1}${G_ARROW}${C_RESET} "
    fi
    printf " ${C_MAIN}${C_BOLD}${G_MID}${C_RESET}  %b%b %-8s ${C_DIM}${G_DOT}  %-42s${C_RESET}\n" \
        "$a0" "$m0" "$_P2_L0" "$_P2_D0"
    printf " ${C_MAIN}${C_BOLD}${G_MID}${C_RESET}  %b%b %-8s ${C_DIM}${G_DOT}  %-42s${C_RESET}\n" \
        "$a1" "$m1" "$_P2_L1" "$_P2_D1"
}
pick2() {
    _P2_L0="$1" _P2_D0="$2" _P2_C0="$3"
    _P2_L1="$4" _P2_D1="$5" _P2_C1="$6"
    local key esc lc
    PICK2=0
    _pick2_draw "$PICK2"
    while true; do
        printf "\033[2A"
        IFS= read -n 1 -rs key <"$TTY_IN"
        case "$key" in
            $'\n'|$'\r'|'') _pick2_draw "$PICK2"; break ;;
            $'\033')
                IFS= read -n 2 -rs -t 0.1 esc <"$TTY_IN" || true
                case "$esc" in
                    '[A'|'[D') PICK2=0 ;;
                    '[B'|'[C') PICK2=1 ;;
                esac
                _pick2_draw "$PICK2" ;;
            *)
                # k/p and b/d are just the labels' initials — nothing to pass in.
                lc="${key,,}"
                if   [ "$lc" = "${_P2_L0:0:1}" ]; then PICK2=0
                elif [ "$lc" = "${_P2_L1:0:1}" ]; then PICK2=1
                fi
                _pick2_draw "$PICK2" ;;
        esac
    done
}

# ── Package helpers ───────────────────────────────────────────────────────────
# Some tools can land outside the package manager entirely — starship's own
# install script and the lazygit tarball drop plain binaries into /usr/local/bin,
# and ghostty may come from a vendor .deb. Map package name → binary so a
# manually-present tool is not reinstalled on every run.
declare -A PKG_BIN
PKG_BIN[starship]="starship"
PKG_BIN[lazygit]="lazygit"
PKG_BIN[ghostty]="ghostty"
PKG_BIN[fastfetch]="fastfetch"
PKG_BIN[eza]="eza"
PKG_BIN[zoxide]="zoxide"
PKG_BIN[fd-find]="fdfind"
PKG_BIN[pay-respects-bin]="pay-respects"
PKG_BIN[pay-respects]="pay-respects"

pkg_installed() {
    local pkg="$1"
    # An empty name means a lookup produced nothing; bash reports it as
    # "PKG_BIN: bad array subscript", which reads like a crash in the middle of
    # an install. Treat it as "not installed" instead.
    [ -n "$pkg" ] || return 1
    if [[ "$DISTRO" == "arch" ]]; then
        pacman -Q "$pkg" &>/dev/null && return 0
    else
        apt_pkg_installed "$pkg" && return 0
    fi
    local bin="${PKG_BIN[$pkg]:-}"
    [ -n "$bin" ] && command -v "$bin" &>/dev/null
}

pacman_install() {
    if [ -f /var/lib/pacman/db.lck ]; then
        sudo rm -f /var/lib/pacman/db.lck
    fi
    sudo pacman -S --needed --noconfirm "$@" &>/dev/null 2>&1 && return 0
    # A sync db older than the mirror resolves to package versions that have
    # since been replaced — "target not found" or a 404 mid-download. Refresh
    # the db once and retry before calling it a failure.
    substep "${C_YELLOW}Stale package database — refreshing and retrying${C_RESET}"
    sudo pacman -Sy --noconfirm &>/dev/null 2>&1 || true
    sudo pacman -S --needed --noconfirm "$@" &>/dev/null 2>&1
}

# Whichever helper this machine ended up with — set by the AUR bootstrap in
# step 1, which prefers one that is already installed. paru and yay take the
# same flags for everything below, so nothing else has to care which it is.
AUR_HELPER=""
aur_ready() { [ -n "$AUR_HELPER" ] && command -v "$AUR_HELPER" &>/dev/null; }

_aur_run_robust() {
    local sync_flag="${1:-}"   # "" | "y" | "yy"
    local pkg="$2"

    # No helper when the AUR bootstrap was skipped — as root, where makepkg
    # refuses to build. Fail cleanly here instead of leaking
    # "paru: command not found" from every attempt below.
    if ! aur_ready; then
        substep "${C_YELLOW}No AUR helper available — ${pkg} needs one${C_RESET}"
        return 1
    fi

    local tmplog; tmplog=$(mktemp -p "$RUN_TMPDIR" aur_XXXXXX.log)

    # ── preflight: stale pacman lock ─────────────────────────────────────────
    if [ -f /var/lib/pacman/db.lck ]; then
        substep "${C_YELLOW}Stale pacman lock — removing${C_RESET}"
        sudo rm -f /var/lib/pacman/db.lck
    fi

    local _flags=( "$AUR_HELPER" -S"${sync_flag}" --needed --noconfirm --removemake --cleanafter )

    # ── attempt 1: normal install ─────────────────────────────────────────────
    if "${_flags[@]}" "$pkg" >"$tmplog" 2>&1; then
        rm -f "$tmplog"; return 0
    fi
    local err; err=$(<"$tmplog")

    # ── attempt 2: PGP / signature problem ───────────────────────────────────
    if grep -qiE 'pgp|key|signature|invalid or corrupted|unknown trust|not trusted' <<< "$err"; then
        substep "${C_YELLOW}PGP key issue — refreshing keyring and retrying${C_RESET}"
        sudo pacman -S --needed --noconfirm archlinux-keyring &>/dev/null 2>&1 || true
        sudo pacman-key --populate archlinux &>/dev/null 2>&1 || true
        if "${_flags[@]}" --mflags "--skippgpcheck" "$pkg" >"$tmplog" 2>&1; then
            rm -f "$tmplog"; return 0
        fi
        err=$(<"$tmplog")
    fi

    # ── attempt 3: file conflict ─────────────────────────────────────────────
    if grep -qiE 'exists in filesystem|file conflict|conflicting files' <<< "$err"; then
        substep "${C_YELLOW}File conflict — retrying with --overwrite${C_RESET}"
        if "${_flags[@]}" --overwrite '*' "$pkg" >"$tmplog" 2>&1; then
            rm -f "$tmplog"; return 0
        fi
        err=$(<"$tmplog")
    fi

    # ── attempt 4: corrupt cache or database ─────────────────────────────────
    if grep -qiE 'corrupted|invalid.*database|unexpected EOF|error.*opening.*database' <<< "$err"; then
        substep "${C_YELLOW}Corrupt cache/database — cleaning and force-resyncing${C_RESET}"
        sudo pacman -Sc --noconfirm &>/dev/null 2>&1 || true
        "$AUR_HELPER" -Sc --noconfirm &>/dev/null 2>&1 || true
        if "$AUR_HELPER" -Syy --needed --noconfirm --removemake --cleanafter "$pkg" >"$tmplog" 2>&1; then
            rm -f "$tmplog"; return 0
        fi
        err=$(<"$tmplog")
    fi

    # ── attempt 5: stale AUR clone ───────────────────────────────────────────
    if grep -qiE 'git.*error|could not.*fetch|unable to.*clone|not a git repo' <<< "$err"; then
        substep "${C_YELLOW}Stale AUR clone — clearing cache and retrying${C_RESET}"
        # paru keeps clones one level deeper than yay; neither has to exist.
        rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/paru/clone/${pkg}" \
               "${XDG_CACHE_HOME:-$HOME/.cache}/yay/${pkg}"
        if "${_flags[@]}" "$pkg" >"$tmplog" 2>&1; then
            rm -f "$tmplog"; return 0
        fi
        err=$(<"$tmplog")
    fi

    # ── all attempts failed ───────────────────────────────────────────────────
    substep "${C_RED}All install attempts failed — last output:${C_RESET}"
    tail -6 "$tmplog" | while IFS= read -r _el; do substep "${C_DIM}${_el}${C_RESET}"; done
    rm -f "$tmplog"
    return 1
}

aur_install()   { _aur_run_robust ""  "$1"; }
aur_install_y() { _aur_run_robust "y" "$1"; }

# Official repos first, AUR only as a fallback. Repo packages are signed,
# prebuilt and install in seconds, where the AUR builds from source — and some
# names now exist in both places (pay-respects, thefuck), so asking paru blindly
# could pick the slower path. 'pacman -Si' answers "is this in a sync repo?"
# without touching the network, so an AUR-only name costs nothing here.
arch_install() {
    local pkg="$1"
    if pacman -Si "$pkg" &>/dev/null; then
        pacman_install "$pkg" && return 0
    fi
    aur_ready || return 1
    aur_install "$pkg"
}

# ── Debian/Ubuntu (apt) package helpers ──────────────────────────────────────
# 'dpkg -s' also succeeds for purged-but-config-files packages ("deinstall ok
# config-files"), which made removed packages look installed. Check the real
# status field instead.
apt_pkg_installed() {
    local st
    st=$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null) || return 1
    [ "$st" = "installed" ]
}

# Every privileged apt-get goes through here. Two things this fixes:
#
#   'sudo DEBIAN_FRONTEND=noninteractive apt-get …' is rejected outright on a
#   stock Debian/Ubuntu sudoers policy — "sorry, you are not allowed to set the
#   following environment variables: DEBIAN_FRONTEND". sudo parses leading
#   VAR=value itself and only honours it when the rule carries SETENV, which
#   '%sudo ALL=(ALL:ALL) ALL' does not. Handing the assignment to env(1) sets it
#   inside the privileged process instead, which no policy blocks.
#
#   needrestart (Ubuntu 22.04+) hooks apt and opens a full-screen "which
#   services should be restarted?" dialog mid-install. Suspending it keeps the
#   run non-interactive and, on a VPS, avoids bouncing sshd underneath you.
#   Fresh images run unattended-upgrades at boot and hold the dpkg lock for
#   minutes. DPkg::Lock::Timeout makes apt itself block until the lock frees
#   (apt 1.9.11+, so Ubuntu 20.04 and Debian 11 onwards) instead of failing
#   immediately and leaving us to poll.
apt_get() {
    sudo env DEBIAN_FRONTEND=noninteractive \
             NEEDRESTART_SUSPEND=1 \
             apt-get -o DPkg::Lock::Timeout=600 "$@"
}

APT_LOCK_RE='could not get lock|unable to lock|another process (is )?using it|frontend lock|resource temporarily unavailable'
apt_is_lock_error() { grep -qiE "$APT_LOCK_RE" <<< "$1"; }

# Killing a package manager halfway leaves dpkg needing a repair pass, and
# every apt-get after that refuses to do anything until it is run. Self-inflicted
# by whoever force-quit the last one, but trivial to fix, so just fix it.
apt_fix_interrupted_dpkg() {
    grep -qiE 'dpkg was interrupted|run .?dpkg --configure -a' <<< "$1" || return 1
    substep "${C_YELLOW}dpkg was left half-configured — repairing${C_RESET}"
    sudo env DEBIAN_FRONTEND=noninteractive dpkg --configure -a &>/dev/null
    substep "${C_DIM}dpkg --configure -a done${C_RESET}"
    return 0
}

# Reached only when apt has already waited ten minutes. Deleting
# /var/lib/dpkg/lock* is the common advice and it is wrong: the lock belongs to
# a running process, removing the file does not release it, and doing so while
# that process writes is how a dpkg database ends up corrupt. The only real fix
# is for the holder to finish or be stopped.
APT_LOCK_HANDLED=0
apt_clear_lock() {
    [ "$APT_LOCK_HANDLED" -eq 1 ] && return 1
    local holder pid name ans
    holder=$(grep -oE 'held by process [0-9]+ \([^)]+\)' <<< "$1" | head -1)
    pid=$(grep -oE '[0-9]+' <<< "$holder" | head -1)
    name=$(sed -nE 's/.*\(([^)]+)\).*/\1/p' <<< "$holder")
    [ -n "$pid" ] && [ -d "/proc/$pid" ] || return 1
    APT_LOCK_HANDLED=1

    substep "${C_YELLOW}Still locked by ${name:-a process} (pid ${pid}) after waiting${C_RESET}"
    case "$name" in
        unattended-upgr*|apt*|packagekit*|dpkg*) ;;   # apt* covers aptd too
        *)  substep "${C_DIM}Not one of the system's own updaters — leaving it alone${C_RESET}"
            return 1 ;;
    esac
    substep "${C_DIM}This is the automatic updater. Deleting the lock file will not help:${C_RESET}"
    substep "${C_DIM}the lock is the process, not the file.${C_RESET}"
    echo -ne "${C_MAIN}${C_BOLD} ${G_MID}  ${C_YELLOW}Stop it and continue? [Y/n]: ${C_RESET}"
    read -r ans <"$TTY_IN"
    [[ "$ans" =~ ^[Nn]$ ]] && { substep "${C_DIM}Left running${C_RESET}"; return 1; }

    sudo systemctl stop unattended-upgrades.service apt-daily.service \
        apt-daily-upgrade.service packagekit.service &>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -d "/proc/$pid" ] || break; sleep 2; done
    if [ -d "/proc/$pid" ]; then
        # Same signal systemctl would send; unattended-upgrades finishes the
        # package it is on and exits rather than dying mid-write.
        sudo kill -TERM "$pid" &>/dev/null
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do [ -d "/proc/$pid" ] || break; sleep 2; done
    fi
    if [ -d "/proc/$pid" ]; then
        substep "${C_RED}It is still running — try again in a few minutes${C_RESET}"
        return 1
    fi
    substep "${C_GREEN}Lock released${C_RESET}"
    substep "${C_DIM}To stop it coming back: sudo systemctl disable --now unattended-upgrades apt-daily.timer apt-daily-upgrade.timer${C_RESET}"
    return 0
}

APT_UPDATED=0
APT_INDEX_OK=1
# Last 'apt-get update' error, kept so the failure can explain itself
APT_UPDATE_ERROR=""
APT_SOURCES_D=/etc/apt/sources.list.d
# Sources this installer is the one that adds. Only these are ever removed
# again — anything else under sources.list.d belongs to the user and is left
# alone. PPAs are matched by their owner prefix, vendor repos by filename.
APT_OWN_PPAS='lazygit-team|zhangsongcui3371|agornostal'
# Every vendor repo written by an ensure_*_deb function below, plus the mirror
# fallback. A stale one of these breaks apt-get update for the whole machine
# exactly as a dead PPA does — and used to do it permanently, because only PPAs
# were ever cleaned up. The fallback list was the last one still uncleanable:
# left out of here, the one file written to heal a broken index was the one file
# that could break it for good. zz-dotfiles-fallback is its pre-rename name, kept
# so a machine that ran that version can still be healed.
APT_OWN_SOURCES='gierens|vscode|vscode-insiders|claude-desktop|brave-browser-.*|zz-installer-fallback|zz-dotfiles-fallback'
APT_HEALED=0

# An earlier run may have added a source that has since stopped publishing for
# this release, or whose signing key was rotated. It breaks every apt-get
# update from then on, and the user has no reason to connect that to this
# installer — so clean up after ourselves.
apt_drop_own_dead_source() {
    local f base owner dropped=0
    for f in "$APT_SOURCES_D"/*; do
        [ -f "$f" ] || continue
        base="${f##*/}"
        if grep -qE "^(${APT_OWN_PPAS})" <<< "$base"; then
            # ppa: owner-ubuntu-name-release.list — the owner is what apt names
            # in the error, so match on that.
            owner="${base%%-ubuntu-*}"
        elif grep -qE "^(${APT_OWN_SOURCES})\.(list|sources)$" <<< "$base"; then
            # vendor repo: the filename stem is not in apt's error text, so
            # match on the hosts the file itself points at instead.
            owner=""
            local _h
            while IFS= read -r _h; do
                grep -qiF "$_h" <<< "$APT_UPDATE_ERROR" && { owner="$_h"; break; }
            done < <(grep -ohE 'https?://[^ ]+' "$f" 2>/dev/null \
                     | sed -E 's#https?://([^/ ]+).*#\1#' | sort -u)
            [ -n "$owner" ] || continue
        else
            continue
        fi
        grep -qiF "$owner" <<< "$APT_UPDATE_ERROR" || continue
        sudo rm -f "$f" || continue
        substep "${C_YELLOW}Removed a dead source from an earlier run: ${base}${C_RESET}"
        dropped=1
    done
    [ "$dropped" -eq 1 ]
}

apt_update_once() {
    [ "$APT_UPDATED" -eq 1 ] && return 0
    local out
    if out=$(apt_get update -qq 2>&1); then
        APT_UPDATE_ERROR=""
        APT_UPDATED=1
        return 0
    fi
    # apt has already waited out the lock by now, so anything still holding it
    # needs dealing with rather than waiting on.
    if apt_is_lock_error "$out" && apt_clear_lock "$out"; then
        if out=$(apt_get update -qq 2>&1); then
            APT_UPDATE_ERROR=""
            APT_UPDATED=1
            return 0
        fi
    fi
    if apt_fix_interrupted_dpkg "$out"; then
        if out=$(apt_get update -qq 2>&1); then
            APT_UPDATE_ERROR=""
            APT_UPDATED=1
            return 0
        fi
    fi
    # One of ours that has gone stale? Remove it and try once more before
    # blaming the mirror — this is by far the likeliest cause of a source with
    # no Release file, and it is the only one we are entitled to fix.
    APT_UPDATE_ERROR="$out"
    if [ "$APT_HEALED" -eq 0 ] && apt_drop_own_dead_source; then
        APT_HEALED=1
        if out=$(apt_get update -qq 2>&1); then
            APT_UPDATE_ERROR=""
            APT_UPDATED=1
            return 0
        fi
    fi

    # Only a mirror-level failure justifies adding another mirror — a broken
    # third-party repo would fail this too and swapping mirrors would not help.
    if grep -qiE 'could not resolve|failed to fetch|connection failed|404 +not found|no longer has a release file|hash sum mismatch' <<< "$out"; then
        substep "${C_YELLOW}Package index unreachable — trying the canonical mirror${C_RESET}"
        if apt_add_fallback_mirror && apt_get update -qq &>/dev/null 2>&1; then
            APT_UPDATED=1
            return 0
        fi
    fi
    # Marked done either way so every later step does not retry the same
    # failing refresh, but remembered as broken so an install failure can say
    # why instead of looking like a missing package.
    APT_UPDATE_ERROR="$out"
    APT_INDEX_OK=0
    APT_UPDATED=1
    return 1
}

# apt-get update exits non-zero when *any* configured source fails — including
# some third-party repo left behind by an earlier install — while the distro
# archive refreshed perfectly well and every package still installs. Print what
# apt actually said, and name the file the failing source lives in: that is the
# difference between "apt ready" (a lie) and a message worth acting on.
APT_SOURCE_DIRS=(/etc/apt/sources.list "$APT_SOURCES_D/")
apt_index_report() {
    [ -n "$APT_UPDATE_ERROR" ] || return 0
    local line url f
    while IFS= read -r line; do
        [ -n "$line" ] && substep "${C_DIM}${line}${C_RESET}"
    done < <(printf '%s\n' "$APT_UPDATE_ERROR" | grep -E '^[EW]:' | tail -4)

    while IFS= read -r url; do
        [ -n "$url" ] || continue
        f=$(grep -rlsF -- "$url" "${APT_SOURCE_DIRS[@]}" 2>/dev/null | head -1)
        [ -n "$f" ] && { substep "${C_YELLOW}Failing source is configured in: ${f}${C_RESET}"; return 0; }
    done < <(printf '%s\n' "$APT_UPDATE_ERROR" \
        | grep -oE 'https?://[^ '\''"]+' | sed 's#/dists/.*##;s#/*$##' | sort -u)
    return 0
}

# Last apt error, so a failure can be shown instead of just "failed"
APT_LAST_ERROR=""

apt_install() {
    apt_update_once
    local out
    if out=$(apt_get install -y --no-install-recommends "$@" 2>&1); then
        return 0
    fi
    # apt itself waits out the lock (DPkg::Lock::Timeout above). Getting here
    # means something has held it for ten minutes — on a freshly booted image
    # that is unattended-upgrades, and it needs stopping, not more waiting.
    if apt_is_lock_error "$out" && apt_clear_lock "$out"; then
        out=$(apt_get install -y --no-install-recommends "$@" 2>&1) && return 0
    fi
    if apt_fix_interrupted_dpkg "$out"; then
        out=$(apt_get install -y --no-install-recommends "$@" 2>&1) && return 0
    fi
    # Still locked and the holder would not go: nothing else here can help, and
    # the stale-index dance below would only print noise on top of it.
    if apt_is_lock_error "$out"; then
        APT_LAST_ERROR="$out"
        return 1
    fi

    # An index older than the mirror 404s on a superseded version.
    substep "${C_YELLOW}Stale package index — refreshing and retrying${C_RESET}"
    APT_UPDATED=0
    apt_update_once
    if out=$(apt_get install -y --no-install-recommends "$@" 2>&1); then
        return 0
    fi
    APT_LAST_ERROR="$out"
    [ "$APT_INDEX_OK" -eq 0 ] && substep "${C_YELLOW}Note: the package index never refreshed cleanly — see the apt errors above${C_RESET}"
    return 1
}

# Bootstraps utilities repo-add steps commonly need
ensure_apt_deps() {
    local need=()
    command -v curl &>/dev/null || need+=(curl)
    command -v gpg  &>/dev/null || need+=(gnupg)
    if [ "$IS_UBUNTU" -eq 1 ] && ! command -v add-apt-repository &>/dev/null; then
        need+=(software-properties-common)
    fi
    if [ "${#need[@]}" -gt 0 ]; then
        apt_update_once
        apt_get install -y "${need[@]}" &>/dev/null 2>&1
    fi
}

# Vendor installers that ship a zip (the fonts, bun) need it, and it is in
# neither distro's base install.
ensure_unzip() {
    command -v unzip &>/dev/null && return 0
    if [[ "$DISTRO" == "arch" ]]; then arch_install unzip; else apt_install unzip; fi
}

# A PPA that has no build for the running release does not just fail to
# provide its package — it leaves behind a source with no Release file, and
# from then on every apt-get update on the machine exits non-zero, including
# ones that have nothing to do with this installer. So: add it, and if the
# refresh starts complaining about this PPA specifically, take it back out
# before falling through to whatever the caller's fallback is.
add_ppa() {
    local ppa="$1" owner name
    ensure_apt_deps
    sudo add-apt-repository -y "$ppa" &>/dev/null 2>&1 || return 1
    APT_UPDATED=0
    apt_update_once && return 0

    owner="${ppa#ppa:}"; name="${owner#*/}"; owner="${owner%%/*}"
    grep -qiE "${owner}/${name}|${owner}-ubuntu-${name}" <<< "$APT_UPDATE_ERROR" || return 1

    substep "${C_YELLOW}${ppa} has no build for this release — removing it again${C_RESET}"
    sudo rm -f "$APT_SOURCES_D/${owner}-ubuntu-${name}"-*.sources \
               "$APT_SOURCES_D/${owner}-ubuntu-${name}"-*.list
    APT_UPDATED=0
    apt_update_once
    return 1
}

deb_arch() { dpkg --print-architecture; }

# ── apt mirror fallback ──────────────────────────────────────────────────────
# VPS and cloud images often ship a regional mirror that is slow, half-synced or
# retired, and then every apt-get fails with 404s or hash mismatches. When the
# index cannot be refreshed, add the canonical mirror alongside whatever is
# already configured (never replacing it).
#
# Architecture decides the Ubuntu host: archive.ubuntu.com carries amd64/i386
# and 404s for arm64, ports.ubuntu.com carries the other architectures and 404s
# for amd64 — both verified against the live indexes. Getting this wrong is
# exactly how an ARM VPS ends up unable to install anything.
APT_FALLBACK_ADDED=0
apt_add_fallback_mirror() {
    [ "$APT_FALLBACK_ADDED" -eq 1 ] && return 1
    APT_FALLBACK_ADDED=1

    local codename; codename="$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_CODENAME:-}")"
    [ -n "$codename" ] || return 1

    # The name carries no "dotfiles": /etc outlives $HOME, so a file here is a
    # more permanent trace than the bashrc hook that dropped the word. The stem
    # is also in APT_OWN_SOURCES, so this file can be removed again — see there.
    local list="$APT_SOURCES_D/zz-installer-fallback.list"
    local host
    if [ "$IS_UBUNTU" -eq 1 ]; then
        case "$(deb_arch)" in
            amd64|i386) host="http://archive.ubuntu.com/ubuntu" ;;
            *)          host="http://ports.ubuntu.com/ubuntu-ports" ;;
        esac
        # Already on the canonical mirror? Then a duplicate cannot fix anything.
        grep -rqs "${host#http://}" /etc/apt/sources.list /etc/apt/sources.list.d/ && return 1
        printf 'deb %s %s main restricted universe multiverse\ndeb %s %s-updates main restricted universe multiverse\ndeb %s %s-security main restricted universe multiverse\n' \
            "$host" "$codename" "$host" "$codename" "$host" "$codename" \
            | sudo tee "$list" >/dev/null
    else
        host="http://deb.debian.org/debian"
        grep -rqs 'deb.debian.org' /etc/apt/sources.list /etc/apt/sources.list.d/ && return 1
        # main/contrib/non-free only — every Debian release has those three,
        # while non-free-firmware would error out on anything before bookworm.
        printf 'deb %s %s main contrib non-free\ndeb %s %s-updates main contrib non-free\ndeb http://security.debian.org/debian-security %s-security main contrib non-free\n' \
            "$host" "$codename" "$host" "$codename" "$codename" \
            | sudo tee "$list" >/dev/null
    fi
    substep "${C_YELLOW}Added fallback mirror: ${host}${C_RESET}"
    return 0
}

# GitHub "latest release" asset lookup — no jq dependency
github_latest_asset_url() {
    local repo="$1" pattern="$2" url tag
    url=$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
        | grep -oP '"browser_download_url":\s*"\K[^"]+' \
        | grep -Ei "$pattern" | head -1)
    [ -n "$url" ] && { printf '%s\n' "$url"; return 0; }

    # The unauthenticated API allows 60 requests/hour per IP — behind shared
    # NAT, or on a second run, it returns a 403 and the lookup came back empty
    # with no explanation. The release page has no such limit: resolve the tag
    # from the /latest redirect, then read that tag's asset list.
    tag=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
              "https://github.com/${repo}/releases/latest" 2>/dev/null | sed 's#.*/tag/##')
    [ -n "$tag" ] || return 1
    curl -fsSL "https://github.com/${repo}/releases/expanded_assets/${tag}" 2>/dev/null \
        | grep -oP 'href="\K[^"]+' \
        | grep -Ei "$pattern" | head -1 | sed 's#^/#https://github.com/#'
}

# Four of the tools below have no apt package anywhere and publish a .deb per
# release instead — same download every time, so it lives here once.
# apt-get on the downloaded file rather than dpkg -i: dpkg leaves unmet deps
# behind for the next apt run to trip over, apt-get resolves them.
# The asset pattern belongs to the caller, since every project names its builds
# differently — but it has to stay $-anchored wherever it is written, or the
# matching .deb.sha256 asset wins the grep.
#
# That .deb.sha256 is also the only integrity check any of the four can get.
# Every apt repo this script adds gets a verified signing key (apt_install_keyring);
# a release .deb gets nothing, and goes into a root install unsigned. So it is
# fetched here rather than only avoided. Checked against the live releases:
# sinelaw/fresh publishes a .sha256 beside every asset, fastfetch-cli/fastfetch,
# Ulauncher/Ulauncher and iffse/pay-respects publish nothing at all — no combined
# checksums.txt anywhere either, which is why this is one URL guess and not a
# per-repo map. A 404 therefore has to stay a normal install: making it fatal
# would break three working tools for a check that cannot be performed. A
# checksum that *is* published and does not match is refused, and said out loud.
install_release_deb() {
    local url tmp want got rc
    url=$(github_latest_asset_url "$1" "$2")
    [ -n "$url" ] || return 1
    tmp=$(mktemp -p "$RUN_TMPDIR" release_XXXXXX.deb)
    curl -fsSL "$url" -o "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }

    # The file holds "<sha256>  <filename>". Grep the hash out instead of using
    # `sha256sum -c`, which insists the file sit there under its published name
    # — this one is a mktemp. Empty $want means nothing was published.
    want=$(curl -fsSL "${url}.sha256" 2>/dev/null | grep -oiE '[0-9a-f]{64}' | head -1)
    if [ -n "$want" ]; then
        # sha256sum is coreutils: Essential:yes on Debian, in base on Arch, so
        # its absence means a box that cannot apt-get either. If it is somehow
        # gone $got comes back empty and fails the compare — being handed a
        # checksum and installing anyway because we could not check it is the
        # one outcome worth refusing over.
        got=$(sha256sum "$tmp" 2>/dev/null | cut -d' ' -f1)
        if [ "$got" != "$want" ]; then
            rm -f "$tmp"
            substep "${C_RED}Checksum mismatch on ${url##*/}${C_RESET}"
            substep "${C_DIM}expected ${want} · got ${got:-nothing, sha256sum failed}${C_RESET}"
            error "Refusing to install it — that .deb would go in as root"
            return 1
        fi
    fi

    apt_get install -y "$tmp" &>/dev/null 2>&1; rc=$?
    rm -f "$tmp"
    return "$rc"
}

# ── ghostty (Debian/Ubuntu) ───────────────────────────────────────────────────
# mkasberg/ghostty-ubuntu's installer self-detects Ubuntu (PPA) vs Debian
# Trixie/Forky (signed repo) and grabs the right .deb either way.
ensure_ghostty_deb() {
    command -v ghostty &>/dev/null && return 0
    ensure_apt_deps
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/mkasberg/ghostty-ubuntu/HEAD/install.sh)" &>/dev/null 2>&1
    command -v ghostty &>/dev/null
}

# ── alacritty (Debian/Ubuntu) ────────────────────────────────────────────────
# Debian has had it in main since bookworm, so plain apt is the whole story
# there. Ubuntu carries it in universe too, a release or so behind upstream —
# good enough to prefer, with aslatter's PPA (the upstream-suggested source,
# builds back to 18.04) only as the fallback when universe has nothing.
ensure_alacritty_deb() {
    apt_pkg_installed alacritty && return 0
    apt_install alacritty
    apt_pkg_installed alacritty && return 0

    if [ "$IS_UBUNTU" -eq 1 ]; then
        add_ppa ppa:aslatter/ppa
        apt_install alacritty
    fi
    apt_pkg_installed alacritty
}

# ── wezterm (Debian/Ubuntu) ──────────────────────────────────────────────────
# Not in apt on either distro, so the vendor Fury repo is the only path. It
# publishes two packages that conflict with each other — take the nightly one:
# the last stable release is 20240203, two and a half years old, and the same
# staleness is why wezterm-git rather than extra/wezterm is the Arch pick here.
ensure_wezterm_deb() {
    apt_pkg_installed wezterm-nightly && return 0
    ensure_apt_deps
    apt_install_keyring https://apt.fury.io/wez/gpg.key \
        /usr/share/keyrings/wezterm-fury.gpg || return 1
    # The two literal asterisks are not a glob left in by mistake — Fury serves
    # one flat pool and wants them as the distribution and component fields.
    echo 'deb [signed-by=/usr/share/keyrings/wezterm-fury.gpg] https://apt.fury.io/wez/ * *' \
        | sudo tee /etc/apt/sources.list.d/wezterm.list >/dev/null
    sudo chmod 644 /etc/apt/sources.list.d/wezterm.list
    APT_UPDATED=0
    apt_update_once
    apt_install wezterm-nightly
    apt_pkg_installed wezterm-nightly
}

# ── fastfetch (Debian/Ubuntu) ─────────────────────────────────────────────────
ensure_fastfetch_deb() {
    apt_pkg_installed fastfetch && return 0
    apt_install fastfetch
    apt_pkg_installed fastfetch && return 0

    if [ "$IS_UBUNTU" -eq 1 ]; then
        add_ppa ppa:zhangsongcui3371/fastfetch
        apt_install fastfetch
    else
        local apat
        # Upstream names 32-bit ARM builds armv7l/armv6l, never Debian's
        # armhf/armel, so those need translating or nothing matches.
        case "$(deb_arch)" in
            amd64) apat='amd64|x86_64' ;;
            arm64) apat='arm64|aarch64' ;;
            armhf) apat='armv7l' ;;
            armel) apat='armv6l' ;;
            *)     apat="$(deb_arch)" ;;
        esac
        install_release_deb "fastfetch-cli/fastfetch" "linux-(${apat})\.deb$"
    fi
    apt_pkg_installed fastfetch
}

# ── ulauncher (Debian/Ubuntu) ─────────────────────────────────────────────────
ensure_ulauncher_deb() {
    apt_pkg_installed ulauncher && return 0
    if [ "$IS_UBUNTU" -eq 1 ]; then
        add_ppa ppa:agornostal/ulauncher
        apt_install ulauncher
    else
        install_release_deb "Ulauncher/Ulauncher" '_all\.deb$'
    fi
    apt_pkg_installed ulauncher
}

# ── fresh (Debian/Ubuntu) ────────────────────────────────────────────────────
# No apt package anywhere — upstream publishes a .deb per release instead. The
# arch suffix is Debian's own (amd64/arm64), which is what deb_arch prints.
ensure_fresh_deb() {
    apt_pkg_installed fresh-editor && return 0
    install_release_deb "sinelaw/fresh" "_$(deb_arch)\.deb$"
    apt_pkg_installed fresh-editor
}

# ── pay-respects (Debian/Ubuntu) ─────────────────────────────────────────────
# Not in apt on any release; upstream publishes a .deb per release, named the
# way ensure_fresh_deb's pattern already expects. Replaces thefuck, which apt
# still ships as the unpatched 3.32 — it imports `imp`, gone since Python 3.12,
# so it dies on import on every supported Ubuntu.
ensure_pay_respects_deb() {
    apt_pkg_installed pay-respects && return 0
    install_release_deb "iffse/pay-respects" "_$(deb_arch)\.deb$"
    apt_pkg_installed pay-respects
}

# ── lazygit (Debian/Ubuntu) ───────────────────────────────────────────────────
ensure_lazygit_deb() {
    apt_pkg_installed lazygit && return 0
    apt_install lazygit
    apt_pkg_installed lazygit && return 0

    # No PPA step here on purpose. ppa:lazygit-team/release last published for
    # hirsute in 2021 — on any supported release it adds a source with no
    # Release file, which then breaks every apt-get update on the machine.
    # The upstream release binary is the only working path.
    local apat url tmp
    case "$(deb_arch)" in
        amd64)        apat='x86_64' ;;
        arm64)        apat='arm64' ;;
        armhf|armel)  apat='armv6' ;;
        i386)         apat='32-bit' ;;
        *)            apat="$(uname -m)" ;;
    esac
    url=$(github_latest_asset_url "jesseduffield/lazygit" "Linux_${apat}\.tar\.gz$")
    if [ -n "$url" ]; then
        tmp=$(mktemp -d -p "$RUN_TMPDIR" lazygit_XXXXXX)
        if curl -fsSL "$url" -o "$tmp/lazygit.tar.gz" 2>/dev/null && tar -xzf "$tmp/lazygit.tar.gz" -C "$tmp" lazygit 2>/dev/null; then
            sudo install -m755 "$tmp/lazygit" /usr/local/bin/lazygit
        fi
        rm -rf "$tmp"
    fi
    command -v lazygit &>/dev/null
}

# ── starship (Debian/Ubuntu) ──────────────────────────────────────────────────
ensure_starship_deb() {
    if apt_pkg_installed starship || command -v starship &>/dev/null; then return 0; fi
    apt_install starship
    command -v starship &>/dev/null && return 0
    # -f, like every other download here. Without it an HTTP error page is
    # piped into sh instead of being treated as a failure.
    curl -fsSL https://starship.rs/install.sh | sh -s -- -y &>/dev/null 2>&1
    command -v starship &>/dev/null
}

# ── Keyring install, checked ─────────────────────────────────────────────────
# `curl … | gpg --dearmor | sudo tee key.gpg` reports the exit status of tee,
# which succeeds whatever it was handed. A failed download therefore wrote an
# empty keyring, the caller went on to add the sources entry anyway, and every
# apt-get update from then on failed to verify that repo — with nothing
# anywhere saying the key never arrived.
#
# Fetch to a temp file, check curl, check the result is non-empty and really is
# a key, and only then install it. Returns non-zero so callers can skip writing
# a sources entry that could not possibly work.
#   apt_install_keyring <url> <dest> [--armored]
apt_install_keyring() {
    local url="$1" dest="$2" armored="${3:-}"
    local tmp; tmp="$(mktemp -p "$RUN_TMPDIR" keyring_XXXXXX)" || return 1
    # ${url%%/*} stops at the // in the scheme and prints "https:".
    local host="${url#*://}"; host="${host%%/*}"
    curl -fsSL "$url" -o "$tmp" 2>/dev/null || {
        substep "${C_YELLOW}Could not download the signing key from ${host}${C_RESET}"
        rm -f "$tmp"; return 1
    }
    [ -s "$tmp" ] || { substep "${C_YELLOW}Signing key came back empty${C_RESET}"; rm -f "$tmp"; return 1; }
    if [ "$armored" = "--armored" ]; then
        # Validate it too. This branch serves three of the five callers, and
        # without a check any 200-response body — a captive portal page, an S3
        # XML error — gets sudo-installed into the trusted keyring directory,
        # after which every apt-get update fails signature verification. That
        # is the exact failure this function exists to prevent.
        if ! gpg --show-keys --with-colons "$tmp" 2>/dev/null | grep -q '^pub'; then
            substep "${C_YELLOW}What came back from ${host} is not a PGP key${C_RESET}"
            rm -f "$tmp"; return 1
        fi
        sudo install -m644 -D "$tmp" "$dest" 2>/dev/null || { rm -f "$tmp"; return 1; }
    else
        gpg --dearmor < "$tmp" > "$tmp.gpg" 2>/dev/null || {
            substep "${C_YELLOW}Signing key is not a valid GPG key${C_RESET}"
            rm -f "$tmp" "$tmp.gpg"; return 1
        }
        [ -s "$tmp.gpg" ] || { rm -f "$tmp" "$tmp.gpg"; return 1; }
        sudo install -m644 -D "$tmp.gpg" "$dest" 2>/dev/null || { rm -f "$tmp" "$tmp.gpg"; return 1; }
    fi
    rm -f "$tmp" "$tmp.gpg"
    return 0
}

# ── eza (Debian/Ubuntu) ───────────────────────────────────────────────────────
ensure_eza_deb() {
    apt_pkg_installed eza && return 0
    apt_install eza
    apt_pkg_installed eza && return 0

    ensure_apt_deps
    apt_install_keyring https://raw.githubusercontent.com/eza-community/eza/main/deb.asc \
        /etc/apt/keyrings/gierens.gpg || return 1
    echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" \
        | sudo tee /etc/apt/sources.list.d/gierens.list >/dev/null
    sudo chmod 644 /etc/apt/sources.list.d/gierens.list
    APT_UPDATED=0
    apt_update_once
    apt_install eza
    apt_pkg_installed eza
}

# ── proton-vpn-cli (Debian/Ubuntu) ────────────────────────────────────────────
# Official ProtonVPN repo bootstrapper — same repo.protonvpn.com/debian path
# serves both Debian and Ubuntu.
ensure_protonvpn_cli_deb() {
    apt_pkg_installed proton-vpn-cli && return 0

    if ! dpkg -s protonvpn-stable-release &>/dev/null; then
        ensure_apt_deps
        local listing_url="https://repo.protonvpn.com/debian/dists/stable/main/binary-all/"
        local listing deb_name tmp
        listing=$(curl -fsSL "$listing_url" 2>/dev/null)
        deb_name=$(grep -oP "protonvpn-stable-release[^\"'>]+\.deb" <<< "$listing" | head -1)
        if [ -n "$deb_name" ]; then
            tmp=$(mktemp -p "$RUN_TMPDIR" protonvpn_XXXXXX.deb)
            if curl -fsSL "${listing_url}${deb_name}" -o "$tmp" 2>/dev/null; then
                sudo env DEBIAN_FRONTEND=noninteractive dpkg -i "$tmp" &>/dev/null 2>&1
            fi
            rm -f "$tmp"
        fi
        APT_UPDATED=0
        apt_update_once
    fi

    apt_install proton-vpn-cli
    apt_pkg_installed proton-vpn-cli
}

# ── Brave (Debian/Ubuntu) ─────────────────────────────────────────────────────
# Confirmed official channel names: brave-origin (stable), brave-origin-beta (beta)
ensure_brave_deb() {
    local channel="$1" pkg="$2"
    apt_pkg_installed "$pkg" && return 0
    ensure_apt_deps

    local host key_url key_file sources_file
    if [[ "$channel" == "beta" ]]; then
        host="brave-browser-apt-beta.s3.brave.com"
        key_url="https://${host}/brave-browser-beta-archive-keyring.gpg"
        key_file="/usr/share/keyrings/brave-browser-beta-archive-keyring.gpg"
        sources_file="/etc/apt/sources.list.d/brave-browser-beta.sources"
    else
        host="brave-browser-apt-release.s3.brave.com"
        key_url="https://${host}/brave-browser-archive-keyring.gpg"
        key_file="/usr/share/keyrings/brave-browser-archive-keyring.gpg"
        sources_file="/etc/apt/sources.list.d/brave-browser-release.sources"
    fi

    apt_install_keyring "$key_url" "$key_file" --armored || return 1
    sudo curl -fsSLo "$sources_file" "https://${host}/brave-browser.sources" &>/dev/null 2>&1 \
        || { substep "${C_YELLOW}Could not download Brave's sources file${C_RESET}"; return 1; }
    APT_UPDATED=0
    apt_update_once
    apt_install "$pkg"
    apt_pkg_installed "$pkg"
}

# ── VS Code (Debian/Ubuntu) ───────────────────────────────────────────────────
# code and code-insiders ship from the same Microsoft repo under the same key,
# differing only in the package name — so one function takes it as an argument.
# The keyring guard is why: picking insiders on its own still installs the key,
# and picking both does not fetch it a second time.
ensure_vscode_deb() {
    local pkg="$1"
    apt_pkg_installed "$pkg" && return 0
    ensure_apt_deps
    if [ ! -s /etc/apt/keyrings/packages.microsoft.gpg ]; then
        apt_install_keyring https://packages.microsoft.com/keys/microsoft.asc \
            /etc/apt/keyrings/packages.microsoft.gpg || return 1
    fi
    echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
        | sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
    APT_UPDATED=0
    apt_update_once
    apt_install "$pkg"
    apt_pkg_installed "$pkg"
}

# ── Flatpak ───────────────────────────────────────────────────────────────────
# A freshly installed flatpak has no remotes, so 'flatpak install <app>' fails
# with "no remote refs found" — the package alone is not usable.
ensure_flathub_remote() {
    command -v flatpak &>/dev/null || return 1
    flatpak remotes 2>/dev/null | grep -q '^flathub' && return 0
    sudo flatpak remote-add --if-not-exists flathub \
        https://dl.flathub.org/repo/flathub.flatpakrepo &>/dev/null 2>&1
}

# ── Claude Desktop (Debian/Ubuntu only — no Arch package) ─────────────────────
ensure_claude_desktop_deb() {
    apt_pkg_installed claude-desktop && return 0
    ensure_apt_deps
    apt_install_keyring https://downloads.claude.ai/claude-desktop/key.asc \
        /usr/share/keyrings/claude-desktop-archive-keyring.asc --armored || return 1
    echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/claude-desktop-archive-keyring.asc] https://downloads.claude.ai/claude-desktop/apt/stable stable main" \
        | sudo tee /etc/apt/sources.list.d/claude-desktop.list >/dev/null
    APT_UPDATED=0
    apt_update_once
    apt_install claude-desktop
    apt_pkg_installed claude-desktop
}

# ── Docker Engine (Debian/Ubuntu) ─────────────────────────────────────────────
# docker.io and the old standalone docker-compose ship different binaries at
# the same paths docker-ce's own packages use — apt refuses to overwrite files
# it does not own, so anything on this list has to go first (Docker's own
# documented pre-install step, not a guess).
ensure_docker_deb() {
    apt_pkg_installed docker-ce && return 0
    ensure_apt_deps

    local pkg
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 docker-buildx podman-docker containerd runc; do
        # apt_get, not a bare sudo apt-get: removing containerd or docker.io is
        # exactly where debconf or needrestart opens a dialog, and where the
        # dpkg lock is still held by whatever ran before us.
        apt_pkg_installed "$pkg" && apt_get remove -y "$pkg" &>/dev/null 2>&1
    done

    local host="debian"
    [ "$IS_UBUNTU" -eq 1 ] && host="ubuntu"
    apt_install_keyring "https://download.docker.com/linux/${host}/gpg" \
        /etc/apt/keyrings/docker.asc --armored || return 1
    local codename; codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
    echo "deb [arch=$(deb_arch) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${host} ${codename} stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    APT_UPDATED=0
    apt_update_once
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    apt_pkg_installed docker-ce
}

# ── Docker post-install (Arch + Debian/Ubuntu) ───────────────────────────────
# nftables-only hosts without the iptable_nat/ip6table_nat kernel modules
# loaded fail dockerd's own NAT chain setup — journalctl shows "CHAIN_ADD
# failed ... chain PREROUTING". Hit on real hardware, not hypothetical: one
# modprobe + retry is the known fix.
docker_start_daemon() {
    sudo systemctl enable --now docker &>/dev/null 2>&1
    systemctl is-active --quiet docker && return 0

    if sudo journalctl -u docker.service -n 50 --no-pager 2>/dev/null \
        | grep -qiE 'CHAIN_ADD failed|iptables.*nat table'; then
        substep "${C_YELLOW}docker.service failed — missing iptable_nat/ip6table_nat kernel modules${C_RESET}"
        sudo systemctl reset-failed docker &>/dev/null 2>&1
        sudo modprobe iptable_nat ip6table_nat &>/dev/null 2>&1
        sudo systemctl start docker &>/dev/null 2>&1
        systemctl is-active --quiet docker && return 0
    fi
    return 1
}

# Group membership, bringing the service up, and WSL — which has no systemd
# running by default, so docker.service has nothing to be enabled into.
docker_postinstall() {
    # id -un, not $USER — the same reason the zsh arm asks the kernel who we
    # are: $USER is unset under cron, `docker exec` and some non-login shells,
    # and `usermod -aG docker ""` then fails. Behind `|| true` that failure went
    # nowhere, and the line under it still claimed the user had been added, on
    # exactly the boxes the rest of this script already defends against.
    local _u; _u="$(id -un)"
    if sudo usermod -aG docker "$_u" &>/dev/null; then
        substep "${C_DIM}${_u} added to the docker group — takes effect on your next login${C_RESET}"
    else
        substep "${C_YELLOW}Could not add ${_u} to the docker group${C_RESET} ${C_DIM}— docker will need sudo until you do${C_RESET}"
    fi

    if [ -d /run/systemd/system ]; then
        if docker_start_daemon; then
            substep "${C_GREEN}docker.service is active${C_RESET}"
        else
            substep "${C_YELLOW}docker.service did not start — check: sudo systemctl status docker${C_RESET}"
        fi
    elif [ "$IS_WSL" -eq 1 ]; then
        if grep -q systemd /etc/wsl.conf 2>/dev/null; then
            substep "${C_YELLOW}systemd is configured in /etc/wsl.conf but not active yet — run 'wsl --shutdown' from Windows, then reopen this terminal${C_RESET}"
        elif [ ! -e /etc/wsl.conf ]; then
            printf '[boot]\nsystemd=true\n' | sudo tee /etc/wsl.conf >/dev/null
            substep "${C_YELLOW}Enabled systemd in /etc/wsl.conf — run 'wsl --shutdown' from Windows, reopen this terminal, then re-run to start docker${C_RESET}"
        else
            substep "${C_YELLOW}Add 'systemd=true' under [boot] in /etc/wsl.conf, then 'wsl --shutdown' and reopen${C_RESET}"
        fi
    else
        substep "${C_YELLOW}No systemd here — start dockerd through your init system${C_RESET}"
    fi
}

# ── vicinae ──────────────────────────────────────────────────────────────────
# The package ships a user unit, and `vicinae toggle` is an IPC call into it —
# so a hotkey bound to the toggle does nothing at all until it is running.
#
# Enabling is safe wherever systemd's *user* instance is reachable. Starting is
# not: the server attaches a layer-shell surface to a compositor, so on a box
# being provisioned ahead of its desktop (--gui with no session yet) it is
# enabled and left for the next login rather than started into nothing.
vicinae_postinstall() {
    # Two separate facts. /run/systemd/system is "systemd is the init here";
    # `systemctl --user` additionally needs a user manager and a session bus,
    # which an SSH login to an account without lingering does not have.
    if [ ! -d /run/systemd/system ] || ! systemctl --user show-environment &>/dev/null; then
        substep "${C_YELLOW}No systemd user session${C_RESET} ${C_DIM}— start it yourself: ${C_ACCENT}vicinae server${C_RESET}"
        return
    fi
    if ! systemctl --user enable vicinae.service &>/dev/null; then
        substep "${C_YELLOW}Could not enable vicinae.service${C_RESET} ${C_DIM}— start it with: ${C_ACCENT}vicinae server${C_RESET}"
        return
    fi
    # `enable` only hooks the unit onto graphical-session.target, and that
    # target is reached by session managers with systemd integration — Plasma
    # and GNOME start it, a bare Hyprland or sway launched from a TTY never
    # does. There the unit is enabled and still dead at every login, which the
    # "is running" line below would otherwise paper over until the next reboot.
    if [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ] \
        && ! systemctl --user is-active --quiet graphical-session.target; then
        substep "${C_YELLOW}This session never reaches graphical-session.target${C_RESET} ${C_DIM}— enabled, but it will not come back by itself: add ${C_ACCENT}exec-once = vicinae server${C_RESET} ${C_DIM}to your compositor config${C_RESET}"
    fi
    # Already up as the unit: enabling was the only thing missing.
    if systemctl --user is-active --quiet vicinae.service; then
        substep "${C_GREEN}vicinae.service is running${C_RESET}"
        return
    fi
    # Up, but started some other way — a compositor's exec-once line, or by
    # hand. The unit runs `vicinae server --replace`, so starting it now would
    # kill and relaunch a live launcher mid-session to gain nothing: it is
    # enabled either way, so the next login is the managed one.
    if command -v pgrep &>/dev/null && pgrep -x vicinae-server &>/dev/null; then
        substep "${C_DIM}vicinae is already running — the unit takes over at your next login${C_RESET}"
        return
    fi
    if [ -z "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]; then
        substep "${C_DIM}vicinae.service enabled — starts with your next graphical session${C_RESET}"
        return
    fi
    # Checked against reality rather than the exit status, the way every other
    # service and installer in here is: `start` returning 0 and the unit dying
    # a second later is the failure this is here to catch.
    systemctl --user start vicinae.service &>/dev/null
    if systemctl --user is-active --quiet vicinae.service; then
        substep "${C_GREEN}vicinae.service is running${C_RESET}"
    else
        substep "${C_YELLOW}vicinae.service enabled but did not start${C_RESET} ${C_DIM}— check: ${C_ACCENT}systemctl --user status vicinae${C_RESET}"
    fi
}

# ── Fonts (Debian/Ubuntu — neither is packaged in apt) ───────────────────────
FONT_DIR_DEB="$HOME/.local/share/fonts/JetBrainsMono"
MAPLE_FONT_DIR_DEB="$HOME/.local/share/fonts/MapleMono"
SYMBOLS_FONT_DIR_DEB="$HOME/.local/share/fonts/NerdFontsSymbols"

font_dir_has_ttf() {
    [ -d "$1" ] && find "$1" -name '*.ttf' -print -quit 2>/dev/null | grep -q .
}

font_installed_deb()       { font_dir_has_ttf "$FONT_DIR_DEB"; }
maple_font_installed_deb() { font_dir_has_ttf "$MAPLE_FONT_DIR_DEB"; }
symbols_font_installed_deb() { font_dir_has_ttf "$SYMBOLS_FONT_DIR_DEB"; }

# Fetch a font zip from a GitHub release into ~/.local/share/fonts/<dir>.
# fontconfig is not guaranteed on a minimal/server image — without fc-cache the
# fonts land on disk but nothing can see them, so make sure it is there first.
install_font_zip() {
    local url="$1" dir="$2"
    ensure_apt_deps
    ensure_unzip
    command -v fc-cache &>/dev/null || apt_install fontconfig
    local tmp; tmp=$(mktemp -d -p "$RUN_TMPDIR" font_XXXXXX)
    if curl -fsSL "$url" -o "$tmp/font.zip" 2>/dev/null; then
        mkdir -p "$dir"
        unzip -oq "$tmp/font.zip" -d "$dir" '*.ttf' &>/dev/null 2>&1
        fc-cache -f "$dir" &>/dev/null 2>&1
    fi
    rm -rf "$tmp"
}

ensure_nerd_font_deb() {
    font_installed_deb && return 0
    install_font_zip "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip" \
                     "$FONT_DIR_DEB"
    font_installed_deb
}

ensure_maple_font_deb() {
    maple_font_installed_deb && return 0
    install_font_zip "https://github.com/subframe7536/maple-font/releases/latest/download/MapleMono-TTF.zip" \
                     "$MAPLE_FONT_DIR_DEB"
    maple_font_installed_deb
}

ensure_symbols_font_deb() {
    symbols_font_installed_deb && return 0
    install_font_zip "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/NerdFontsSymbolsOnly.zip" \
                     "$SYMBOLS_FONT_DIR_DEB"
    symbols_font_installed_deb
}

font_installed() {
    if [[ "$DISTRO" == "arch" ]]; then
        pkg_installed "$FONT_PKG"
    else
        font_installed_deb
    fi
}

install_font() {
    if [[ "$DISTRO" == "arch" ]]; then
        arch_install "$FONT_PKG"
    else
        ensure_nerd_font_deb
    fi
}

# wezterm renders its tab bar and the powerline glyphs in a config with this
# font and nothing else — so it is installed silently alongside it rather than
# offered as a choice. Not in FONT_PKG/MAPLE_FONT_PKG territory: those two go
# in on every run that installs a config, this one only follows one app.
SYMBOLS_FONT_PKG="ttf-nerd-fonts-symbols-mono"

install_symbols_font() {
    if [[ "$DISTRO" == "arch" ]]; then
        pkg_installed "$SYMBOLS_FONT_PKG" && return 0
        arch_install "$SYMBOLS_FONT_PKG"
    else
        ensure_symbols_font_deb
    fi
}

maple_font_installed() {
    if [[ "$DISTRO" == "arch" ]]; then
        pkg_installed "$MAPLE_FONT_PKG"
    else
        maple_font_installed_deb
    fi
}

install_maple_font() {
    if [[ "$DISTRO" == "arch" ]]; then
        # AUR-only on Arch — pacman cannot resolve it
        arch_install "$MAPLE_FONT_PKG"
    else
        ensure_maple_font_deb
    fi
}

# ── bat/fd binary-name shims (Debian/Ubuntu ship batcat/fdfind) ──────────────
ensure_bat_shim() {
    command -v bat &>/dev/null && return 0
    command -v batcat &>/dev/null || return 1
    mkdir -p "$HOME/.local/bin"
    ln -sf "$(command -v batcat)" "$HOME/.local/bin/bat"
}

ensure_fd_shim() {
    command -v fd &>/dev/null && return 0
    command -v fdfind &>/dev/null || return 1
    mkdir -p "$HOME/.local/bin"
    ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
}

# ── Fallback: hand an interactive bash session over to zsh ───────────────────
# Some machines keep starting bash after login even though /etc/passwd has been
# updated and reads back correctly — SSH sessions on cloud images are the usual
# offender. A guarded hook in .bashrc makes the switch happen regardless of why
# the passwd entry is being ignored. Idempotent, and only written once zsh has
# been confirmed to actually run.
same_shell() {
    # /bin/zsh and /usr/bin/zsh are one file on Debian/Ubuntu, where /bin is a
    # symlink to usr/bin — comparing the strings would report a shell that was
    # set correctly as still unchanged.
    [ -n "$1" ] && [ -n "$2" ] || return 1
    [ "$(readlink -f "$1" 2>/dev/null || printf '%s' "$1")" = \
      "$(readlink -f "$2" 2>/dev/null || printf '%s' "$2")" ]
}

# ── The pristine ~/.bashrc ───────────────────────────────────────────────────
# Written once, ever. Neither name contains "dotfiles": these live in $HOME,
# and private mode exists to remove exactly that kind of trace.
PRISTINE_BASHRC="$HOME/.bashrc.orig"
PRISTINE_ABSENT="$HOME/.bashrc.none"

# True when <path> is a stow symlink into the checkout — ours, put there by an
# earlier run. Two different rules hang off it:
#   * never write *through* one: that edits the repo itself, dirtying the
#     working tree and shipping the edit to everyone who clones it
#   * removing one is safe and is the whole idempotent re-stow — while removing
#     any *other* symlink destroys something only the user has
# A dangling link still counts as ours if it resolves under the checkout, since
# stow is about to recreate it. One that resolves nowhere at all (its parent
# directory is gone too) fails the readlink and is treated as foreign, which is
# the safe way round.
is_repo_link() {
    local p="$1" t d
    [ -L "$p" ] || return 1
    t="$(readlink -f "$p" 2>/dev/null)" || return 1
    d="$(readlink -f "$DOTFILES_DIR" 2>/dev/null || printf '%s' "$DOTFILES_DIR")"
    [ -n "$t" ] && [ -n "$d" ] && [[ "$t" == "$d"/* ]]
}

# Keep a copy of ~/.bashrc as it was before this installer ever touched it.
#
# Deliberately not gated on $BACKUP_MODE. Delete mode is a statement about the
# user's old *configs*; it is not permission to destroy the only copy of a file
# this script is about to edit, and which --restore-bash needs to put back.
snapshot_bashrc() {
    local rc="$HOME/.bashrc"
    # Write-once. A second run must never overwrite the pristine copy with one
    # that already carries our hook.
    [ -e "$PRISTINE_BASHRC" ] && return 0
    [ -e "$PRISTINE_ABSENT" ] && return 0

    # If ~/.bashrc is a stow symlink into the checkout, the file behind it is
    # the repo's, not the user's. Copying that would record the repo's own rc
    # as "the original" — permanently, because of the write-once rule above.
    # -e follows the link, so none of the tests below would notice.
    is_repo_link "$rc" && return 0

    if [ ! -e "$rc" ]; then
        # Record the absence, so a restore knows to remove what we created
        # rather than leave a file the machine never had.
        printf '%s\n' "there was no ~/.bashrc before the dotfiles installer ran" \
            > "$PRISTINE_ABSENT" 2>/dev/null || return 1
        return 0
    fi

    # A .bashrc that already carries the hook is not an original — that is
    # every machine an earlier version of this installer has run on, including
    # the author's. Snapshot it hook-free or the write-once guarantee preserves
    # the wrong thing permanently.
    #
    # bashrc_hook_range is tri-state and this has to branch on all three. A
    # binary if sends status 2 — a BEGIN marker whose END was hand-deleted —
    # down the plain-copy path, which preserves the broken block *as the
    # original*, forever. --restore-bash would then faithfully put a file back
    # that still execs zsh and report success.
    bashrc_hook_range "$rc" >/dev/null 2>&1
    case "$?" in
        0) bashrc_hook_strip_to "$rc" "$PRISTINE_BASHRC" || return 1 ;;
        1) cp -p "$rc" "$PRISTINE_BASHRC" 2>/dev/null || return 1 ;;
        *) # Malformed. Refuse rather than record something we cannot vouch for;
           # the caller reports it and nothing is written, so a later run can
           # still take a good snapshot once the file is repaired.
           return 1 ;;
    esac
    return 0
}

# The tag is stable across versions and is what detection and removal match on,
# so a block written by any past version is still found. v1 said
# "dotfiles: <tag>"; the optional group below still catches it — and dropping
# that word from v2 takes the repo's name back out of $HOME/.bashrc, which
# private mode never scrubbed.
HOOK_TAG='hand interactive bash to zsh'
HOOK_BEGIN="# >>> ${HOOK_TAG} (v2) >>>"
HOOK_END="# <<< ${HOOK_TAG} (v2) <<<"
HOOK_BEGIN_RE="^# >>> (dotfiles: )?${HOOK_TAG}"
HOOK_END_RE="^# <<< (dotfiles: )?${HOOK_TAG}"

# Prints "<first> <last>" for the hook block in a file.
#   0 found · 1 not present · 2 a begin with no matching end
bashrc_hook_range() {
    local f="$1" b e
    [ -f "$f" ] || return 1
    b="$(grep -nE "$HOOK_BEGIN_RE" "$f" 2>/dev/null | head -1 | cut -d: -f1)"
    [ -n "$b" ] || return 1
    e="$(awk -v s="$b" 'NR>=s' "$f" 2>/dev/null | grep -nE "$HOOK_END_RE" | head -1 | cut -d: -f1)"
    # Hand-edited past recognition. Refuse rather than let an open-ended range
    # delete everything from the marker to the end of the file.
    [ -n "$e" ] || return 2
    printf '%s %s' "$b" "$(( b + e - 1 ))"
}

# Copy src to dst with the hook block removed. dst may be src.
bashrc_hook_strip_to() {
    local src="$1" dst="$2" range b e tmp
    is_repo_link "$dst" && return 2
    range="$(bashrc_hook_range "$src")" || {
        [ "$?" = 2 ] && return 2
        # Nothing to strip — still produce dst.
        [ "$src" = "$dst" ] || cp -p "$src" "$dst" 2>/dev/null || return 1
        return 0
    }
    b="${range% *}"; e="${range#* }"
    tmp="$(mktemp -p "$RUN_TMPDIR" bashrc_XXXXXX)" || return 1
    awk -v b="$b" -v e="$e" 'NR<b || NR>e' "$src" > "$tmp" 2>/dev/null || return 1
    # cat rather than mv, so an existing dst keeps its inode and permissions.
    cat "$tmp" > "$dst" 2>/dev/null || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    return 0
}

# The block itself, as a single source of truth for writing and previewing.
bashrc_hook_block() {
    cat <<EOF
$HOOK_BEGIN
# Interactive bash only. \`ssh host cmd\`, scp, rsync and sftp all source this
# file with no 'i' in \$- — one exec here breaks every one of them. That is
# what the old \`[ -t 1 ]\` test failed to catch, since stdout is not a tty
# there either.
case \$- in
    *i*) ;;
      *) return ;;
esac
# Escape hatch, for when you want bash and mean it:
#     DOTFILES_NO_ZSH=1 bash
# To undo permanently: delete this block, or run
#     bash ~/dotfiles/install.sh --restore-bash
if [ -z "\${ZSH_VERSION:-}" ] && [ -z "\${DOTFILES_NO_ZSH:-}" ]; then
    _zsh_bin=\$(command -v zsh 2>/dev/null)
    # Verified, not assumed. A zsh that is on PATH but cannot actually start
    # would otherwise end every new session instantly — on a machine you may
    # only be able to reach through one.
    if [ -n "\$_zsh_bin" ] && [ -x "\$_zsh_bin" ] && "\$_zsh_bin" -c exit >/dev/null 2>&1; then
        unset _zsh_bin
        exec zsh -l
    fi
    unset _zsh_bin
fi
$HOOK_END
EOF
}

# Selecting the bash config is an explicit request for a working bash, so the
# hand-off hook — which exists only as a fallback for a passwd change being
# ignored — has no business firing out of it. The login shell still becomes
# zsh; that is the zsh package's job and is unaffected.
#
# Two layers, both needed. This one is the decision; ensure_zsh_autoexec's own
# repo-symlink check is the safety net, and catches the case where bash was
# stowed by an earlier run and only zsh is selected now. Ordering cannot fix
# either, because the numeric fallback menu installs in the order typed.
zsh_hook_wanted() {
    printf '%s\n' "${SELECTED[@]}" | grep -qx bash && return 1
    return 0
}

# Why the hook was or was not written, so the caller can say something true.
_HOOK_STATE=""

ensure_zsh_autoexec() {
    local rc="$HOME/.bashrc"
    _HOOK_STATE=""
    command -v zsh &>/dev/null && zsh -c 'exit 0' &>/dev/null || return 1

    # Never write through a stow symlink into the checkout.
    if is_repo_link "$rc"; then
        _HOOK_STATE="skipped-repo-link"
        return 1
    fi

    snapshot_bashrc || return 1

    if [ -f "$rc" ] && grep -qF "$HOOK_BEGIN" "$rc" 2>/dev/null; then
        _HOOK_STATE="present"
        return 0
    fi

    # An older block: replace it rather than stacking a second one on top.
    # Only the exit status matters here (0 found / 1 absent / 2 malformed), so
    # the range itself is discarded — bashrc_hook_strip_to looks it up again.
    if bashrc_hook_range "$rc" >/dev/null; then
        bashrc_hook_strip_to "$rc" "$rc" || { _HOOK_STATE="malformed"; return 1; }
        _HOOK_STATE="migrated"
    elif [ "$?" = 2 ]; then
        _HOOK_STATE="malformed"
        return 1
    fi

    { printf '\n'; bashrc_hook_block; } >> "$rc" || return 1
    [ "$_HOOK_STATE" = "migrated" ] || _HOOK_STATE="added"
    return 0
}

# ── Private: remove the repo, and any sign of who owns it ────────────────────
# Two kinds of target. Repo scaffolding is deleted outright — it has no value
# once the configs are stowed. Live configs are scrubbed instead: they have to
# keep working, they just must not carry a name, an address or a URL.
#
# tests/, .editorconfig and .shellcheckrc are on the list because stripping the
# git metadata alone left the *shape* of a checkout behind: a directory holding
# tests/run.sh and a shellcheck config is a clone whatever .git says, and the
# line printed above the prompt promises no sign that ~/dotfiles came from a
# repo. Nothing under tests/ is read at runtime, so a re-run is unaffected.
# doctor.sh deliberately stays: it carries no name, handle or URL, it is
# read-only, and it is the thing to run when the install misbehaves later — it
# already reports git metadata as "stripped (private mode)".
PRIVATE_DELETE=(menu_temp tests .git .github .gitignore .gitattributes
                .editorconfig .shellcheckrc
                README.md CLAUDE.md LICENSE LICENSE.md linux.sh)

# file → what is taken out of it
PRIVATE_SCRUB_FILES=(git/.gitconfig fastfetch/config.jsonc install.sh)
PRIVATE_SCRUB_WHAT=("user.name and user.email"
                    "author byline (name, GitHub handle, contact address)"
                    "hosted bootstrap domain in comments")

private_preview() {
    local d="$DOTFILES_DIR" item i present=()
    for item in "${PRIVATE_DELETE[@]}"; do
        { [ -e "$d/$item" ] || [ -L "$d/$item" ]; } && present+=("$item")
    done
    if [ "${#present[@]}" -gt 0 ]; then
        echo -e "${C_MAIN}${C_BOLD} ${G_MID}    ${C_RED}delete${C_RESET} ${C_DIM}${present[*]}${C_RESET}"
    else
        echo -e "${C_MAIN}${C_BOLD} ${G_MID}    ${C_DIM}delete  nothing left to remove${C_RESET}"
    fi
    for i in "${!PRIVATE_SCRUB_FILES[@]}"; do
        [ -f "$d/${PRIVATE_SCRUB_FILES[$i]}" ] || continue
        printf "${C_MAIN}${C_BOLD} ${G_MID}    ${C_YELLOW}scrub${C_RESET}  ${C_DIM}%-24s %s${C_RESET}\n" \
            "${PRIVATE_SCRUB_FILES[$i]}" "${PRIVATE_SCRUB_WHAT[$i]}"
    done
}

# Take the identifying lines out of a config without breaking it
private_scrub() {
    local d="$DOTFILES_DIR" done_any=0

    # Remembered before it is removed, so the folder can be checked for leftovers
    # at the end — nothing about the identity is hardcoded here.
    local ident=()
    if [ -f "$d/git/.gitconfig" ]; then
        mapfile -t ident < <(sed -nE 's/^[[:space:]]*(name|email)[[:space:]]*=[[:space:]]*//p' \
            "$d/git/.gitconfig" 2>/dev/null)

        if command -v git &>/dev/null; then
            git config --file "$d/git/.gitconfig" --unset user.name  2>/dev/null
            git config --file "$d/git/.gitconfig" --unset user.email 2>/dev/null
        fi
        # Verified, not assumed: git may be missing, and a wrapper or shim can
        # exit 0 having done nothing. What matters is that the lines are gone.
        if grep -qE '^[[:space:]]*(name|email)[[:space:]]*=' "$d/git/.gitconfig" 2>/dev/null; then
            sed -i -E '/^[[:space:]]*(name|email)[[:space:]]*=/d' "$d/git/.gitconfig" 2>/dev/null
        fi
        done_any=1
    fi

    # The whole leading comment block of the fastfetch config is the byline.
    # Matched structurally rather than by name — hardcoding the name here would
    # just move the leak into this script.
    if [ -f "$d/fastfetch/config.jsonc" ]; then
        local tmp_ff="${RUN_TMPDIR}/ff.jsonc"
        if awk 'BEGIN{head=1}
                head && (/^[[:space:]]*\/\// || /^[[:space:]]*$/) {next}
                {head=0} {print}' "$d/fastfetch/config.jsonc" > "$tmp_ff" 2>/dev/null \
           && [ -s "$tmp_ff" ]; then
            cat "$tmp_ff" > "$d/fastfetch/config.jsonc"
        fi
        rm -f "$tmp_ff"
        done_any=1
    fi

    # Any hosted bootstrap URL mentioned in this script's own comments. Done
    # last: sed -i replaces the file by rename, so the running shell keeps
    # reading the original inode and cannot be corrupted mid-run.
    if [ -f "$d/install.sh" ]; then
        sed -i -E 's#(https?://)?[A-Za-z0-9._-]+/linux\.sh#the hosted bootstrap script#g' \
            "$d/install.sh" 2>/dev/null
        done_any=1
    fi

    # A privacy feature that cannot say whether it worked is not worth much.
    # Search the folder for the identity that was there a moment ago.
    local leak=() v
    for v in "${ident[@]}"; do
        [ -n "$v" ] || continue
        grep -rqiF -- "$v" "$d" 2>/dev/null && leak+=("$v")
    done
    if [ "${#leak[@]}" -gt 0 ]; then
        substep "${C_YELLOW}Still present in ${d}: ${leak[*]}${C_RESET}"
        substep "${C_DIM}Remove those by hand — everything else was scrubbed${C_RESET}"
        # Finding the user's name still in the tree and then returning success
        # is the wrong outcome for a privacy feature: the caller would print
        # "Scrubbed: name, address and URLs" directly underneath it.
        PRIVATE_LEAKED=("${leak[@]}")
        return 2
    fi
    PRIVATE_LEAKED=()

    return $(( 1 - done_any ))
}

# ── Strip every trace that ~/dotfiles came from a git repo ───────────────────
# The stowed configs are symlinks *into* ~/dotfiles, so the directory itself has
# to stay — what goes is anything identifying it as a clone: git metadata (the
# remote URL, the full commit history, the author name and email), the repo
# documentation, and linux.sh, which carries the GitHub URL. install.sh and the
# config folders are kept, so the checkout still works and can be re-run.
strip_repo_traces() {
    local d="$DOTFILES_DIR"
    # Refuse to touch anything that is not recognisably the dotfiles checkout
    [ -n "$d" ] && [ -d "$d" ] && [ -f "$d/install.sh" ] || return 1
    [ "$d" != "/" ] && [ "$d" != "$HOME" ] || return 1

    local removed=() item
    STRIP_SURVIVED=()
    PRIVATE_LEAKED=()
    for item in "${PRIVATE_DELETE[@]}"; do
        { [ -e "$d/$item" ] || [ -L "$d/$item" ]; } || continue
        rm -rf "${d:?}/${item:?}" 2>/dev/null
        if [ -e "$d/$item" ] || [ -L "$d/$item" ]; then
            # A clone made under a different uid, or a directory left without
            # write permission, cannot be unlinked through — but can be after
            # a chmod. Worth one retry before giving up on it.
            chmod -R u+rwX "${d:?}/${item:?}" 2>/dev/null || true
            rm -rf "${d:?}/${item:?}" 2>/dev/null
        fi
        # Verified, not assumed. This used to record success from rm's exit
        # status and then print "No git metadata left" regardless — the one
        # sentence in the whole run that had to be true.
        if [ -e "$d/$item" ] || [ -L "$d/$item" ]; then
            STRIP_SURVIVED+=("$item")
        else
            removed+=("$item")
        fi
    done

    if [ "${#removed[@]}" -gt 0 ]; then
        substep "Removed: ${C_DIM}${removed[*]}${C_RESET}"
    elif [ "${#STRIP_SURVIVED[@]}" -eq 0 ]; then
        substep "${C_DIM}Nothing left to remove${C_RESET}"
    fi

    private_scrub; local _scrub=$?
    case "$_scrub" in
        0) substep "Scrubbed: ${C_DIM}name, address and URLs from the remaining configs${C_RESET}" ;;
        2) STRIP_SURVIVED+=("identity still in: ${PRIVATE_LEAKED[*]}") ;;
    esac
    [ "${#STRIP_SURVIVED[@]}" -eq 0 ] || return 2
    return 0
}

# ── Stow package directly into ~/.config/<name>/ (flat repo structure) ────────
stow_config() {
    local name="$1"
    # Both branches below reach an rm -rf on $target. Every caller passes a
    # literal today, but a future one passing an empty name would aim that at
    # ~/.config itself — cheap to make impossible, expensive to discover.
    [ -n "$name" ] || return 1
    local target="$HOME/.config/$name"
    local bak="${target}.bak"
    local oldbak="${target}.old.bak"

    if is_repo_link "$target"; then
        # Dir-level symlink from an old wrong stow — ours, and the stow below
        # puts it back.
        rm "$target"

    elif [ -L "$target" ]; then
        # Not ours: the user pointed ~/.config/<name> somewhere themselves.
        # `rm` here was the same silent, backup-less delete backup_file had.
        # Decided before the -d branch, because -d follows the link and would
        # judge it by contents that are not what gets moved — the link is.
        # backup_file already rotates, backs up or deletes-and-says-so, and its
        # wording is this branch's wording.
        backup_file "$target"

    elif [ -d "$target" ]; then
        # Only real files (not symlinks, not dirs) need handling — stow -D
        # removes our own symlinks; foreign symlinks coexist or cause a conflict.
        if find "$target" -mindepth 1 -maxdepth 3 \
                ! -type l ! -type d 2>/dev/null | grep -q .; then
            if [[ "$BACKUP_MODE" == "delete" ]]; then
                rm -rf "$target"
                # The path, not the bare name: "Deleted btop" in the middle of
                # the dep-tool installs reads like the tool was removed.
                substep "Deleted ${C_ACCENT}~/.config/${name}${C_RESET}"
            else
                # -L as well as -e, the same as backup_file: a .bak that is
                # itself a backed-up broken symlink is invisible to -e, and the
                # mv below then fails against it instead of rotating it.
                if [ -e "$bak" ] || [ -L "$bak" ]; then
                    { [ -e "$oldbak" ] || [ -L "$oldbak" ]; } && rm -rf "$oldbak"
                    mv "$bak" "$oldbak"
                fi
                mv "$target" "$bak"
                substep "Backed up ${C_ACCENT}~/.config/${name}${C_RESET} → ${C_DIM}${name}.bak${C_RESET}"
            fi
        fi
        # Only symlinks / empty dir: nothing to do — stow_to -D cleans ours
    fi

    # Explicitly create the target dir before stowing.
    # Needed when: (a) it never existed, (b) it was just moved to .bak above.
    mkdir -p "$target"
    stow_to "$target" "$name"
}

# ── Claude Code statusLine wiring ────────────────────────────────────────────
# The command Claude Code gets pointed at. `@latest` is what keeps the
# statusline current with nothing to update; the second link is what stops it
# going blank, because Claude Code blanks the line for any command that exits
# non-zero or prints nothing — and `bunx …@latest` does exactly that when the
# registry cannot be reached. Plain `bunx ccstatusline` resolves from bun's
# cache instead, so an offline machine still renders.
CCSTATUSLINE_CMD='bunx -y ccstatusline@latest 2>/dev/null || bunx -y ccstatusline'

# Point Claude Code at ccstatusline by merging one key into its settings.json.
#
# That file is Claude Code's, not this repo's: it carries the signed-in account,
# the plugin registry and the permission rules. It is the second file the
# installer edits rather than stows (after ~/.bashrc), and every rule below is
# here because a corrupted settings.json is a Claude Code that will not start:
#   * only statusLine is written — every other key is preserved exactly
#   * a statusLine already pointing at something else is left alone and said so;
#     silently replacing someone's own script is not this installer's call
#   * JSON that does not parse is not touched at all, only reported
#   * the result is parsed back before it replaces anything, and moved into
#     place with mv, so an interrupt cannot leave a truncated settings.json
#   * BACKUP_MODE=delete never reaches it — delete mode drops what this repo
#     installed, and this file was here first
wire_claude_statusline() {
    local f="$HOME/.claude/settings.json"

    # No hand-rolled JSON editing. sed-ing someone's settings.json is how the
    # file ends up unparseable, which is the one outcome worth avoiding here.
    if ! command -v python3 &>/dev/null; then
        substep "${C_YELLOW}python3 not found${C_RESET} ${C_DIM}— set${C_RESET} ${C_ACCENT}statusLine.command${C_RESET} ${C_DIM}to${C_RESET} ${C_ACCENT}${CCSTATUSLINE_CMD}${C_RESET} ${C_DIM}by hand${C_RESET}"
        return 0
    fi

    mkdir -p "$HOME/.claude" 2>/dev/null || return 0

    # Deliberately NOT $RUN_TMPDIR: that lives in /tmp, which is a different
    # filesystem (often tmpfs), and mv across filesystems is copy-then-unlink —
    # interruptible halfway, which is exactly the truncated settings.json this
    # whole function exists to avoid. Same directory as the target makes the mv
    # a rename, which is atomic.
    local tmp; tmp=$(mktemp -p "$HOME/.claude" .settings.json.new_XXXXXX) || return 0

    # stdout carries advisory notes, the exit status carries the outcome.
    local out rc
    out=$(CC_SETTINGS="$f" CC_CMD="$CCSTATUSLINE_CMD" CC_TMP="$tmp" \
          CC_MANAGED="${CC_MANAGED_SETTINGS:-/etc/claude-code/managed-settings.json}" \
          python3 - <<'PY'
import json, os, sys
from collections import OrderedDict

path, cmd, tmp = os.environ["CC_SETTINGS"], os.environ["CC_CMD"], os.environ["CC_TMP"]


def load(p):
    """Parsed dict, or None if it is missing or not a JSON object."""
    try:
        with open(p, encoding="utf-8") as fh:
            d = json.load(fh, object_pairs_hook=OrderedDict)
    except Exception:
        return None
    return d if isinstance(d, dict) else None


# ~/.claude/settings.json is the *lowest* precedence scope Claude Code reads:
# managed, command line, project-local and project settings all beat it. A
# statusLine written underneath one that already exists higher up is a no-op
# that looks like success, so report it rather than claim the wiring worked.
# Only the managed file is knowable from here — project scopes depend on which
# directory Claude Code is started in.
managed = os.environ.get("CC_MANAGED", "")
if managed:
    m = load(managed)
    if m is not None and m.get("statusLine"):
        print("shadowed")

if os.path.exists(path):
    data = load(path)
    if data is None:
        sys.exit(3)                       # unparseable — do not touch it
else:
    data = OrderedDict()

existing = data.get("statusLine")
if isinstance(existing, dict):
    cur = existing.get("command", "")
    # Already in there and already right: nothing to merge, leave the file
    # alone entirely rather than rewrite it to identical content.
    if cur == cmd and existing.get("type") == "command":
        sys.exit(1)
    if "ccstatusline" not in cur:
        sys.exit(2)                       # somebody else's statusline — leave it
    line = existing                       # ours, but an older command: update
else:
    line = OrderedDict()
    data["statusLine"] = line

line["type"] = "command"
line["command"] = cmd
# setdefault, not assignment: if these were tuned by hand they stay tuned.
line.setdefault("padding", 0)
line.setdefault("refreshInterval", 10)    # seconds; the documented minimum is 1

with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
    fh.write("\n")

# Read it back before it is allowed to replace anything.
with open(tmp, encoding="utf-8") as fh:
    json.load(fh)
sys.exit(0)
PY
)
    rc=$?

    case "$rc" in
      0)
        # Keep one copy of whatever was there before the first edit. Write-once,
        # so re-running never overwrites the pristine copy with an edited one —
        # the same rule the .bashrc snapshot follows.
        [ -e "$f" ] && [ ! -e "${f}.orig" ] && cp -p "$f" "${f}.orig" 2>/dev/null
        if mv "$tmp" "$f"; then
            substep "Claude Code statusline ${C_GREEN}wired up${C_RESET}"
        else
            rm -f "$tmp"
            substep "${C_YELLOW}Could not write ~/.claude/settings.json${C_RESET}"
        fi
        ;;
      1) rm -f "$tmp"; substep "${C_DIM}Claude Code statusline already wired up${C_RESET}" ;;
      2) rm -f "$tmp"
         substep "${C_YELLOW}Left your existing statusLine alone${C_RESET} ${C_DIM}— it does not point at ccstatusline${C_RESET}" ;;
      3) rm -f "$tmp"
         substep "${C_YELLOW}~/.claude/settings.json is not valid JSON${C_RESET} ${C_DIM}— left untouched${C_RESET}" ;;
      *) rm -f "$tmp"
         substep "${C_YELLOW}Could not update ~/.claude/settings.json${C_RESET} ${C_DIM}— left untouched${C_RESET}" ;;
    esac

    # Said after the outcome, not instead of it: the merge itself succeeded,
    # it just will not be the statusLine that wins.
    if [[ "$out" == *shadowed* ]]; then
        substep "${C_YELLOW}A managed statusLine overrides it${C_RESET} ${C_DIM}— user settings are the lowest precedence scope${C_RESET}"
    fi
    return 0
}

# ── Backup a single file or dir (for home/ and scripts/ → ~) ─────────────────
backup_file() {
    local target="$1"
    # Same reasoning as stow_config: delete mode rm -rf's this path.
    [ -n "$target" ] || return 1
    local bak="${target}.bak"
    local oldbak="${target}.old.bak"
    local name; name="$(basename "$target")"
    local shown="${target/#$HOME/\~}"

    # Only *our* symlink is disposable — stow puts it straight back. This used
    # to be a bare `[ -L ]`, which quietly rm'd any symlink at all, in backup
    # mode too: someone keeping ~/.zshrc pointed at a sync folder lost the link
    # with no .bak and not one word said. A foreign link is the user's file as
    # far as this function is concerned, so it takes the same path as a real
    # one. Broken ones included — an unresolvable target is usually a drive
    # that is not mounted right now, and the link is the only record of where
    # they wanted it.
    if is_repo_link "$target"; then
        rm "$target"
    elif [ -e "$target" ] || [ -L "$target" ]; then
        if [[ "$BACKUP_MODE" == "delete" ]]; then
            rm -rf "$target"
            substep "Deleted ${C_ACCENT}${shown}${C_RESET}"
        else
            # -L as well as -e, or a .bak that is itself a backed-up broken
            # symlink is invisible here and mv overwrites it without rotating.
            if [ -e "$bak" ] || [ -L "$bak" ]; then
                { [ -e "$oldbak" ] || [ -L "$oldbak" ]; } && rm -rf "$oldbak"
                mv "$bak" "$oldbak"
                substep "Rotated ${C_DIM}${name}.bak → ${name}.old.bak${C_RESET}"
            fi
            mv "$target" "$bak"
            substep "Backed up ${C_ACCENT}${shown}${C_RESET} → ${C_DIM}${name}.bak${C_RESET}"
        fi
    fi
}

# ── Stow to an arbitrary target dir ──────────────────────────────────────────
# Usage: stow_to <target-dir> <package-name>
stow_to() {
    local target_dir="$1"
    local name="$2"
    mkdir -p "$target_dir"
    # Un-stow first so re-runs are idempotent
    stow --target "$target_dir" --dir "$DOTFILES_DIR" -D "$name" &>/dev/null 2>&1 || true
    if ! stow --target "$target_dir" --dir "$DOTFILES_DIR" "$name" &>/dev/null 2>&1; then
        error "Stow failed for ${C_ACCENT}${name}${C_RESET} — check for conflicts in ${target_dir}/"
        return 1
    fi
    return 0
}

# ── Stow to ~ (zsh, etc.) ────────────────────────────────────────────────────
stow_home() {
    stow_to "$HOME" "$1"
}

# ── App + package mapping ─────────────────────────────────────────────────────
declare -A PKG_MAP
PKG_MAP[fastfetch]="fastfetch"
PKG_MAP[ghostty]="ghostty"
PKG_MAP[kitty]="kitty"
PKG_MAP[zsh]="zsh"
PKG_MAP[bash]="bash"
PKG_MAP[protonvpn]="proton-vpn-cli"
PKG_MAP[starship]="starship"
PKG_MAP[rofi]="rofi"
PKG_MAP[ulauncher]="ulauncher"
PKG_MAP[git]="git"
PKG_MAP[micro]="micro"
# Not a package on either distro: the statusline runs as `bunx …@latest`, so
# bun is the whole dependency. Named here because show_plan reads PKG_MAP for
# every config before it reaches the per-config case.
PKG_MAP[ccstatusline]="bun"
# AUR-only on Arch, a GitHub-release .deb on Debian/Ubuntu — and the two name
# the package differently, which every pkg_installed check here goes through.
PKG_MAP[fresh]="fresh-editor-bin"
[[ "$DISTRO" == "debian" ]] && PKG_MAP[fresh]="fresh-editor"

# Debian/Ubuntu install-method overrides, same shape as DEP_PKG_DEB/APP_TYPE_DEB:
# an entry only where a plain `apt install` will not do. Absent means apt.
declare -A DEB_INSTALLER
DEB_INSTALLER[ghostty]="ensure_ghostty_deb"
DEB_INSTALLER[fastfetch]="ensure_fastfetch_deb"
DEB_INSTALLER[fresh]="ensure_fresh_deb"
DEB_INSTALLER[protonvpn]="ensure_protonvpn_cli_deb"
DEB_INSTALLER[starship]="ensure_starship_deb"
DEB_INSTALLER[ulauncher]="ensure_ulauncher_deb"

# The install-or-fail preamble every config arm opened with — six near-identical
# copies of it, which is how the wording drifted apart between them. Returns
# non-zero on failure; the `continue` stays at the call site because it has to
# continue the config loop, not this function.
#   ensure_cfg_pkg <cfg> <pkg>   # pkg already resolved by PKG_MAP, per distro
ensure_cfg_pkg() {
    local cfg="$1" pkg="$2"
    if pkg_installed "$pkg"; then
        substep "${C_ACCENT}${pkg}${C_RESET} already installed"
        return 0
    fi
    substep "Installing ${C_ACCENT}${pkg}${C_RESET}..."
    if [[ "$DISTRO" == "arch" ]]; then
        # arch_install tries the official repos before the AUR — keep it that way
        arch_install "$pkg" && return 0
    else
        # The ensure_*_deb functions take no arguments and ignore this one; it
        # is here for the apt_install default, which is the whole point of the
        # map being sparse.
        "${DEB_INSTALLER[$cfg]:-apt_install}" "$pkg" && return 0
    fi
    error "Failed to install ${C_ACCENT}${pkg}${C_RESET} — skipping ${cfg}"
    return 1
}

FONT_PKG="ttf-jetbrains-mono-nerd"
MAPLE_FONT_PKG="maplemono-ttf"   # family "Maple Mono" — the name kitty.conf asks for

# Wallpapers are only for terminal emulators, not all font-using configs
NEEDS_WALLPAPER=(ghostty kitty)
needs_wallpaper() {
    local cfg="$1" n
    for n in "${NEEDS_WALLPAPER[@]}"; do [[ "$cfg" == "$n" ]] && return 0; done
    return 1
}

# ── Optional dep tools ───────────────────────────────────────────────────────
declare -A DEP_PKG
DEP_PKG[bat]="bat"
DEP_PKG[eza]="eza"
DEP_PKG[fd]="fd"
DEP_PKG[zoxide]="zoxide"
DEP_PKG[pay-respects]="pay-respects-bin"
DEP_PKG[lazygit]="lazygit"
DEP_PKG[btop]="btop"
DEP_PKG[tree]="tree"
DEPS_LIST=(bat eza fd zoxide pay-respects lazygit btop tree)

# Debian/Ubuntu apt package-name overrides (only where it differs from Arch)
declare -A DEP_PKG_DEB
DEP_PKG_DEB[fd]="fd-find"
# The AUR package is the -bin one; the .deb upstream publishes is plain.
DEP_PKG_DEB[pay-respects]="pay-respects"

# Deps that also have a config to stow into ~/.config
DEP_HAS_CONFIG=(bat btop)

dep_pkg_name() {
    local dep="$1"
    if [[ "$DISTRO" == "arch" ]]; then
        echo "${DEP_PKG[$dep]}"
    else
        echo "${DEP_PKG_DEB[$dep]:-${DEP_PKG[$dep]}}"
    fi
}

# ── Applications ──────────────────────────────────────────────────────────────
APPS_LIST=(brave-beta brave-stable vscode vscode-insiders neovim alacritty wezterm antigravity-ide claude-code antigravity antigravity-cli codex-cli cursor-cli opencode kimi-code muse hermes devin grok-cli mistral-cli postman-cli bun vicinae notion obsidian vlc obs-studio zoom flatpak docker)
if [[ "$DISTRO" == "debian" ]]; then
    # Notion (no official Linux build), Obsidian (only a vendor .deb/AppImage on
    # apt, no repo), the Antigravity desktop/IDE (upstream packaging still a
    # moving target on apt), Vicinae (AUR only — upstream ships a tarball and a
    # Nix flake, no apt repo) and Zoom (a vendor .deb behind a download page, no
    # apt repo — the same shape as Obsidian) are Arch-only for now.
    # Claude Desktop is the inverse case: an official Anthropic apt repo exists,
    # but there is no Arch package — so it is Debian/Ubuntu-only.
    # Strip + append, never a second literal list — see the CONFIGS note below.
    strip_items APPS_LIST notion obsidian antigravity-ide antigravity vicinae zoom
    APPS_LIST+=(claude-desktop)
fi
# No display server → drop everything that needs one, keeping the CLI tools
[ "$IS_HEADLESS" -eq 1 ] && strip_items APPS_LIST "${GUI_APPS[@]}"

declare -A APP_LABEL APP_TYPE APP_PKG APP_BIN

APP_LABEL[brave-beta]="Brave Origin Beta"
APP_LABEL[brave-stable]="Brave Origin Stable"
APP_LABEL[vscode]="Visual Studio Code"
APP_LABEL[vscode-insiders]="VS Code Insiders"
APP_LABEL[neovim]="Neovim"
APP_LABEL[alacritty]="Alacritty"
APP_LABEL[wezterm]="WezTerm"
APP_LABEL[antigravity-ide]="Antigravity IDE"
APP_LABEL[claude-code]="Claude Code CLI"
APP_LABEL[antigravity]="Antigravity 2.0"
APP_LABEL[antigravity-cli]="Antigravity CLI"
APP_LABEL[codex-cli]="Codex CLI"
APP_LABEL[cursor-cli]="Cursor CLI"
APP_LABEL[opencode]="Opencode CLI"
APP_LABEL[kimi-code]="Kimi Code CLI"
APP_LABEL[muse]="Muse"
APP_LABEL[hermes]="Hermes Agent"
APP_LABEL[devin]="Devin CLI"
APP_LABEL[grok-cli]="Grok CLI"
APP_LABEL[mistral-cli]="Mistral CLI"
APP_LABEL[postman-cli]="Postman CLI"
APP_LABEL[bun]="Bun"
APP_LABEL[vicinae]="Vicinae"
APP_LABEL[notion]="Notion"
APP_LABEL[obsidian]="Obsidian"
APP_LABEL[claude-desktop]="Claude Desktop"
APP_LABEL[vlc]="VLC"
APP_LABEL[obs-studio]="OBS Studio"
APP_LABEL[zoom]="Zoom"
APP_LABEL[flatpak]="Flatpak"
APP_LABEL[docker]="Docker + Compose"

# paru-y forces a db refresh first (Brave bumps versions faster than a stale
# db notices); paru and pacman both resolve through arch_install — repo first,
# AUR second — so the distinction is only about which one is expected to hit.
APP_TYPE[brave-beta]="paru-y"
APP_TYPE[brave-stable]="paru-y"
APP_TYPE[vscode]="paru"
APP_TYPE[vscode-insiders]="paru"
# same name in the official repos and on apt, so no *_DEB override — apt is the
# Debian/Ubuntu default in app_type_resolved
APP_TYPE[neovim]="pacman"
APP_TYPE[alacritty]="pacman"
# AUR-only: extra/wezterm is pinned to the 20240203 stable release
APP_TYPE[wezterm]="paru"
APP_TYPE[antigravity-ide]="paru"
APP_TYPE[claude-code]="curl"
APP_TYPE[antigravity]="paru"
APP_TYPE[antigravity-cli]="curl"
APP_TYPE[codex-cli]="curl"
APP_TYPE[cursor-cli]="curl"
APP_TYPE[opencode]="curl"
APP_TYPE[kimi-code]="curl"
APP_TYPE[muse]="curl"
APP_TYPE[hermes]="curl"
APP_TYPE[devin]="curl"
APP_TYPE[grok-cli]="curl"
APP_TYPE[mistral-cli]="curl"
APP_TYPE[postman-cli]="curl"
APP_TYPE[bun]="curl"
APP_TYPE[vicinae]="paru"
APP_TYPE[notion]="paru"
APP_TYPE[obsidian]="pacman"
APP_TYPE[vlc]="pacman"
APP_TYPE[obs-studio]="pacman"
# AUR-only, like vicinae — no zoom in the official repos
APP_TYPE[zoom]="paru"
APP_TYPE[flatpak]="pacman"
APP_TYPE[docker]="pacman"

APP_PKG[brave-beta]="brave-origin-beta-bin"
APP_PKG[brave-stable]="brave-origin-bin"
APP_PKG[vscode]="visual-studio-code-bin"
APP_PKG[vscode-insiders]="visual-studio-code-insiders-bin"
APP_PKG[neovim]="neovim"
APP_PKG[alacritty]="alacritty"
APP_PKG[wezterm]="wezterm-git"
APP_PKG[antigravity-ide]="antigravity-ide"
APP_PKG[antigravity]="antigravity"
APP_PKG[vicinae]="vicinae-bin"
APP_PKG[notion]="notion-app-electron"
APP_PKG[obsidian]="obsidian"
APP_PKG[vlc]="vlc"
# v4l2loopback-dkms (virtual camera) and qt6-wayland (Wayland rendering) are
# pulled in as a post-install step, same shape as docker's compose/buildx:
# app_pkg_name carries one name, and this is the anchor for the installed check.
APP_PKG[obs-studio]="obs-studio"
APP_PKG[zoom]="zoom"
APP_PKG[flatpak]="flatpak"
# docker-compose and docker-buildx are pulled in as a post-install step (see
# the "docker" branch after the install loop) — pacman needs all three in one
# transaction to resolve shared deps cleanly, and app_pkg_name only carries one
# name, so this is the anchor package used for the before/after installed check.
APP_PKG[docker]="docker"

# Installer bin dirs, exported before running them: opencode, codex and kimi
# all append a PATH block to ~/.zshrc, which is a stow symlink into this repo —
# they would silently edit the tracked dotfile. Seeing their dir already on
# PATH (plus the opt-out flags below) makes them leave it alone.
CURL_APP_PATH="$HOME/.local/bin:$HOME/.opencode/bin:$HOME/.kimi-code/bin:$HOME/.bun/bin:$HOME/.grok/bin"

declare -A APP_CURL_ARGS APP_CURL_ENV
APP_CURL_ARGS[opencode]="--no-modify-path"
APP_CURL_ENV[kimi-code]="KIMI_NO_MODIFY_PATH=1"
APP_CURL_ENV[muse]="MUSE_NO_MODIFY_PATH=1"
# Hermes ends with an interactive setup wizard that reads /dev/tty — which our
# run has, so without this it stops mid-install to ask for API keys. Skipped;
# `hermes setup` runs it later. Its PATH block is the bun case: it only writes
# to ~/.zshrc when ~/.local/bin is missing from PATH, and CURL_APP_PATH has it.
APP_CURL_ARGS[hermes]="--skip-setup"
# bun has no opt-out flag. Two separate writes to ~/.zshrc have to be stopped:
# the PATH block (skipped once it sees its bin dir on PATH, hence CURL_APP_PATH
# above) and the completions line, written by `bun completions` — which picks
# the rc file off $SHELL and does nothing at all for a shell it cannot handle.
APP_CURL_ENV[bun]="SHELL=/bin/sh"
# Grok is the same trick for a blunter installer: it appends its PATH and
# completions block to the rc file $SHELL names, unconditionally — no flag,
# no "already on PATH" check, and it resolves the symlink first so the write
# lands on the tracked zsh/.zshrc in this repo. A $SHELL it has no block for
# is the only way out. ~/.grok/bin in CURL_APP_PATH above stops the other
# half: without it, grok and `agent` get symlinked into ~/.local/bin too.
APP_CURL_ENV[grok-cli]="SHELL=/bin/sh"
# Mistral ships a wrapper, so the rc-file writer is one level down: it
# installs uv when uv is missing, and uv's installer shotguns a PATH line
# into .profile, .bashrc, .bash_profile, .bash_login, .zshrc and .zshenv —
# ~/.zshrc among them, the stow symlink into this repo. UV_NO_MODIFY_PATH=1
# is its documented opt-out and reaches it by inheritance. ~/.local/bin in
# CURL_APP_PATH above is a second guard, but only for the default install
# dir — UV_INSTALL_DIR or XDG_BIN_HOME moves it out from under that.
APP_CURL_ENV[mistral-cli]="UV_NO_MODIFY_PATH=1"

# These CLIs install into their own bin dirs, which are not necessarily on the
# PATH of whatever shell is running this script — search them explicitly, or an
# already-installed tool looks missing and gets reinstalled every run.
curl_app_installed() {
    [ -n "$1" ] || return 1
    PATH="${CURL_APP_PATH}:$PATH" command -v "$1" &>/dev/null
}

# The interactive CLIs among the curl apps. Their installers are first-install
# scripts, so a re-run is the wrong tool for an existing one — the value is the
# update command it ships instead, and an empty value means it ships none and
# the installer is all there is. Being in this map is also what earns an app the
# "run it like this" line, so the keys are the ones you launch by name.
declare -A APP_UPDATE
APP_UPDATE[antigravity-cli]="agy update"
APP_UPDATE[claude-code]="claude update"
APP_UPDATE[codex-cli]="codex update"
APP_UPDATE[cursor-cli]="agent update"
APP_UPDATE[opencode]=""

app_open_hint() {
    [ -n "${APP_UPDATE[$1]+x}" ] || return 0
    substep "${C_DIM}Run ${C_ACCENT}${APP_BIN[$1]}${C_RESET}${C_DIM} in a terminal to open it${C_RESET}"
}

APP_BIN[claude-code]="claude"
# 'agy', not 'antigravity' — that name is the IDE's, and the vendor installer
# writes $TARGET_DIR/agy. Missing here, the ':-' fallbacks made the row read new
# forever, the plan always say "install", and — the one that mattered — the
# post-install check below is guarded on this being non-empty, so the single app
# whose installer ends in '|| true' was the one never verified against reality.
APP_BIN[antigravity-cli]="agy"
APP_BIN[codex-cli]="codex"
APP_BIN[cursor-cli]="agent"
APP_BIN[opencode]="opencode"
APP_BIN[kimi-code]="kimi"
APP_BIN[muse]="muse"
APP_BIN[hermes]="hermes"
APP_BIN[devin]="devin"
# ...and `agent`, a second name for the same binary, beside it in ~/.grok/bin
APP_BIN[grok-cli]="grok"
# `uv tool install mistral-vibe`, so the binary carries neither name:
# vibe (and vibe-acp beside it) in ~/.local/bin
APP_BIN[mistral-cli]="vibe"
APP_BIN[postman-cli]="postman"
APP_BIN[bun]="bun"

# Debian/Ubuntu overrides — package names and install mechanism differ
declare -A APP_PKG_DEB
APP_PKG_DEB[brave-stable]="brave-origin"
APP_PKG_DEB[brave-beta]="brave-origin-beta"
APP_PKG_DEB[vscode]="code"
APP_PKG_DEB[vscode-insiders]="code-insiders"
APP_PKG_DEB[claude-desktop]="claude-desktop"
APP_PKG_DEB[wezterm]="wezterm-nightly"
APP_PKG_DEB[docker]="docker-ce"

declare -A APP_TYPE_DEB
APP_TYPE_DEB[brave-stable]="brave"
APP_TYPE_DEB[brave-beta]="brave"
APP_TYPE_DEB[vscode]="vscode"
APP_TYPE_DEB[vscode-insiders]="vscode-insiders"
APP_TYPE_DEB[claude-code]="curl"
APP_TYPE_DEB[antigravity-cli]="curl"
APP_TYPE_DEB[codex-cli]="curl"
APP_TYPE_DEB[cursor-cli]="curl"
APP_TYPE_DEB[opencode]="curl"
APP_TYPE_DEB[kimi-code]="curl"
APP_TYPE_DEB[muse]="curl"
APP_TYPE_DEB[hermes]="curl"
APP_TYPE_DEB[devin]="curl"
APP_TYPE_DEB[grok-cli]="curl"
APP_TYPE_DEB[mistral-cli]="curl"
APP_TYPE_DEB[postman-cli]="curl"
APP_TYPE_DEB[bun]="curl"
APP_TYPE_DEB[alacritty]="alacritty"
APP_TYPE_DEB[wezterm]="wezterm"
APP_TYPE_DEB[claude-desktop]="claude-desktop"
APP_TYPE_DEB[docker]="docker"
# vlc/flatpak fall through to the "apt" default below

app_pkg_name() {
    local app="$1"
    if [[ "$DISTRO" == "arch" ]]; then
        echo "${APP_PKG[$app]}"
    else
        echo "${APP_PKG_DEB[$app]:-${APP_PKG[$app]}}"
    fi
}

app_type_resolved() {
    local app="$1"
    if [[ "$DISTRO" == "arch" ]]; then
        echo "${APP_TYPE[$app]}"
    else
        echo "${APP_TYPE_DEB[$app]:-apt}"
    fi
}

# ── Menu descriptions ─────────────────────────────────────────────────────────
declare -A CONFIG_DESC
CONFIG_DESC[fastfetch]="system info display at login"
CONFIG_DESC[ghostty]="GPU-accelerated terminal   ${G_DOT}  JetBrains Nerd Font"
CONFIG_DESC[kitty]="cross-platform terminal    ${G_DOT}  JetBrains Nerd Font"
CONFIG_DESC[zsh]="shell + Zinit plugins"
CONFIG_DESC[bash]="plain bash rc      ${G_DOT}  aliases, no prompt tooling"
CONFIG_DESC[protonvpn]="ProtonVPN wrapper script"
CONFIG_DESC[starship]="cross-shell prompt"
CONFIG_DESC[rofi]="keyboard-driven launcher   ${G_DOT}  JetBrains Nerd Font"
CONFIG_DESC[git]="git config  →  ~/.gitconfig"
CONFIG_DESC[micro]="terminal editor            ${G_DOT}  Catppuccin Mocha"
CONFIG_DESC[fresh]="terminal IDE              ${G_DOT}  AUR / GitHub deb"
CONFIG_DESC[ccstatusline]="Claude Code statusline  ${G_DOT}  bunx, always latest"
if [[ "$DISTRO" == "arch" ]]; then
    CONFIG_DESC[ulauncher]="app launcher              ${G_DOT}  AUR"
else
    CONFIG_DESC[ulauncher]="app launcher              ${G_DOT}  PPA/deb"
fi

# One line each, for the menu's description column. Apps only — configs and
# dep tools have CONFIG_DESC and DEP_DESC already.
declare -A APP_DESC
APP_DESC[brave-beta]="chromium browser, no telemetry  ${G_DOT}  beta channel"
APP_DESC[brave-stable]="chromium browser, no telemetry"
APP_DESC[vscode]="the editor"
APP_DESC[vscode-insiders]="the editor  ${G_DOT}  nightly channel"
APP_DESC[neovim]="the editor, in the terminal"
APP_DESC[alacritty]="GPU-accelerated terminal"
APP_DESC[wezterm]="GPU-accelerated terminal  ${G_DOT}  multiplexer built in"
APP_DESC[antigravity-ide]="agentic IDE"
APP_DESC[antigravity]="agentic IDE  ${G_DOT}  2.0"
APP_DESC[claude-code]="Anthropic's coding agent, in the terminal"
APP_DESC[antigravity-cli]="the CLI half of Antigravity"
APP_DESC[codex-cli]="OpenAI's coding agent"
APP_DESC[cursor-cli]="Cursor's coding agent in the terminal"
APP_DESC[opencode]="open-source coding agent"
APP_DESC[kimi-code]="Moonshot's coding agent"
APP_DESC[muse]="terminal agent"
APP_DESC[hermes]="Nous Research's agent  ${G_DOT}  run 'hermes setup' after"
APP_DESC[devin]="Cognition's coding agent  ${G_DOT}  run 'devin setup' after"
APP_DESC[grok-cli]="xAI's coding agent  ${G_DOT}  also installs as 'agent'"
APP_DESC[mistral-cli]="Mistral's coding agent  ${G_DOT}  run 'vibe --setup' after"
APP_DESC[postman-cli]="run Postman collections from the terminal"
APP_DESC[bun]="JavaScript runtime, bundler and package manager"
APP_DESC[vicinae]="Raycast-style launcher  ${G_DOT}  bind: vicinae toggle"
APP_DESC[notion]="notes and workspace"
APP_DESC[obsidian]="markdown knowledge base"
APP_DESC[claude-desktop]="Claude, as a desktop app"
APP_DESC[vlc]="plays anything"
APP_DESC[obs-studio]="screen recording and streaming  ${G_DOT}  virtual camera, Wayland"
APP_DESC[zoom]="video calls"
APP_DESC[flatpak]="sandboxed app runtime  ${G_DOT}  adds flathub"
APP_DESC[docker]="containers  ${G_DOT}  compose, buildx, group, service"

declare -A DEP_DESC
DEP_DESC[bat]="cat with syntax highlighting  ${G_DOT}  Catppuccin theme"
DEP_DESC[eza]="modern ls  →  ls  ll  lt  la aliases"
DEP_DESC[fd]="fast find replacement  →  fzf integration"
DEP_DESC[zoxide]="smart cd  →  z command"
DEP_DESC[pay-respects]="corrects last command  →  fuck alias"
DEP_DESC[lazygit]="git TUI  →  lg alias"
DEP_DESC[btop]="resource monitor  ${G_DOT}  Catppuccin theme"
DEP_DESC[tree]="directory tree listing"

# ── Pre-install plan ──────────────────────────────────────────────────────────
# The four outcomes for one dotfile in $HOME — our symlink, present, present
# with a .bak to rotate, absent — read identically for .bashrc, .zshrc and
# .gitconfig, and each has to keep step with the install loop. Written out three
# times that was three places to remember, and a plan that disagrees with the
# loop is how someone is promised "backup" and gets a delete. Appends to the
# caller's `steps` by nameref, like strip_items. $3 is the only real difference
# left: --restore-bash keeps the original .bashrc, so deleting it is not the
# loss it is for the other two, and the bash arm passes a note saying so.
plan_home_file() {      # plan_home_file <steps-array> <path> [delete-note]
    local -n _steps="$1"
    local _file="$2" _name="${2##*/}" _note="${3:-}"
    if is_repo_link "$_file"; then
        _steps+=("${C_ACCENT}re-stow ${_name}${C_RESET} ${C_DIM}(unlink + relink)${C_RESET}")
    elif [ -e "$_file" ] || [ -L "$_file" ]; then
        # "re-stow (unlink + relink)" for *any* symlink was the plan agreeing
        # with the old bug. A link that is not ours gets backed up like a real
        # file, so say that — and name it, or the backup row reads like it is
        # about a file the user does not think they have.
        [ -L "$_file" ] && _steps+=("${C_DIM}${_name} is your own symlink, not ours${C_RESET}")
        if [[ "$BACKUP_MODE" == "delete" ]]; then
            _steps+=("${C_RED}delete${C_RESET} ${C_DIM}${_name}${C_RESET}${_note}")
        else
            { [ -e "${_file}.bak" ] || [ -L "${_file}.bak" ]; } && \
                _steps+=("${C_YELLOW}rotate${C_RESET} ${C_DIM}${_name}.bak → ${_name}.old.bak${C_RESET}")
            _steps+=("${C_YELLOW}backup${C_RESET} ${C_DIM}${_name} → ${_name}.bak${C_RESET}")
        fi
        _steps+=("${C_GREEN}stow ~/${_name}${C_RESET}")
    else
        _steps+=("${C_GREEN}stow ~/${_name}${C_RESET} ${C_DIM}(fresh)${C_RESET}")
    fi
}

show_plan() {
    local cfgs=("$@")
    local wallpaper_stowed=0
    # Every loop variable below, declared. cfg and step were missed once
    # already; _d and _a were missed the same way and leaked into the global
    # scope, where the install loop's own `for dep in "${DEPS[@]}"` and the
    # apps loop run afterwards with names close enough to be worth not
    # gambling on.
    local cfg step _d _a

    local _mode_label
    [[ "$BACKUP_MODE" == "delete" ]] \
        && _mode_label="${C_RED}delete${C_RESET}" \
        || _mode_label="${C_YELLOW}backup${C_RESET}"
    echo -e "${C_MAIN}${C_BOLD} ${G_TOP} ${G_INFO} Installation plan ${C_DIM}(existing configs: ${_mode_label}${C_DIM})${C_RESET}"

    # Only two generations are kept, so a rotation destroys whatever is in
    # .old.bak. The rows below say "x.bak → x.old.bak" and stop there, which
    # reads like nothing is lost. On a third run something is.
    if [[ "$BACKUP_MODE" != "delete" ]]; then
        local _o
        for _o in "$HOME"/.zshrc.old.bak "$HOME"/.bashrc.old.bak \
                  "$HOME"/.gitconfig.old.bak "$HOME"/.config/*.old.bak; do
            [ -e "$_o" ] || continue
            echo -e "${C_MAIN}${C_BOLD} ${G_MID}  ${C_YELLOW}${G_DOT}${C_RESET} ${C_DIM}two backups are kept — rotating discards the current .old.bak${C_RESET}"
            break
        done
    fi

    for cfg in "${cfgs[@]}"; do
        local pkg="${PKG_MAP[$cfg]}"
        local steps=()
        local target bak

        # ccstatusline has no package on either distro — it is fetched per
        # render by `bunx …@latest`. bun arrives through the curl installer,
        # which puts it outside PATH, so curl_app_installed is what can see it.
        if [[ "$cfg" == "ccstatusline" ]]; then
            if curl_app_installed bun; then
                steps+=("${C_DIM}bun already installed${C_RESET}")
            elif printf '%s\n' "${APPS[@]}" | grep -qx bun; then
                steps+=("${C_YELLOW}install bun${C_RESET} ${C_DIM}(with the applications)${C_RESET}")
            else
                steps+=("${C_YELLOW}needs bun${C_RESET} ${C_DIM}— it will not render without it${C_RESET}")
            fi
        elif pkg_installed "$pkg"; then
            steps+=("${C_DIM}$pkg already installed${C_RESET}")
        else
            steps+=("${C_YELLOW}install $pkg${C_RESET}")
        fi

        case "$cfg" in
          # One arm for all eight: same target shape (~/.config/<name>/), same
          # backup rules. The ones that differ do so by a line or two at the end.
          fastfetch|ghostty|kitty|rofi|micro|fresh|ccstatusline|ulauncher)
            target="$HOME/.config/$cfg"; bak="${target}.bak"
            # The symlink test comes first for the same reason it does in
            # stow_config: -d follows the link, and what gets moved aside is
            # the link, not whatever it happens to point at.
            if { [ -L "$target" ] && ! is_repo_link "$target"; } \
               || { [ -d "$target" ] && find "$target" -mindepth 1 -maxdepth 3 \
                    ! -type l ! -type d 2>/dev/null | grep -q .; }; then
                if [[ "$BACKUP_MODE" == "delete" ]]; then
                    steps+=("${C_RED}delete${C_RESET} ${C_DIM}${cfg}${C_RESET}")
                else
                    [ -e "$bak" ] && steps+=("${C_YELLOW}backup${C_RESET} ${C_DIM}$cfg.bak → $cfg.old.bak${C_RESET}")
                    steps+=("${C_YELLOW}backup${C_RESET} ${C_DIM}$cfg → $cfg.bak${C_RESET}")
                fi
                steps+=("${C_GREEN}stow → ~/.config/${cfg}/${C_RESET}")
            elif [ -e "$target" ]; then
                steps+=("${C_GREEN}re-stow → ~/.config/${cfg}/${C_RESET}")
            else
                steps+=("${C_GREEN}stow → ~/.config/${cfg}/${C_RESET} ${C_DIM}(fresh)${C_RESET}")
            fi
            # needs_wallpaper is what the install loop branches on too, so the
            # plan cannot drift from it the way a second hardcoded list would.
            if needs_wallpaper "$cfg" && [ "$wallpaper_stowed" -eq 0 ]; then
                local wp="$HOME/.config/wallpapers/Serene Japanese Landscape with Red Sun.jpg"
                if [ ! -f "$wp" ]; then
                    steps+=("${C_GREEN}stow wallpapers${C_RESET}")
                else
                    steps+=("${C_DIM}wallpaper already in place${C_RESET}")
                fi
                wallpaper_stowed=1
            fi
            [[ "$cfg" == "rofi" ]] && steps+=("${C_DIM}launch: rofi -show drun${C_RESET}")
            # The one step that writes outside the stow targets, so the plan has
            # to name it rather than let it happen quietly.
            [[ "$cfg" == "ccstatusline" ]] && \
                steps+=("${C_GREEN}point Claude Code at it${C_RESET} ${C_DIM}(merges statusLine into ~/.claude/settings.json)${C_RESET}")
            if [[ "$cfg" == "ulauncher" ]]; then
                if [ ! -f "$HOME/.config/autostart/ulauncher.desktop" ]; then
                    steps+=("${C_GREEN}enable autostart${C_RESET}")
                else
                    steps+=("${C_DIM}autostart already configured${C_RESET}")
                fi
            fi
            ;;
          bash)
            # This one line really is bash-only, so it stays out here rather
            # than becoming a flag on the helper.
            [ -e "$PRISTINE_BASHRC" ] || [ -e "$PRISTINE_ABSENT" ] \
                || steps+=("${C_YELLOW}keep a pristine copy${C_RESET} ${C_DIM}of .bashrc (once, kept for --restore-bash)${C_RESET}")
            plan_home_file steps "$HOME/.bashrc" " ${C_DIM}(pristine copy still kept)${C_RESET}"
            ;;
          zsh)
            plan_home_file steps "$HOME/.zshrc"
            ;;
          protonvpn)
            local script="$HOME/scripts/pvpn/pvpn.zsh"
            # The directory above it, when it is a symlink someone else made.
            # The install loop moves that aside now rather than deleting it, so
            # the plan has to say so — it is a directory, not a file, and the
            # row below only ever spoke for pvpn.zsh.
            if [ -L "$HOME/scripts/pvpn" ] && ! is_repo_link "$HOME/scripts/pvpn"; then
                steps+=("${C_DIM}~/scripts/pvpn is your own symlink, not ours${C_RESET}")
                if [[ "$BACKUP_MODE" == "delete" ]]; then
                    steps+=("${C_RED}delete${C_RESET} ${C_DIM}~/scripts/pvpn${C_RESET}")
                else
                    steps+=("${C_YELLOW}backup${C_RESET} ${C_DIM}~/scripts/pvpn → pvpn.bak${C_RESET}")
                fi
            fi
            # Anything here that is not ours, symlink or not — backup_file
            # moves a foreign link aside now, and a plan that skipped the row
            # for one promised a backup would not happen.
            if { [ -e "$script" ] || [ -L "$script" ]; } && ! is_repo_link "$script"; then
                if [[ "$BACKUP_MODE" == "delete" ]]; then
                    steps+=("${C_RED}delete${C_RESET} ${C_DIM}pvpn.zsh${C_RESET}")
                else
                    steps+=("${C_YELLOW}backup${C_RESET} ${C_DIM}pvpn.zsh → pvpn.zsh.bak${C_RESET}")
                fi
            fi
            steps+=("${C_GREEN}stow ~/scripts/pvpn/pvpn.zsh${C_RESET}")
            ;;
          starship)
            # Mirrors the three outcomes in the install loop. No backup line
            # here any more: an existing starship.toml is never moved, so
            # promising a .bak we will not take would be worse than silence.
            target="$HOME/.config/starship.toml"
            if is_repo_link "$target"; then
                steps+=("${C_ACCENT}re-stow config${C_RESET} ${C_DIM}(unlink + relink)${C_RESET}")
            elif [ -e "$target" ] || [ -L "$target" ]; then
                steps+=("${C_DIM}keep your existing starship.toml — ours not installed${C_RESET}")
            else
                steps+=("${C_GREEN}stow ~/.config/starship.toml${C_RESET} ${C_DIM}(fresh)${C_RESET}")
            fi
            ;;
          git)
            plan_home_file steps "$HOME/.gitconfig"
            ;;
        esac

        echo -e "${C_MAIN}${C_BOLD} ${G_MID}${C_RESET}"
        echo -e "${C_MAIN}${C_BOLD} ${G_MID}  ${C_ACCENT}${C_BOLD}${cfg}${C_RESET}"
        for step in "${steps[@]}"; do
            echo -e "${C_MAIN}${C_BOLD} ${G_MID}    ${C_DIM}${G_DOT}${C_RESET} ${step}"
        done
    done

    # Fonts — installed on every run, so they get their own plan entry
    echo -e "${C_MAIN}${C_BOLD} ${G_MID}${C_RESET}"
    echo -e "${C_MAIN}${C_BOLD} ${G_MID}  ${C_ACCENT}${C_BOLD}fonts${C_RESET}"
    if [ "${#cfgs[@]}" -eq 0 ]; then
        echo -e "${C_MAIN}${C_BOLD} ${G_MID}    ${C_DIM}${G_DOT}${C_RESET} ${C_DIM}skip — no configs selected, nothing asks for them${C_RESET}"
    elif [ "$IS_WSL" -eq 1 ]; then
        echo -e "${C_MAIN}${C_BOLD} ${G_MID}    ${C_DIM}${G_DOT}${C_RESET} ${C_DIM}skip — WSL, install them on Windows${C_RESET}"
    elif [ "$IS_HEADLESS" -eq 1 ]; then
        echo -e "${C_MAIN}${C_BOLD} ${G_MID}    ${C_DIM}${G_DOT}${C_RESET} ${C_DIM}skip — no display server${C_RESET}"
    else
        if font_installed; then
            echo -e "${C_MAIN}${C_BOLD} ${G_MID}    ${C_DIM}${G_DOT}${C_RESET} ${C_DIM}JetBrainsMono Nerd Font already installed${C_RESET}"
        else
            echo -e "${C_MAIN}${C_BOLD} ${G_MID}    ${C_DIM}${G_DOT}${C_RESET} ${C_YELLOW}install JetBrainsMono Nerd Font${C_RESET}"
        fi
        if maple_font_installed; then
            echo -e "${C_MAIN}${C_BOLD} ${G_MID}    ${C_DIM}${G_DOT}${C_RESET} ${C_DIM}Maple Mono already installed${C_RESET}"
        else
            echo -e "${C_MAIN}${C_BOLD} ${G_MID}    ${C_DIM}${G_DOT}${C_RESET} ${C_YELLOW}install Maple Mono${C_RESET}"
        fi
    fi

    # Dep tools section
    if [ "${#DEPS[@]}" -gt 0 ]; then
        echo -e "${C_MAIN}${C_BOLD} ${G_MID}${C_RESET}"
        echo -e "${C_MAIN}${C_BOLD} ${G_MID}  ${C_ACCENT}${C_BOLD}dep tools${C_RESET}"
        local _dc _dtarget
        for _d in "${DEPS[@]}"; do
            if pkg_installed "$(dep_pkg_name "$_d")"; then
                echo -e "${C_MAIN}${C_BOLD} ${G_MID}    ${C_DIM}${G_DOT}${C_RESET} ${C_DIM}${_d} already installed${C_RESET}"
            else
                echo -e "${C_MAIN}${C_BOLD} ${G_MID}    ${C_DIM}${G_DOT}${C_RESET} ${C_YELLOW}install ${_d}${C_RESET}"
            fi
            # Two of these carry a config as well as a binary, and in delete
            # mode that means an rm -rf of ~/.config/<tool> with no .bak. The
            # plan used to say only "already installed" and then delete it.
            for _dc in "${DEP_HAS_CONFIG[@]}"; do
                [ "$_d" = "$_dc" ] || continue
                [ -d "$DOTFILES_DIR/$_d" ] || continue
                _dtarget="$HOME/.config/$_d"
                if [ -d "$_dtarget" ] && find "$_dtarget" -mindepth 1 -maxdepth 3 \
                        ! -type l ! -type d 2>/dev/null | grep -q .; then
                    if [[ "$BACKUP_MODE" == "delete" ]]; then
                        echo -e "${C_MAIN}${C_BOLD} ${G_MID}      ${C_DIM}${G_DOT}${C_RESET} ${C_RED}delete${C_RESET} ${C_DIM}~/.config/${_d}${C_RESET}"
                    else
                        echo -e "${C_MAIN}${C_BOLD} ${G_MID}      ${C_DIM}${G_DOT}${C_RESET} ${C_YELLOW}backup${C_RESET} ${C_DIM}~/.config/${_d} → ${_d}.bak${C_RESET}"
                    fi
                fi
                echo -e "${C_MAIN}${C_BOLD} ${G_MID}      ${C_DIM}${G_DOT}${C_RESET} ${C_GREEN}stow → ~/.config/${_d}/${C_RESET} ${C_DIM}(theme)${C_RESET}"
            done
        done
    fi

    # Applications section
    if [ "${#APPS[@]}" -gt 0 ]; then
        echo -e "${C_MAIN}${C_BOLD} ${G_MID}${C_RESET}"
        echo -e "${C_MAIN}${C_BOLD} ${G_MID}  ${C_ACCENT}${C_BOLD}applications${C_RESET}"
        for _a in "${APPS[@]}"; do
            local _lbl="${APP_LABEL[$_a]}"
            local _type; _type="$(app_type_resolved "$_a")"
            if [[ "$_type" == "curl" ]]; then
                local _bin="${APP_BIN[$_a]:-}"
                if curl_app_installed "$_bin"; then
                    echo -e "${C_MAIN}${C_BOLD} ${G_MID}    ${C_DIM}${G_DOT}${C_RESET} ${C_DIM}${_lbl} already installed${C_RESET}"
                else
                    echo -e "${C_MAIN}${C_BOLD} ${G_MID}    ${C_DIM}${G_DOT}${C_RESET} ${C_YELLOW}install ${_lbl}${C_RESET} ${C_DIM}(curl)${C_RESET}"
                fi
            else
                local _pkg; _pkg="$(app_pkg_name "$_a")"
                if pkg_installed "$_pkg"; then
                    echo -e "${C_MAIN}${C_BOLD} ${G_MID}    ${C_DIM}${G_DOT}${C_RESET} ${C_DIM}${_lbl} already installed — will update${C_RESET}"
                else
                    echo -e "${C_MAIN}${C_BOLD} ${G_MID}    ${C_DIM}${G_DOT}${C_RESET} ${C_YELLOW}install ${_lbl}${C_RESET}"
                fi
            fi
        done
        # Step 5c½ fires on either trigger, so picking Claude Code alone
        # still writes to ~/.claude/settings.json. Only the ccstatusline config
        # said so, which left the apps-only path editing a file the plan never
        # named — the one thing this section exists to prevent.
        if printf '%s\n' "${APPS[@]}" | grep -qx claude-code \
           && ! printf '%s\n' "${cfgs[@]}" | grep -qx ccstatusline; then
            echo -e "${C_MAIN}${C_BOLD} ${G_MID}    ${C_DIM}${G_DOT}${C_RESET} ${C_GREEN}point Claude Code at ccstatusline${C_RESET} ${C_DIM}(merges statusLine into ~/.claude/settings.json)${C_RESET}"
        fi
    fi

    if [ "$STRIP_REPO" -eq 1 ]; then
        echo -e "${C_MAIN}${C_BOLD} ${G_MID}${C_RESET}"
        echo -e "${C_MAIN}${C_BOLD} ${G_MID}  ${C_ACCENT}${C_BOLD}repo traces${C_RESET}"
        private_preview
        echo -e "${C_MAIN}${C_BOLD} ${G_MID}    ${C_DIM}${G_DOT}${C_RESET} ${C_DIM}runs last; configs keep working and install.sh stays${C_RESET}"
    fi

    echo -e "${C_MAIN}${C_BOLD} ${G_MID}${C_RESET}"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo -e "${C_MAIN}${C_BOLD} ${G_END} ${C_YELLOW}[dry run] No changes made.${C_RESET}\n"
        exit 0
    fi
    echo -ne "${C_MAIN}${C_BOLD} ${G_END} ${C_YELLOW}Proceed? [Y/n]: ${C_RESET}"
    read -r CONFIRM <"$TTY_IN"
    [[ "$CONFIRM" =~ ^[Nn]$ ]] && echo "" && exit 0
    echo ""
}


# ── Restore bash ─────────────────────────────────────────────────────────────
# Undoes what selecting zsh did: the hand-off hook, the stowed rc files, and
# the login shell. Everything it needs already exists by this point in the
# script (TTY_IN, colours, same_shell, the bashrc_* helpers), and everything it
# must not trigger — the privacy and backup prompts, the menus, the install
# loop — comes after.
restore_bash() {
    local rc="$HOME/.bashrc" steps=() ans bash_path new_shell
    local current_shell target_user
    # Any error below sets this. Without it the function printed "bash
    # restored" and returned 0 after every possible failure, so
    # `install.sh --restore-bash && echo ok` always said ok.
    local _rb_failed=0
    target_user="$(id -un)"
    current_shell="$(getent passwd "$target_user" 2>/dev/null | cut -d: -f7)"
    bash_path="$(command -v bash 2>/dev/null)"

    echo -e "${C_MAIN}${C_BOLD} ${G_TOP} ${G_INFO} Restore bash${C_RESET}"

    # ── survey, no writes ──
    local has_hook=0 hook_state=""
    if bashrc_hook_range "$rc" >/dev/null 2>&1; then
        has_hook=1; steps+=("${C_YELLOW}remove${C_RESET} ${C_DIM}the zsh hand-off block from ~/.bashrc${C_RESET}")
    elif [ "$?" = 2 ]; then
        hook_state="malformed"
        steps+=("${C_RED}skip${C_RESET} ${C_DIM}~/.bashrc hook block is hand-edited — left for you${C_RESET}")
    fi

    # Decide against the real file, not the symlink. `-e "$rc"` follows a stow
    # link into the checkout and reports the repo's own rc as "an existing
    # bashrc", which is how this used to unstow the bash config and then
    # immediately stow it straight back — or, with no pristine copy, unstow it
    # and leave the user with no ~/.bashrc at all while printing success.
    local bashrc_action="" stowed_bash=0
    is_repo_link "$rc" && stowed_bash=1
    if [ -e "$PRISTINE_BASHRC" ]; then
        bashrc_action="restore"
        steps+=("${C_GREEN}restore${C_RESET} ${C_DIM}~/.bashrc from the copy kept before the first run${C_RESET}")
    elif [ -e "$PRISTINE_ABSENT" ] || [ "$stowed_bash" = 1 ] || [ ! -e "$rc" ]; then
        bashrc_action="repo"
        if [ "$stowed_bash" = 1 ]; then
            steps+=("${C_GREEN}keep${C_RESET} ${C_DIM}the stowed bash/.bashrc — no earlier ~/.bashrc was ever saved${C_RESET}")
        else
            steps+=("${C_GREEN}install${C_RESET} ${C_DIM}bash/.bashrc — there was no ~/.bashrc to restore${C_RESET}")
        fi
    fi
    # Only worth unstowing if something else is going to take its place.
    [ "$stowed_bash" = 1 ] && [ "$bashrc_action" = "restore" ] \
        && steps+=("${C_YELLOW}unstow${C_RESET} ${C_DIM}the bash config so ~/.bashrc is a real file again${C_RESET}")

    # is_repo_link, not a bare -L. This is the undo command, so it is the last
    # place that should take a link it did not make: someone who tried this repo
    # and went back to their own ~/.zshrc symlink had it rm'd with no .bak and
    # nothing said. The starship branch below already guarded on the target;
    # this one did not, and the two sat four lines apart.
    local zsh_action=""
    if is_repo_link "$HOME/.zshrc"; then
        zsh_action="unstow"
        steps+=("${C_YELLOW}unstow${C_RESET} ${C_DIM}~/.zshrc${C_RESET}")
        [ -e "$HOME/.zshrc.bak" ] && steps+=("${C_GREEN}restore${C_RESET} ${C_DIM}~/.zshrc.bak → ~/.zshrc${C_RESET}")
    elif [ -L "$HOME/.zshrc" ]; then
        steps+=("${C_DIM}leave ~/.zshrc alone — it is your own symlink, not ours${C_RESET}")
    fi

    # The same test, by the same name now: this was is_repo_link written out by
    # hand, which is how the two drifted apart in the first place.
    local st="$HOME/.config/starship.toml" st_action=""
    if is_repo_link "$st"; then
        st_action="unstow"
        steps+=("${C_YELLOW}unstow${C_RESET} ${C_DIM}~/.config/starship.toml${C_RESET}")
        [ -e "${st}.bak" ] && steps+=("${C_GREEN}restore${C_RESET} ${C_DIM}starship.toml.bak → starship.toml${C_RESET}")
    fi

    local shell_action=""
    if [ -z "$bash_path" ]; then
        steps+=("${C_RED}skip${C_RESET} ${C_DIM}no bash on PATH — login shell left alone${C_RESET}")
    elif same_shell "$current_shell" "$bash_path"; then
        steps+=("${C_DIM}login shell is already bash${C_RESET}")
    else
        shell_action="change"
        steps+=("${C_GREEN}set${C_RESET} ${C_DIM}login shell for ${target_user} back to ${bash_path}${C_RESET}")
    fi

    if [ "${#steps[@]}" -eq 0 ]; then
        substep "${C_DIM}Nothing to undo — no hook, no stowed rc, already on bash${C_RESET}"
        success "Already restored"
        return 0
    fi
    local _s
    for _s in "${steps[@]}"; do
        echo -e "${C_MAIN}${C_BOLD} ${G_MID}  ${C_DIM}${G_ARROW}${C_RESET} ${_s}"
    done
    echo -e "${C_MAIN}${C_BOLD} ${G_MID}  ${C_DIM}${G_DOT}${C_RESET} ${C_DIM}the pristine copy is kept, so this can be re-run${C_RESET}"

    if [ "$DRY_RUN" -eq 1 ]; then
        echo -e "${C_MAIN}${C_BOLD} ${G_END} ${C_DIM}dry run — nothing changed${C_RESET}\n"
        return 0
    fi
    echo -ne "${C_MAIN}${C_BOLD} ${G_END} ${C_YELLOW}Proceed? [Y/n]: ${C_RESET}"
    read -r ans <"$TTY_IN"
    [[ "$ans" =~ ^[Nn]$ ]] && { echo ""; return 0; }
    echo ""

    # ── act ──
    # Order matters and is not negotiable: ~/.bashrc is made good BEFORE the
    # login shell moves to it. The other way round, a failure between the two
    # leaves you logging into a bash whose rc still execs a zsh that may no
    # longer be there — unrecoverable over SSH without a console.
    info "Restoring bash..."
    snapshot_bashrc >/dev/null 2>&1 || true   # first run here may be a restore

    # Unstow only when a pristine copy is going to replace it. Otherwise the
    # stowed rc *is* the best bash config on the machine and removing it would
    # be a downgrade, not a restore.
    if [ "$stowed_bash" = 1 ] && [ "$bashrc_action" = "restore" ]; then
        stow --target "$HOME" --dir "$DOTFILES_DIR" -D bash &>/dev/null 2>&1 || true
        [ -L "$rc" ] && rm -f "$rc"
        substep "Unstowed the bash config"
    fi

    if [ "$has_hook" = 1 ] && [ -f "$rc" ] && [ ! -L "$rc" ]; then
        if bashrc_hook_strip_to "$rc" "$rc"; then
            substep "Removed the zsh hand-off block from ${C_ACCENT}~/.bashrc${C_RESET}"
        else
            error "Could not edit ~/.bashrc — remove the hook block by hand"
            _rb_failed=1
        fi
    elif [ "$hook_state" = "malformed" ]; then
        substep "${C_YELLOW}Left the hand-edited hook block in ~/.bashrc alone${C_RESET}"
    fi

    case "$bashrc_action" in
      restore)
        if cp -p "$PRISTINE_BASHRC" "$rc" 2>/dev/null; then
            substep "Restored ${C_ACCENT}~/.bashrc${C_RESET} ${C_DIM}from the pristine copy${C_RESET}"
        else
            error "Could not write ~/.bashrc"
            _rb_failed=1
        fi ;;
      repo)
        if [ "$stowed_bash" = 1 ]; then
            substep "${C_DIM}~/.bashrc already is the stowed bash config — left in place${C_RESET}"
        elif [ ! -f "$DOTFILES_DIR/bash/.bashrc" ]; then
            error "bash/.bashrc is missing from the checkout — nothing to install"
            _rb_failed=1
        else
            # Stripping the hook leaves the file the installer created to hold
            # it — one newline. stow refuses to link over a real file, so that
            # leftover has to go first or the restore ends with a 1-byte
            # ~/.bashrc and no config at all.
            if [ -e "$rc" ] && [ ! -L "$rc" ]; then
                if [ -s "$rc" ] && grep -qv '^[[:space:]]*$' "$rc" 2>/dev/null; then
                    backup_file "$rc"          # real content: keep it
                else
                    rm -f "$rc"                # only what we created; drop it
                fi
            fi
            if stow_home "bash"; then
                substep "Installed ${C_ACCENT}bash/.bashrc${C_RESET} ${C_DIM}(there was no original)${C_RESET}"
            else
                error "Could not install bash/.bashrc — ~/.bashrc may be missing"
                _rb_failed=1
            fi
        fi ;;
    esac

    if [ "$zsh_action" = "unstow" ]; then
        stow --target "$HOME" --dir "$DOTFILES_DIR" -D zsh &>/dev/null 2>&1 || true
        [ -L "$HOME/.zshrc" ] && rm -f "$HOME/.zshrc"
        substep "Unstowed ${C_ACCENT}~/.zshrc${C_RESET}"
        if [ -e "$HOME/.zshrc.bak" ] && [ ! -e "$HOME/.zshrc" ]; then
            mv "$HOME/.zshrc.bak" "$HOME/.zshrc" && substep "Restored ${C_ACCENT}~/.zshrc${C_RESET} from .bak"
        fi
    fi

    if [ "$st_action" = "unstow" ]; then
        stow --target "$HOME/.config" --dir "$DOTFILES_DIR" -D starship &>/dev/null 2>&1 || true
        [ -L "$st" ] && rm -f "$st"
        substep "Unstowed ${C_ACCENT}~/.config/starship.toml${C_RESET}"
        if [ -e "${st}.bak" ] && [ ! -e "$st" ]; then
            mv "${st}.bak" "$st" && substep "Restored ${C_ACCENT}starship.toml${C_RESET} from .bak"
        fi
    fi

    # Login shell last, and verified by reading /etc/passwd back rather than
    # trusting chsh's exit code — chsh can exit 0 having changed nothing.
    if [ "$shell_action" = "change" ]; then
        # An empty path here would run `chsh -s "" user` and blank the field.
        if [ -z "$bash_path" ]; then
            error "No bash on PATH — leaving the login shell alone"
            _rb_failed=1
        else
            grep -qxs "$bash_path" /etc/shells \
                || echo "$bash_path" | sudo tee -a /etc/shells &>/dev/null
            sudo chsh -s "$bash_path" "$target_user" </dev/null &>/dev/null || true
            if ! same_shell "$(getent passwd "$target_user" | cut -d: -f7)" "$bash_path"; then
                sudo usermod -s "$bash_path" "$target_user" </dev/null &>/dev/null || true
            fi
            new_shell="$(getent passwd "$target_user" | cut -d: -f7)"
            if same_shell "$new_shell" "$bash_path"; then
                substep "${C_GREEN}Login shell for ${target_user} is now ${bash_path}${C_RESET}"
            else
                error "Login shell unchanged — still ${new_shell:-unknown}"
                substep "To fix it by hand: ${C_ACCENT}sudo usermod -s ${bash_path} ${target_user}${C_RESET}"
                _rb_failed=1
            fi
        fi
    fi

    substep "${C_DIM}Switch this session now with: ${C_ACCENT}exec bash -l${C_RESET}"
    if [ -n "${SSH_CONNECTION:-}${SSH_TTY:-}${SSH_CLIENT:-}" ]; then
        substep "${C_DIM}On SSH the new shell applies to new logins; if reconnecting still${C_RESET}"
        substep "${C_DIM}gives you zsh, your client is reusing a multiplexed connection.${C_RESET}"
    fi
    if [ "$_rb_failed" -ne 0 ]; then
        error "Restore finished with errors — see above"
        return 1
    fi
    success "bash restored"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
header

# ── Privileges ────────────────────────────────────────────────────────────────
# VPS and container images normally drop you straight into root, and plenty of
# them ship without sudo at all — 'sudo -v' died with "command not found" before
# the installer did anything. As root, run privileged commands directly. The
# passthrough goes through env so that 'sudo VAR=value cmd' (which sudo parses
# itself) keeps working unchanged at every call site.
#
# This has to run before the --restore-bash short-circuit below, not after it:
# that path needs the root shim as much as the install does. On a root image
# with no sudo, restore_bash's 'sudo chsh' and 'sudo tee /etc/shells' died with
# "command not found", the failures were swallowed by '|| true', and the readback
# reported "Login shell unchanged" — --restore-bash could not restore the login
# shell at all on exactly the images it exists for.
info "Authentication..."
if [ "$(id -u)" -eq 0 ]; then
    # Tell a real root login apart from 'sudo bash install.sh'. Under sudo,
    # $HOME is /root or the caller's home depending on the sudoers policy, so
    # the configs either land in the wrong home or land in the right one owned
    # by root. Both are wrong and neither is obvious later, so stop and explain.
    if [ -n "${SUDO_USER:-}" ]; then
        error "Do not run this through sudo."
        substep "The installer asks for sudo itself, only for the steps that need it."
        substep "Run as your own user instead:   ${C_ACCENT}bash install.sh${C_RESET}"
        substep "Or log in as root properly and run it there — both are supported."
        substep "${C_DIM}(As it stands the configs would be stowed into ${HOME}${C_RESET}"
        substep "${C_DIM} and any files created would be owned by root.)${C_RESET}"
        exit 1
    fi
    IS_ROOT=1
    sudo() { env "$@"; }
    substep "Running as root — sudo not needed"
    success "Ready"
elif ! command -v sudo &>/dev/null; then
    IS_ROOT=0
    error "sudo is not installed and you are not root."
    substep "Install sudo, or re-run this script as root."
    exit 1
elif [ "$RESTORE_BASH" -eq 1 ] && [ "$DRY_RUN" -eq 1 ]; then
    # A --restore-bash dry run prints its plan and returns without running a
    # single privileged command. The ad-hoc 'sudo -v' this branch used to do for
    # itself skipped DRY_RUN for that reason; hoisting must not turn a mode whose
    # contract is "no writes" into a password prompt.
    IS_ROOT=0
    substep "Dry run — nothing to authenticate for"
    success "Ready"
else
    IS_ROOT=0
    substep "Enter your sudo password once — cached for the full install"
    if ! sudo -v; then
        error "Authentication failed. Exiting."
        exit 1
    fi
    success "Authenticated"

    # </dev/null matters as much as the output redirect: without it the loop
    # inherits this terminal, and the sleep it forks keeps that fd open after
    # the installer exits. Anything reading the other end — script(1), a CI
    # runner, a parent that waits for EOF — then hangs for the rest of the
    # sleep rather than finishing when we do.
    ( while true; do sudo -v; sleep 240; done ) </dev/null &>/dev/null &
    _SUDO_KEEPALIVE=$!
fi

# --restore-bash short-circuits everything below: no privacy prompt, no backup
# mode, no menus, no install loop. Privileges above it are already sorted out.
if [ "$RESTORE_BASH" -eq 1 ]; then
    restore_bash
    exit $?
fi

# ── Backup mode ───────────────────────────────────────────────────────────────
# What happens to existing configs (backup / delete) and whether to strip the
# repo traces are two unrelated decisions, so the second is a toggle rather than
# a third mode — you can keep your backups and still leave no trace of the repo.
# ── Privacy ───────────────────────────────────────────────────────────────────
# Asked first and on its own, because it is a decision about this machine, not
# about what happens to existing configs. The exact list is printed before the
# choice — nothing here should be a surprise afterwards.
STRIP_REPO=0

echo -e "${C_MAIN}${C_BOLD} ${G_TOP} ${G_INFO} Privacy${C_RESET}"
echo -e "${C_MAIN}${C_BOLD} ${G_MID}  ${C_DIM}Private leaves no sign that ~/dotfiles came from a repo, or whose:${C_RESET}"
echo -e "${C_MAIN}${C_BOLD} ${G_MID}${C_RESET}"
private_preview
echo -e "${C_MAIN}${C_BOLD} ${G_MID}${C_RESET}"
echo -e "${C_MAIN}${C_BOLD} ${G_MID}  ${C_DIM}Configs keep working and install.sh stays, so it can be re-run.${C_RESET}"
echo -e "${C_MAIN}${C_BOLD} ${G_MID}${C_RESET}"

pick2 "keep"    "leave it as a normal checkout"      "$C_GREEN" \
      "private" "remove and scrub everything above"  "$C_RED"
STRIP_REPO=$PICK2

if [ "$STRIP_REPO" -eq 1 ]; then
    echo -e " ${C_MAIN}${C_BOLD}${G_END} ${C_RED}${G_OK}${C_RESET} private — traces removed at the end of the run\n"
else
    echo -e " ${C_MAIN}${C_BOLD}${G_END} ${C_GREEN}${G_OK}${C_RESET} keep\n"
fi

# ── Existing configs: backup or delete ───────────────────────────────────────
# Stays here, before the menus, even though it only matters once a config is
# selected: both single-key prompts have to be asked back to back at the very
# start. A `read -n 1` puts the terminal in raw mode, which discards whatever is
# already sitting in the input queue — harmless for a human typing, fatal for
# anything feeding keystrokes from a file (see tests/harness.sh).
echo -e "${C_MAIN}${C_BOLD} ${G_TOP} ${G_INFO} Existing configs  ${C_DIM}↑↓ navigate  ${G_DOT}  Enter confirm${C_RESET}"
pick2 "backup" "move to .bak, safe and reversible" "$C_GREEN" \
      "delete" "wipe cleanly, no backup kept"      "$C_RED"

if [ "$PICK2" -eq 1 ]; then
    BACKUP_MODE="delete"
    echo -e " ${C_MAIN}${C_BOLD}${G_END} ${C_RED}${G_OK}${C_RESET} delete\n"
else
    BACKUP_MODE="backup"
    echo -e " ${C_MAIN}${C_BOLD}${G_END} ${C_GREEN}${G_OK}${C_RESET} backup\n"
fi

# "No internet" and "no curl" are different facts, and reading the second as
# the first is how a minimal Debian or Ubuntu install — neither ships curl —
# got told it had no network on a box that was online, and stopped there before
# the step that would have installed curl. The bare debian:12 and ubuntu:24.04
# images the smoke job runs are exactly that box.
net_reachable() {       # <host> [host...] — false only if a probe ran and failed
    local h probed=0
    for h in "$@"; do
        if command -v curl &>/dev/null; then
            probed=1
            curl -fsSL --connect-timeout 5 --max-time 8 "https://$h" -o /dev/null 2>/dev/null && return 0
        elif command -v wget &>/dev/null; then
            probed=1
            wget -q --timeout=8 --tries=1 -O /dev/null "https://$h" 2>/dev/null && return 0
        fi
    done
    # A minimal Debian or Ubuntu has neither — and bash's own /dev/tcp is not a
    # dependable stand-in, since some builds compile net redirections out. With
    # nothing to probe with, "cannot tell" is not "offline": carry on and let
    # the install itself produce the real error. apt is about to refresh its
    # index anyway, and it says what actually went wrong.
    [ "$probed" -eq 1 ] || return 0
    return 1
}

# ── Step 1: AUR helper (Arch) / apt bootstrap (Debian/Ubuntu) ───────────────
if [[ "$DISTRO" == "arch" ]]; then
    info "Checking AUR helper..."
    # Either helper does everything this script asks of one, so an existing
    # install wins over a new one — no reason to build paru on a yay machine.
    for _h in paru yay; do
        command -v "$_h" &>/dev/null && { AUR_HELPER="$_h"; break; }
    done
    unset _h
    if [ -n "$AUR_HELPER" ]; then
        substep "${AUR_HELPER} already installed"
        success "AUR helper ready"
    else
        if [ "$IS_ROOT" -eq 1 ]; then
            # makepkg hard-refuses to build as root, so paru cannot be
            # bootstrapped here. Repo packages still install fine; only
            # AUR-only items are affected, and they report as failed.
            substep "${C_YELLOW}Running as root — makepkg refuses to build as root,${C_RESET}"
            substep "${C_YELLOW}so paru cannot be installed. Repo packages will work;${C_RESET}"
            substep "${C_YELLOW}AUR-only ones will be skipped.${C_RESET}"
            substep "${C_DIM}To get AUR support: create a normal user with sudo rights${C_RESET}"
            substep "${C_DIM}and re-run this script as that user.${C_RESET}"
            success "Continuing without an AUR helper"
        else
        substep "No AUR helper found — installing paru..."
        substep "Checking internet connection..."
        if ! net_reachable archlinux.org; then
            error "No internet connection — paru requires internet to install."
            exit 1
        fi
        substep "Installing build dependencies..."
        if ! sudo pacman -S --needed --noconfirm base-devel git; then
            error "Failed to install base-devel/git. Check your internet or sudo access."
            exit 1
        fi

        # Under RUN_TMPDIR, like every other temp artifact: a predictable
        # /tmp/paru-build is shared across users, and the EXIT trap cleans this
        # up if the build is interrupted between the two rm -rf calls.
        _paru_build="$RUN_TMPDIR/paru-build"

        # paru-bin is the same paru, prebuilt. Building from source drags in the
        # whole rust toolchain — 300+ MB and 2–4 minutes of compiling — for an
        # identical binary, so that is the fallback, not the default.
        for _src in paru-bin paru; do
            substep "Cloning ${C_ACCENT}${_src}${C_RESET} from AUR..."
            rm -rf "$_paru_build"
            if ! git clone "https://aur.archlinux.org/${_src}.git" "$_paru_build" &>/dev/null 2>&1; then
                substep "${C_YELLOW}Could not clone ${_src}${C_RESET}"
                continue
            fi
            if [[ "$_src" == "paru" ]]; then
                echo -e "${C_MAIN}${C_BOLD} ${G_MID}  ${C_DIM}❯ ${C_YELLOW}Building paru from source — output below (takes 2–4 min)${C_RESET}\n"
                (cd "$_paru_build" && makepkg -si --noconfirm) || true
                echo ""
            else
                substep "Installing prebuilt paru..."
                (cd "$_paru_build" && makepkg -si --noconfirm) &>/dev/null 2>&1 || true
            fi
            command -v paru &>/dev/null && break
            substep "${C_YELLOW}${_src} did not install${C_RESET}"
        done

        rm -rf "$_paru_build"
        unset _paru_build _src

        if ! command -v paru &>/dev/null; then
            error "paru installation failed — binary not found after build."
            exit 1
        fi
        AUR_HELPER="paru"
        success "paru installed"
        fi
    fi
else
    info "Preparing apt..."
    substep "Checking internet connection..."
    if ! net_reachable deb.debian.org archive.ubuntu.com; then
        error "No internet connection — apt requires internet to install packages."
        exit 1
    fi
    substep "Updating package index..."
    if apt_update_once; then
        ensure_apt_deps
        success "apt ready"
    else
        # Not fatal: one dead source fails the whole refresh even though every
        # other list updated and installs still work. Say so plainly here
        # instead of printing "apt ready" and letting the next step look like
        # the thing that broke.
        substep "${C_YELLOW}Package index did not refresh cleanly${C_RESET}"
        apt_index_report
        substep "${C_DIM}Continuing — installs usually still work when one source is broken${C_RESET}"
        ensure_apt_deps
        success "apt ready (index refreshed with errors)"
    fi
fi

# ── Step 2: tools (stow + fzf) ───────────────────────────────────────────────
info "Checking tools..."
TOOLS_TO_INSTALL=()
TOOLS_TO_UPDATE=()
for tool in stow fzf; do
    if ! command -v "$tool" &>/dev/null; then
        TOOLS_TO_INSTALL+=("$tool")
    else
        TOOLS_TO_UPDATE+=("$tool")
    fi
done

[ "${#TOOLS_TO_INSTALL[@]}" -gt 0 ] && substep "Installing:         ${C_ACCENT}${TOOLS_TO_INSTALL[*]}${C_RESET}"
[ "${#TOOLS_TO_UPDATE[@]}"  -gt 0 ] && substep "Updating to latest: ${C_ACCENT}${TOOLS_TO_UPDATE[*]}${C_RESET}"

if [[ "$DISTRO" == "arch" ]]; then
    if ! pacman_install stow fzf; then
        error "Failed to install/update stow and fzf."
        exit 1
    fi
else
    if ! apt_install stow fzf; then
        error "Failed to install/update stow and fzf."
        if [ -n "$APT_LAST_ERROR" ]; then
            substep "${C_DIM}apt said:${C_RESET}"
            printf '%s\n' "$APT_LAST_ERROR" | tail -5 | while IFS= read -r _l; do
                substep "${C_DIM}${_l}${C_RESET}"
            done
        fi
        exit 1
    fi
fi
success "Tools verified"

# ── Step 3: the menu ─────────────────────────────────────────────────────────
CONFIGS=(fastfetch ghostty kitty bash zsh protonvpn starship rofi ulauncher git micro fresh ccstatusline)
# Arch ships rofi 2.0 (Wayland support merged upstream); Debian/Ubuntu are
# still on the 1.7.x X11-only build, so rofi stays Arch-only. Stripped, never
# re-declared as a second literal list: a hand-maintained Debian copy silently
# drops every config added after it was written (micro and fresh both were).
[[ "$DISTRO" == "debian" ]] && strip_items CONFIGS rofi
[ "$IS_HEADLESS" -eq 1 ] && strip_items CONFIGS "${GUI_CONFIGS[@]}"
declare -a SELECTED=() DEPS=() APPS=()

# The numbered lists this script shipped with, kept for terminals that cannot
# draw the menu — and for --configs/--tools/--apps, which skip both.
menu_numeric() {
    info "Select configs to install..."
    echo ""
    local attempts=0 valid _i _c _dd _line _disp token
    local -a tmp
    while true; do
        for _i in "${!CONFIGS[@]}"; do
            _c="${CONFIGS[$_i]}"
            printf "${C_MAIN}${C_BOLD} ${G_MID}  ${C_ACCENT}%2d ${C_DIM}${G_ARROW} ${C_RESET}%-11s ${C_DIM}${G_DOT}  %s${C_RESET}\n" "$((_i+1))" "$_c" "${CONFIG_DESC[$_c]}"
        done
        echo -e "${C_MAIN}${C_BOLD} ${G_MID}  ${C_ACCENT} a ${C_DIM}${G_ARROW} ${C_RESET}All  ${C_DIM}${G_DOT}  Enter to skip${C_RESET}"
        echo -ne "${C_MAIN}${C_BOLD} ${G_END} ${C_YELLOW}Choice (e.g. 1 4 or a, Enter=skip): ${C_RESET}"
        read -r RAW <"$TTY_IN"
        echo ""

        if [[ "$RAW" == "a" || "$RAW" == "A" ]]; then
            SELECTED=("${CONFIGS[@]}")
            break
        fi
        # Same as esc in the menu: no configs is a valid answer — tools and
        # apps are still ahead.
        [ -z "$RAW" ] && break

        valid=true
        tmp=()
        for token in $RAW; do
            if [[ "$token" =~ ^[0-9]+$ ]] && (( token >= 1 && token <= ${#CONFIGS[@]} )); then
                tmp+=("${CONFIGS[$((token-1))]}")
            else
                valid=false; break
            fi
        done

        if $valid && [ "${#tmp[@]}" -gt 0 ]; then
            SELECTED=("${tmp[@]}")
            break
        fi

        (( attempts++ ))
        if [ "$attempts" -ge 3 ]; then
            error "Too many invalid attempts. Exiting."
            exit 1
        fi
        error "Invalid input — enter numbers 1–${#CONFIGS[@]} separated by spaces, or 'a' for all"
        echo ""
    done

    info "Optional dep tools..."
    echo ""
    for _i in "${!DEPS_LIST[@]}"; do
        _dd="${DEPS_LIST[$_i]}"
        printf "${C_MAIN}${C_BOLD} ${G_MID}  ${C_ACCENT}%2d ${C_DIM}${G_ARROW} ${C_RESET}%-9s ${C_DIM}${G_DOT}  %s${C_RESET}\n" "$((_i+1))" "$_dd" "${DEP_DESC[$_dd]}"
    done
    echo -e "${C_MAIN}${C_BOLD} ${G_MID}  ${C_ACCENT} a ${C_DIM}${G_ARROW} ${C_RESET}All  ${C_DIM}${G_DOT}  Enter to skip${C_RESET}"
    echo -ne "${C_MAIN}${C_BOLD} ${G_END} ${C_YELLOW}Choice (e.g. 1 2 or a, Enter=skip): ${C_RESET}"
    read -r DEP_RAW <"$TTY_IN"
    echo ""
    if [[ "$DEP_RAW" == "a" || "$DEP_RAW" == "A" ]]; then
        DEPS=("${DEPS_LIST[@]}")
    elif [[ -n "$DEP_RAW" ]]; then
        for token in $DEP_RAW; do
            [[ "$token" =~ ^[0-9]+$ ]] && \
            (( token >= 1 && token <= ${#DEPS_LIST[@]} )) && \
            DEPS+=("${DEPS_LIST[$((token-1))]}")
        done
    fi

    info "Optional applications..."
    echo ""
    local _app_i=1
    for _line in "${APPS_LIST[@]}"; do
        printf "${C_MAIN}${C_BOLD} ${G_MID}  ${C_ACCENT}%2d ${C_DIM}${G_ARROW} ${C_RESET}%-22s ${C_DIM}${G_DOT}  %s${C_RESET}\n" \
            "$_app_i" "${APP_LABEL[$_line]}" "$(app_type_resolved "$_line")"
        (( _app_i++ ))
    done
    echo -e "${C_MAIN}${C_BOLD} ${G_MID}  ${C_ACCENT} a ${C_DIM}${G_ARROW} ${C_RESET}All  ${C_DIM}${G_DOT}  Enter to skip${C_RESET}"
    echo -ne "${C_MAIN}${C_BOLD} ${G_END} ${C_YELLOW}Choice (e.g. 1 3 or a, Enter=skip): ${C_RESET}"
    read -r APP_RAW <"$TTY_IN"
    echo ""
    if [[ "$APP_RAW" == "a" || "$APP_RAW" == "A" ]]; then
        APPS=("${APPS_LIST[@]}")
    elif [[ -n "$APP_RAW" ]]; then
        for token in $APP_RAW; do
            [[ "$token" =~ ^[0-9]+$ ]] && \
            (( token >= 1 && token <= ${#APPS_LIST[@]} )) && \
            APPS+=("${APPS_LIST[$((token-1))]}")
        done
    fi
}

# --configs / --tools / --apps: name what you want and no menu is drawn at all.
# Unknown names are an error rather than a silent omission — a typo in an
# unattended run would otherwise look like a successful install of nothing.
menu_from_flags() {
    local -n _out=$1; local -n _pool=$2
    local raw=$3 what=$4 name found item
    [ "$raw" = "-" ] && return 0
    if [ "$raw" = "all" ]; then _out=("${_pool[@]}"); return 0; fi
    local IFS=', '
    for name in $raw; do
        found=0
        for item in "${_pool[@]}"; do
            [ "$item" = "$name" ] && { _out+=("$name"); found=1; break; }
        done
        if [ "$found" -eq 0 ]; then
            error "Unknown ${what}: ${C_RED}${name}${C_RESET}"
            substep "${C_DIM}available: ${_pool[*]}${C_RESET}"
            exit 2
        fi
    done
}

if [ -n "$PICK_CONFIGS$PICK_TOOLS$PICK_APPS" ]; then
    info "Selection given on the command line..."
    menu_from_flags SELECTED CONFIGS   "${PICK_CONFIGS:--}" "config"
    menu_from_flags DEPS     DEPS_LIST "${PICK_TOOLS:--}"   "tool"
    menu_from_flags APPS     APPS_LIST "${PICK_APPS:--}"    "app"
elif tui_available; then
    info "Choose what to install..."
    substep "${C_DIM}dotfiles, tools and apps — one screen, ${G_LEFT} ${G_RIGHT} between them${C_RESET}"
    if ! tui_pick; then
        error "Cancelled — nothing was installed."
        exit 0
    fi
else
    substep "${C_DIM}This terminal cannot draw the menu — using the numbered list${C_RESET}"
    echo ""
    menu_numeric
fi

# After every selection path, not inside one: the TUI ticks bun where it can be
# seen and undone, but --configs=ccstatusline and the numbered list have no menu
# to show it in, and a statusline with no bun renders nothing at all. Harmless
# when the TUI already ticked it — this only adds what is missing.
if printf '%s\n' "${SELECTED[@]}" | grep -qx ccstatusline \
   && ! printf '%s\n' "${APPS[@]}" | grep -qx bun; then
    APPS+=(bun)
    substep "${C_DIM}ccstatusline renders through bunx — adding bun${C_RESET}"
fi

# .zshrc ends with `eval "$(starship init zsh)"` — the entire prompt is
# starship. Picking zsh without it produced a bare "hostname#", which looks
# like the install failed. It is a hard dependency, so pull it in. The menu
# ticks it for you; this catches the paths that do not, and the case where it
# was deliberately unticked.
if printf '%s\n' "${SELECTED[@]}" | grep -qx zsh \
   && ! printf '%s\n' "${SELECTED[@]}" | grep -qx starship; then
    SELECTED+=(starship)
    substep "${C_DIM}zsh draws its prompt with starship — adding starship${C_RESET}"
fi

# Everything .zshrc reaches for is guarded by `command -v`, so without the tools
# the shell comes up looking half-installed: no ls/cat/z/lg aliases, no fzf key
# bindings. This lived twice, character for character, inside menu_numeric and
# the --configs= path — the shape that lets a rule get fixed in one copy only.
# Last of the three blocks, because it is the only one that writes DEPS and
# nothing else reads DEPS, while the block above is still adding to SELECTED:
# from here it sees every config the earlier rules put there.
# The menu is exempt rather than merely a no-op: it ticks the tools where you
# can see and untick them, and re-adding one that was deliberately unticked
# would contradict the screen that was just confirmed.
if [ "$TUI_CONFIRMED" != 1 ] && printf '%s\n' "${SELECTED[@]}" | grep -qx zsh; then
    _dep_added=()
    for _d in "${DEPS_LIST[@]}"; do
        printf '%s\n' "${DEPS[@]}" | grep -qx "$_d" && continue
        DEPS+=("$_d"); _dep_added+=("$_d")
    done
    [ "${#_dep_added[@]}" -gt 0 ] \
        && substep "${C_DIM}zsh needs these for its aliases — adding ${_dep_added[*]}${C_RESET}"
    unset _d _dep_added
fi

# No configs is a normal answer: "install these apps, leave my dotfiles alone".
# The run only stops if nothing at all is picked, which is checked below.
if [ "${#SELECTED[@]}" -gt 0 ]; then
    success "Configs: ${C_ACCENT}${SELECTED[*]}${C_RESET}"
else
    success "${C_DIM}No configs selected — nothing of yours will be touched${C_RESET}"
fi

if [ "${#DEPS[@]}" -gt 0 ]; then
    success "Dep tools: ${C_ACCENT}${DEPS[*]}${C_RESET}"
else
    success "${C_DIM}No dep tools selected${C_RESET}"
fi

if [ "${#APPS[@]}" -gt 0 ]; then
    _app_labels=()
    for _k in "${APPS[@]}"; do _app_labels+=("${APP_LABEL[$_k]}"); done
    success "Apps: ${C_ACCENT}${_app_labels[*]}${C_RESET}"
    unset _app_labels _k
else
    success "${C_DIM}No apps selected${C_RESET}"
fi

# Three empty menus in a row means the answer was "nothing" — there is no plan
# to show and no reason to ask for sudo again.
if [ "${#SELECTED[@]}" -eq 0 ] && [ "${#DEPS[@]}" -eq 0 ] && [ "${#APPS[@]}" -eq 0 ]; then
    error "Nothing selected. Exiting."
    exit 0
fi

# ── Step 4: plan + confirm ────────────────────────────────────────────────────
show_plan "${SELECTED[@]}"

# ── Step 5a: install dep tools ───────────────────────────────────────────────
STOWED_WALLPAPER=0
INSTALLED=()
FAILED=()

# ── Step 5a0: fonts ───────────────────────────────────────────────────────────
# Both fonts are installed on every run rather than only when a terminal config
# happens to be selected: the configs reference them by name, so picking zsh or
# starship alone used to leave a terminal with no font to render. Skipped only
# where they cannot do anything — no display server, or WSL, where the terminal
# is a Windows program and the Linux filesystem is the wrong place for them.
if [ "${#SELECTED[@]}" -eq 0 ]; then
    # "Every run" is really "every run that installs a config" — the configs are
    # what name these fonts. An apps-only run has nothing to render with them.
    info "Fonts..."
    substep "${C_DIM}No configs selected — nothing names them, skipping${C_RESET}"
    success "Skipped"
elif [ "$IS_WSL" -eq 1 ]; then
    info "Fonts..."
    substep "${C_YELLOW}WSL — install the fonts on Windows, not here${C_RESET}"
    substep "${C_DIM}Get JetBrainsMono Nerd Font and Maple Mono, install them in${C_RESET}"
    substep "${C_DIM}Windows, then select them in Windows Terminal / VS Code.${C_RESET}"
    success "Skipped"
elif [ "$IS_HEADLESS" -eq 1 ]; then
    info "Fonts..."
    substep "${C_DIM}No display server — nothing here can render them, skipping${C_RESET}"
    success "Skipped"
else
    info "Fonts..."
    if font_installed; then
        substep "${C_DIM}JetBrainsMono Nerd Font already installed${C_RESET}"
    else
        substep "Installing ${C_ACCENT}JetBrainsMono Nerd Font${C_RESET}..."
        install_font || { error "Failed to install JetBrainsMono — continuing"; FAILED+=("JetBrainsMono font"); }
    fi
    if maple_font_installed; then
        substep "${C_DIM}Maple Mono already installed${C_RESET}"
    else
        substep "Installing ${C_ACCENT}Maple Mono${C_RESET}..."
        install_maple_font || { error "Failed to install Maple Mono — continuing"; FAILED+=("Maple Mono font"); }
    fi
    substep "Rebuilding font cache..."
    fc-cache -fv &>/dev/null 2>&1 || true
    success "Fonts ready"
fi

if [ "${#DEPS[@]}" -gt 0 ]; then
    info "Installing dep tools..."
    for dep in "${DEPS[@]}"; do
        dep_pkg="$(dep_pkg_name "$dep")"
        if pkg_installed "$dep_pkg"; then
            substep "${C_ACCENT}${dep}${C_RESET} ${C_DIM}already installed${C_RESET}"
        else
            substep "Installing ${C_ACCENT}${dep}${C_RESET}..."
            _dep_ok=1
            if [[ "$DISTRO" == "arch" ]]; then
                arch_install "$dep_pkg" || _dep_ok=0
            else
                case "$dep" in
                    eza)          ensure_eza_deb          || _dep_ok=0 ;;
                    lazygit)      ensure_lazygit_deb      || _dep_ok=0 ;;
                    pay-respects) ensure_pay_respects_deb || _dep_ok=0 ;;
                    *)            apt_install "$dep_pkg"  || _dep_ok=0 ;;
                esac
            fi
            if [ "$_dep_ok" -eq 0 ]; then
                error "Failed to install ${dep} — skipping"
                FAILED+=("$dep")
                continue
            fi
        fi
        # Debian ships these as batcat/fdfind; the shim is what makes the
        # .zshrc aliases resolve. Not fatal on its own — the tool still works
        # under its Debian name — so warn rather than fail the dep.
        if [[ "$DISTRO" == "debian" ]]; then
            if [[ "$dep" == "bat" ]] && ! ensure_bat_shim; then
                substep "${C_YELLOW}bat installed as batcat; could not add the bat shim${C_RESET}"
            fi
            if [[ "$dep" == "fd" ]] && ! ensure_fd_shim; then
                substep "${C_YELLOW}fd installed as fdfind; could not add the fd shim${C_RESET}"
            fi
        fi

        # Stow config for deps that have one. A stow conflict here used to be
        # printed and then forgotten, leaving the tool reported as installed
        # with none of its configuration in place.
        _dep_cfg_ok=1
        for _dc in "${DEP_HAS_CONFIG[@]}"; do
            if [[ "$dep" == "$_dc" ]] && [ -d "$DOTFILES_DIR/$dep" ]; then
                stow_config "$dep" || _dep_cfg_ok=0
                break
            fi
        done
        if [ "$_dep_cfg_ok" -eq 0 ]; then
            FAILED+=("${dep} config")
        fi

        INSTALLED+=("$dep")
    done
    unset _dep_cfg_ok
    success "Dep tools done"
fi

# ── Step 5b: install configs ──────────────────────────────────────────────────

_cfg_i=0
for cfg in "${SELECTED[@]}"; do
    _cfg_i=$(( _cfg_i + 1 ))
    info "${C_DIM}[${_cfg_i}/${#SELECTED[@]}]${C_RESET} Installing ${C_ACCENT}${cfg}${C_RESET}..."
    pkg="${PKG_MAP[$cfg]}"

    case "$cfg" in

      # ── fastfetch / ghostty / kitty / rofi / micro / fresh ──────────────
      fastfetch|ghostty|kitty|rofi|micro|fresh)
        ensure_cfg_pkg "$cfg" "$pkg" || { FAILED+=("$cfg"); continue; }

        if ! stow_config "$cfg"; then
            FAILED+=("$cfg")
            continue
        fi

        if [ "$STOWED_WALLPAPER" -eq 0 ] && needs_wallpaper "$cfg"; then
            if [ -d "$DOTFILES_DIR/wallpapers" ]; then
                stow_config "wallpapers"
                STOWED_WALLPAPER=1
            fi
        fi

        if [[ "$cfg" == "rofi" ]]; then
            substep "${C_DIM}Launch rofi with: ${C_ACCENT}rofi -show drun${C_RESET}"
        fi

        # micro downloads plugins itself, into ~/.config/micro/plug/ — which is
        # deliberately not in this repo, since it is runtime state rather than
        # config. Re-running is how it comes back after stow_config has moved a
        # populated ~/.config/micro aside, so this stays in the normal path.
        if [[ "$cfg" == "micro" ]]; then
            substep "Installing micro plugins..."
            if micro -plugin install filemanager &>/dev/null 2>&1; then
                substep "${C_DIM}Tree view: ${C_ACCENT}> tree${C_RESET}"
            else
                substep "${C_YELLOW}Could not install the filemanager plugin${C_RESET}"
            fi
        fi
        ;;

      # ── ccstatusline ─────────────────────────────────────────────────────
      ccstatusline)
        # Nothing to install. Claude Code runs `bunx -y ccstatusline@latest`,
        # which resolves the newest release on every render — that is the whole
        # point of picking bunx over a pinned global, and it means this config
        # is a settings file plus a bun dependency and nothing else. bun is its
        # own entry in the apps tab rather than a second curl installer here.
        # The configs loop runs before the apps loop, so bun being absent here
        # is the normal case on a fresh machine, not a problem — it is queued
        # and lands a few steps down. Only say something when it is genuinely
        # not coming.
        if curl_app_installed bun; then
            substep "${C_ACCENT}bun${C_RESET} already installed"
        elif printf '%s\n' "${APPS[@]}" | grep -qx bun; then
            substep "${C_DIM}bun installs with the applications below${C_RESET}"
        else
            substep "${C_YELLOW}bun is not installed${C_RESET} ${C_DIM}— the statusline cannot render without it${C_RESET}"
        fi

        if ! stow_config "$cfg"; then
            FAILED+=("$cfg")
            continue
        fi

        # The settings file is only half of it — Claude Code still has to be
        # told to call the thing. That happens once in step 5c½, which the
        # apps loop can also reach by installing Claude Code itself.
        ;;

      # ── bash ─────────────────────────────────────────────────────────────
      bash)
        # No install step: we are running in it. PKG_MAP[bash] exists so the
        # plan and the menus can treat this like any other config.
        substep "${C_ACCENT}bash${C_RESET} already installed"
        # Before backup_file, always: in delete mode that rm -rf's ~/.bashrc
        # with no .bak, and this is the only other copy.
        # Enforced, not just asserted in a comment. In delete mode backup_file
        # rm -rf's ~/.bashrc with no .bak, so if the snapshot did not happen
        # this step is the difference between reversible and gone. Refuse the
        # config rather than take that trade on the user's behalf.
        if ! snapshot_bashrc; then
            error "Could not keep a pristine copy of ~/.bashrc — not touching it"
            substep "${C_DIM}Without that copy this change would be irreversible.${C_RESET}"
            substep "${C_DIM}Check permissions on \$HOME and re-run.${C_RESET}"
            FAILED+=(bash)
            continue
        fi
        backup_file "$HOME/.bashrc"
        if ! stow_home "bash"; then
            FAILED+=(bash)
            continue
        fi
        substep "${C_DIM}Plain rc — no starship, no plugins. Undo with ${C_ACCENT}--restore-bash${C_RESET}"
        ;;

      # ── zsh ──────────────────────────────────────────────────────────────
      zsh)
        ensure_cfg_pkg "$cfg" "$pkg" || { FAILED+=("$cfg"); continue; }

        backup_file "$HOME/.zshrc"
        if ! stow_home "zsh"; then
            FAILED+=(zsh)
            continue
        fi

        # Change default shell to zsh if still on bash/something else
        # $USER is unset under cron/docker exec/some non-login shells — ask the
        # kernel who we are instead of trusting the environment.
        target_user="$(id -un)"
        zsh_path="$(command -v zsh)"
        current_shell="$(getent passwd "$target_user" | cut -d: -f7)"
        if [ -z "$zsh_path" ]; then
            # The package manager reported success but no zsh landed on PATH.
            # Without this guard the fallbacks below run 'chsh -s "" <user>',
            # which blanks the login shell entry.
            error "zsh binary not found on PATH — leaving the default shell alone"
        elif same_shell "$current_shell" "$zsh_path"; then
            substep "${C_DIM}Login shell for ${target_user} is already zsh${C_RESET}"
        else
            substep "Changing login shell for ${C_ACCENT}${target_user}${C_RESET} to zsh..."

            # chsh refuses any shell missing from /etc/shells (-s creates the
            # file if the image does not ship one).
            grep -qxs "$zsh_path" /etc/shells \
                || echo "$zsh_path" | sudo tee -a /etc/shells &>/dev/null

            # </dev/null: chsh goes through PAM and may prompt for a password.
            # Without it the prompt reads the installer's own stdin and hangs.
            sudo chsh -s "$zsh_path" "$target_user" </dev/null &>/dev/null || true

            if ! same_shell "$(getent passwd "$target_user" | cut -d: -f7)" "$zsh_path"; then
                # PAM refuses on cloud accounts with no local password
                # (SSH-key-only login). usermod writes /etc/passwd directly.
                sudo usermod -s "$zsh_path" "$target_user" </dev/null &>/dev/null || true
            fi

            # Read it back rather than trusting an exit code. chsh can exit 0
            # having changed nothing, which is exactly how the shell ends up
            # still being bash after logging out and back in.
            new_shell="$(getent passwd "$target_user" | cut -d: -f7)"
            if same_shell "$new_shell" "$zsh_path"; then
                substep "${C_GREEN}Login shell for ${target_user} is now ${zsh_path}${C_RESET}"
                substep "${C_DIM}Applies at next login — or run ${C_ACCENT}exec zsh${C_DIM} to switch now${C_RESET}"
                if ! zsh_hook_wanted; then
                    substep "${C_DIM}bash config selected too — leaving ~/.bashrc as a working bash${C_RESET}"
                elif ensure_zsh_autoexec; then
                    substep "${C_DIM}Added a .bashrc fallback in case a session still starts bash${C_RESET}"
                elif [ "$_HOOK_STATE" = "skipped-repo-link" ]; then
                    substep "${C_YELLOW}~/.bashrc is a stowed symlink — fallback hook not written${C_RESET}"
                elif [ "$_HOOK_STATE" = "malformed" ]; then
                    substep "${C_YELLOW}A hand-edited hook block is in ~/.bashrc — left alone${C_RESET}"
                fi
                # An SSH client with ControlMaster keeps handing out sessions from
                # a master opened before the change, so reconnecting still lands in
                # bash and the change looks like it failed. Say so up front.
                if [ -n "${SSH_CONNECTION:-}${SSH_TTY:-}${SSH_CLIENT:-}" ]; then
                    _ssh_host="$(printf '%s' "${SSH_CONNECTION:-}" | awk '{print $3}')"
                    substep ""
                    substep "${C_YELLOW}On SSH: the new shell applies to new logins.${C_RESET}"
                    substep "${C_DIM}If reconnecting still gives you bash, your client is reusing a${C_RESET}"
                    substep "${C_DIM}multiplexed connection. Run this ${C_RESET}${C_DIM}on your local machine${C_RESET}${C_DIM}:${C_RESET}"
                    substep "  ${C_ACCENT}ssh -O exit ${_ssh_host:-<host>}${C_RESET}   ${C_DIM}then reconnect${C_RESET}"
                    substep "${C_DIM}Use whatever name you connect by — an alias from ~/.ssh/config${C_RESET}"
                    substep "${C_DIM}works too. Or switch this session now: ${C_ACCENT}exec zsh${C_RESET}"
                    unset _ssh_host
                fi
            else
                error "Login shell unchanged — still ${new_shell:-unknown}"
                if ! zsh_hook_wanted; then
                    substep "${C_DIM}bash config selected too — leaving ~/.bashrc as a working bash${C_RESET}"
                elif ensure_zsh_autoexec; then
                    substep "${C_GREEN}Added a .bashrc fallback — bash will hand over to zsh${C_RESET}"
                elif [ "$_HOOK_STATE" = "skipped-repo-link" ]; then
                    substep "${C_YELLOW}~/.bashrc is a stowed symlink — fallback hook not written${C_RESET}"
                fi
                substep "To fix it properly: ${C_ACCENT}sudo usermod -s ${zsh_path} ${target_user}${C_RESET}"
                substep "${C_DIM}This sets the shell for '${target_user}'. If you SSH in as a${C_RESET}"
                substep "${C_DIM}different account, run that command for that account instead.${C_RESET}"
            fi
        fi
        unset zsh_path current_shell target_user new_shell
        ;;

      # ── protonvpn ────────────────────────────────────────────────────────
      protonvpn)
        ensure_cfg_pkg "$cfg" "$pkg" || { FAILED+=("$cfg"); continue; }

        # Unlink stow-folded dirs from a previous run before backup — ours
        # only. A bare `rm` on any symlink here was the same silent, backup-less
        # delete backup_file and stow_config both had: someone keeping
        # ~/scripts pointed at a synced folder or another drive lost the link,
        # in backup mode, with not one word said. backup_file already rotates,
        # backs up or deletes-and-says-so, so a foreign link takes that path.
        pvpn_dir="$HOME/scripts/pvpn"
        if is_repo_link "$pvpn_dir"; then
            rm "$pvpn_dir"
        elif [ -L "$pvpn_dir" ]; then
            backup_file "$pvpn_dir"
        fi
        if is_repo_link "$HOME/scripts"; then
            rm "$HOME/scripts"
        fi
        # A foreign ~/scripts is left exactly where it points: mkdir -p follows
        # it, and moving someone's whole scripts directory aside to install one
        # VPN helper is not a reasonable reading of "install protonvpn". It can
        # still fail — a link to an unwritable or unmounted path — and stow's
        # own error for that names neither the directory nor the reason.
        if ! mkdir -p "$pvpn_dir" 2>/dev/null; then
            error "Could not create ${C_ACCENT}~/scripts/pvpn${C_RESET}"
            substep "${C_DIM}~/scripts may be a symlink to somewhere unwritable or not mounted${C_RESET}"
            FAILED+=(protonvpn)
            continue
        fi
        backup_file "$pvpn_dir/pvpn.zsh"
        # stow proton-vpn/ directly into ~/scripts/pvpn/
        if ! stow_to "$pvpn_dir" "proton-vpn"; then
            FAILED+=(protonvpn)
            continue
        fi
        unset pvpn_dir
        ;;

      # ── starship ─────────────────────────────────────────────────────────
      starship)
        ensure_cfg_pkg "$cfg" "$pkg" || { FAILED+=("$cfg"); continue; }

        # starship is a single file, not a directory — handle differently.
        #
        # An existing starship.toml is left exactly where it is. A prompt
        # config is something people tune by hand, and replacing it (or, in
        # delete mode, erasing it) to install our own is not a reasonable
        # reading of "install starship". Ours goes in only when there is
        # nothing there.
        _st="$HOME/.config/starship.toml"
        # is_repo_link, not a fourth hand-written copy of it. There were three,
        # and the one in restore_bash had already drifted into deleting links
        # it did not own before anyone noticed they were meant to agree.
        if is_repo_link "$_st"; then
            # ours from an earlier run — refresh the link
            stow --target "$HOME/.config" --dir "$DOTFILES_DIR" -D "starship" &>/dev/null 2>&1 || true
            if ! stow --target "$HOME/.config" --dir "$DOTFILES_DIR" "starship" &>/dev/null 2>&1; then
                error "Stow failed for starship — check for conflicts in ~/.config/"
                FAILED+=(starship)
                continue
            fi
        elif [ -e "$_st" ] || [ -L "$_st" ]; then
            substep "${C_DIM}Keeping your existing ~/.config/starship.toml — ours not installed${C_RESET}"
        else
            if ! stow --target "$HOME/.config" --dir "$DOTFILES_DIR" "starship" &>/dev/null 2>&1; then
                error "Stow failed for starship — check for conflicts in ~/.config/"
                FAILED+=(starship)
                continue
            fi
        fi
        unset _st
        ;;

      # ── git ──────────────────────────────────────────────────────────────
      git)
        ensure_cfg_pkg "$cfg" "$pkg" || { FAILED+=("$cfg"); continue; }

        backup_file "$HOME/.gitconfig"
        if ! stow_home "git"; then
            FAILED+=(git)
            continue
        fi
        ;;

      # ── ulauncher ────────────────────────────────────────────────────────
      ulauncher)
        ensure_cfg_pkg "$cfg" "$pkg" || { FAILED+=("$cfg"); continue; }

        if ! stow_config "ulauncher"; then
            FAILED+=(ulauncher)
            continue
        fi

        # Autostart — create desktop entry if missing
        autostart_dir="$HOME/.config/autostart"
        autostart_file="$autostart_dir/ulauncher.desktop"
        mkdir -p "$autostart_dir"
        if [ ! -f "$autostart_file" ]; then
            substep "Enabling autostart..."
            cat > "$autostart_file" << 'AUTOSTART'
[Desktop Entry]
Name=Ulauncher
Comment=Application Launcher
Exec=ulauncher --hide-window
Icon=ulauncher
Terminal=false
Type=Application
X-GNOME-Autostart-enabled=true
AUTOSTART
            substep "${C_GREEN}Autostart enabled${C_RESET}"
        else
            substep "${C_DIM}Autostart already configured${C_RESET}"
        fi

        substep "${C_DIM}Toggle command: ${C_ACCENT}ulauncher-toggle${C_RESET}"
        ;;

    esac

    success "${C_ACCENT}${cfg}${C_RESET} installed"
    INSTALLED+=("$cfg")
done

# ── Step 5c: install applications ────────────────────────────────────────────
if [ "${#APPS[@]}" -gt 0 ]; then
    info "Installing applications..."
    _app_n=0
    for app in "${APPS[@]}"; do
        _app_n=$(( _app_n + 1 ))
        _lbl="${APP_LABEL[$app]}"
        _type="$(app_type_resolved "$app")"
        # counter only in the running output — $_lbl also feeds the summary
        substep "${C_DIM}[${_app_n}/${#APPS[@]}]${C_RESET} ${C_ACCENT}${_lbl}${C_RESET}"

        if [[ "$_type" == "curl" ]]; then
            _bin="${APP_BIN[$app]:-}"
            _have=0; curl_app_installed "$_bin" && _have=1
            if [ "$_have" -eq 1 ] && [ -z "${APP_UPDATE[$app]+x}" ]; then
                substep "${C_ACCENT}${_lbl}${C_RESET} already installed"
                success "${C_ACCENT}${_lbl}${C_RESET} done"
                INSTALLED+=("$_lbl")
            elif [ "$_have" -eq 1 ] && [ -n "${APP_UPDATE[$app]}" ]; then
                substep "${C_ACCENT}${_lbl}${C_RESET} already installed — updating..."
                # A failed update still leaves the working version behind, so it
                # is a warning here, not a failed app.
                read -ra _ucmd <<< "${APP_UPDATE[$app]}"
                PATH="${CURL_APP_PATH}:$PATH" "${_ucmd[@]}" </dev/null \
                    || substep "${C_DIM}Update failed — keeping the installed version${C_RESET}"
                app_open_hint "$app"
                success "${C_ACCENT}${_lbl}${C_RESET} done"
                INSTALLED+=("$_lbl")
            else
                # $_have here means an app with no update command: its installer
                # is the only updater it has, so it runs again.
                [ "$_have" -eq 1 ] && substep "${C_ACCENT}${_lbl}${C_RESET} already installed — its installer is its updater"
                substep "Downloading installer for ${C_ACCENT}${_lbl}${C_RESET}..."
                _tmpsh=$(mktemp -p "$RUN_TMPDIR" installer_XXXXXX.sh)
                case "$app" in
                    claude-code)     _curl_url="https://claude.ai/install.sh"              ; _shell=bash ;;
                    antigravity-cli) _curl_url="https://antigravity.google/cli/install.sh" ; _shell=bash ;;
                    codex-cli)       _curl_url="https://chatgpt.com/codex/install.sh"      ; _shell=sh   ;;
                    cursor-cli)      _curl_url="https://cursor.com/install"                ; _shell=bash ;;
                    opencode)        _curl_url="https://opencode.ai/install"               ; _shell=bash ;;
                    kimi-code)       _curl_url="https://code.kimi.com/kimi-code/install.sh"  ; _shell=bash ;;
                    muse)            _curl_url="https://dev.meta.ai/install.sh"              ; _shell=bash ;;
                    hermes)          _curl_url="https://hermes-agent.nousresearch.com/install.sh" ; _shell=bash ;;
                    # ends by launching its interactive setup wizard, with no
                    # flag to skip it — </dev/null below is what stops that,
                    # and the exit status it leaves behind is why the check
                    # after it looks at the binary instead.
                    devin)           _curl_url="https://cli.devin.ai/install.sh"                ; _shell=bash ;;
                    grok-cli)        _curl_url="https://x.ai/cli/install.sh"                    ; _shell=bash ;;
                    # a wrapper: it installs uv first when uv is missing, then
                    # `uv tool install mistral-vibe`
                    mistral-cli)     _curl_url="https://mistral.ai/vibe/install.sh"             ; _shell=bash ;;
                    # installs into /usr/local/bin — its own sudo, already cached
                    postman-cli)     _curl_url="https://dl-cli.pstmn.io/install/unix.sh"    ; _shell=sh   ;;
                    bun)             _curl_url="https://bun.com/install"                   ; _shell=bash
                                     ensure_unzip ;;
                esac
                if curl -fsSL "$_curl_url" -o "$_tmpsh" 2>/dev/null; then
                    substep "Running installer..."
                    _cenv=()  ; [ -n "${APP_CURL_ENV[$app]:-}" ]  && read -ra _cenv  <<< "${APP_CURL_ENV[$app]}"
                    _cargs=() ; [ -n "${APP_CURL_ARGS[$app]:-}" ] && read -ra _cargs <<< "${APP_CURL_ARGS[$app]}"
                    # </dev/null: a vendor installer must never read this
                    # script's stdin — under `curl … | bash` that is the rest of
                    # the download stream, and on a terminal it is the keys the
                    # remaining prompts are waiting for. Devin's is the one that
                    # would actually sit there: it ends by running `devin setup`,
                    # an interactive login with no flag to skip it.
                    env PATH="${CURL_APP_PATH}:$PATH" "${_cenv[@]}" "$_shell" "$_tmpsh" "${_cargs[@]}" </dev/null
                    _rc=$?
                    # Verified against reality, the way the package path is, and
                    # the binary is the verdict rather than the exit status. An
                    # installer that swallows its own failure and exits 0 leaves
                    # nothing behind and still fails here; Devin's, which installs
                    # cleanly and *then* exits 1 because the login it launched was
                    # cancelled, is not a failed install. Only an app with no
                    # APP_BIN entry to probe has nothing but the status to go on.
                    _ok=1
                    if [ -n "$_bin" ] && ! curl_app_installed "$_bin"; then _ok=0; fi
                    if [ "$_ok" -eq 1 ] && { [ -n "$_bin" ] || [ "$_rc" -eq 0 ]; }; then
                        success "${C_ACCENT}${_lbl}${C_RESET} installed"
                        app_open_hint "$app"
                        INSTALLED+=("$_lbl")
                    elif [ "$_rc" -ne 0 ]; then
                        error "Installer exited with error for ${C_ACCENT}${_lbl}${C_RESET}"
                        FAILED+=("$_lbl")
                    else
                        error "Installer finished but ${C_ACCENT}${_bin}${C_RESET} is not on PATH"
                        FAILED+=("$_lbl")
                    fi
                else
                    error "Download failed for ${C_ACCENT}${_lbl}${C_RESET} — check network"
                    FAILED+=("$_lbl")
                fi
                rm -f "$_tmpsh"
                unset _tmpsh _curl_url _shell _cenv _cargs _rc _ok
            fi
        else
            _pkg="$(app_pkg_name "$app")"
            if pkg_installed "$_pkg"; then
                substep "${C_ACCENT}${_lbl}${C_RESET} already installed — updating..."
            else
                substep "Installing ${C_ACCENT}${_lbl}${C_RESET}..."
            fi
            case "$_type" in
                paru-y) aur_install_y "$_pkg" ;;
                pacman|paru) arch_install "$_pkg" ;;
                apt)    apt_install "$_pkg" ;;
                brave)
                    case "$app" in
                        brave-stable) ensure_brave_deb stable "$_pkg" ;;
                        brave-beta)   ensure_brave_deb beta   "$_pkg" ;;
                    esac
                    ;;
                vscode|vscode-insiders) ensure_vscode_deb "$_pkg" ;;
                alacritty) ensure_alacritty_deb ;;
                wezterm) ensure_wezterm_deb ;;
                claude-desktop) ensure_claude_desktop_deb ;;
                docker) ensure_docker_deb ;;
            esac
            if pkg_installed "$_pkg"; then
                if [[ "$app" == "wezterm" ]]; then
                    # Silent — no menu row, no plan line: it is part of what
                    # "wezterm" means here, not a separate thing to pick.
                    substep "Installing Nerd Font symbols..."
                    install_symbols_font \
                        || substep "${C_YELLOW}Could not install the symbols font — glyphs may not render${C_RESET}"
                elif [[ "$app" == "flatpak" ]]; then
                    substep "Adding Flathub remote..."
                    ensure_flathub_remote \
                        || substep "${C_YELLOW}Could not add Flathub — add it manually${C_RESET}"
                elif [[ "$app" == "vicinae" ]]; then
                    vicinae_postinstall
                    substep "${C_DIM}Toggle command: ${C_ACCENT}vicinae toggle${C_RESET} ${C_DIM}— bind it to a hotkey in your compositor${C_RESET}"
                elif [[ "$app" == "obs-studio" ]]; then
                    # Both are required, not extras: without v4l2loopback-dkms
                    # the Start Virtual Camera button fails at runtime, and
                    # without qt6-wayland OBS falls back to XWayland (blurry UI,
                    # broken screen capture) on a Wayland session. Same package
                    # names on Arch and apt, so no *_DEB map entry.
                    substep "Installing v4l2loopback-dkms and qt6-wayland..."
                    if [[ "$DISTRO" == "arch" ]]; then
                        pacman_install v4l2loopback-dkms qt6-wayland &>/dev/null 2>&1
                    else
                        apt_install v4l2loopback-dkms qt6-wayland &>/dev/null 2>&1
                    fi || substep "${C_YELLOW}Could not install v4l2loopback-dkms/qt6-wayland${C_RESET} ${C_DIM}— OBS itself is installed; the virtual camera will not work until they are${C_RESET}"
                elif [[ "$app" == "docker" ]]; then
                    if [[ "$DISTRO" == "arch" ]]; then
                        substep "Installing docker-compose and docker-buildx..."
                        # The app is called "Docker + Compose" and the plan
                        # promises both. Losing compose silently and still
                        # reporting the app done is the label telling a lie.
                        pacman_install docker-compose docker-buildx &>/dev/null 2>&1 \
                            || substep "${C_YELLOW}Could not install docker-compose/docker-buildx${C_RESET} ${C_DIM}— docker itself is installed${C_RESET}"
                    fi
                    docker_postinstall
                fi
                success "${C_ACCENT}${_lbl}${C_RESET} done"
                INSTALLED+=("$_lbl")
            else
                error "Failed to install ${C_ACCENT}${_lbl}${C_RESET}"
                FAILED+=("$_lbl")
            fi
        fi
    done
    unset app _lbl _type _pkg _bin
fi

# ── Step 5c½: point Claude Code at the statusline ────────────────────────────
# Either trigger is enough, and both are the same intent: the config is the
# statusline's settings, the app is the thing that renders it. One call site
# rather than one in each loop, so picking both cannot wire it twice.
if printf '%s\n' "${SELECTED[@]}" | grep -qx ccstatusline \
   || printf '%s\n' "${APPS[@]}" | grep -qx claude-code; then
    info "Claude Code statusline..."
    wire_claude_statusline
    # Every step closes its own box. Without this the next header opens inside
    # this one and the whole run reads as one unterminated block.
    success "Statusline ready"
fi

# ── Step 5d: strip repo traces (private mode) ────────────────────────────────
if [ "$STRIP_REPO" -eq 1 ]; then
    info "Stripping repo traces..."
    strip_repo_traces; _strip_rc=$?
    case "$_strip_rc" in
      0)
        substep "${C_DIM}~/dotfiles is now a plain folder — symlinks still resolve${C_RESET}"
        substep "${C_DIM}Re-run any time with: ${C_ACCENT}bash ~/dotfiles/install.sh${C_RESET}"
        substep "${C_DIM}Only pulling new changes needs a clone — nothing else does${C_RESET}"
        # Gated on the specific fact, not on the general run having gone well.
        if [ -e "$DOTFILES_DIR/.git" ]; then
            error ".git is still there — this checkout is still identifiable"
            FAILED+=("private mode")
        else
            success "No git metadata left"
        fi
        ;;
      2)
        error "Could not remove: ${C_RED}${STRIP_SURVIVED[*]}${C_RESET}"
        substep "Remove by hand: ${C_ACCENT}rm -rf ${DOTFILES_DIR}/{${STRIP_SURVIVED[*]// /,}}${C_RESET}"
        substep "${C_DIM}Until then this checkout is still identifiable as a clone${C_RESET}"
        FAILED+=("private mode")
        ;;
      *)
        error "Refused — ${DOTFILES_DIR} does not look like the dotfiles checkout"
        FAILED+=("private mode")
        ;;
    esac
    unset _strip_rc
fi

# ── Step 6: summary ───────────────────────────────────────────────────────────
echo -e "${C_MAIN}${C_BOLD} ${G_TOP} ${G_SUM} Summary${C_RESET}"

if [ "${#INSTALLED[@]}" -gt 0 ]; then
    echo -e "${C_MAIN}${C_BOLD} ${G_MID}  ${C_GREEN}${G_OK} ${C_RESET}Installed (${#INSTALLED[@]}): ${C_ACCENT}${INSTALLED[*]}${C_RESET}"
fi
if [ "${#FAILED[@]}" -gt 0 ]; then
    echo -e "${C_MAIN}${C_BOLD} ${G_MID}  ${C_RED}${G_FAIL} ${C_RESET}Failed (${#FAILED[@]}):    ${C_RED}${FAILED[*]}${C_RESET}"
fi
_elapsed=$(( SECONDS - START_TS ))
echo -e "${C_MAIN}${C_BOLD} ${G_MID}  ${C_DIM}${G_DOT} ${C_RESET}${C_DIM}took $(( _elapsed / 60 ))m $(( _elapsed % 60 ))s${C_RESET}"

if [ "${#INSTALLED[@]}" -gt 0 ]; then
    echo -e "${C_MAIN}${C_BOLD} ${G_END} ${C_GREEN}${G_OK} ${C_RESET}Restart your terminal to apply changes.\n"
else
    echo -e "${C_MAIN}${C_BOLD} ${G_END} ${C_RED}${G_FAIL} ${C_RESET}No configs were installed.\n"
fi

# Exit status reflects the summary: a partial install used to look identical to
# a clean one to anything calling this — including the curl bootstrap, which
# execs us and passes our status straight back.
[ "${#FAILED[@]}" -gt 0 ] && exit 1
exit 0
