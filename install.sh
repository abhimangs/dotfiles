#!/usr/bin/env bash

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

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

# ── Backup + stow a config ────────────────────────────────────────────────────
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

    if ! stow --target "$HOME/.config" --dir "$DOTFILES_DIR" "$name" &>/dev/null 2>&1; then
        error "Stow failed for ${C_ACCENT}${name}${C_RESET} — check for conflicts in ~/.config/${name}"
        return 1
    fi
    return 0
}

# ── App + package mapping ─────────────────────────────────────────────────────
declare -A PKG_MAP
PKG_MAP[fastfetch]="fastfetch"
PKG_MAP[ghostty]="ghostty"
PKG_MAP[kitty]="kitty"

FONT_PKG="ttf-jetbrains-mono-nerd"
NEEDS_FONT=(ghostty kitty)

# ─────────────────────────────────────────────────────────────────────────────
header

# ── Step 1: paru ─────────────────────────────────────────────────────────────
info "Checking AUR helper..."
if command -v paru &>/dev/null; then
    substep "paru already installed"
    success "AUR helper ready"
else
    substep "paru not found — installing..."
    substep "Installing build dependencies..."
    if ! sudo pacman -S --needed --noconfirm base-devel git &>/dev/null 2>&1; then
        error "Failed to install base-devel/git. Check your internet or sudo access."
        exit 1
    fi

    substep "Cloning paru from AUR..."
    rm -rf /tmp/paru-build
    if ! git clone https://aur.archlinux.org/paru.git /tmp/paru-build &>/dev/null 2>&1; then
        error "Failed to clone paru. Check your internet connection."
        exit 1
    fi

    substep "Building and installing paru (this may take a minute)..."
    if ! (cd /tmp/paru-build && makepkg -si --noconfirm &>/dev/null 2>&1); then
        error "paru build failed. Check /tmp/paru-build for details."
        exit 1
    fi

    rm -rf /tmp/paru-build

    if ! command -v paru &>/dev/null; then
        error "paru installation failed — binary not found after build."
        exit 1
    fi
    success "paru installed"
fi

# ── Step 2: stow ─────────────────────────────────────────────────────────────
info "Checking stow..."
if ! command -v stow &>/dev/null; then
    substep "Installing stow..."
    if ! pacman_install stow; then
        error "Failed to install stow."
        exit 1
    fi
fi
substep "stow ready"
success "Dependencies verified"

# ── Step 3: multi-select menu ─────────────────────────────────────────────────
info "Select configs to install..."
CONFIGS=(fastfetch ghostty kitty)
declare -a SELECTED=()

if command -v fzf &>/dev/null; then
    substep "Use ${C_ACCENT}Tab${C_RESET} to toggle, ${C_ACCENT}Enter${C_RESET} to confirm, ${C_ACCENT}Ctrl-a${C_RESET} to select all"
    echo ""
    mapfile -t SELECTED < <(
        printf '%s\n' "${CONFIGS[@]}" | \
        fzf --multi \
            --height=8 \
            --reverse \
            --border=rounded \
            --prompt="  " \
            --pointer="❯" \
            --marker="✔" \
            --color="prompt:#c0392b,pointer:#c0392b,marker:#a6e3a1,border:#91b1f0" \
            --header="Tab=toggle  Enter=confirm  Ctrl-a=select all" \
            --bind='ctrl-a:select-all'
    )
    echo ""
else
    substep "${C_DIM}fzf not found — using basic menu${C_RESET}"
    echo ""
    attempts=0
    while true; do
        echo -e "${C_MAIN}${C_BOLD} │  ${C_ACCENT}1 ${C_DIM}❯ ${C_RESET}fastfetch"
        echo -e "${C_MAIN}${C_BOLD} │  ${C_ACCENT}2 ${C_DIM}❯ ${C_RESET}ghostty"
        echo -e "${C_MAIN}${C_BOLD} │  ${C_ACCENT}3 ${C_DIM}❯ ${C_RESET}kitty"
        echo -e "${C_MAIN}${C_BOLD} │  ${C_ACCENT}a ${C_DIM}❯ ${C_RESET}Select All"
        echo -ne "${C_MAIN}${C_BOLD} ╰─ ${C_YELLOW}Choice (e.g. 1 3 or a): ${C_RESET}"
        read -rp "" RAW

        if [[ "$RAW" == "a" || "$RAW" == "A" ]]; then
            SELECTED=("${CONFIGS[@]}")
            break
        fi

        valid=true
        declare -a tmp=()
        for token in $RAW; do
            case "$token" in
                1) tmp+=(fastfetch) ;;
                2) tmp+=(ghostty)   ;;
                3) tmp+=(kitty)     ;;
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
        error "Invalid input — enter numbers 1–3 separated by spaces, or 'a' for all"
        echo ""
    done
fi

if [ "${#SELECTED[@]}" -eq 0 ]; then
    error "Nothing selected. Exiting."
    exit 0
fi

# ── Step 4: install selected configs ─────────────────────────────────────────
FONT_DONE=0
STOWED_WALLPAPER=0
INSTALLED=()
FAILED=()

for cfg in "${SELECTED[@]}"; do
    info "Installing ${C_ACCENT}${cfg}${C_RESET}..."
    pkg="${PKG_MAP[$cfg]}"

    # 4a — app package
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

    # 4b — font (once, only for ghostty/kitty)
    if [ "$FONT_DONE" -eq 0 ]; then
        for needs in "${NEEDS_FONT[@]}"; do
            if [[ "$cfg" == "$needs" ]]; then
                if ! pkg_installed "$FONT_PKG"; then
                    substep "Installing ${C_ACCENT}JetBrainsMono Nerd Font${C_RESET}..."
                    if ! pacman_install "$FONT_PKG"; then
                        error "Failed to install font — continuing without it"
                    fi
                fi
                FONT_DONE=1
                break
            fi
        done
    fi

    # 4c+d — backup existing config and stow
    if ! backup_and_stow "$cfg"; then
        FAILED+=("$cfg")
        continue
    fi

    # 4e — stow wallpapers once (needed by ghostty/kitty)
    if [ "$STOWED_WALLPAPER" -eq 0 ]; then
        for needs in "${NEEDS_FONT[@]}"; do
            if [[ "$cfg" == "$needs" ]]; then
                if [ -d "$DOTFILES_DIR/wallpapers" ]; then
                    backup_and_stow "wallpapers" >/dev/null 2>&1 || true
                    STOWED_WALLPAPER=1
                fi
                break
            fi
        done
    fi

    success "${C_ACCENT}${cfg}${C_RESET} installed"
    INSTALLED+=("$cfg")
done

# ── Step 5: summary ───────────────────────────────────────────────────────────
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
