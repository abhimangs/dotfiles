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
for _arg in "$@"; do
    [[ "$_arg" == "--dry-run" ]] && DRY_RUN=1
    [[ "$_arg" == "--gui"     ]] && FORCE_GUI=1
done
unset _arg
# linux.sh (deployed by hand at abhiman.io/linux.sh, and not editable) ends in
# `exec ./install.sh` with no arguments, so flags cannot reach us through the
# curl bootstrap. The environment does survive exec, so every flag has an env
# equivalent:  DOTFILES_GUI=1 curl -fsSL https://abhiman.io/linux.sh | bash
[ -n "${DOTFILES_DRY_RUN:-}" ] && DRY_RUN=1
[ -n "${DOTFILES_GUI:-}" ]     && FORCE_GUI=1

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
    [ -n "${DISPLAY:-}" ]         && return 1
    [ -n "${WAYLAND_DISPLAY:-}" ] && return 1
    # A graphical default target means a display manager is meant to run here
    if command -v systemctl &>/dev/null; then
        [[ "$(systemctl get-default 2>/dev/null)" == "graphical.target" ]] && return 1
    fi
    # Installed session files are the last positive signal of a desktop
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
GUI_APPS=(brave-beta brave-stable vscode antigravity-ide antigravity notion obsidian claude-desktop vlc)

trap 'echo -ne "\033[0m"' EXIT

# ── Interactive input source ──────────────────────────────────────────────────
# Every prompt must read from the terminal, never stdin: reached through
# `curl … | bash` (the documented bootstrap path) stdin is the download stream,
# so a plain `read` silently eats script text instead of waiting for input.
if [ -r /dev/tty ]; then
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
    G_INFO='󰓅' ; G_SUM='󰄴'  ; G_RULE='─' ; G_DOT='·'
else
    G_TOP='+-' ; G_MID='|'  ; G_END='+-'
    G_ARROW='>'; G_OK='[ok]'; G_FAIL='[!]'
    G_INFO='*' ; G_SUM='='  ; G_RULE='-' ; G_DOT='.'
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

    local tmplog; tmplog=$(mktemp /tmp/paru_XXXXXX.log)

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

APT_UPDATED=0
apt_update_once() {
    [ "$APT_UPDATED" -eq 1 ] && return 0
    local out try
    for try in 1 2 3; do
        if out=$(sudo apt-get update -qq 2>&1); then
            APT_UPDATED=1
            return 0
        fi
        grep -qiE 'could not get lock|another process (is )?using it|frontend lock' <<< "$out" || break
        substep "${C_YELLOW}apt is locked — waiting 20s (${try}/3)${C_RESET}"
        sleep 20
    done
    # Only a mirror-level failure justifies adding another mirror — a broken
    # third-party repo would fail this too and swapping mirrors would not help.
    if grep -qiE 'could not resolve|failed to fetch|connection failed|404 +not found|no longer has a release file|hash sum mismatch' <<< "$out"; then
        substep "${C_YELLOW}Package index unreachable — trying the canonical mirror${C_RESET}"
        if apt_add_fallback_mirror; then
            sudo apt-get update -qq &>/dev/null 2>&1
        fi
    fi
    APT_UPDATED=1
}

# Last apt error, so a failure can be shown instead of just "failed"
APT_LAST_ERROR=""

