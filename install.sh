#!/usr/bin/env bash

# ── Arch Linux check ──────────────────────────────────────────────────────────
if [ ! -f /etc/arch-release ]; then
    echo "This installer is for Arch Linux only." >&2
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
C_BOLD='\033[1m'
C_RESET='\033[0m'

# ── UI helpers ────────────────────────────────────────────────────────────────
header() {
    clear
    echo -e "${C_MAIN}${C_BOLD}"
    echo " ╭──────────────────────────────────────────╮"
    echo " │        󰄴 DOTFILES INSTALLER 󰄴            │"
    echo " ╰──────────────────────────────────────────╯"
    echo -e "${C_RESET}"
}

info()    { echo -e "${C_MAIN}${C_BOLD} ╭─ 󰓅 $1${C_RESET}"; }
substep() { echo -e "${C_MAIN}${C_BOLD} │  ${C_DIM}❯ ${C_RESET}$1"; }
success() { echo -e "${C_MAIN}${C_BOLD} ╰─ ${C_GREEN}✔ ${C_RESET}$1\n"; }
error()   { echo -e "${C_MAIN}${C_BOLD} ╰─ ${C_RED}✘ ${C_RESET}$1\n"; }

# ── Package helpers ───────────────────────────────────────────────────────────
pkg_installed() { pacman -Q "$1" &>/dev/null; }

pacman_install() {
    sudo pacman -S --needed --noconfirm "$1" &>/dev/null 2>&1
}

paru_install() {
    paru -S --needed --noconfirm "$1" &>/dev/null 2>&1
}

