#!/usr/bin/env bash

# ── Distro detection ──────────────────────────────────────────────────────────
DISTRO=""
IS_UBUNTU=0

if [ -f /etc/arch-release ]; then
    DISTRO="arch"
else
    _os_id="" _os_id_like=""
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        _os_id="${ID:-}"
        _os_id_like="${ID_LIKE:-}"
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

DRY_RUN=0
for _arg in "$@"; do [[ "$_arg" == "--dry-run" ]] && DRY_RUN=1; done
unset _arg

trap 'echo -ne "\033[0m"' EXIT

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

# Full Catppuccin Mocha fzf theme
_FZF_CLR="bg+:#313244,bg:#1e1e2e,fg:#cdd6f4,fg+:#cdd6f4,hl:#f38ba8,hl+:#f38ba8,prompt:#cba6f7,pointer:#f5e0dc,marker:#a6e3a1,border:#585b70,header:#94e2d5,info:#cba6f7,spinner:#f5e0dc,separator:#585b70,gutter:#1e1e2e"

# ── UI helpers ────────────────────────────────────────────────────────────────
header() {
    clear
    echo ""
    echo -e "${C_MAIN}  ──────────────────────────────────────────────────────${C_RESET}"
    echo -e "        ${C_ACCENT}${C_BOLD}󰄴  D O T F I L E S${C_RESET}  ${C_DIM}·${C_RESET}  ${C_TEAL}${C_BOLD}I N S T A L L E R${C_RESET}"
    echo -e "${C_MAIN}  ──────────────────────────────────────────────────────${C_RESET}"
    echo ""
    local _distro_label
    case "$DISTRO" in
        arch)   _distro_label="Arch Linux" ;;
        debian) [ "$IS_UBUNTU" -eq 1 ] && _distro_label="Ubuntu" || _distro_label="Debian" ;;
    esac
    echo -e "      ${C_DIM}${_distro_label}  ·  GNU Stow  ·  Catppuccin Mocha${C_RESET}"
    echo ""
}

info()    { echo -e "${C_MAIN}${C_BOLD} ╭─ 󰓅 $1${C_RESET}"; }
substep() { echo -e "${C_MAIN}${C_BOLD} │  ${C_DIM}❯ ${C_RESET}$1"; }
success() { echo -e "${C_MAIN}${C_BOLD} ╰─ ${C_GREEN}✔ ${C_RESET}$1\n"; }
error()   { echo -e "${C_MAIN}${C_BOLD} ╰─ ${C_RED}✘ ${C_RESET}$1\n"; }

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
    sudo pacman -S --needed --noconfirm "$1" &>/dev/null 2>&1
}

_paru_run_robust() {
    local sync_flag="${1:-}"   # "" | "y" | "yy"
    local pkg="$2"
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
    sudo apt-get update -qq &>/dev/null 2>&1
    APT_UPDATED=1
}

apt_install() {
    apt_update_once
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$1" &>/dev/null 2>&1
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

# GitHub "latest release" asset lookup — no jq dependency
github_latest_asset_url() {
    local repo="$1" pattern="$2"
    curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
        | grep -oP '"browser_download_url":\s*"\K[^"]+' \
        | grep -E "$pattern" | head -1
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
        case "$(deb_arch)" in amd64) apat='amd64|x86_64' ;; arm64) apat='arm64|aarch64' ;; *) apat="$(deb_arch)" ;; esac
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
    case "$(deb_arch)" in amd64) apat='x86_64' ;; arm64) apat='arm64' ;; *) apat="$(uname -m)" ;; esac
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

# ── JetBrainsMono Nerd Font (Debian/Ubuntu — no apt package) ─────────────────
FONT_DIR_DEB="$HOME/.local/share/fonts/JetBrainsMono"

font_installed_deb() {
    [ -d "$FONT_DIR_DEB" ] && find "$FONT_DIR_DEB" -name '*.ttf' -print -quit 2>/dev/null | grep -q .
}

