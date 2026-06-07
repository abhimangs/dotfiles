# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commit behavior

- Always commit using: `git -c user.name="abhimangs" -c user.email="abhimangs23@gmail.com" commit`
- Never add a Claude co-author line to commit messages
- Auto-commit after every change without asking
- Push only when explicitly told to

## Repo overview

Dotfiles for an Arch Linux setup managed with GNU Stow. The repo root mirrors `~/.config` — each top-level folder (`fastfetch/`, `ghostty/`, `kitty/`, `wallpapers/`) maps directly to `~/.config/<folder>`.

## Installing configs

```bash
bash install.sh
```

The script handles: paru (AUR helper), stow, package installs, font dependency, config backup, and symlinking via stow. Run from the repo root.

## Stow manually

```bash
# From the repo root — installs one config
stow --target ~/.config fastfetch
stow --target ~/.config ghostty
stow --target ~/.config kitty
stow --target ~/.config wallpapers
```

## Config layout

| Folder | Maps to | App package |
|--------|---------|-------------|
| `fastfetch/` | `~/.config/fastfetch/` | `fastfetch` |
| `ghostty/` | `~/.config/ghostty/` | `ghostty` |
| `kitty/` | `~/.config/kitty/` | `kitty` |
| `wallpapers/` | `~/.config/wallpapers/` | — |

Font dependency: `ttf-jetbrains-mono-nerd` (required by ghostty and kitty).

## Wallpaper path

Both ghostty and kitty reference:
```
~/.config/wallpapers/Serene Japanese Landscape with Red Sun.jpg
```
This resolves once `wallpapers/` is stowed. Never use an absolute `/home/abhi/...` path — it breaks portability.

## Kitty config structure

Kitty loads `kitty.conf` first, which includes `custom.conf` at the bottom. Theme colors live in `current-theme.conf` (Catppuccin Mocha). `session.conf` sets the startup window state.

## Backup convention

`install.sh` backs up existing configs as `.bak`. If `.bak` already exists it is renamed to `.old.bak` first (`.old.bak` is deleted if it exists). Never touches anything inside the config folder — only the folder itself is moved.