# ── Backup + stow to ~/.config ────────────────────────────────────────────────
backup_and_stow() {
    local name="$1"
    local target="$HOME/.config/$name"
    local bak="${target}.bak"

    if [ -L "$target" ]; then
        substep "Removing existing stow link for ${C_ACCENT}${name}${C_RESET}..."
        stow --target "$HOME/.config" --dir "$DOTFILES_DIR" -D "$name" &>/dev/null 2>&1
    elif [ -e "$target" ]; then
        if [ -e "$bak" ]; then
            local oldbak="${target}.old.bak"
            substep "Backing up ${C_ACCENT}${name}${C_RESET} → ${C_DIM}${name}.bak${C_RESET} (old .bak → .old.bak)..."
            [ -e "$oldbak" ] && rm -rf "$oldbak"
            mv "$bak" "$oldbak"
        else
            substep "Backing up ${C_ACCENT}${name}${C_RESET} → ${C_DIM}${name}.bak${C_RESET}..."
        fi
        mv "$target" "$bak"
    fi

    mkdir -p "$HOME/.config"
    if ! stow --target "$HOME/.config" --dir "$DOTFILES_DIR" "$name" &>/dev/null 2>&1; then
        error "Stow failed for ${C_ACCENT}${name}${C_RESET} — check for conflicts in ~/.config/${name}"
        return 1
    fi
    return 0
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
        if [ -e "$bak" ]; then
            [ -e "$oldbak" ] && rm -rf "$oldbak"
            mv "$bak" "$oldbak"
            substep "Rotated ${C_DIM}${name}.bak → ${name}.old.bak${C_RESET}"
        fi
        mv "$target" "$bak"
        substep "Backed up ${C_ACCENT}${name}${C_RESET} → ${C_DIM}${name}.bak${C_RESET}"
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
PKG_MAP[ulauncher]="ulauncher"

FONT_PKG="ttf-jetbrains-mono-nerd"
NEEDS_FONT=(ghostty kitty)

needs_font() {
    local cfg="$1"
    for n in "${NEEDS_FONT[@]}"; do [[ "$cfg" == "$n" ]] && return 0; done
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

# Deps that also have a config to stow into ~/.config
DEP_HAS_CONFIG=(bat btop)

# ── Pre-install plan ──────────────────────────────────────────────────────────
show_plan() {
    local cfgs=("$@")
    local wallpaper_stowed=0

    echo -e "${C_MAIN}${C_BOLD} ╭─ 󰓅 Installation plan${C_RESET}"

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
            if ! pkg_installed "$FONT_PKG"; then
                steps+=("${C_YELLOW}install JetBrainsMono Nerd Font${C_RESET}")
            fi
            target="$HOME/.config/$cfg"; bak="${target}.bak"
            if [ -L "$target" ]; then
                steps+=("${C_ACCENT}re-stow config${C_RESET} ${C_DIM}(unlink + relink)${C_RESET}")
            elif [ -e "$target" ]; then
                [ -e "$bak" ] && steps+=("${C_YELLOW}backup${C_RESET} ${C_DIM}$cfg.bak → $cfg.old.bak${C_RESET}")
                steps+=("${C_YELLOW}backup${C_RESET} ${C_DIM}$cfg → $cfg.bak${C_RESET}")
                steps+=("${C_GREEN}stow ~/.config/${cfg}${C_RESET}")
            else
                steps+=("${C_GREEN}stow ~/.config/${cfg}${C_RESET} ${C_DIM}(fresh)${C_RESET}")
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
          fastfetch)
            target="$HOME/.config/$cfg"; bak="${target}.bak"
            if [ -L "$target" ]; then
                steps+=("${C_ACCENT}re-stow config${C_RESET} ${C_DIM}(unlink + relink)${C_RESET}")
            elif [ -e "$target" ]; then
                [ -e "$bak" ] && steps+=("${C_YELLOW}backup${C_RESET} ${C_DIM}$cfg.bak → $cfg.old.bak${C_RESET}")
                steps+=("${C_YELLOW}backup${C_RESET} ${C_DIM}$cfg → $cfg.bak${C_RESET}")
                steps+=("${C_GREEN}stow ~/.config/${cfg}${C_RESET}")
            else
                steps+=("${C_GREEN}stow ~/.config/${cfg}${C_RESET} ${C_DIM}(fresh)${C_RESET}")
            fi
            ;;
          zsh)
            local rc="$HOME/.zshrc"
            if [ -L "$rc" ]; then
                steps+=("${C_ACCENT}re-stow .zshrc${C_RESET} ${C_DIM}(unlink + relink)${C_RESET}")
            elif [ -e "$rc" ]; then
                [ -e "${rc}.bak" ] && steps+=("${C_YELLOW}rotate${C_RESET} ${C_DIM}.zshrc.bak → .zshrc.old.bak${C_RESET}")
                steps+=("${C_YELLOW}backup${C_RESET} ${C_DIM}.zshrc → .zshrc.bak${C_RESET}")
                steps+=("${C_GREEN}stow ~/.zshrc${C_RESET}")
            else
                steps+=("${C_GREEN}stow ~/.zshrc${C_RESET} ${C_DIM}(fresh)${C_RESET}")
            fi
            ;;
          protonvpn)
            local script="$HOME/scripts/pvpn/pvpn.zsh"
            if [ -e "$script" ] && [ ! -L "$script" ]; then
                steps+=("${C_YELLOW}backup${C_RESET} ${C_DIM}pvpn.zsh → pvpn.zsh.bak${C_RESET}")
            fi
            steps+=("${C_GREEN}stow ~/scripts/pvpn/pvpn.zsh${C_RESET}")
            ;;
          starship)
            target="$HOME/.config/starship.toml"; bak="${target}.bak"
            if [ -L "$target" ]; then
                steps+=("${C_ACCENT}re-stow config${C_RESET} ${C_DIM}(unlink + relink)${C_RESET}")
            elif [ -e "$target" ]; then
                [ -e "$bak" ] && steps+=("${C_YELLOW}backup${C_RESET} ${C_DIM}starship.toml.bak → starship.toml.old.bak${C_RESET}")
                steps+=("${C_YELLOW}backup${C_RESET} ${C_DIM}starship.toml → starship.toml.bak${C_RESET}")
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
                [ -e "$bak" ] && steps+=("${C_YELLOW}backup${C_RESET} ${C_DIM}$cfg.bak → $cfg.old.bak${C_RESET}")
                steps+=("${C_YELLOW}backup${C_RESET} ${C_DIM}$cfg → $cfg.bak${C_RESET}")
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
            if pkg_installed "${DEP_PKG[$_d]}"; then
                echo -e "${C_MAIN}${C_BOLD} │    ${C_DIM}·${C_RESET} ${C_DIM}${_d} already installed${C_RESET}"
            else
                echo -e "${C_MAIN}${C_BOLD} │    ${C_DIM}·${C_RESET} ${C_YELLOW}install ${_d}${C_RESET}"
            fi
        done
    fi

    echo -e "${C_MAIN}${C_BOLD} │${C_RESET}"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo -e "${C_MAIN}${C_BOLD} ╰─ ${C_YELLOW}[dry run] No changes made.${C_RESET}\n"
        exit 0
    fi
    echo -ne "${C_MAIN}${C_BOLD} ╰─ ${C_YELLOW}Proceed? [Y/n]: ${C_RESET}"
    read -rp "" CONFIRM
    [[ "$CONFIRM" =~ ^[Nn]$ ]] && echo "" && exit 0
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
header