apt_install() {
    apt_update_once
    local try out
    # Fresh cloud images run unattended-upgrades / apt-daily at boot and hold
    # the dpkg lock for minutes. Every apt-get in that window dies with "Could
    # not get lock /var/lib/dpkg/lock-frontend" — the usual reason a server
    # install fails before stow and fzf are even in place. Wait it out.
    for try in 1 2 3 4 5; do
        if out=$(sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" 2>&1); then
            return 0
        fi
        if grep -qiE 'could not get lock|another process (is )?using it|frontend lock|resource temporarily unavailable' <<< "$out"; then
            substep "${C_YELLOW}apt is locked by another process — waiting 20s (${try}/5)${C_RESET}"
            sleep 20
            continue
        fi
        break
    done

    # An index older than the mirror 404s on a superseded version.
    substep "${C_YELLOW}Stale package index — refreshing and retrying${C_RESET}"
    APT_UPDATED=0
    apt_update_once
    if out=$(sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" 2>&1); then
        return 0
    fi
    APT_LAST_ERROR="$out"
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
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${need[@]}" &>/dev/null 2>&1
    fi
}

add_ppa() {
    local ppa="$1"
    ensure_apt_deps
    sudo add-apt-repository -y "$ppa" &>/dev/null 2>&1
    APT_UPDATED=0
    apt_update_once
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
            local tmp; tmp=$(mktemp /tmp/fastfetch_XXXXXX.deb)
            curl -fsSL "$url" -o "$tmp" 2>/dev/null && sudo apt-get install -y "$tmp" &>/dev/null 2>&1
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
            local tmp; tmp=$(mktemp /tmp/ulauncher_XXXXXX.deb)
            curl -fsSL "$url" -o "$tmp" 2>/dev/null && sudo apt-get install -y "$tmp" &>/dev/null 2>&1
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

    if [ "$IS_UBUNTU" -eq 1 ]; then
        add_ppa ppa:lazygit-team/release
        apt_install lazygit
        apt_pkg_installed lazygit && return 0
    fi

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
        tmp=$(mktemp -d /tmp/lazygit_XXXXXX)
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
    curl -sS https://starship.rs/install.sh | sh -s -- -y &>/dev/null 2>&1
    command -v starship &>/dev/null
}

# ── eza (Debian/Ubuntu) ───────────────────────────────────────────────────────
ensure_eza_deb() {
    apt_pkg_installed eza && return 0
    apt_install eza
    apt_pkg_installed eza && return 0

    ensure_apt_deps
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://raw.githubusercontent.com/eza-community/eza/main/deb.asc 2>/dev/null \
        | gpg --dearmor | sudo tee /etc/apt/keyrings/gierens.gpg >/dev/null
    echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" \
        | sudo tee /etc/apt/sources.list.d/gierens.list >/dev/null
    sudo chmod 644 /etc/apt/keyrings/gierens.gpg /etc/apt/sources.list.d/gierens.list
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
            tmp=$(mktemp /tmp/protonvpn_XXXXXX.deb)
            if curl -fsSL "${listing_url}${deb_name}" -o "$tmp" 2>/dev/null; then
                sudo dpkg -i "$tmp" &>/dev/null 2>&1
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

    sudo curl -fsSLo "$key_file" "$key_url" &>/dev/null 2>&1
    sudo curl -fsSLo "$sources_file" "https://${host}/brave-browser.sources" &>/dev/null 2>&1
    APT_UPDATED=0
    apt_update_once
    apt_install "$pkg"
    apt_pkg_installed "$pkg"
}

# ── VS Code (Debian/Ubuntu) ───────────────────────────────────────────────────
ensure_vscode_deb() {
    apt_pkg_installed code && return 0
    ensure_apt_deps
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc 2>/dev/null \
        | gpg --dearmor | sudo tee /etc/apt/keyrings/packages.microsoft.gpg >/dev/null
    echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
        | sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
    APT_UPDATED=0
    apt_update_once
    apt_install code
    apt_pkg_installed code
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
    sudo curl -fsSLo /usr/share/keyrings/claude-desktop-archive-keyring.asc \
        https://downloads.claude.ai/claude-desktop/key.asc &>/dev/null 2>&1
    echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/claude-desktop-archive-keyring.asc] https://downloads.claude.ai/claude-desktop/apt/stable stable main" \
        | sudo tee /etc/apt/sources.list.d/claude-desktop.list >/dev/null
    APT_UPDATED=0
    apt_update_once
    apt_install claude-desktop
    apt_pkg_installed claude-desktop
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
    local tmp; tmp=$(mktemp -d /tmp/font_XXXXXX)
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
    for item in .git .github .gitignore .gitattributes \
                README.md CLAUDE.md LICENSE LICENSE.md linux.sh; do
        if [ -e "$d/$item" ] || [ -L "$d/$item" ]; then
            rm -rf "${d:?}/${item:?}" && removed+=("$item")
        fi
    done

    if [ "${#removed[@]}" -gt 0 ]; then
        substep "Removed: ${C_DIM}${removed[*]}${C_RESET}"
    else
        substep "${C_DIM}Nothing left to remove${C_RESET}"
    fi
    return 0
}

# ── Stow package directly into ~/.config/<name>/ (flat repo structure) ────────
stow_config() {
    local name="$1"
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
    local cfg="$1"
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
APPS_LIST=(brave-beta brave-stable vscode antigravity-ide claude-code antigravity antigravity-cli codex-cli opencode kimi-code notion obsidian vlc flatpak)
if [[ "$DISTRO" == "debian" ]]; then
    # Notion (no official Linux build), Obsidian (only a vendor .deb/AppImage on
    # apt, no repo) and the Antigravity desktop/IDE (upstream packaging still a
    # moving target on apt) are Arch-only for now.
    # Claude Desktop is the inverse case: an official Anthropic apt repo exists,
    # but there is no Arch package — so it is Debian/Ubuntu-only.
    APPS_LIST=(brave-beta brave-stable vscode claude-desktop claude-code antigravity-cli codex-cli opencode kimi-code vlc flatpak)
fi
# No display server → drop everything that needs one, keeping the CLI tools
[ "$IS_HEADLESS" -eq 1 ] && strip_items APPS_LIST "${GUI_APPS[@]}"

declare -A APP_LABEL APP_TYPE APP_PKG APP_BIN

APP_LABEL[brave-beta]="Brave Origin Beta"
APP_LABEL[brave-stable]="Brave Origin Stable"
APP_LABEL[vscode]="Visual Studio Code"
APP_LABEL[antigravity-ide]="Antigravity IDE"
APP_LABEL[claude-code]="Claude Code CLI"
APP_LABEL[antigravity]="Antigravity 2.0"
APP_LABEL[antigravity-cli]="Antigravity CLI"
APP_LABEL[codex-cli]="Codex CLI"
APP_LABEL[opencode]="OpenCode"
APP_LABEL[kimi-code]="Kimi Code CLI"
APP_LABEL[notion]="Notion"
APP_LABEL[obsidian]="Obsidian"
APP_LABEL[claude-desktop]="Claude Desktop"
APP_LABEL[vlc]="VLC"
APP_LABEL[flatpak]="Flatpak"

# paru-y forces a db refresh first (Brave bumps versions faster than a stale
# db notices); paru and pacman both resolve through arch_install — repo first,
# AUR second — so the distinction is only about which one is expected to hit.
APP_TYPE[brave-beta]="paru-y"
APP_TYPE[brave-stable]="paru-y"
APP_TYPE[vscode]="paru"
APP_TYPE[antigravity-ide]="paru"
APP_TYPE[claude-code]="curl"
APP_TYPE[antigravity]="paru"
APP_TYPE[antigravity-cli]="curl"
APP_TYPE[codex-cli]="curl"
APP_TYPE[opencode]="paru"
APP_TYPE[kimi-code]="curl"
APP_TYPE[notion]="paru"
APP_TYPE[obsidian]="pacman"
APP_TYPE[vlc]="pacman"
APP_TYPE[flatpak]="pacman"

APP_PKG[brave-beta]="brave-origin-beta-bin"
APP_PKG[brave-stable]="brave-origin-bin"
APP_PKG[vscode]="visual-studio-code-bin"
APP_PKG[antigravity-ide]="antigravity-ide"
APP_PKG[antigravity]="antigravity"
APP_PKG[opencode]="opencode"
APP_PKG[notion]="notion-app-electron"
APP_PKG[obsidian]="obsidian"
APP_PKG[vlc]="vlc"
APP_PKG[flatpak]="flatpak"

# Installer bin dirs, exported before running them: opencode, codex and kimi
# all append a PATH block to ~/.zshrc, which is a stow symlink into this repo —
# they would silently edit the tracked dotfile. Seeing their dir already on
# PATH (plus the opt-out flags below) makes them leave it alone.
CURL_APP_PATH="$HOME/.local/bin:$HOME/.opencode/bin:$HOME/.kimi-code/bin"

declare -A APP_CURL_ARGS APP_CURL_ENV
APP_CURL_ARGS[opencode]="--no-modify-path"
APP_CURL_ENV[kimi-code]="KIMI_NO_MODIFY_PATH=1"

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

# Debian/Ubuntu overrides — package names and install mechanism differ
declare -A APP_PKG_DEB
APP_PKG_DEB[brave-stable]="brave-origin"
APP_PKG_DEB[brave-beta]="brave-origin-beta"
APP_PKG_DEB[vscode]="code"
APP_PKG_DEB[claude-desktop]="claude-desktop"

declare -A APP_TYPE_DEB
APP_TYPE_DEB[brave-stable]="brave"
APP_TYPE_DEB[brave-beta]="brave"
APP_TYPE_DEB[vscode]="vscode"
APP_TYPE_DEB[claude-code]="curl"
APP_TYPE_DEB[antigravity-cli]="curl"
APP_TYPE_DEB[codex-cli]="curl"
APP_TYPE_DEB[opencode]="curl"
APP_TYPE_DEB[kimi-code]="curl"
APP_TYPE_DEB[claude-desktop]="claude-desktop"
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

    local _mode_label
    [[ "$BACKUP_MODE" == "delete" ]] \
        && _mode_label="${C_RED}delete${C_RESET}" \
        || _mode_label="${C_YELLOW}backup${C_RESET}"
    echo -e "${C_MAIN}${C_BOLD} ${G_TOP} ${G_INFO} Installation plan ${C_DIM}(existing configs: ${_mode_label}${C_DIM})${C_RESET}"

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
            target="$HOME/.config/starship.toml"; bak="${target}.bak"
            if [ -L "$target" ]; then
                steps+=("${C_ACCENT}re-stow config${C_RESET} ${C_DIM}(unlink + relink)${C_RESET}")
            elif [ -e "$target" ]; then
                if [[ "$BACKUP_MODE" == "delete" ]]; then
                    steps+=("${C_RED}delete${C_RESET} ${C_DIM}starship.toml${C_RESET}")
                else
                    [ -e "$bak" ] && steps+=("${C_YELLOW}backup${C_RESET} ${C_DIM}starship.toml.bak → starship.toml.old.bak${C_RESET}")
                    steps+=("${C_YELLOW}backup${C_RESET} ${C_DIM}starship.toml → starship.toml.bak${C_RESET}")
                fi
                steps+=("${C_GREEN}stow ~/.config/starship.toml${C_RESET}")
            else
                steps+=("${C_GREEN}stow ~/.config/starship.toml${C_RESET} ${C_DIM}(fresh)${C_RESET}")
            fi
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
        echo -e "${C_MAIN}${C_BOLD} ${G_MID}  ${C_ACCENT}${C_BOLD}private mode${C_RESET}"
        echo -e "${C_MAIN}${C_BOLD} ${G_MID}    ${C_DIM}${G_DOT}${C_RESET} ${C_RED}remove${C_RESET} ${C_DIM}~/dotfiles/.git and repo files at the end${C_RESET}"
        echo -e "${C_MAIN}${C_BOLD} ${G_MID}    ${C_DIM}${G_DOT}${C_RESET} ${C_DIM}configs keep working — re-running needs a fresh clone${C_RESET}"
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

# ─────────────────────────────────────────────────────────────────────────────
header

# ── Backup mode ───────────────────────────────────────────────────────────────
BACKUP_MODE="backup"
STRIP_REPO=0
_bm_sel=0
_BM_N=3

_bm_row() {   # <index> <selected> <colour> <label> <description>
    local mark="   "
    [ "$1" -eq "$2" ] && mark=" $3${G_ARROW}${C_RESET} "
    printf " ${C_MAIN}${C_BOLD}${G_MID}${C_RESET} %b %-8s ${C_DIM}${G_DOT}  %-44s${C_RESET}\n" "$mark" "$4" "$5"
}

_bm_draw() {
    _bm_row 0 "$1" "$C_GREEN"  "backup"  "move to .bak, safe and reversible"
    _bm_row 1 "$1" "$C_RED"    "delete"  "wipe cleanly, no backup kept"
    _bm_row 2 "$1" "$C_RED"    "private" "delete, then strip repo traces from ~/dotfiles"
}

echo -e "${C_MAIN}${C_BOLD} ${G_TOP} ${G_INFO} Existing configs  ${C_DIM}↑↓ navigate  ${G_DOT}  Enter confirm${C_RESET}"
_bm_draw $_bm_sel

while true; do
    printf "\033[%dA" "$_BM_N"
    IFS= read -n 1 -rs _bm_key <"$TTY_IN"
    case "$_bm_key" in
        $'\n'|$'\r'|'')
            _bm_draw $_bm_sel
            break
            ;;
        'b'|'B') _bm_sel=0; _bm_draw $_bm_sel ;;
        'd'|'D') _bm_sel=1; _bm_draw $_bm_sel ;;
        'p'|'P') _bm_sel=2; _bm_draw $_bm_sel ;;
        $'\033')
            IFS= read -n 2 -rs -t 0.1 _bm_esc <"$TTY_IN" || true
            case "$_bm_esc" in
                '[A'|'[D') [ "$_bm_sel" -gt 0 ] && _bm_sel=$(( _bm_sel - 1 )) ;;
                '[B'|'[C') [ "$_bm_sel" -lt 2 ] && _bm_sel=$(( _bm_sel + 1 )) ;;
            esac
            _bm_draw $_bm_sel
            ;;
        *) _bm_draw $_bm_sel ;;
    esac