ensure_nerd_font_deb() {
    font_installed_deb && return 0
    ensure_apt_deps
    command -v unzip &>/dev/null || apt_install unzip
    local tmp; tmp=$(mktemp -d /tmp/jbmono_XXXXXX)
    if curl -fsSL "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip" -o "$tmp/font.zip" 2>/dev/null; then
        mkdir -p "$FONT_DIR_DEB"
        unzip -oq "$tmp/font.zip" -d "$FONT_DIR_DEB" '*.ttf' &>/dev/null 2>&1
        fc-cache -f "$FONT_DIR_DEB" &>/dev/null 2>&1
    fi
    rm -rf "$tmp"
    font_installed_deb
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
        pacman_install "$FONT_PKG"
    else
        ensure_nerd_font_deb
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
NEEDS_FONT=(ghostty kitty rofi)

needs_font() {
    local cfg="$1"
    for n in "${NEEDS_FONT[@]}"; do [[ "$cfg" == "$n" ]] && return 0; done
    return 1
}

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

# AUR-only dep tools — must use paru, not pacman (Arch only)
declare -A DEP_TYPE
DEP_TYPE[thefuck]="paru"

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
CONFIG_DESC[ghostty]="GPU-accelerated terminal   ·  JetBrains Nerd Font"
CONFIG_DESC[kitty]="cross-platform terminal    ·  JetBrains Nerd Font"
CONFIG_DESC[zsh]="shell + Zinit plugins"
CONFIG_DESC[protonvpn]="ProtonVPN wrapper script"
CONFIG_DESC[starship]="cross-shell prompt"
CONFIG_DESC[rofi]="keyboard-driven launcher   ·  JetBrains Nerd Font"
CONFIG_DESC[git]="git config  →  ~/.gitconfig"
if [[ "$DISTRO" == "arch" ]]; then
    CONFIG_DESC[ulauncher]="app launcher              ·  AUR"
else
    CONFIG_DESC[ulauncher]="app launcher              ·  PPA/deb"
fi

declare -A DEP_DESC
DEP_DESC[bat]="cat with syntax highlighting  ·  Catppuccin theme"
DEP_DESC[eza]="modern ls  →  ls  ll  lt  la aliases"
DEP_DESC[fd]="fast find replacement  →  fzf integration"
DEP_DESC[zoxide]="smart cd  →  z command"
DEP_DESC[thefuck]="corrects last command  →  fuck alias"
DEP_DESC[lazygit]="git TUI  →  lg alias"
DEP_DESC[btop]="resource monitor  ·  Catppuccin theme"
DEP_DESC[tree]="directory tree listing"

# ── Pre-install plan ──────────────────────────────────────────────────────────
show_plan() {
    local cfgs=("$@")
    local wallpaper_stowed=0
    local _font_planned=0

    local _mode_label
    [[ "$BACKUP_MODE" == "delete" ]] \
        && _mode_label="${C_RED}delete${C_RESET}" \
        || _mode_label="${C_YELLOW}backup${C_RESET}"
    echo -e "${C_MAIN}${C_BOLD} ╭─ 󰓅 Installation plan ${C_DIM}(existing configs: ${_mode_label}${C_DIM})${C_RESET}"

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
            if [ "$_font_planned" -eq 0 ] && ! font_installed; then
                steps+=("${C_YELLOW}install JetBrainsMono Nerd Font${C_RESET}")
                _font_planned=1
            fi
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
            if [[ "$cfg" == "rofi" ]] && [ "$_font_planned" -eq 0 ] && ! font_installed; then
                steps+=("${C_YELLOW}install JetBrainsMono Nerd Font${C_RESET}")
                _font_planned=1
            fi
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

        echo -e "${C_MAIN}${C_BOLD} │${C_RESET}"
        echo -e "${C_MAIN}${C_BOLD} │  ${C_ACCENT}${C_BOLD}${cfg}${C_RESET}"
        for step in "${steps[@]}"; do
            echo -e "${C_MAIN}${C_BOLD} │    ${C_DIM}·${C_RESET} ${step}"
        done
    done

    # Dep tools section
    if [ "${#DEPS[@]}" -gt 0 ]; then
        echo -e "${C_MAIN}${C_BOLD} │${C_RESET}"
        echo -e "${C_MAIN}${C_BOLD} │  ${C_ACCENT}${C_BOLD}dep tools${C_RESET}"
        for _d in "${DEPS[@]}"; do
            if pkg_installed "$(dep_pkg_name "$_d")"; then
                echo -e "${C_MAIN}${C_BOLD} │    ${C_DIM}·${C_RESET} ${C_DIM}${_d} already installed${C_RESET}"
            else
                echo -e "${C_MAIN}${C_BOLD} │    ${C_DIM}·${C_RESET} ${C_YELLOW}install ${_d}${C_RESET}"
            fi
        done
    fi

    # Applications section
    if [ "${#APPS[@]}" -gt 0 ]; then
        echo -e "${C_MAIN}${C_BOLD} │${C_RESET}"
        echo -e "${C_MAIN}${C_BOLD} │  ${C_ACCENT}${C_BOLD}applications${C_RESET}"
        for _a in "${APPS[@]}"; do
            local _lbl="${APP_LABEL[$_a]}"
            local _type; _type="$(app_type_resolved "$_a")"
            if [[ "$_type" == "curl" ]]; then
                local _bin="${APP_BIN[$_a]:-}"
                if [[ -n "$_bin" ]] && command -v "$_bin" &>/dev/null; then
                    echo -e "${C_MAIN}${C_BOLD} │    ${C_DIM}·${C_RESET} ${C_DIM}${_lbl} already installed${C_RESET}"
                else
                    echo -e "${C_MAIN}${C_BOLD} │    ${C_DIM}·${C_RESET} ${C_YELLOW}install ${_lbl}${C_RESET} ${C_DIM}(curl)${C_RESET}"
                fi
            else
                local _pkg; _pkg="$(app_pkg_name "$_a")"
                if pkg_installed "$_pkg"; then
                    echo -e "${C_MAIN}${C_BOLD} │    ${C_DIM}·${C_RESET} ${C_DIM}${_lbl} already installed — will update${C_RESET}"
                else
                    echo -e "${C_MAIN}${C_BOLD} │    ${C_DIM}·${C_RESET} ${C_YELLOW}install ${_lbl}${C_RESET}"
                fi
            fi
        done
    fi

    echo -e "${C_MAIN}${C_BOLD} │${C_RESET}"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo -e "${C_MAIN}${C_BOLD} ╰─ ${C_YELLOW}[dry run] No changes made.${C_RESET}\n"
        exit 0
    fi
    echo -ne "${C_MAIN}${C_BOLD} ╰─ ${C_YELLOW}Proceed? [Y/n]: ${C_RESET}"
    read -r CONFIRM </dev/tty
    [[ "$CONFIRM" =~ ^[Nn]$ ]] && echo "" && exit 0
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
header

# ── Backup mode ───────────────────────────────────────────────────────────────
BACKUP_MODE="backup"
_bm_sel=0

_bm_draw() {
    if [ "$1" -eq 0 ]; then
        printf " ${C_MAIN}${C_BOLD}│${C_RESET}  ${C_GREEN}❯${C_RESET}  backup  ${C_DIM}·  move to .bak, safe and reversible   ${C_RESET}\n"
        printf " ${C_MAIN}${C_BOLD}│${C_RESET}     delete  ${C_DIM}·  wipe cleanly, no backup kept         ${C_RESET}\n"
    else
        printf " ${C_MAIN}${C_BOLD}│${C_RESET}     backup  ${C_DIM}·  move to .bak, safe and reversible   ${C_RESET}\n"
        printf " ${C_MAIN}${C_BOLD}│${C_RESET}  ${C_RED}❯${C_RESET}  delete  ${C_DIM}·  wipe cleanly, no backup kept         ${C_RESET}\n"
    fi
}

echo -e "${C_MAIN}${C_BOLD} ╭─ 󰓅 Existing configs  ${C_DIM}↑↓ navigate  ·  Enter confirm${C_RESET}"
_bm_draw $_bm_sel

while true; do
    printf "\033[2A"
    IFS= read -n 1 -rs _bm_key </dev/tty
    case "$_bm_key" in
        $'\n'|$'\r'|'')
            _bm_draw $_bm_sel
            break
            ;;
        'b'|'B') _bm_sel=0; _bm_draw $_bm_sel ;;
        'd'|'D') _bm_sel=1; _bm_draw $_bm_sel ;;
        $'\033')
            IFS= read -n 2 -rs -t 0.1 _bm_esc </dev/tty || true
            case "$_bm_esc" in
                '[A'|'[D') _bm_sel=0 ;;
                '[B'|'[C') _bm_sel=1 ;;
            esac
            _bm_draw $_bm_sel
            ;;
        *) _bm_draw $_bm_sel ;;
    esac
