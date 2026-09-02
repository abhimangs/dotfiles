#!/usr/bin/env bash
set -eu

REPO=https://github.com/abhimangs/dotfiles.git

# set -eu catches HOME being unset, but not HOME being set and empty — and an
# empty one makes DIR "/dotfiles", pointing the rm and mv below at the root of
# the filesystem. This script runs unattended through curl | bash, so there is
# no prompt in front of them.
if [ -z "${HOME:-}" ] || [ ! -d "$HOME" ]; then
    echo "HOME is not set to a usable directory — refusing to run." >&2
    exit 1
fi
DIR="$HOME/dotfiles"

if ! command -v git >/dev/null 2>&1; then
    if [ "$(id -u)" -eq 0 ]; then SUDO=; else SUDO=sudo; fi
    if command -v pacman >/dev/null 2>&1; then
        $SUDO pacman -Sy --needed --noconfirm git
    else
        $SUDO apt-get update -qq || true
        $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 \
            apt-get -o DPkg::Lock::Timeout=600 install -y git
    fi
fi

if [ -e "$DIR" ] || [ -L "$DIR" ]; then
    # Two generations, matching install.sh's own convention. This used to keep
    # one: running the documented curl one-liner twice destroyed whatever the
    # first run had saved, with no prompt and no warning.
    if [ -e "$DIR.bak" ] || [ -L "$DIR.bak" ]; then
        rm -rf "$DIR.old.bak"
        mv "$DIR.bak" "$DIR.old.bak"
        echo "Rotated ~/dotfiles.bak to ~/dotfiles.old.bak"
    fi
    mv "$DIR" "$DIR.bak"
    echo "Moved existing ~/dotfiles to ~/dotfiles.bak"
fi

git clone "$REPO" "$DIR"
cd "$DIR"
exec bash install.sh "$@"
