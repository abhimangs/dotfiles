#!/usr/bin/env bash

# ── Arch Linux check ──────────────────────────────────────────────────────────
if [ ! -f /etc/arch-release ]; then
    echo "This installer is for Arch Linux only." >&2
    exit 1
fi

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

    mkdir -p "$HOME/.config"
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

needs_font() {
    local cfg="$1"
    for n in "${NEEDS_FONT[@]}"; do [[ "$cfg" == "$n" ]] && return 0; done
    return 1
}

# ── Pre-install plan (shown after selection, before running) ──────────────────
show_plan() {
    local cfgs=("$@")
    local wallpaper_stowed=0

    echo -e "${C_MAIN}${C_BOLD} ╭─ 󰓅 Installation plan${C_RESET}"

    for cfg in "${cfgs[@]}"; do
        local pkg="${PKG_MAP[$cfg]}"
        local target="$HOME/.config/$cfg"
        local bak="${target}.bak"
        local oldbak="${target}.old.bak"
        local steps=()

        # package
        if pkg_installed "$pkg"; then
            steps+=("${C_DIM}$pkg already installed${C_RESET}")
        else
            steps+=("${C_YELLOW}install $pkg${C_RESET}")
        fi

        # font
        if needs_font "$cfg" && ! pkg_installed "$FONT_PKG"; then
            steps+=("${C_YELLOW}install JetBrainsMono Nerd Font${C_RESET}")
        fi

        # config backup
        if [ -L "$target" ]; then
            steps+=("${C_ACCENT}re-stow config${C_RESET} ${C_DIM}(unlink + relink)${C_RESET}")
        elif [ -e "$target" ]; then
            if [ -e "$bak" ]; then
                steps+=("${C_YELLOW}backup${C_RESET} ${C_DIM}$cfg.bak → $cfg.old.bak, $cfg → $cfg.bak${C_RESET}")
            else
                steps+=("${C_YELLOW}backup${C_RESET} ${C_DIM}$cfg → $cfg.bak${C_RESET}")
            fi
            steps+=("${C_GREEN}stow config${C_RESET}")
        else
            steps+=("${C_GREEN}stow config${C_RESET} ${C_DIM}(fresh)${C_RESET}")
        fi

        # wallpaper (once)
        if needs_font "$cfg" && [ "$wallpaper_stowed" -eq 0 ]; then
            local wp="$HOME/.config/wallpapers/Serene Japanese Landscape with Red Sun.jpg"
            if [ ! -f "$wp" ]; then
                steps+=("${C_GREEN}stow wallpapers${C_RESET}")
            else
                steps+=("${C_DIM}wallpaper already in place${C_RESET}")
            fi
            wallpaper_stowed=1
        fi

        echo -e "${C_MAIN}${C_BOLD} │${C_RESET}"
        echo -e "${C_MAIN}${C_BOLD} │  ${C_ACCENT}${C_BOLD}${cfg}${C_RESET}"
        for step in "${steps[@]}"; do
            echo -e "${C_MAIN}${C_BOLD} │    ${C_DIM}·${C_RESET} ${step}"
        done
    done

    echo -e "${C_MAIN}${C_BOLD} │${C_RESET}"
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

[ "${#TOOLS_TO_INSTALL[@]}" -gt 0 ] && substep "Installing:        ${C_ACCENT}${TOOLS_TO_INSTALL[*]}${C_RESET}"
[ "${#TOOLS_TO_UPDATE[@]}"  -gt 0 ] && substep "Updating to latest: ${C_ACCENT}${TOOLS_TO_UPDATE[*]}${C_RESET}"

if ! sudo pacman -S --needed --noconfirm stow fzf &>/dev/null 2>&1; then
    error "Failed to install/update stow and fzf."
    exit 1
fi
success "Tools verified"

# ── Step 3: multi-select menu ─────────────────────────────────────────────────
info "Select configs to install..."
CONFIGS=(fastfetch ghostty kitty)
declare -a SELECTED=()

if command -v fzf &>/dev/null; then
    echo ""

    # Preview script: runs per highlighted item, shows live status
    PREVIEW='
cfg="{}"
case "$cfg" in
  fastfetch) pkg="fastfetch" ; nf=0 ;;
  ghostty)   pkg="ghostty"   ; nf=1 ;;
  kitty)     pkg="kitty"     ; nf=1 ;;
  *)         pkg="$cfg"      ; nf=0 ;;
