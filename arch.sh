#!/usr/bin/env bash
# Bootstrap script — clone dotfiles and run the installer on a fresh Arch Linux system.
# Usage: bash arch.sh          — fresh clone + install
#        bash arch.sh --pull   — update existing ~/dotfiles then run install
#        curl -fsSL https://raw.githubusercontent.com/abhimangs/dotfiles/main/arch.sh | sh

set -uo pipefail

REPO_URL="https://github.com/abhimangs/dotfiles.git"
DOTFILES_DIR="$HOME/dotfiles"

DO_PULL=0
for _arg in "$@"; do [[ "$_arg" == "--pull" ]] && DO_PULL=1; done
unset _arg

# ── Palette (Catppuccin Mocha) ────────────────────────────────────────────────
C_MAUVE='\033[38;2;202;158;230m'    # mauve
C_BLUE='\033[38;2;140;170;238m'     # blue
C_LAVENDER='\033[38;2;186;187;241m' # lavender
C_GREEN='\033[38;2;166;209;137m'    # green
C_YELLOW='\033[38;2;229;200;144m'   # yellow
C_RED='\033[38;2;231;130;132m'      # red
C_PEACH='\033[38;2;239;159;118m'    # peach
C_DIM='\033[38;2;129;122;150m'      # overlay1
C_SURFACE='\033[38;2;110;104;133m'  # surface2
C_BOLD='\033[1m'
C_RESET='\033[0m'

trap 'echo -ne "\033[0m"' EXIT

# ── UI helpers ────────────────────────────────────────────────────────────────
_banner() {
    clear
    echo
    echo -e "${C_MAUVE}${C_BOLD}  ╭─────────────────────────────────────────────────╮${C_RESET}"
    echo -e "${C_MAUVE}${C_BOLD}  │                                                 │${C_RESET}"
    echo -e "${C_MAUVE}${C_BOLD}  │   ${C_LAVENDER}  dotfiles${C_MAUVE} / ${C_BLUE}arch bootstrap${C_MAUVE}                    │${C_RESET}"
    echo -e "${C_MAUVE}${C_BOLD}  │                                                 │${C_RESET}"
    echo -e "${C_MAUVE}${C_BOLD}  │  ${C_DIM}Arch Linux · GNU Stow · Catppuccin Mocha${C_MAUVE}      │${C_RESET}"
    echo -e "${C_MAUVE}${C_BOLD}  │  ${C_DIM}github.com/abhimangs/dotfiles${C_MAUVE}                 │${C_RESET}"
    echo -e "${C_MAUVE}${C_BOLD}  │                                                 │${C_RESET}"
    echo -e "${C_MAUVE}${C_BOLD}  ╰─────────────────────────────────────────────────╯${C_RESET}"
    echo
}

_step() {
    local n="$1"; shift
    echo -e "${C_MAUVE}${C_BOLD}  ╭─ ${C_LAVENDER}Step ${n}${C_MAUVE} ─ ${C_RESET}${C_BOLD}$*${C_RESET}"
}
_sub()  { echo -e "${C_MAUVE}${C_BOLD}  │  ${C_DIM}❯${C_RESET}  $*"; }
_ok()   { echo -e "${C_MAUVE}${C_BOLD}  ╰─ ${C_GREEN}✔${C_RESET}  $*"; echo; }
_warn() { echo -e "${C_MAUVE}${C_BOLD}  ╰─ ${C_YELLOW}⚠${C_RESET}  $*"; echo; }
_die()  {
    echo -e "${C_MAUVE}${C_BOLD}  ╰─ ${C_RED}✘${C_RESET}  $*" >&2
    echo
    exit 1
}

_divider() {
    echo -e "  ${C_SURFACE}───────────────────────────────────────────────────${C_RESET}"
}

# ── Step 0: Arch check ────────────────────────────────────────────────────────
_banner

if [ ! -f /etc/arch-release ]; then
    echo -e "  ${C_RED}${C_BOLD}✘  Not running on Arch Linux.${C_RESET}"
    echo
    echo -e "  ${C_DIM}This script requires Arch Linux (checks /etc/arch-release).${C_RESET}"
    echo -e "  ${C_DIM}Use your distro's package manager to install the tools manually.${C_RESET}"
    echo
    exit 1
fi

echo -e "  ${C_DIM}Running on Arch Linux — proceeding.${C_RESET}"
echo
_divider
echo

