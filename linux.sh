#!/usr/bin/env bash
set -eu

REPO=https://github.com/abhimangs/dotfiles.git
DIR="$HOME/dotfiles"

if ! command -v git >/dev/null 2>&1; then
    if [ "$(id -u)" -eq 0 ]; then SUDO=; else SUDO=sudo; fi
    if command -v pacman >/dev/null 2>&1; then
        $SUDO pacman -Sy --needed --noconfirm git
    else
        $SUDO apt-get update -qq || true
        $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 \
            apt-get install -y git
    fi
fi

if [ -e "$DIR" ] || [ -L "$DIR" ]; then
    rm -rf "$DIR.bak"
    mv "$DIR" "$DIR.bak"
    echo "Moved existing ~/dotfiles to ~/dotfiles.bak"
fi

git clone "$REPO" "$DIR"
cd "$DIR"
exec bash install.sh "$@"
