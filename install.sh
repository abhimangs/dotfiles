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

DRY_RUN=0
FORCE_GUI=0
RESTORE_BASH=0
for _arg in "$@"; do
    [[ "$_arg" == "--dry-run" ]] && DRY_RUN=1
    [[ "$_arg" == "--gui"     ]] && FORCE_GUI=1
    [[ "$_arg" == "--restore-bash" ]] && RESTORE_BASH=1
done
unset _arg
# linux.sh does `exec bash install.sh "$@"`, but nothing can put arguments there
# when it is reached the documented way: `curl … | bash` gives bash the script on
# stdin, and there is no argv to forward. The environment does survive, so every
# flag has an env equivalent, and that is the only way to pass one through the
# bootstrap:  DOTFILES_GUI=1 curl -fsSL https://abhiman.io/linux.sh | bash
# (Verified against the hosted copy, which is deployed by hand and can lag.)
[ -n "${DOTFILES_DRY_RUN:-}" ] && DRY_RUN=1
[ -n "${DOTFILES_GUI:-}" ]     && FORCE_GUI=1
[ -n "${DOTFILES_RESTORE_BASH:-}" ] && RESTORE_BASH=1

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
GUI_APPS=(brave-beta brave-stable vscode vscode-insiders antigravity-ide antigravity notion obsidian claude-desktop vlc)

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
for _arg in "$@"; do
    [[ "$_arg" == "--ascii" ]]    && USE_GLYPHS=0
    [[ "$_arg" == "--no-color" ]] && USE_COLOR=0
done
unset _arg
[ -n "${DOTFILES_ASCII:-}" ]    && USE_GLYPHS=0
[ -n "${DOTFILES_NO_COLOR:-}" ] && USE_COLOR=0
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
else
    G_TOP='+-' ; G_MID='|'  ; G_END='+-'
    G_ARROW='>'; G_OK='[ok]'; G_FAIL='[!]'
    G_INFO='*' ; G_SUM='='  ; G_RULE='-' ; G_DOT='.' ; G_PICK='x'
fi

# ── Palette ───────────────────────────────────────────────────────────────────
C_MAIN='\033[38;2;202;169;224m'
C_ACCENT='\033[38;2;145;177;240m'
C_DIM='\033[38;2;129;122;150m'
C_GREEN='\033[38;2;166;209;137m'
C_YELLOW='\033[38;2;229;200;144m'
C_RED='\033[38;2;231;130;132m'
C_TEAL='\033[38;2;148;226;213m'
C_BOLD='\033[1m'
C_RESET='\033[0m'

if [ "$USE_COLOR" -eq 0 ]; then
    C_MAIN='' C_ACCENT='' C_DIM='' C_GREEN='' C_YELLOW='' C_RED='' C_TEAL='' C_BOLD='' C_RESET=''
fi

# Full Catppuccin Mocha fzf theme
_FZF_CLR="bg+:#313244,bg:#1e1e2e,fg:#cdd6f4,fg+:#cdd6f4,hl:#f38ba8,hl+:#f38ba8,prompt:#cba6f7,pointer:#f5e0dc,marker:#a6e3a1,border:#585b70,header:#94e2d5,info:#cba6f7,spinner:#f5e0dc,separator:#585b70,gutter:#1e1e2e"
_FZF_COLOR_OPT="--color=${_FZF_CLR}"
[ "$USE_COLOR" -eq 0 ] && _FZF_COLOR_OPT="--no-color"

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

_paru_run_robust() {
    local sync_flag="${1:-}"   # "" | "y" | "yy"
    local pkg="$2"

    # paru is absent when the AUR bootstrap was skipped — as root, where
    # makepkg refuses to build. Fail cleanly here instead of leaking
    # "paru: command not found" from every attempt below.
    if ! command -v paru &>/dev/null; then
        substep "${C_YELLOW}No AUR helper available — ${pkg} needs one${C_RESET}"
        return 1
    fi

    local tmplog; tmplog=$(mktemp -p "$RUN_TMPDIR" paru_XXXXXX.log)

    # ── preflight: stale pacman lock ─────────────────────────────────────────
    if [ -f /var/lib/pacman/db.lck ]; then
        substep "${C_YELLOW}Stale pacman lock — removing${C_RESET}"
        sudo rm -f /var/lib/pacman/db.lck
    fi

    local _flags=( paru -S"${sync_flag}" --needed --noconfirm --removemake --cleanafter )

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
        paru -Sc --noconfirm &>/dev/null 2>&1 || true
        if paru -Syy --needed --noconfirm --removemake --cleanafter "$pkg" >"$tmplog" 2>&1; then
            rm -f "$tmplog"; return 0
        fi
        err=$(<"$tmplog")
    fi

    # ── attempt 5: stale AUR clone ───────────────────────────────────────────
    if grep -qiE 'git.*error|could not.*fetch|unable to.*clone|not a git repo' <<< "$err"; then
        substep "${C_YELLOW}Stale AUR clone — clearing cache and retrying${C_RESET}"
        local _clone="${XDG_CACHE_HOME:-$HOME/.cache}/paru/clone/${pkg}"
        [ -d "$_clone" ] && rm -rf "$_clone"
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

paru_install()   { _paru_run_robust ""  "$1"; }
paru_install_y() { _paru_run_robust "y" "$1"; }

# Official repos first, AUR only as a fallback. Repo packages are signed,
# prebuilt and install in seconds, where the AUR builds from source — and some
# names now exist in both places (opencode, thefuck), so asking paru blindly
# could pick the slower path. 'pacman -Si' answers "is this in a sync repo?"
# without touching the network, so an AUR-only name costs nothing here.
arch_install() {
    local pkg="$1"
    if pacman -Si "$pkg" &>/dev/null; then
        pacman_install "$pkg" && return 0
    fi
    command -v paru &>/dev/null || return 1
    paru_install "$pkg"
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
# Every vendor repo written by an ensure_*_deb function below. A stale one of
# these breaks apt-get update for the whole machine exactly as a dead PPA does
# — and used to do it permanently, because only PPAs were ever cleaned up.
APT_OWN_SOURCES='gierens|vscode|vscode-insiders|claude-desktop|brave-browser-.*'
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

    local list=/etc/apt/sources.list.d/zz-dotfiles-fallback.list
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

# ── ghostty (Debian/Ubuntu) ───────────────────────────────────────────────────
# mkasberg/ghostty-ubuntu's installer self-detects Ubuntu (PPA) vs Debian
# Trixie/Forky (signed repo) and grabs the right .deb either way.
ensure_ghostty_deb() {
    command -v ghostty &>/dev/null && return 0
    ensure_apt_deps
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/mkasberg/ghostty-ubuntu/HEAD/install.sh)" &>/dev/null 2>&1
    command -v ghostty &>/dev/null
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
        local apat url
        # Upstream names 32-bit ARM builds armv7l/armv6l, never Debian's
        # armhf/armel, so those need translating or nothing matches.
        case "$(deb_arch)" in
            amd64) apat='amd64|x86_64' ;;
            arm64) apat='arm64|aarch64' ;;
            armhf) apat='armv7l' ;;
            armel) apat='armv6l' ;;
            *)     apat="$(deb_arch)" ;;
        esac
        url=$(github_latest_asset_url "fastfetch-cli/fastfetch" "linux-(${apat})\.deb$")
        if [ -n "$url" ]; then
            local tmp; tmp=$(mktemp -p "$RUN_TMPDIR" fastfetch_XXXXXX.deb)
            curl -fsSL "$url" -o "$tmp" 2>/dev/null && apt_get install -y "$tmp" &>/dev/null 2>&1
            rm -f "$tmp"
        fi
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
        local url; url=$(github_latest_asset_url "Ulauncher/Ulauncher" '_all\.deb$')
        if [ -n "$url" ]; then
            local tmp; tmp=$(mktemp -p "$RUN_TMPDIR" ulauncher_XXXXXX.deb)
            curl -fsSL "$url" -o "$tmp" 2>/dev/null && apt_get install -y "$tmp" &>/dev/null 2>&1
            rm -f "$tmp"
        fi
    fi
    apt_pkg_installed ulauncher
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
ensure_vscode_deb() {
    apt_pkg_installed code && return 0
    ensure_apt_deps
    apt_install_keyring https://packages.microsoft.com/keys/microsoft.asc \
        /etc/apt/keyrings/packages.microsoft.gpg || return 1
    echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
        | sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
    APT_UPDATED=0
    apt_update_once
    apt_install code
    apt_pkg_installed code
}