# ── Step 1: Sudo cache ────────────────────────────────────────────────────────
_step 1 "Caching sudo credentials"
if ! sudo -v 2>/dev/null; then
    _die "sudo failed — ensure your user has sudo privileges."
fi
_ok "${C_DIM}sudo credentials cached${C_RESET}"

# ── Step 2: Ensure git is installed ──────────────────────────────────────────
_step 2 "Checking for git"

if command -v git &>/dev/null; then
    _ok "git ${C_DIM}$(git --version | awk '{print $3}')${C_RESET} already installed"
else
    _sub "Installing ${C_PEACH}git${C_RESET} via pacman..."
    if ! sudo pacman -S --needed --noconfirm git &>/dev/null 2>&1; then
        _die "Failed to install git — check pacman output and try again."
    fi
    _ok "${C_PEACH}git${C_RESET} installed"
fi

# ── Step 3: Get dotfiles (pull or clone) ──────────────────────────────────────
if [ "$DO_PULL" -eq 1 ] && [ -d "$DOTFILES_DIR/.git" ]; then
    _step 3 "Updating existing dotfiles (--pull)"
    _sub "git pull in ${C_BLUE}~/dotfiles${C_RESET}..."
    if ! git -C "$DOTFILES_DIR" pull 2>/tmp/arch_pull_err; then
        err=$(head -3 /tmp/arch_pull_err 2>/dev/null)
        _die "git pull failed.\n\n  ${C_DIM}${err}${C_RESET}"
    fi
    _ok "${C_BLUE}~/dotfiles${C_RESET} updated to latest"
else
    if [ "$DO_PULL" -eq 1 ]; then
        _warn "--pull specified but ${C_BLUE}~/dotfiles${C_RESET} is not a git repo — falling back to fresh clone"
    fi

    _step 3 "Backing up existing ~/dotfiles"

    if [ -L "$DOTFILES_DIR" ]; then
        _sub "Found symlink at ${C_BLUE}~/dotfiles${C_RESET} — removing..."
        rm "$DOTFILES_DIR"
        _ok "Symlink removed"
    elif [ -d "$DOTFILES_DIR" ] || [ -f "$DOTFILES_DIR" ]; then
        bak="${DOTFILES_DIR}.bak"
        oldbak="${DOTFILES_DIR}.old.bak"

        if [ -e "$oldbak" ] || [ -L "$oldbak" ]; then
            _sub "Removing stale ${C_DIM}dotfiles.old.bak${C_RESET}..."
            rm -rf "$oldbak"
        fi
        if [ -e "$bak" ] || [ -L "$bak" ]; then
            _sub "Rotating ${C_DIM}dotfiles.bak → dotfiles.old.bak${C_RESET}..."
            mv "$bak" "$oldbak"
        fi

        _sub "Moving ${C_BLUE}~/dotfiles${C_RESET} → ${C_DIM}dotfiles.bak${C_RESET}..."
        mv "$DOTFILES_DIR" "${DOTFILES_DIR}.bak"
        _ok "${C_BLUE}~/dotfiles${C_RESET} backed up to ${C_DIM}~/dotfiles.bak${C_RESET}"
    else
        _ok "No existing ${C_BLUE}~/dotfiles${C_RESET} — clean slate"
    fi

    _step 4 "Cloning dotfiles"
    _sub "${C_DIM}${REPO_URL}${C_RESET} → ${C_BLUE}~/dotfiles${C_RESET}"

    if ! git clone "$REPO_URL" "$DOTFILES_DIR" 2>/tmp/arch_clone_err; then
        err=$(head -3 /tmp/arch_clone_err 2>/dev/null)
        _die "git clone failed — check your internet connection.\n\n  ${C_DIM}${err}${C_RESET}"
    fi

    if [ ! -f "$DOTFILES_DIR/install.sh" ]; then
        _die "Cloned repo is missing install.sh — the clone may be corrupt."
    fi

    _ok "Cloned to ${C_BLUE}~/dotfiles${C_RESET}"
fi

# ── Step 5: Launch installer ──────────────────────────────────────────────────
_step 5 "Launching install.sh"

chmod a+x "$DOTFILES_DIR/install.sh"
_sub "chmod a+x install.sh"
_ok "Permissions set — handing off to installer"

_divider
echo
echo -e "${C_MAUVE}${C_BOLD}  Starting dotfiles installer...${C_RESET}"
echo

cd "$DOTFILES_DIR" || _die "Cannot enter ~/dotfiles — check permissions."
exec ./install.sh