done

if [ "$_bm_sel" -eq 1 ]; then
    BACKUP_MODE="delete"
    echo -e " ${C_MAIN}${C_BOLD}╰─ ${C_RED}✔${C_RESET} delete\n"
else
    echo -e " ${C_MAIN}${C_BOLD}╰─ ${C_GREEN}✔${C_RESET} backup\n"
fi
unset -f _bm_draw
unset _bm_sel _bm_key _bm_esc

# ── Sudo cache ────────────────────────────────────────────────────────────────
info "Authentication..."
substep "Enter your sudo password once — cached for the full install"
if ! sudo -v; then
    error "Authentication failed. Exiting."
    exit 1
fi
success "Authenticated"

( while true; do sudo -v; sleep 240; done ) &>/dev/null &
_SUDO_KEEPALIVE=$!
trap 'kill "$_SUDO_KEEPALIVE" 2>/dev/null; echo -ne "\033[0m"' EXIT

# ── Step 1: AUR helper (Arch) / apt bootstrap (Debian/Ubuntu) ───────────────
if [[ "$DISTRO" == "arch" ]]; then
    info "Checking AUR helper..."
    if command -v paru &>/dev/null; then
        substep "paru already installed"
        success "AUR helper ready"
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

        echo -e "${C_MAIN}${C_BOLD} │  ${C_DIM}❯ ${C_YELLOW}Building paru — output shown below (takes 2–4 min)${C_RESET}\n"
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
    if ! sudo pacman -S --needed --noconfirm stow fzf &>/dev/null 2>&1; then
        error "Failed to install/update stow and fzf."
        exit 1
    fi