# ── Sudo cache ────────────────────────────────────────────────────────────────
info "Authentication..."
substep "Enter your sudo password once — cached for the full install"
if ! sudo -v; then
    error "Authentication failed. Exiting."
    exit 1
fi
success "Authenticated"

# ── Step 1: paru ─────────────────────────────────────────────────────────────
info "Checking AUR helper..."
if command -v paru &>/dev/null; then
    substep "paru already installed"
    success "AUR helper ready"
else
    substep "paru not found — installing..."
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

if ! sudo pacman -S --needed --noconfirm stow fzf &>/dev/null 2>&1; then
    error "Failed to install/update stow and fzf."
    exit 1
fi
success "Tools verified"

# ── Step 3: multi-select menu ─────────────────────────────────────────────────
info "Select configs to install..."
CONFIGS=(fastfetch ghostty kitty zsh protonvpn starship ulauncher)
declare -a SELECTED=()

if command -v fzf &>/dev/null; then
    echo ""
    mapfile -t SELECTED < <(
        printf '%s\n' "${CONFIGS[@]}" | \
        fzf --multi \
            --height=40% \
            --min-height=12 \
            --reverse \
            --border=rounded \
            --prompt="  " \
            --pointer="❯" \
            --marker="✔" \
            --color="prompt:#c0392b,pointer:#c0392b,marker:#a6e3a1,border:#91b1f0,header:#91b1f0" \
            --header=$'Enter=select  Ctrl-J=install  Ctrl-A=select all\n' \
            --bind='enter:toggle+down' \
            --bind='ctrl-j:accept' \
            --bind='ctrl-a:select-all'
    )
    echo ""
else
    substep "${C_DIM}fzf unavailable — using basic menu${C_RESET}"
    echo ""
    attempts=0
    while true; do
        echo -e "${C_MAIN}${C_BOLD} │  ${C_ACCENT}1 ${C_DIM}❯ ${C_RESET}fastfetch"
        echo -e "${C_MAIN}${C_BOLD} │  ${C_ACCENT}2 ${C_DIM}❯ ${C_RESET}ghostty"
        echo -e "${C_MAIN}${C_BOLD} │  ${C_ACCENT}3 ${C_DIM}❯ ${C_RESET}kitty"
        echo -e "${C_MAIN}${C_BOLD} │  ${C_ACCENT}4 ${C_DIM}❯ ${C_RESET}zsh"
        echo -e "${C_MAIN}${C_BOLD} │  ${C_ACCENT}5 ${C_DIM}❯ ${C_RESET}protonvpn"
        echo -e "${C_MAIN}${C_BOLD} │  ${C_ACCENT}6 ${C_DIM}❯ ${C_RESET}starship"
        echo -e "${C_MAIN}${C_BOLD} │  ${C_ACCENT}7 ${C_DIM}❯ ${C_RESET}ulauncher"
        echo -e "${C_MAIN}${C_BOLD} │  ${C_ACCENT}a ${C_DIM}❯ ${C_RESET}Select All"
        echo -ne "${C_MAIN}${C_BOLD} ╰─ ${C_YELLOW}Choice (e.g. 1 4 or a): ${C_RESET}"
        read -rp "" RAW

        if [[ "$RAW" == "a" || "$RAW" == "A" ]]; then
            SELECTED=("${CONFIGS[@]}")
            break
        fi

        valid=true
        tmp=()
        for token in $RAW; do
            case "$token" in
                1) tmp+=(fastfetch)  ;;
                2) tmp+=(ghostty)    ;;
                3) tmp+=(kitty)      ;;
                4) tmp+=(zsh)        ;;
                5) tmp+=(protonvpn)  ;;
                6) tmp+=(starship)   ;;
                7) tmp+=(ulauncher)  ;;
                *) valid=false; break ;;
            esac
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
        error "Invalid input — enter numbers 1–6 separated by spaces, or 'a' for all"
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
    mapfile -t DEPS < <(
        printf '%s\n' "${DEPS_LIST[@]}" | \
        fzf --multi \
            --height=35% \
            --min-height=12 \
            --reverse \
            --border=rounded \
            --prompt="  " \
            --pointer="❯" \
            --marker="✔" \
            --color="prompt:#c0392b,pointer:#c0392b,marker:#a6e3a1,border:#91b1f0,header:#91b1f0" \
            --header=$'Enter=select  Ctrl-J=confirm  Ctrl-A=all  Esc=skip\n' \
            --bind='enter:toggle+down' \
            --bind='ctrl-j:accept' \
            --bind='ctrl-a:select-all'
    )
