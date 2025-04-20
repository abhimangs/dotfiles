#!/bin/bash

# Define script paths
script_dir="$HOME/dotfiles/scripts"

declare -A options=(
    ["1"]="All"
    ["2"]="Bash"
    ["3"]="Fastfetch"
    ["4"]="Ghostty"
    ["5"]="KDE Keybinds"
    ["6"]="Neofetch"
    ["7"]="Pacman"
    ["8"]="Rofi"
    ["9"]="Ulauncher"
    ["10"]="Wallpaper"
    ["11"]="Exit"
)

declare -A scripts=(
    ["2"]="$script_dir/bash.sh"
    ["3"]="$script_dir/fastfetch.sh"
    ["4"]="$script_dir/ghostty.sh"
    ["5"]="$script_dir/kde-keybinds.sh"
    ["6"]="$script_dir/neofetch.sh"
    ["7"]="$script_dir/pacman.sh"
    ["8"]="$script_dir/rofi.sh"
    ["9"]="$script_dir/ulauncher.sh"
    ["10"]="$script_dir/wallpaper.sh"
)

# Display menu in sorted order
echo "                                  "
echo "=================================="
echo "  🔧 Dotfiles Configuration Menu  "
echo "=================================="
echo "                                  "
for key in $(printf "%s\n" "${!options[@]}" | sort -n); do
    echo "$key) ${options[$key]}"
done
echo "                                  "
echo "=================================="
echo "                                  "

# Get user input (multiple selections)
read -p "Enter numbers (e.g., 2 5 9): " -a choices

# Process selections
for choice in "${choices[@]}"; do
    if [[ -n "${options[$choice]}" ]]; then
        if [[ "$choice" == "11" ]]; then
            echo "Exiting..."
            exit 0
        fi
        if [[ "$choice" == "1" ]]; then
            "$script_dir/alacritty.sh"
            "$script_dir/bash.sh"
            "$script_dir/fastfetch.sh"
            "$script_dir/ghostty.sh"
            "$script_dir/kde-keybinds.sh"
            "$script_dir/neofetch.sh"
            "$script_dir/pacman.sh"
            "$script_dir/rofi.sh"
            "$script_dir/ulauncher.sh"
            "$script_dir/wallpaper.sh"
            exit 0
        fi
        if [[ -x "${scripts[$choice]}" ]]; then
            echo "Running ${options[$choice]}..."
            bash "${scripts[$choice]}"
        else
            echo "Error: Script for ${options[$choice]} not found or not executable!"
        fi
    else
        echo "Invalid option: $choice"
    fi
done