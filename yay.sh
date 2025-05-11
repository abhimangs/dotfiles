#!/bin/sh

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# If yay is installed, exit
if command_exists yay; then
    echo "yay is already installed."
    exit 0
fi

echo "yay is not installed. Installing yay..."

# Install required packages
sudo pacman -Sy --needed --noconfirm base-devel git

# Remove conflicting debug package if it exists
if pacman -Qq | grep -qw yay-debug; then
    echo "Removing conflicting package: yay-debug"
    sudo pacman -Rns --noconfirm yay-debug
fi

# Set working directory
WORKDIR="/opt/yay-git"

# If repo exists, reset it cleanly; else clone it
if [ -d "$WORKDIR" ]; then
    echo "Found existing $WORKDIR, resetting..."
    sudo chown -R "$USER:$USER" "$WORKDIR"
    cd "$WORKDIR" || exit 1
    git reset --hard
    git clean -fd
    git pull
else
    echo "Cloning yay AUR repo..."
    cd /opt || exit 1
    sudo git clone https://aur.archlinux.org/yay-git.git
    sudo chown -R "$USER:$USER" yay-git
    cd yay-git || exit 1
fi

# Build and install yay
makepkg --noconfirm -si

# Verify
if command_exists yay; then
    echo "✅ yay installed successfully!"
else
    echo "❌ Failed to install yay."
    exit 1
fi