else
    echo -e "${C_MAIN}${C_BOLD} │  ${C_ACCENT}1 ${C_DIM}❯ ${C_RESET}bat     ${C_DIM}(cat alias, Catppuccin theme)${C_RESET}"
    echo -e "${C_MAIN}${C_BOLD} │  ${C_ACCENT}2 ${C_DIM}❯ ${C_RESET}eza     ${C_DIM}(ls ll lt la)${C_RESET}"
    echo -e "${C_MAIN}${C_BOLD} │  ${C_ACCENT}3 ${C_DIM}❯ ${C_RESET}fd      ${C_DIM}(fzf file search)${C_RESET}"
    echo -e "${C_MAIN}${C_BOLD} │  ${C_ACCENT}4 ${C_DIM}❯ ${C_RESET}zoxide  ${C_DIM}(z smart cd)${C_RESET}"
    echo -e "${C_MAIN}${C_BOLD} │  ${C_ACCENT}5 ${C_DIM}❯ ${C_RESET}thefuck ${C_DIM}(fuck command)${C_RESET}"
    echo -e "${C_MAIN}${C_BOLD} │  ${C_ACCENT}6 ${C_DIM}❯ ${C_RESET}lazygit ${C_DIM}(lg alias)${C_RESET}"
    echo -e "${C_MAIN}${C_BOLD} │  ${C_ACCENT}7 ${C_DIM}❯ ${C_RESET}btop    ${C_DIM}(resource monitor, Catppuccin theme)${C_RESET}"
    echo -e "${C_MAIN}${C_BOLD} │  ${C_ACCENT}8 ${C_DIM}❯ ${C_RESET}tree    ${C_DIM}(directory tree listing)${C_RESET}"
    echo -e "${C_MAIN}${C_BOLD} │  ${C_ACCENT}a ${C_DIM}❯ ${C_RESET}All    ${C_DIM}· Enter to skip${C_RESET}"
    echo -ne "${C_MAIN}${C_BOLD} ╰─ ${C_YELLOW}Choice (e.g. 1 2 or a, Enter=skip): ${C_RESET}"
    read -rp "" DEP_RAW
    if [[ "$DEP_RAW" == "a" || "$DEP_RAW" == "A" ]]; then
        DEPS=("${DEPS_LIST[@]}")
    elif [[ -n "$DEP_RAW" ]]; then
        for token in $DEP_RAW; do
            case "$token" in
                1) DEPS+=(bat)      ;;
                2) DEPS+=(eza)      ;;
                3) DEPS+=(fd)       ;;
                4) DEPS+=(zoxide)   ;;
                5) DEPS+=(thefuck)  ;;
                6) DEPS+=(lazygit)  ;;
                7) DEPS+=(btop)     ;;
                8) DEPS+=(tree)     ;;
            esac
        done
    fi