done

case "$_bm_sel" in
    2)  BACKUP_MODE="delete"; STRIP_REPO=1
        echo -e " ${C_MAIN}${C_BOLD}${G_END} ${C_RED}${G_OK}${C_RESET} private ${C_DIM}(delete + strip repo traces)${C_RESET}\n" ;;
    1)  BACKUP_MODE="delete"
        echo -e " ${C_MAIN}${C_BOLD}${G_END} ${C_RED}${G_OK}${C_RESET} delete\n" ;;
    *)  echo -e " ${C_MAIN}${C_BOLD}${G_END} ${C_GREEN}${G_OK}${C_RESET} backup\n" ;;
esac
unset -f _bm_draw _bm_row
unset _bm_sel _bm_key _bm_esc _BM_N

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

    ( while true; do sudo -v; sleep 240; done ) &>/dev/null &
    _SUDO_KEEPALIVE=$!
    trap 'kill "$_SUDO_KEEPALIVE" 2>/dev/null; echo -ne "\033[0m"' EXIT
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

        substep "Cloning paru from AUR..."
        rm -rf /tmp/paru-build
        if ! git clone https://aur.archlinux.org/paru.git /tmp/paru-build &>/dev/null 2>&1; then
            error "Failed to clone paru. Check your internet connection."
            exit 1
        fi

        echo -e "${C_MAIN}${C_BOLD} ${G_MID}  ${C_DIM}❯ ${C_YELLOW}Building paru — output shown below (takes 2–4 min)${C_RESET}\n"
        if ! (cd /tmp/paru-build && makepkg -si --noconfirm); then
            error "paru build failed."
            exit 1
        fi
        echo ""

        rm -rf /tmp/paru-build

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
    apt_update_once
    ensure_apt_deps
    success "apt ready"
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
CONFIGS=(fastfetch ghostty kitty zsh protonvpn starship rofi ulauncher git)
if [[ "$DISTRO" == "debian" ]]; then
    # Arch ships rofi 2.0 (Wayland support merged upstream); Debian/Ubuntu are
    # still on the 1.7.x X11-only build, so rofi stays Arch-only.
    CONFIGS=(fastfetch ghostty kitty zsh protonvpn starship ulauncher git)
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