# code-insiders ships from the same Microsoft repo/key as stable code, just a
# different package — so this only needs to add that repo when vscode-insiders
# is picked on its own, without ensure_vscode_deb having done it already.
ensure_vscode_insiders_deb() {
    apt_pkg_installed code-insiders && return 0
    ensure_apt_deps
    if [ ! -s /etc/apt/keyrings/packages.microsoft.gpg ]; then
        apt_install_keyring https://packages.microsoft.com/keys/microsoft.asc \
            /etc/apt/keyrings/packages.microsoft.gpg || return 1
    fi
    echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
        | sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
    APT_UPDATED=0
    apt_update_once
    apt_install code-insiders
    apt_pkg_installed code-insiders
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
        apt_pkg_installed "$pkg" && sudo apt-get remove -y "$pkg" &>/dev/null 2>&1
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
    sudo usermod -aG docker "$USER" &>/dev/null || true
    substep "${C_DIM}${USER} added to the docker group — takes effect on your next login${C_RESET}"

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

# ── Fonts (Debian/Ubuntu — neither is packaged in apt) ───────────────────────
FONT_DIR_DEB="$HOME/.local/share/fonts/JetBrainsMono"
MAPLE_FONT_DIR_DEB="$HOME/.local/share/fonts/MapleMono"

font_dir_has_ttf() {
    [ -d "$1" ] && find "$1" -name '*.ttf' -print -quit 2>/dev/null | grep -q .
}

font_installed_deb()       { font_dir_has_ttf "$FONT_DIR_DEB"; }
maple_font_installed_deb() { font_dir_has_ttf "$MAPLE_FONT_DIR_DEB"; }

# Fetch a font zip from a GitHub release into ~/.local/share/fonts/<dir>.
# fontconfig is not guaranteed on a minimal/server image — without fc-cache the
# fonts land on disk but nothing can see them, so make sure it is there first.
install_font_zip() {
    local url="$1" dir="$2"
    ensure_apt_deps
    command -v unzip    &>/dev/null || apt_install unzip
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

# True when ~/.bashrc is a stow symlink into the checkout. Writing through one
# edits the repo itself, which would both dirty the working tree and ship the
# edit to everyone who clones it.
bashrc_is_repo_link() {
    local rc="${1:-$HOME/.bashrc}" t d
    [ -L "$rc" ] || return 1
    t="$(readlink -f "$rc" 2>/dev/null)" || return 1
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
    bashrc_is_repo_link "$rc" && return 0

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
    bashrc_is_repo_link "$dst" && return 2
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
    if bashrc_is_repo_link "$rc"; then
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
PRIVATE_DELETE=(.git .github .gitignore .gitattributes
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

    if [ -L "$target" ]; then
        # Dir-level symlink (old wrong stow) — always remove
        rm "$target"

    elif [ -d "$target" ]; then
        # Only real files (not symlinks, not dirs) need handling — stow -D
        # removes our own symlinks; foreign symlinks coexist or cause a conflict.
        if find "$target" -mindepth 1 -maxdepth 3 \
                ! -type l ! -type d 2>/dev/null | grep -q .; then
            if [[ "$BACKUP_MODE" == "delete" ]]; then
                rm -rf "$target"
                substep "Deleted ${C_ACCENT}${name}${C_RESET}"
            else
                if [ -e "$bak" ]; then
                    [ -e "$oldbak" ] && rm -rf "$oldbak"
                    mv "$bak" "$oldbak"
                fi
                mv "$target" "$bak"
                substep "Backed up ${C_ACCENT}${name}${C_RESET} → ${C_DIM}${name}.bak${C_RESET}"
            fi
        fi
        # Only symlinks / empty dir: nothing to do — stow_to -D cleans ours
    fi

    # Explicitly create the target dir before stowing.
    # Needed when: (a) it never existed, (b) it was just moved to .bak above.
    mkdir -p "$target"
    stow_to "$target" "$name"
}

# ── Backup a single file or dir (for home/ and scripts/ → ~) ─────────────────
backup_file() {
    local target="$1"
    # Same reasoning as stow_config: delete mode rm -rf's this path.
    [ -n "$target" ] || return 1
    local bak="${target}.bak"
    local oldbak="${target}.old.bak"
    local name; name="$(basename "$target")"

    if [ -L "$target" ]; then
        rm "$target"
    elif [ -e "$target" ]; then
        if [[ "$BACKUP_MODE" == "delete" ]]; then
            rm -rf "$target"
            substep "Deleted ${C_ACCENT}${name}${C_RESET}"
        else
            if [ -e "$bak" ]; then
                [ -e "$oldbak" ] && rm -rf "$oldbak"
                mv "$bak" "$oldbak"
                substep "Rotated ${C_DIM}${name}.bak → ${name}.old.bak${C_RESET}"
            fi
            mv "$target" "$bak"
            substep "Backed up ${C_ACCENT}${name}${C_RESET} → ${C_DIM}${name}.bak${C_RESET}"
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
DEP_PKG[thefuck]="thefuck"
DEP_PKG[lazygit]="lazygit"
DEP_PKG[btop]="btop"
DEP_PKG[tree]="tree"
DEPS_LIST=(bat eza fd zoxide thefuck lazygit btop tree)

# Debian/Ubuntu apt package-name overrides (only where it differs from Arch)
declare -A DEP_PKG_DEB
DEP_PKG_DEB[fd]="fd-find"

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
APPS_LIST=(brave-beta brave-stable vscode vscode-insiders antigravity-ide claude-code antigravity antigravity-cli codex-cli opencode kimi-code muse notion obsidian vlc flatpak docker)
if [[ "$DISTRO" == "debian" ]]; then
    # Notion (no official Linux build), Obsidian (only a vendor .deb/AppImage on
    # apt, no repo) and the Antigravity desktop/IDE (upstream packaging still a
    # moving target on apt) are Arch-only for now.
    # Claude Desktop is the inverse case: an official Anthropic apt repo exists,
    # but there is no Arch package — so it is Debian/Ubuntu-only.
    APPS_LIST=(brave-beta brave-stable vscode vscode-insiders claude-desktop claude-code antigravity-cli codex-cli opencode kimi-code muse vlc flatpak docker)
fi
# No display server → drop everything that needs one, keeping the CLI tools
[ "$IS_HEADLESS" -eq 1 ] && strip_items APPS_LIST "${GUI_APPS[@]}"

declare -A APP_LABEL APP_TYPE APP_PKG APP_BIN

APP_LABEL[brave-beta]="Brave Origin Beta"
APP_LABEL[brave-stable]="Brave Origin Stable"
APP_LABEL[vscode]="Visual Studio Code"
APP_LABEL[vscode-insiders]="VS Code Insiders"
APP_LABEL[antigravity-ide]="Antigravity IDE"
APP_LABEL[claude-code]="Claude Code CLI"
APP_LABEL[antigravity]="Antigravity 2.0"
APP_LABEL[antigravity-cli]="Antigravity CLI"
APP_LABEL[codex-cli]="Codex CLI"
APP_LABEL[opencode]="OpenCode"
APP_LABEL[kimi-code]="Kimi Code CLI"
APP_LABEL[muse]="Muse"
APP_LABEL[notion]="Notion"
APP_LABEL[obsidian]="Obsidian"
APP_LABEL[claude-desktop]="Claude Desktop"
APP_LABEL[vlc]="VLC"
APP_LABEL[flatpak]="Flatpak"
APP_LABEL[docker]="Docker + Compose"

# paru-y forces a db refresh first (Brave bumps versions faster than a stale
# db notices); paru and pacman both resolve through arch_install — repo first,
# AUR second — so the distinction is only about which one is expected to hit.
APP_TYPE[brave-beta]="paru-y"
APP_TYPE[brave-stable]="paru-y"
APP_TYPE[vscode]="paru"
APP_TYPE[vscode-insiders]="paru"
APP_TYPE[antigravity-ide]="paru"
APP_TYPE[claude-code]="curl"
APP_TYPE[antigravity]="paru"
APP_TYPE[antigravity-cli]="curl"
APP_TYPE[codex-cli]="curl"
APP_TYPE[opencode]="paru"
APP_TYPE[kimi-code]="curl"
APP_TYPE[muse]="curl"
APP_TYPE[notion]="paru"
APP_TYPE[obsidian]="pacman"
APP_TYPE[vlc]="pacman"
APP_TYPE[flatpak]="pacman"
APP_TYPE[docker]="pacman"

APP_PKG[brave-beta]="brave-origin-beta-bin"
APP_PKG[brave-stable]="brave-origin-bin"
APP_PKG[vscode]="visual-studio-code-bin"
APP_PKG[vscode-insiders]="visual-studio-code-insiders-bin"
APP_PKG[antigravity-ide]="antigravity-ide"
APP_PKG[antigravity]="antigravity"
APP_PKG[opencode]="opencode"
APP_PKG[notion]="notion-app-electron"
APP_PKG[obsidian]="obsidian"
APP_PKG[vlc]="vlc"
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
CURL_APP_PATH="$HOME/.local/bin:$HOME/.opencode/bin:$HOME/.kimi-code/bin"

declare -A APP_CURL_ARGS APP_CURL_ENV
APP_CURL_ARGS[opencode]="--no-modify-path"
APP_CURL_ENV[kimi-code]="KIMI_NO_MODIFY_PATH=1"
APP_CURL_ENV[muse]="MUSE_NO_MODIFY_PATH=1"

# These CLIs install into their own bin dirs, which are not necessarily on the
# PATH of whatever shell is running this script — search them explicitly, or an
# already-installed tool looks missing and gets reinstalled every run.
curl_app_installed() {
    [ -n "$1" ] || return 1
    PATH="${CURL_APP_PATH}:$PATH" command -v "$1" &>/dev/null
}

APP_BIN[claude-code]="claude"
APP_BIN[codex-cli]="codex"
APP_BIN[opencode]="opencode"
APP_BIN[kimi-code]="kimi"
APP_BIN[muse]="muse"

# Debian/Ubuntu overrides — package names and install mechanism differ
declare -A APP_PKG_DEB
APP_PKG_DEB[brave-stable]="brave-origin"
APP_PKG_DEB[brave-beta]="brave-origin-beta"
APP_PKG_DEB[vscode]="code"
APP_PKG_DEB[vscode-insiders]="code-insiders"
APP_PKG_DEB[claude-desktop]="claude-desktop"
APP_PKG_DEB[docker]="docker-ce"

declare -A APP_TYPE_DEB
APP_TYPE_DEB[brave-stable]="brave"
APP_TYPE_DEB[brave-beta]="brave"
APP_TYPE_DEB[vscode]="vscode"
APP_TYPE_DEB[vscode-insiders]="vscode-insiders"
APP_TYPE_DEB[claude-code]="curl"
APP_TYPE_DEB[antigravity-cli]="curl"
APP_TYPE_DEB[codex-cli]="curl"
APP_TYPE_DEB[opencode]="curl"
APP_TYPE_DEB[kimi-code]="curl"
APP_TYPE_DEB[muse]="curl"
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
if [[ "$DISTRO" == "arch" ]]; then
    CONFIG_DESC[ulauncher]="app launcher              ${G_DOT}  AUR"
else
    CONFIG_DESC[ulauncher]="app launcher              ${G_DOT}  PPA/deb"
fi

declare -A DEP_DESC
DEP_DESC[bat]="cat with syntax highlighting  ${G_DOT}  Catppuccin theme"
DEP_DESC[eza]="modern ls  →  ls  ll  lt  la aliases"
DEP_DESC[fd]="fast find replacement  →  fzf integration"
DEP_DESC[zoxide]="smart cd  →  z command"
DEP_DESC[thefuck]="corrects last command  →  fuck alias"
DEP_DESC[lazygit]="git TUI  →  lg alias"
DEP_DESC[btop]="resource monitor  ${G_DOT}  Catppuccin theme"
DEP_DESC[tree]="directory tree listing"

# ── Pre-install plan ──────────────────────────────────────────────────────────
show_plan() {
    local cfgs=("$@")
    local wallpaper_stowed=0
    # cfg and step are the loop variables below; every other local in this
    # function was declared and these two were missed, so they leaked out.
    local cfg step

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
                  "$HOME"/.gitconfig.old.bak "$HOME"/.config/*.old.bak \
                  "$HOME"/.config/*/../*.old.bak; do
            [ -e "$_o" ] || continue
            echo -e "${C_MAIN}${C_BOLD} ${G_MID}  ${C_YELLOW}${G_DOT}${C_RESET} ${C_DIM}two backups are kept — rotating discards the current .old.bak${C_RESET}"
            break
        done
    fi

    for cfg in "${cfgs[@]}"; do
        local pkg="${PKG_MAP[$cfg]}"
        local steps=()
        local target bak

        if pkg_installed "$pkg"; then
            steps+=("${C_DIM}$pkg already installed${C_RESET}")
        else
            steps+=("${C_YELLOW}install $pkg${C_RESET}")
        fi

        case "$cfg" in
          ghostty|kitty)
            target="$HOME/.config/$cfg"; bak="${target}.bak"
            if [ -d "$target" ] && find "$target" -mindepth 1 -maxdepth 3 \
                    ! -type l ! -type d 2>/dev/null | grep -q .; then
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
            if [ "$wallpaper_stowed" -eq 0 ]; then
                local wp="$HOME/.config/wallpapers/Serene Japanese Landscape with Red Sun.jpg"
                if [ ! -f "$wp" ]; then
                    steps+=("${C_GREEN}stow wallpapers${C_RESET}")
                else
                    steps+=("${C_DIM}wallpaper already in place${C_RESET}")
                fi
                wallpaper_stowed=1
            fi
            ;;
          fastfetch|rofi)
            target="$HOME/.config/$cfg"; bak="${target}.bak"
            if [ -d "$target" ] && find "$target" -mindepth 1 -maxdepth 3 \
                    ! -type l ! -type d 2>/dev/null | grep -q .; then
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
            [[ "$cfg" == "rofi" ]] && steps+=("${C_DIM}launch: rofi -show drun${C_RESET}")
            ;;
          bash)
            local brc="$HOME/.bashrc"
            [ -e "$PRISTINE_BASHRC" ] || [ -e "$PRISTINE_ABSENT" ] \
                || steps+=("${C_YELLOW}keep a pristine copy${C_RESET} ${C_DIM}of .bashrc (once, kept for --restore-bash)${C_RESET}")
            if [ -L "$brc" ]; then
                steps+=("${C_ACCENT}re-stow .bashrc${C_RESET} ${C_DIM}(unlink + relink)${C_RESET}")
            elif [ -e "$brc" ]; then
                if [[ "$BACKUP_MODE" == "delete" ]]; then
                    steps+=("${C_RED}delete${C_RESET} ${C_DIM}.bashrc${C_RESET} ${C_DIM}(pristine copy still kept)${C_RESET}")
                else
                    [ -e "${brc}.bak" ] && steps+=("${C_YELLOW}rotate${C_RESET} ${C_DIM}.bashrc.bak → .bashrc.old.bak${C_RESET}")
                    steps+=("${C_YELLOW}backup${C_RESET} ${C_DIM}.bashrc → .bashrc.bak${C_RESET}")
                fi
                steps+=("${C_GREEN}stow ~/.bashrc${C_RESET}")
            else
                steps+=("${C_GREEN}stow ~/.bashrc${C_RESET} ${C_DIM}(fresh)${C_RESET}")
            fi
            ;;
          zsh)
            local rc="$HOME/.zshrc"
            if [ -L "$rc" ]; then
                steps+=("${C_ACCENT}re-stow .zshrc${C_RESET} ${C_DIM}(unlink + relink)${C_RESET}")
            elif [ -e "$rc" ]; then
                if [[ "$BACKUP_MODE" == "delete" ]]; then
                    steps+=("${C_RED}delete${C_RESET} ${C_DIM}.zshrc${C_RESET}")
                else
                    [ -e "${rc}.bak" ] && steps+=("${C_YELLOW}rotate${C_RESET} ${C_DIM}.zshrc.bak → .zshrc.old.bak${C_RESET}")
                    steps+=("${C_YELLOW}backup${C_RESET} ${C_DIM}.zshrc → .zshrc.bak${C_RESET}")
                fi
                steps+=("${C_GREEN}stow ~/.zshrc${C_RESET}")
            else
                steps+=("${C_GREEN}stow ~/.zshrc${C_RESET} ${C_DIM}(fresh)${C_RESET}")
            fi
            ;;
          protonvpn)
            local script="$HOME/scripts/pvpn/pvpn.zsh"
            if [ -e "$script" ] && [ ! -L "$script" ]; then
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
            _pdf="$(readlink -f "$DOTFILES_DIR" 2>/dev/null || printf '%s' "$DOTFILES_DIR")"
            if [ -L "$target" ] && [[ "$(readlink -f "$target" 2>/dev/null)" == "$_pdf"/* ]]; then
                steps+=("${C_ACCENT}re-stow config${C_RESET} ${C_DIM}(unlink + relink)${C_RESET}")
            elif [ -e "$target" ] || [ -L "$target" ]; then
                steps+=("${C_DIM}keep your existing starship.toml — ours not installed${C_RESET}")
            else
                steps+=("${C_GREEN}stow ~/.config/starship.toml${C_RESET} ${C_DIM}(fresh)${C_RESET}")
            fi
            unset _pdf
            ;;
          ulauncher)
            target="$HOME/.config/$cfg"; bak="${target}.bak"
            if [ -L "$target" ]; then
                steps+=("${C_ACCENT}re-stow config${C_RESET} ${C_DIM}(unlink + relink)${C_RESET}")
            elif [ -e "$target" ]; then
                if [[ "$BACKUP_MODE" == "delete" ]]; then
                    steps+=("${C_RED}delete${C_RESET} ${C_DIM}${cfg}${C_RESET}")
                else
                    [ -e "$bak" ] && steps+=("${C_YELLOW}backup${C_RESET} ${C_DIM}$cfg.bak → $cfg.old.bak${C_RESET}")
                    steps+=("${C_YELLOW}backup${C_RESET} ${C_DIM}$cfg → $cfg.bak${C_RESET}")
                fi
                steps+=("${C_GREEN}stow ~/.config/${cfg}${C_RESET}")
            else
                steps+=("${C_GREEN}stow ~/.config/${cfg}${C_RESET} ${C_DIM}(fresh)${C_RESET}")
            fi
            if [ ! -f "$HOME/.config/autostart/ulauncher.desktop" ]; then
                steps+=("${C_GREEN}enable autostart${C_RESET}")
            else
                steps+=("${C_DIM}autostart already configured${C_RESET}")
            fi
            ;;
          git)
            local gc="$HOME/.gitconfig"
            if [ -L "$gc" ]; then
                steps+=("${C_ACCENT}re-stow .gitconfig${C_RESET} ${C_DIM}(unlink + relink)${C_RESET}")
            elif [ -e "$gc" ]; then
                if [[ "$BACKUP_MODE" == "delete" ]]; then
                    steps+=("${C_RED}delete${C_RESET} ${C_DIM}.gitconfig${C_RESET}")
                else
                    [ -e "${gc}.bak" ] && steps+=("${C_YELLOW}rotate${C_RESET} ${C_DIM}.gitconfig.bak → .gitconfig.old.bak${C_RESET}")
                    steps+=("${C_YELLOW}backup${C_RESET} ${C_DIM}.gitconfig → .gitconfig.bak${C_RESET}")
                fi
                steps+=("${C_GREEN}stow ~/.gitconfig${C_RESET}")
            else
                steps+=("${C_GREEN}stow ~/.gitconfig${C_RESET} ${C_DIM}(fresh)${C_RESET}")
            fi
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
    if [ "$IS_WSL" -eq 1 ]; then
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
        for _d in "${DEPS[@]}"; do
            if pkg_installed "$(dep_pkg_name "$_d")"; then
                echo -e "${C_MAIN}${C_BOLD} ${G_MID}    ${C_DIM}${G_DOT}${C_RESET} ${C_DIM}${_d} already installed${C_RESET}"
            else
                echo -e "${C_MAIN}${C_BOLD} ${G_MID}    ${C_DIM}${G_DOT}${C_RESET} ${C_YELLOW}install ${_d}${C_RESET}"
            fi
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
    bashrc_is_repo_link "$rc" && stowed_bash=1
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

    local zsh_action=""
    if [ -L "$HOME/.zshrc" ]; then
        zsh_action="unstow"
        steps+=("${C_YELLOW}unstow${C_RESET} ${C_DIM}~/.zshrc${C_RESET}")
        [ -e "$HOME/.zshrc.bak" ] && steps+=("${C_GREEN}restore${C_RESET} ${C_DIM}~/.zshrc.bak → ~/.zshrc${C_RESET}")
    fi

    local st="$HOME/.config/starship.toml" st_action=""
    local _rdf; _rdf="$(readlink -f "$DOTFILES_DIR" 2>/dev/null || printf '%s' "$DOTFILES_DIR")"
    if [ -L "$st" ] && [[ "$(readlink -f "$st" 2>/dev/null)" == "$_rdf"/* ]]; then
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

# --restore-bash short-circuits everything below: no privacy prompt, no backup
# mode, no menus, no install loop. It needs sudo for chsh, and sudo -v is only
# reached further down, so ask here.
if [ "$RESTORE_BASH" -eq 1 ]; then
    if [ "$(id -u)" -ne 0 ] && command -v sudo &>/dev/null && [ "$DRY_RUN" -eq 0 ]; then
        sudo -v || true
    fi
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

_pv_cur=0
_pv_row() {
    local mark="  "
    [ "$1" -eq "$2" ] && mark="$3${G_ARROW}${C_RESET} "
    printf " ${C_MAIN}${C_BOLD}${G_MID}${C_RESET}  %b%b %-8s ${C_DIM}${G_DOT}  %-42s${C_RESET}\n" \
        "$mark" "$4" "$5" "$6"
}
_pv_draw() {
    local m0="( )" m1="( )"
    [ "$STRIP_REPO" -eq 0 ] && m0="(${G_PICK})" || m1="(${G_PICK})"
    _pv_row 0 "$1" "$C_GREEN" "$m0" "keep"    "leave it as a normal checkout"
    _pv_row 1 "$1" "$C_RED"   "$m1" "private" "remove and scrub everything above"
}
_pv_draw $_pv_cur

while true; do
    printf "\033[2A"
    IFS= read -n 1 -rs _pv_key <"$TTY_IN"
    case "$_pv_key" in
        $'\n'|$'\r'|'') _pv_draw $_pv_cur; break ;;
        ' ')     STRIP_REPO=$_pv_cur; _pv_draw $_pv_cur ;;
        'k'|'K') STRIP_REPO=0; _pv_cur=0; _pv_draw $_pv_cur ;;
        'p'|'P') STRIP_REPO=1; _pv_cur=1; _pv_draw $_pv_cur ;;
        $'\033')
            IFS= read -n 2 -rs -t 0.1 _pv_esc <"$TTY_IN" || true
            case "$_pv_esc" in
                '[A'|'[D') _pv_cur=0 ;;
                '[B'|'[C') _pv_cur=1 ;;
            esac
            STRIP_REPO=$_pv_cur
            _pv_draw $_pv_cur ;;
        *) _pv_draw $_pv_cur ;;
    esac
done

if [ "$STRIP_REPO" -eq 1 ]; then
    echo -e " ${C_MAIN}${C_BOLD}${G_END} ${C_RED}${G_OK}${C_RESET} private — traces removed at the end of the run\n"
else
    echo -e " ${C_MAIN}${C_BOLD}${G_END} ${C_GREEN}${G_OK}${C_RESET} keep\n"
fi
unset -f _pv_draw _pv_row
unset _pv_cur _pv_key _pv_esc

# ── Existing configs: backup or delete ───────────────────────────────────────
BACKUP_MODE="backup"
_bm_sel=0

_bm_draw() {
    local m0="( )" m1="( )"
    [ "$1" -eq 0 ] && m0="(${G_PICK})" || m1="(${G_PICK})"
    printf " ${C_MAIN}${C_BOLD}${G_MID}${C_RESET}  %b%b %-8s ${C_DIM}${G_DOT}  %-42s${C_RESET}\n" \
        "$( [ "$1" -eq 0 ] && printf '%b' "${C_GREEN}${G_ARROW}${C_RESET} " || printf '  ')" \
        "$m0" "backup" "move to .bak, safe and reversible"
    printf " ${C_MAIN}${C_BOLD}${G_MID}${C_RESET}  %b%b %-8s ${C_DIM}${G_DOT}  %-42s${C_RESET}\n" \
        "$( [ "$1" -eq 1 ] && printf '%b' "${C_RED}${G_ARROW}${C_RESET} " || printf '  ')" \
        "$m1" "delete" "wipe cleanly, no backup kept"
}

echo -e "${C_MAIN}${C_BOLD} ${G_TOP} ${G_INFO} Existing configs  ${C_DIM}↑↓ navigate  ${G_DOT}  Enter confirm${C_RESET}"
_bm_draw $_bm_sel

while true; do
    printf "\033[2A"
    IFS= read -n 1 -rs _bm_key <"$TTY_IN"
    case "$_bm_key" in
        $'\n'|$'\r'|'') _bm_draw $_bm_sel; break ;;
        'b'|'B') _bm_sel=0; _bm_draw $_bm_sel ;;
        'd'|'D') _bm_sel=1; _bm_draw $_bm_sel ;;
        $'\033')
            IFS= read -n 2 -rs -t 0.1 _bm_esc <"$TTY_IN" || true
            case "$_bm_esc" in
                '[A'|'[D') _bm_sel=0 ;;
                '[B'|'[C') _bm_sel=1 ;;
            esac
            _bm_draw $_bm_sel ;;
        *) _bm_draw $_bm_sel ;;
    esac
done

if [ "$_bm_sel" -eq 1 ]; then
    BACKUP_MODE="delete"
    echo -e " ${C_MAIN}${C_BOLD}${G_END} ${C_RED}${G_OK}${C_RESET} delete\n"
else
    echo -e " ${C_MAIN}${C_BOLD}${G_END} ${C_GREEN}${G_OK}${C_RESET} backup\n"
fi
unset -f _bm_draw
unset _bm_sel _bm_key _bm_esc

# ── Privileges ────────────────────────────────────────────────────────────────
# VPS and container images normally drop you straight into root, and plenty of
# them ship without sudo at all — 'sudo -v' died with "command not found" before
# the installer did anything. As root, run privileged commands directly. The
# passthrough goes through env so that 'sudo VAR=value cmd' (which sudo parses
# itself) keeps working unchanged at every call site.
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

# ── Step 1: AUR helper (Arch) / apt bootstrap (Debian/Ubuntu) ───────────────
if [[ "$DISTRO" == "arch" ]]; then
    info "Checking AUR helper..."
    if command -v paru &>/dev/null; then
        substep "paru already installed"
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
        substep "paru not found — installing..."
        substep "Checking internet connection..."
        if ! curl -fsSL --connect-timeout 5 --max-time 8 https://archlinux.org -o /dev/null 2>/dev/null; then
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
        substep "Cloning paru from AUR..."
        rm -rf "$_paru_build"
        if ! git clone https://aur.archlinux.org/paru.git "$_paru_build" &>/dev/null 2>&1; then
            error "Failed to clone paru. Check your internet connection."
            exit 1
        fi

        echo -e "${C_MAIN}${C_BOLD} ${G_MID}  ${C_DIM}❯ ${C_YELLOW}Building paru — output shown below (takes 2–4 min)${C_RESET}\n"
        if ! (cd "$_paru_build" && makepkg -si --noconfirm); then
            error "paru build failed."
            exit 1
        fi
        echo ""

        rm -rf "$_paru_build"
        unset _paru_build

        if ! command -v paru &>/dev/null; then
            error "paru installation failed — binary not found after build."
            exit 1
        fi
        success "paru installed"
        fi
    fi
else
    info "Preparing apt..."
    substep "Checking internet connection..."
    if ! curl -fsSL --connect-timeout 5 --max-time 8 https://deb.debian.org -o /dev/null 2>/dev/null \
        && ! curl -fsSL --connect-timeout 5 --max-time 8 https://archive.ubuntu.com -o /dev/null 2>/dev/null; then
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

# ── Step 3: multi-select menu ─────────────────────────────────────────────────
info "Select configs to install..."
CONFIGS=(fastfetch ghostty kitty bash zsh protonvpn starship rofi ulauncher git)
if [[ "$DISTRO" == "debian" ]]; then
    # Arch ships rofi 2.0 (Wayland support merged upstream); Debian/Ubuntu are
    # still on the 1.7.x X11-only build, so rofi stays Arch-only.
    CONFIGS=(fastfetch ghostty kitty bash zsh protonvpn starship ulauncher git)
fi
[ "$IS_HEADLESS" -eq 1 ] && strip_items CONFIGS "${GUI_CONFIGS[@]}"
declare -a SELECTED=()

if command -v fzf &>/dev/null; then
    echo ""
    _cfg_lines=()
    for _c in "${CONFIGS[@]}"; do
        _cfg_lines+=("$(printf '%-11s  %s  %s' "$_c" "$G_DOT" "${CONFIG_DESC[$_c]}")")
    done
    mapfile -t SELECTED < <(
        printf '%s\n' "${_cfg_lines[@]}" | \
        fzf --multi \
            --height=40% \
            --min-height=12 \
            --reverse \
            --border=rounded \
            --prompt="  " \
            --pointer="$G_ARROW" \
            --marker="$G_OK" \
            ${_FZF_COLOR_OPT} \
            --header=$'Enter=select  Ctrl-J=confirm  Ctrl-A=all\n' \
            --bind='enter:toggle+down' \
            --bind='ctrl-j:accept' \
            --bind='ctrl-a:select-all' | \
        awk '{print $1}'
    )
    unset _cfg_lines _c
    echo ""
else
    substep "${C_DIM}fzf unavailable — using basic menu${C_RESET}"
    echo ""
    attempts=0
    while true; do
        for _i in "${!CONFIGS[@]}"; do
            _c="${CONFIGS[$_i]}"
            printf "${C_MAIN}${C_BOLD} ${G_MID}  ${C_ACCENT}%2d ${C_DIM}${G_ARROW} ${C_RESET}%-11s ${C_DIM}${G_DOT}  %s${C_RESET}\n" "$((_i+1))" "$_c" "${CONFIG_DESC[$_c]}"
        done
        echo -e "${C_MAIN}${C_BOLD} ${G_MID}  ${C_ACCENT} a ${C_DIM}${G_ARROW} ${C_RESET}All${C_RESET}"
        echo -ne "${C_MAIN}${C_BOLD} ${G_END} ${C_YELLOW}Choice (e.g. 1 4 or a): ${C_RESET}"
        read -r RAW <"$TTY_IN"
    echo ""

        if [[ "$RAW" == "a" || "$RAW" == "A" ]]; then
            SELECTED=("${CONFIGS[@]}")
            break
        fi

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
fi

if [ "${#SELECTED[@]}" -eq 0 ]; then
    error "Nothing selected. Exiting."
    exit 0
fi

# .zshrc ends with `eval "$(starship init zsh)"` — the entire prompt is
# starship. Picking zsh without it produced a bare "hostname#", which looks
# like the install failed. It is a hard dependency, so pull it in.
if printf '%s\n' "${SELECTED[@]}" | grep -qx zsh \
   && ! printf '%s\n' "${SELECTED[@]}" | grep -qx starship; then
    SELECTED+=(starship)
    substep "${C_DIM}zsh draws its prompt with starship — adding starship${C_RESET}"
fi
success "Configs: ${C_ACCENT}${SELECTED[*]}${C_RESET}"

# ── Dep tools sub-menu (always shown) ────────────────────────────────────────
DEPS=()
info "Optional dep tools..."
echo ""

if command -v fzf &>/dev/null; then
    _dep_lines=()
    for _dd in "${DEPS_LIST[@]}"; do
        _dep_lines+=("$(printf '%-10s  %s  %s' "$_dd" "$G_DOT" "${DEP_DESC[$_dd]}")")
    done
    mapfile -t DEPS < <(
        printf '%s\n' "${_dep_lines[@]}" | \
        fzf --multi \
            --height=40% \
            --min-height=12 \
            --reverse \
            --border=rounded \
            --prompt="  " \
            --pointer="$G_ARROW" \
            --marker="$G_OK" \
            ${_FZF_COLOR_OPT} \
            --header=$'Enter=select  Ctrl-J=confirm  Ctrl-A=all  Esc=skip\n' \
            --bind='enter:toggle+down' \
            --bind='ctrl-j:accept' \
            --bind='ctrl-a:select-all' | \
        awk '{print $1}'
    )
    unset _dep_lines _dd
else
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
fi

# Everything .zshrc reaches for is guarded by `command -v`, so without these the
# shell comes up looking half-installed: no ls/cat/z/lg aliases, no fzf key
# bindings. They are part of the shell, not optional extras — pull them all in.
if printf '%s\n' "${SELECTED[@]}" | grep -qx zsh; then
    _dep_added=()
    for _d in "${DEPS_LIST[@]}"; do
        printf '%s\n' "${DEPS[@]}" | grep -qx "$_d" && continue
        DEPS+=("$_d")
        _dep_added+=("$_d")
    done
    if [ "${#_dep_added[@]}" -gt 0 ]; then
        substep "${C_DIM}zsh needs these for its aliases — adding ${_dep_added[*]}${C_RESET}"
    fi
    unset _dep_added _d
fi

if [ "${#DEPS[@]}" -gt 0 ]; then
    success "Dep tools: ${C_ACCENT}${DEPS[*]}${C_RESET}"
else
    success "${C_DIM}No dep tools selected${C_RESET}"
fi

# ── App menu ─────────────────────────────────────────────────────────────────
APPS=()
info "Optional applications..."
echo ""

# Build tab-delimited lines: key<TAB>display — fzf shows only the display column
_app_lines=()
for _k in "${APPS_LIST[@]}"; do
    _rt="$(app_type_resolved "$_k")"
    case "$_rt" in
        paru-y|paru) _tl="paru"   ;;
        pacman)      _tl="pacman" ;;
        curl)        _tl="curl"   ;;
        apt|brave|vscode|claude-desktop|docker) _tl="apt" ;;
        *)           _tl="$_rt" ;;
    esac
    _app_lines+=("${_k}"$'\t'"$(printf '%-22s  %s  %s' "${APP_LABEL[$_k]}" "$G_DOT" "$_tl")")
done
unset _rt

if command -v fzf &>/dev/null; then
    mapfile -t APPS < <(
        printf '%s\n' "${_app_lines[@]}" | \
        fzf --multi \
            --delimiter=$'\t' \
            --with-nth=2 \
            --height=45% \
            --min-height=14 \
            --reverse \
            --border=rounded \
            --prompt="  " \
            --pointer="$G_ARROW" \
            --marker="$G_OK" \
            ${_FZF_COLOR_OPT} \
            --header=$'Enter=select  Ctrl-J=confirm  Ctrl-A=all  Esc=skip\n' \
            --bind='enter:toggle+down' \
            --bind='ctrl-j:accept' \
            --bind='ctrl-a:select-all' | \
        awk -F'\t' '{print $1}'
    )
    echo ""
else
    _app_i=1
    for _line in "${_app_lines[@]}"; do
        _disp="${_line#*$'\t'}"
        printf "${C_MAIN}${C_BOLD} ${G_MID}  ${C_ACCENT}%2d ${C_DIM}${G_ARROW} ${C_RESET}%b\n" "$_app_i" "$_disp"
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
    unset _app_i _disp APP_RAW token
fi
unset _app_lines _k _tl _line

if [ "${#APPS[@]}" -gt 0 ]; then
    _app_labels=()
    for _k in "${APPS[@]}"; do _app_labels+=("${APP_LABEL[$_k]}"); done
    success "Apps: ${C_ACCENT}${_app_labels[*]}${C_RESET}"
    unset _app_labels _k
else
    success "${C_DIM}No apps selected${C_RESET}"
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
if [ "$IS_WSL" -eq 1 ]; then
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
                    eza)     ensure_eza_deb     || _dep_ok=0 ;;
                    lazygit) ensure_lazygit_deb || _dep_ok=0 ;;
                    *)       apt_install "$dep_pkg" || _dep_ok=0 ;;
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

      # ── fastfetch / ghostty / kitty / rofi ──────────────────────────────
      fastfetch|ghostty|kitty|rofi)
        if pkg_installed "$pkg"; then
            substep "${C_ACCENT}${pkg}${C_RESET} already installed"
        else
            substep "Installing ${C_ACCENT}${pkg}${C_RESET}..."
            _install_ok=1
            if [[ "$DISTRO" == "arch" ]]; then
                arch_install "$pkg" || _install_ok=0
            else
                case "$cfg" in
                    ghostty)   ensure_ghostty_deb   || _install_ok=0 ;;
                    fastfetch) ensure_fastfetch_deb || _install_ok=0 ;;
                    *)         apt_install "$pkg"   || _install_ok=0 ;;
                esac
            fi
            if [ "$_install_ok" -eq 0 ]; then
                error "Failed to install ${C_ACCENT}${pkg}${C_RESET} — skipping ${cfg}"
                FAILED+=("$cfg")
                continue
            fi
        fi

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
        if pkg_installed zsh; then
            substep "${C_ACCENT}zsh${C_RESET} already installed"
        else
            substep "Installing ${C_ACCENT}zsh${C_RESET}..."
            _install_ok=1
            if [[ "$DISTRO" == "arch" ]]; then
                arch_install zsh || _install_ok=0
            else
                apt_install zsh || _install_ok=0
            fi
            if [ "$_install_ok" -eq 0 ]; then
                error "Failed to install zsh — skipping"
                FAILED+=(zsh)
                continue
            fi
        fi

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
        if pkg_installed proton-vpn-cli; then
            substep "${C_ACCENT}proton-vpn-cli${C_RESET} already installed"
        else
            substep "Installing ${C_ACCENT}proton-vpn-cli${C_RESET}..."
            _install_ok=1
            if [[ "$DISTRO" == "arch" ]]; then
                arch_install proton-vpn-cli || _install_ok=0
            else
                ensure_protonvpn_cli_deb || _install_ok=0
            fi
            if [ "$_install_ok" -eq 0 ]; then
                error "Failed to install proton-vpn-cli — skipping"
                FAILED+=(protonvpn)
                continue
            fi
        fi

        # Unlink stow-folded dirs from a previous run before backup
        pvpn_dir="$HOME/scripts/pvpn"
        if [ -L "$pvpn_dir" ]; then
            rm "$pvpn_dir"
        fi
        if [ -L "$HOME/scripts" ]; then
            rm "$HOME/scripts"
        fi
        mkdir -p "$pvpn_dir"
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
        if pkg_installed starship; then
            substep "${C_ACCENT}starship${C_RESET} already installed"
        else
            substep "Installing ${C_ACCENT}starship${C_RESET}..."
            _install_ok=1
            if [[ "$DISTRO" == "arch" ]]; then
                arch_install starship || _install_ok=0
            else
                ensure_starship_deb || _install_ok=0
            fi
            if [ "$_install_ok" -eq 0 ]; then
                error "Failed to install starship — skipping"
                FAILED+=(starship)
                continue
            fi
        fi

        # starship is a single file, not a directory — handle differently.
        #
        # An existing starship.toml is left exactly where it is. A prompt
        # config is something people tune by hand, and replacing it (or, in
        # delete mode, erasing it) to install our own is not a reasonable
        # reading of "install starship". Ours goes in only when there is
        # nothing there.
        _st="$HOME/.config/starship.toml"
        _stow_df="$(readlink -f "$DOTFILES_DIR" 2>/dev/null || printf '%s' "$DOTFILES_DIR")"
        if [ -L "$_st" ] && [[ "$(readlink -f "$_st" 2>/dev/null)" == "$_stow_df"/* ]]; then
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
        unset _st _stow_df
        ;;

      # ── git ──────────────────────────────────────────────────────────────
      git)
        if pkg_installed git; then
            substep "${C_ACCENT}git${C_RESET} already installed"
        else
            substep "Installing ${C_ACCENT}git${C_RESET}..."
            _install_ok=1
            if [[ "$DISTRO" == "arch" ]]; then
                arch_install git || _install_ok=0
            else
                apt_install git || _install_ok=0
            fi
            if [ "$_install_ok" -eq 0 ]; then
                error "Failed to install git — skipping"
                FAILED+=(git)
                continue
            fi
        fi

        backup_file "$HOME/.gitconfig"
        if ! stow_home "git"; then
            FAILED+=(git)
            continue
        fi
        ;;

      # ── ulauncher ────────────────────────────────────────────────────────
      ulauncher)
        if pkg_installed ulauncher; then
            substep "${C_ACCENT}ulauncher${C_RESET} already installed"
        else
            if [[ "$DISTRO" == "arch" ]]; then
                substep "Installing ${C_ACCENT}ulauncher${C_RESET}..."
                if ! arch_install ulauncher; then
                    error "Failed to install ulauncher — skipping"
                    FAILED+=(ulauncher)
                    continue
                fi
            else
                substep "Installing ${C_ACCENT}ulauncher${C_RESET}..."
                if ! ensure_ulauncher_deb; then
                    error "Failed to install ulauncher — skipping"
                    FAILED+=(ulauncher)
                    continue
                fi
            fi
        fi

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
            if curl_app_installed "$_bin"; then
                substep "${C_ACCENT}${_lbl}${C_RESET} already installed"
                success "${C_ACCENT}${_lbl}${C_RESET} done"
                INSTALLED+=("$_lbl")
            else
                substep "Downloading installer for ${C_ACCENT}${_lbl}${C_RESET}..."
                _tmpsh=$(mktemp -p "$RUN_TMPDIR" installer_XXXXXX.sh)
                case "$app" in
                    claude-code)     _curl_url="https://claude.ai/install.sh"              ; _shell=bash ;;
                    antigravity-cli) _curl_url="https://antigravity.google/cli/install.sh" ; _shell=bash ;;
                    codex-cli)       _curl_url="https://chatgpt.com/codex/install.sh"      ; _shell=sh   ;;
                    opencode)        _curl_url="https://opencode.ai/install"               ; _shell=bash ;;
                    kimi-code)       _curl_url="https://code.kimi.com/kimi-code/install.sh"  ; _shell=bash ;;
                    muse)            _curl_url="https://dev.meta.ai/install.sh"              ; _shell=bash ;;
                esac
                if curl -fsSL "$_curl_url" -o "$_tmpsh" 2>/dev/null; then
                    substep "Running installer..."
                    _cenv=()  ; [ -n "${APP_CURL_ENV[$app]:-}" ]  && read -ra _cenv  <<< "${APP_CURL_ENV[$app]}"
                    _cargs=() ; [ -n "${APP_CURL_ARGS[$app]:-}" ] && read -ra _cargs <<< "${APP_CURL_ARGS[$app]}"
                    if env PATH="${CURL_APP_PATH}:$PATH" "${_cenv[@]}" "$_shell" "$_tmpsh" "${_cargs[@]}"; then
                        # Verified against reality, the way the package path is.
                        # A vendor installer that swallows its own failure and
                        # exits 0 otherwise gets reported as a success.
                        if [ -z "$_bin" ] || curl_app_installed "$_bin"; then
                            success "${C_ACCENT}${_lbl}${C_RESET} installed"
                            INSTALLED+=("$_lbl")
                        else
                            error "Installer finished but ${C_ACCENT}${_bin}${C_RESET} is not on PATH"
                            FAILED+=("$_lbl")
                        fi
                    else
                        error "Installer exited with error for ${C_ACCENT}${_lbl}${C_RESET}"
                        FAILED+=("$_lbl")
                    fi
                else
                    error "Download failed for ${C_ACCENT}${_lbl}${C_RESET} — check network"
                    FAILED+=("$_lbl")
                fi
                rm -f "$_tmpsh"
                unset _tmpsh _curl_url _shell _cenv _cargs
            fi
        else
            _pkg="$(app_pkg_name "$app")"
            if pkg_installed "$_pkg"; then
                substep "${C_ACCENT}${_lbl}${C_RESET} already installed — updating..."
            else
                substep "Installing ${C_ACCENT}${_lbl}${C_RESET}..."
            fi
            case "$_type" in
                paru-y) paru_install_y "$_pkg" ;;
                pacman|paru) arch_install "$_pkg" ;;
                apt)    apt_install "$_pkg" ;;
                brave)
                    case "$app" in
                        brave-stable) ensure_brave_deb stable "$_pkg" ;;
                        brave-beta)   ensure_brave_deb beta   "$_pkg" ;;
                    esac
                    ;;
                vscode) ensure_vscode_deb ;;
                vscode-insiders) ensure_vscode_insiders_deb ;;
                claude-desktop) ensure_claude_desktop_deb ;;
                docker) ensure_docker_deb ;;
            esac
            if pkg_installed "$_pkg"; then
                if [[ "$app" == "flatpak" ]]; then
                    substep "Adding Flathub remote..."
                    ensure_flathub_remote \
                        || substep "${C_YELLOW}Could not add Flathub — add it manually${C_RESET}"
                elif [[ "$app" == "docker" ]]; then
                    if [[ "$DISTRO" == "arch" ]]; then
                        substep "Installing docker-compose and docker-buildx..."
                        pacman_install docker-compose docker-buildx &>/dev/null 2>&1
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
            error "\.git is still there — this checkout is still identifiable"
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