fi

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
        dep_pkg="${DEP_PKG[$dep]}"
        if pkg_installed "$dep_pkg"; then
            substep "${C_ACCENT}${dep}${C_RESET} ${C_DIM}already installed${C_RESET}"
        else
            substep "Installing ${C_ACCENT}${dep}${C_RESET}..."
            pacman_install "$dep_pkg" || error "Failed to install ${dep} — skipping"
        fi

        # Stow config for deps that have one
        for _dc in "${DEP_HAS_CONFIG[@]}"; do
            if [[ "$dep" == "$_dc" ]] && [ -d "$DOTFILES_DIR/$dep" ]; then
                backup_and_stow "$dep"
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

      # ── fastfetch / ghostty / kitty ──────────────────────────────────────
      fastfetch|ghostty|kitty)
        if pkg_installed "$pkg"; then
            substep "${C_ACCENT}${pkg}${C_RESET} already installed"
        else
            substep "Installing ${C_ACCENT}${pkg}${C_RESET}..."
            if ! pacman_install "$pkg"; then
                error "Failed to install ${C_ACCENT}${pkg}${C_RESET} — skipping ${cfg}"
                FAILED+=("$cfg")
                continue
            fi
        fi

        if [ "$FONT_DONE" -eq 0 ] && needs_font "$cfg"; then
            if ! pkg_installed "$FONT_PKG"; then
                substep "Installing ${C_ACCENT}JetBrainsMono Nerd Font${C_RESET}..."
                pacman_install "$FONT_PKG" || error "Failed to install font — continuing"
            fi
            substep "Rebuilding font cache..."
            fc-cache -fv &>/dev/null 2>&1 || true
            FONT_DONE=1
        fi

        if ! backup_and_stow "$cfg"; then
            FAILED+=("$cfg")
            continue
        fi

        if [ "$STOWED_WALLPAPER" -eq 0 ] && needs_font "$cfg"; then
            if [ -d "$DOTFILES_DIR/wallpapers" ]; then
                backup_and_stow "wallpapers"
                STOWED_WALLPAPER=1
            fi
        fi
        ;;

      # ── zsh ──────────────────────────────────────────────────────────────
      zsh)
        if pkg_installed zsh; then
            substep "${C_ACCENT}zsh${C_RESET} already installed"
        else
            substep "Installing ${C_ACCENT}zsh${C_RESET}..."
            if ! pacman_install zsh; then
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
            if chsh -s "$zsh_path"; then
                substep "${C_GREEN}Default shell changed — log out and back in to apply${C_RESET}"
            else
                error "chsh failed — change shell manually: chsh -s $zsh_path"
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
            if ! pacman_install proton-vpn-cli; then
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
            if ! pacman_install starship; then
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

      # ── ulauncher ────────────────────────────────────────────────────────
      ulauncher)
        if pkg_installed ulauncher; then
            substep "${C_ACCENT}ulauncher${C_RESET} already installed"
        else
            substep "Installing ${C_ACCENT}ulauncher${C_RESET} via paru (AUR)..."
            if ! paru_install ulauncher; then
                error "Failed to install ulauncher — skipping"
                FAILED+=(ulauncher)
                continue
            fi
        fi

        # Stow directly into ~/.config/ulauncher (package has flat structure, no subdir)
        ul_target="$HOME/.config/ulauncher"
        ul_bak="${ul_target}.bak"
        ul_oldbak="${ul_target}.old.bak"
        if [ -L "$ul_target" ]; then
            stow --target "$ul_target" --dir "$DOTFILES_DIR" -D "ulauncher" &>/dev/null 2>&1 || rm "$ul_target"
        elif [ -e "$ul_target" ]; then
            if [ -e "$ul_bak" ]; then
                [ -e "$ul_oldbak" ] && rm -rf "$ul_oldbak"
                mv "$ul_bak" "$ul_oldbak"
                substep "Rotated ${C_DIM}ulauncher.bak → ulauncher.old.bak${C_RESET}"
            fi
            mv "$ul_target" "$ul_bak"
            substep "Backed up ${C_ACCENT}ulauncher${C_RESET} → ${C_DIM}ulauncher.bak${C_RESET}"
        fi
        if ! stow_to "$ul_target" "ulauncher"; then
            FAILED+=(ulauncher)
            continue
        fi
        unset ul_target ul_bak ul_oldbak

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