else
    if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y stow fzf &>/dev/null 2>&1; then
        error "Failed to install/update stow and fzf."
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
declare -a SELECTED=()

if command -v fzf &>/dev/null; then
    echo ""
    _cfg_lines=()
    for _c in "${CONFIGS[@]}"; do
        _cfg_lines+=("$(printf '%-11s  ·  %s' "$_c" "${CONFIG_DESC[$_c]}")")
    done
    mapfile -t SELECTED < <(
        printf '%s\n' "${_cfg_lines[@]}" | \
        fzf --multi \
            --height=40% \
            --min-height=12 \
            --reverse \
            --border=rounded \
            --prompt="  " \
            --pointer="❯" \
            --marker="✔" \
            --color="${_FZF_CLR}" \
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
            printf "${C_MAIN}${C_BOLD} │  ${C_ACCENT}%d ${C_DIM}❯ ${C_RESET}%-11s ${C_DIM}·  %s${C_RESET}\n" "$((_i+1))" "$_c" "${CONFIG_DESC[$_c]}"
        done
        echo -e "${C_MAIN}${C_BOLD} │  ${C_ACCENT}a ${C_DIM}❯ ${C_RESET}All${C_RESET}"
        echo -ne "${C_MAIN}${C_BOLD} ╰─ ${C_YELLOW}Choice (e.g. 1 4 or a): ${C_RESET}"
        read -rp "" RAW

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

# ── Dep tools sub-menu (always shown) ────────────────────────────────────────
DEPS=()
info "Optional dep tools..."
echo ""

if command -v fzf &>/dev/null; then
    _dep_lines=()
    for _dd in "${DEPS_LIST[@]}"; do
        _dep_lines+=("$(printf '%-10s  ·  %s' "$_dd" "${DEP_DESC[$_dd]}")")
    done
    mapfile -t DEPS < <(
        printf '%s\n' "${_dep_lines[@]}" | \
        fzf --multi \
            --height=40% \
            --min-height=12 \
            --reverse \
            --border=rounded \
            --prompt="  " \
            --pointer="❯" \
            --marker="✔" \
            --color="${_FZF_CLR}" \
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
        printf "${C_MAIN}${C_BOLD} │  ${C_ACCENT}%d ${C_DIM}❯ ${C_RESET}%-9s ${C_DIM}·  %s${C_RESET}\n" "$((_i+1))" "$_dd" "${DEP_DESC[$_dd]}"
    done
    echo -e "${C_MAIN}${C_BOLD} │  ${C_ACCENT}a ${C_DIM}❯ ${C_RESET}All  ${C_DIM}·  Enter to skip${C_RESET}"
    echo -ne "${C_MAIN}${C_BOLD} ╰─ ${C_YELLOW}Choice (e.g. 1 2 or a, Enter=skip): ${C_RESET}"
    read -rp "" DEP_RAW
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
    _app_lines+=("${_k}"$'\t'"$(printf '%-22s  ·  %s' "${APP_LABEL[$_k]}" "$_tl")")
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
            --pointer="❯" \
            --marker="✔" \
            --color="${_FZF_CLR}" \
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
        echo -e "${C_MAIN}${C_BOLD} │  ${C_ACCENT}${_app_i} ${C_DIM}❯ ${C_RESET}${_disp}"
        (( _app_i++ ))
    done
    echo -e "${C_MAIN}${C_BOLD} │  ${C_ACCENT}a ${C_DIM}❯ ${C_RESET}All  ${C_DIM}·  Enter to skip${C_RESET}"
    echo -ne "${C_MAIN}${C_BOLD} ╰─ ${C_YELLOW}Choice (e.g. 1 3 or a, Enter=skip): ${C_RESET}"
    read -rp "" APP_RAW
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

# ── Step 4: plan + confirm ────────────────────────────────────────────────────
show_plan "${SELECTED[@]}"

# ── Step 5a: install dep tools ───────────────────────────────────────────────
FONT_DONE=0
STOWED_WALLPAPER=0
INSTALLED=()
FAILED=()

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
                if [[ "${DEP_TYPE[$dep]:-pacman}" == "paru" ]]; then
                    paru_install "$dep_pkg" || _dep_ok=0
                else
                    pacman_install "$dep_pkg" || _dep_ok=0
                fi
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

for cfg in "${SELECTED[@]}"; do
    info "Installing ${C_ACCENT}${cfg}${C_RESET}..."
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
                pacman_install "$pkg" || _install_ok=0
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

        if [ "$FONT_DONE" -eq 0 ] && needs_font "$cfg"; then
            if ! font_installed; then
                substep "Installing ${C_ACCENT}JetBrainsMono Nerd Font${C_RESET}..."
                install_font || error "Failed to install font — continuing"
            fi
            substep "Rebuilding font cache..."
            fc-cache -fv &>/dev/null 2>&1 || true
            FONT_DONE=1
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
                pacman_install zsh || _install_ok=0
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
        zsh_path="$(command -v zsh)"
        current_shell="$(getent passwd "$USER" | cut -d: -f7)"
        if [ "$current_shell" != "$zsh_path" ]; then
            substep "Changing default shell to ${C_ACCENT}zsh${C_RESET}..."
            if ! grep -qx "$zsh_path" /etc/shells; then
                echo "$zsh_path" | sudo tee -a /etc/shells &>/dev/null
            fi
            if sudo chsh -s "$zsh_path" "$USER"; then
                substep "${C_GREEN}Default shell changed — log out and back in to apply${C_RESET}"
            else
                error "chsh failed — change shell manually: sudo chsh -s $zsh_path $USER"
            fi
        else
            substep "${C_DIM}Default shell already zsh${C_RESET}"
        fi
        unset zsh_path current_shell
        ;;

      # ── protonvpn ────────────────────────────────────────────────────────
      protonvpn)
        if pkg_installed proton-vpn-cli; then
            substep "${C_ACCENT}proton-vpn-cli${C_RESET} already installed"
        else
            substep "Installing ${C_ACCENT}proton-vpn-cli${C_RESET}..."
            _install_ok=1
            if [[ "$DISTRO" == "arch" ]]; then
                pacman_install proton-vpn-cli || _install_ok=0
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
                pacman_install starship || _install_ok=0
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
                pacman_install git || _install_ok=0
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
                substep "Installing ${C_ACCENT}ulauncher${C_RESET} via paru (AUR)..."
                if ! paru_install ulauncher; then
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
    for app in "${APPS[@]}"; do
        _lbl="${APP_LABEL[$app]}"
        _type="$(app_type_resolved "$app")"
        substep "${C_ACCENT}${_lbl}${C_RESET}"

        if [[ "$_type" == "curl" ]]; then
            _bin="${APP_BIN[$app]:-}"
            if [[ -n "$_bin" ]] && command -v "$_bin" &>/dev/null; then
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
                    if "$_shell" "$_tmpsh"; then
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
                unset _tmpsh _curl_url _shell
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
                pacman) pacman_install "$_pkg" ;;
                paru)   paru_install "$_pkg" ;;
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

# ── Step 6: summary ───────────────────────────────────────────────────────────
echo -e "${C_MAIN}${C_BOLD} ╭─ 󰄴 Summary${C_RESET}"

if [ "${#INSTALLED[@]}" -gt 0 ]; then
    echo -e "${C_MAIN}${C_BOLD} │  ${C_GREEN}✔ ${C_RESET}Installed: ${C_ACCENT}${INSTALLED[*]}${C_RESET}"
fi
if [ "${#FAILED[@]}" -gt 0 ]; then
    echo -e "${C_MAIN}${C_BOLD} │  ${C_RED}✘ ${C_RESET}Failed:    ${C_RED}${FAILED[*]}${C_RESET}"
fi

if [ "${#INSTALLED[@]}" -gt 0 ]; then
    echo -e "${C_MAIN}${C_BOLD} ╰─ ${C_GREEN}✔ ${C_RESET}Restart your terminal to apply changes.\n"
else
    echo -e "${C_MAIN}${C_BOLD} ╰─ ${C_RED}✘ ${C_RESET}No configs were installed.\n"
fi