esac
P="\033[38;2;202;169;224m\033[1m"
A="\033[38;2;145;177;240m"
G="\033[38;2;166;209;137m"
R="\033[38;2;231;130;132m"
Y="\033[38;2;229;200;144m"
D="\033[38;2;129;122;150m"
X="\033[0m"
echo -e "${P}  Package${X}"
if pacman -Q "$pkg" &>/dev/null; then
  echo -e "  ${G}✔${X} ${A}$pkg${X} ${D}already installed${X}"
else
  echo -e "  ${Y}→${X} ${A}$pkg${X} ${D}will be installed${X}"
fi
echo ""
echo -e "${P}  Config${X}"
target="$HOME/.config/$cfg"
bak="${target}.bak"
if [ -L "$target" ]; then
  echo -e "  ${A}~${X} already stowed ${D}(will re-stow)${X}"
elif [ -d "$target" ] || [ -f "$target" ]; then
  if [ -e "$bak" ]; then
    echo -e "  ${Y}→${X} ${D}$cfg.bak → $cfg.old.bak${X}"
  fi
  echo -e "  ${Y}→${X} ${D}$cfg → $cfg.bak${X}"
  echo -e "  ${G}+${X} stow ${D}dotfiles/$cfg/${X}"
else
  echo -e "  ${G}+${X} fresh stow ${D}(no existing config)${X}"
fi
if [ "$nf" = "1" ]; then
  echo ""
  echo -e "${P}  Font${X}"
  if pacman -Q ttf-jetbrains-mono-nerd &>/dev/null; then
    echo -e "  ${G}✔${X} JetBrainsMono Nerd Font ${D}installed${X}"
  else
    echo -e "  ${Y}→${X} JetBrainsMono Nerd Font ${D}will be installed${X}"
  fi
  echo ""
  echo -e "${P}  Wallpaper${X}"
  wp="$HOME/.config/wallpapers/Serene Japanese Landscape with Red Sun.jpg"
  if [ -f "$wp" ]; then
    echo -e "  ${G}✔${X} wallpaper already in place"
  else
    echo -e "  ${Y}→${X} stow ${D}dotfiles/wallpapers/${X}"
  fi
fi
'

    mapfile -t SELECTED < <(
        printf '%s\n' "${CONFIGS[@]}" | \
        fzf --multi \
            --height=70% \
            --min-height=16 \
            --reverse \
            --border=rounded \
            --prompt="  " \
            --pointer="❯" \
            --marker="✔" \
            --color="prompt:#c0392b,pointer:#c0392b,marker:#a6e3a1,border:#91b1f0,header:#91b1f0,preview-border:#91b1f0" \
            --header=$'Enter=select  Ctrl-J=install  Ctrl-A=select all\n' \
            --bind='enter:toggle+down' \
            --bind='ctrl-j:accept' \
            --bind='ctrl-a:select-all' \
            --preview="$PREVIEW" \
            --preview-window='right:45%:wrap:border-left'
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

# ── Step 4: show plan + confirm ───────────────────────────────────────────────
show_plan "${SELECTED[@]}"

# ── Step 5: install selected configs ─────────────────────────────────────────
FONT_DONE=0
STOWED_WALLPAPER=0
INSTALLED=()
FAILED=()

for cfg in "${SELECTED[@]}"; do
    info "Installing ${C_ACCENT}${cfg}${C_RESET}..."
    pkg="${PKG_MAP[$cfg]}"

    # package
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

    # font (once, ghostty/kitty only)
    if [ "$FONT_DONE" -eq 0 ] && needs_font "$cfg"; then
        if ! pkg_installed "$FONT_PKG"; then
            substep "Installing ${C_ACCENT}JetBrainsMono Nerd Font${C_RESET}..."
            if ! pacman_install "$FONT_PKG"; then
                error "Failed to install font — continuing without it"
            fi
        fi
        FONT_DONE=1
    fi

    # backup + stow config
    if ! backup_and_stow "$cfg"; then
        FAILED+=("$cfg")
        continue
    fi

    # stow wallpapers (once, ghostty/kitty only)
    if [ "$STOWED_WALLPAPER" -eq 0 ] && needs_font "$cfg"; then
        if [ -d "$DOTFILES_DIR/wallpapers" ]; then
            backup_and_stow "wallpapers"
            STOWED_WALLPAPER=1
        fi
    fi

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