if [ "${#DEPS[@]}" -gt 0 ]; then
    success "Dep tools: ${C_ACCENT}${DEPS[*]}${C_RESET}"
else
    success "${C_DIM}No dep tools selected${C_RESET}"
fi

# Warn if alias-heavy dep tools selected without zsh
if [ "${#DEPS[@]}" -gt 0 ] && ! printf '%s\n' "${SELECTED[@]}" | grep -qx "zsh"; then
    _alias_deps=(bat eza zoxide thefuck)
    for _d in "${DEPS[@]}"; do
        for _a in "${_alias_deps[@]}"; do
            if [[ "$_d" == "$_a" ]]; then
                echo -e " ${C_YELLOW}  Note: bat/eza/zoxide/thefuck aliases live in .zshrc — consider also selecting zsh${C_RESET}"
                echo ""
                break 2
            fi
        done
    done
    unset _alias_deps _d _a
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
        apt|brave|vscode|claude-desktop) _tl="apt" ;;
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
        install_font || error "Failed to install JetBrainsMono — continuing"
    fi
    if maple_font_installed; then
        substep "${C_DIM}Maple Mono already installed${C_RESET}"
    else
        substep "Installing ${C_ACCENT}Maple Mono${C_RESET}..."
        install_maple_font || error "Failed to install Maple Mono — continuing"
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
        INSTALLED+=("$dep")

        if [[ "$DISTRO" == "debian" ]]; then
            [[ "$dep" == "bat" ]] && ensure_bat_shim
            [[ "$dep" == "fd"  ]] && ensure_fd_shim
        fi

        # Stow config for deps that have one
        for _dc in "${DEP_HAS_CONFIG[@]}"; do
            if [[ "$dep" == "$_dc" ]] && [ -d "$DOTFILES_DIR/$dep" ]; then
                stow_config "$dep"
                break
            fi
        done
    done
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
        elif [ "$current_shell" = "$zsh_path" ]; then
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

            if [ "$(getent passwd "$target_user" | cut -d: -f7)" != "$zsh_path" ]; then
                # PAM refuses on cloud accounts with no local password
                # (SSH-key-only login). usermod writes /etc/passwd directly.
                sudo usermod -s "$zsh_path" "$target_user" </dev/null &>/dev/null || true
            fi

            # Read it back rather than trusting an exit code. chsh can exit 0
            # having changed nothing, which is exactly how the shell ends up
            # still being bash after logging out and back in.
            new_shell="$(getent passwd "$target_user" | cut -d: -f7)"
            if [ "$new_shell" = "$zsh_path" ]; then
                substep "${C_GREEN}Login shell for ${target_user} is now ${zsh_path}${C_RESET}"
                substep "${C_DIM}Applies at next login — or run ${C_ACCENT}exec zsh${C_DIM} to switch now${C_RESET}"
            else
                error "Login shell unchanged — still ${new_shell:-unknown}"
                substep "Run it manually: ${C_ACCENT}sudo usermod -s ${zsh_path} ${target_user}${C_RESET}"
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

        # starship is a single file, not a directory — handle differently
        stow --target "$HOME/.config" --dir "$DOTFILES_DIR" -D "starship" &>/dev/null 2>&1 || true
        backup_file "$HOME/.config/starship.toml"
        if ! stow --target "$HOME/.config" --dir "$DOTFILES_DIR" "starship" &>/dev/null 2>&1; then
            error "Stow failed for starship — check for conflicts in ~/.config/"
            FAILED+=(starship)
            continue
        fi
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
                _tmpsh=$(mktemp /tmp/installer_XXXXXX.sh)
                case "$app" in
                    claude-code)     _curl_url="https://claude.ai/install.sh"              ; _shell=bash ;;
                    antigravity-cli) _curl_url="https://antigravity.google/cli/install.sh" ; _shell=bash ;;
                    codex-cli)       _curl_url="https://chatgpt.com/codex/install.sh"      ; _shell=sh   ;;
                    opencode)        _curl_url="https://opencode.ai/install"               ; _shell=bash ;;
                    kimi-code)       _curl_url="https://code.kimi.com/kimi-code/install.sh"  ; _shell=bash ;;
                esac
                if curl -fsSL "$_curl_url" -o "$_tmpsh" 2>/dev/null; then
                    substep "Running installer..."
                    _cenv=()  ; [ -n "${APP_CURL_ENV[$app]:-}" ]  && read -ra _cenv  <<< "${APP_CURL_ENV[$app]}"
                    _cargs=() ; [ -n "${APP_CURL_ARGS[$app]:-}" ] && read -ra _cargs <<< "${APP_CURL_ARGS[$app]}"
                    if env PATH="${CURL_APP_PATH}:$PATH" "${_cenv[@]}" "$_shell" "$_tmpsh" "${_cargs[@]}"; then
                        success "${C_ACCENT}${_lbl}${C_RESET} installed"
                        INSTALLED+=("$_lbl")
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
                claude-desktop) ensure_claude_desktop_deb ;;
            esac
            if pkg_installed "$_pkg"; then
                if [[ "$app" == "flatpak" ]]; then
                    substep "Adding Flathub remote..."
                    ensure_flathub_remote \
                        || substep "${C_YELLOW}Could not add Flathub — add it manually${C_RESET}"
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
    if strip_repo_traces; then
        substep "${C_DIM}~/dotfiles is now a plain folder — symlinks still resolve${C_RESET}"
        substep "${C_YELLOW}Re-running the installer now needs a fresh clone${C_RESET}"
        success "No git metadata left"
    else
        error "Refused — ${DOTFILES_DIR} does not look like the dotfiles checkout"
    fi
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
