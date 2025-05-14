#!/bin/bash

# Set a very dark black theme for whiptail with a white square border
export NEWT_COLORS='
root=white,black
window=white,black
border=white,black
listbox=white,black
label=white,black
checkbox=green,black
title=white,black
button=black,green
actlistbox=green,black
shadow=black,black
'

# Function to check for errors and exit if something fails
check() {
    exit_code=$1
    message=$2
    if [ "$exit_code" -ne 0 ]; then
        echo -e "\033[0;31mERROR: $message\033[0m"
        exit 1
    fi
    unset exit_code
    unset message
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if yay is installed
if command_exists yay; then
    echo "yay is already installed. Proceeding to software selection..."
else
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
fi

# Ensure the system has whiptail installed (simulated)
if ! command -v whiptail >/dev/null; then
    echo -e "\033[0;32mWould install whiptail...\033[0m"
fi

# Use whiptail to create a checkbox menu for software selection
OPTIONS=$(whiptail --title "Abhiman's Dotfiles" --checklist \
"Choose the software to install (space to select, Enter to confirm):" 18 65 5 \
"Fastfetch" "" OFF \
"Ghostty" "" OFF \
"Kitty" "" OFF \
"NeoVim" "" OFF \
"Rofi" "" OFF \
"ULauncher" "" OFF \
"Pacman" "" OFF 3>&1 1>&2 2>&3)

# Check if the user pressed Cancel (exit status 1) or OK (exit status 0)
check $? "You canceled the selection. Exiting..."

# Convert the space-separated output into an array
IFS=' ' read -r -a SELECTED <<< "$OPTIONS"

# Remove quotes from each element in the array
for i in "${!SELECTED[@]}"; do
    SELECTED[$i]=${SELECTED[$i]//\"}
done

# Check if no options were selected
if [ ${#SELECTED[@]} -eq 0 ]; then
    echo -e "\033[0;31mNo options selected. Exiting...\033[0m"
    exit 1
fi

# Echo only the application names
echo -e "\033[1;33mThe following software would be installed:\033[0m"
for OPTION in "${SELECTED[@]}"; do
    case $OPTION in
        "Fastfetch")
            echo -e "\033[0;32m- fastfetch\033[0m"
            # Add your code here to execute when Fastfetch is selected (e.g., installation commands)
            ;;
        "Ghostty")
            echo -e "\033[0;32m- ghostty\033[0m"
            # Add your code here to execute when Ghostty is selected (e.g., installation commands)
            ;;
        "Kitty")
            echo -e "\033[0;32m- kitty\033[0m"
            # Add your code here to execute when Kitty is selected (e.g., installation commands)
            ;;
        "NeoVim")
            echo -e "\033[0;32m- neovim\033[0m"
            # Add your code here to execute when NeoVim is selected (e.g., installation commands)
            ;;
        "Rofi")
            echo -e "\033[0;32m- rofi\033[0m"
            # Add your code here to execute when Rofi is selected (e.g., installation commands)
            ;;
        "ULauncher")
            echo -e "\033[0;32m- ulauncher\033[0m"
            # Add your code here to execute when ULauncher is selected (e.g., installation commands)
            ;;
        "Pacman")
            echo -e "\033[0;32m- pacman\033[0m"
            # Add your code here to execute when Pacman is selected (e.g., installation commands)
            ;;
        *)
            echo -e "\033[0;31m- Unknown option: $OPTION\033[0m"
            ;;
    esac
done

echo -e "\033[0;32mInstallation simulation complete.\033[0m"