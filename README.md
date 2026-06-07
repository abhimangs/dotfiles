# dotfiles

Arch Linux dotfiles managed with [GNU Stow](https://www.gnu.org/software/stow/). Each top-level folder mirrors the path relative to its stow target so files symlink directly into place.

## Quick start — fresh Arch install

```bash
curl -fsSL https://abhiman.io/arch.sh | sh
```

Or clone manually:

```bash
git clone https://github.com/abhimangs/dotfiles.git ~/dotfiles
cd ~/dotfiles
bash install.sh
```

## What's included

| Config | Stow target | Package |
|--------|------------|---------|
| `fastfetch/` | `~/.config/fastfetch/` | `fastfetch` |
| `ghostty/` | `~/.config/ghostty/` | `ghostty` |
| `kitty/` | `~/.config/kitty/` | `kitty` |
| `rofi/` | `~/.config/rofi/` | `rofi` |
| `starship/` | `~/.config/starship.toml` | `starship` |
| `ulauncher/` | `~/.config/ulauncher/` | `ulauncher` *(AUR)* |
| `bat/` | `~/.config/bat/` | `bat` *(dep)* |
| `btop/` | `~/.config/btop/` | `btop` *(dep)* |
| `wallpapers/` | `~/.config/wallpapers/` | — |
| `zsh/` | `~/.zshrc` | `zsh` |
| `proton-vpn/` | `~/scripts/pvpn/pvpn.zsh` | `proton-vpn-cli` |

## Installer features

- **fzf TUI** — multi-select configs with a live preview pane
- **Dep tools menu** — select bat, eza, fd, zoxide, thefuck, lazygit, btop, tree
- **App menu** — select apps to install: Brave Origin Beta/Stable, Visual Studio Code, Antigravity IDE, Claude Code CLI, Antigravity 2.0, Antigravity CLI, Codex CLI, Notion
- **Confirmation plan** — shows exactly what will be installed before proceeding
- **Backup rotation** — existing configs move to `.bak`, old `.bak` rotates to `.old.bak`
- **Idempotent** — safe to re-run; stow uses `-D` before re-stowing
- **paru** — installed automatically if missing (AUR helper)
- **chsh** — changes default shell to zsh when zsh is selected

## Theme

[Catppuccin Mocha](https://github.com/catppuccin/catppuccin) throughout: ghostty, kitty, starship, bat, btop.

Font: `ttf-jetbrains-mono-nerd` (auto-installed with ghostty, kitty, or rofi).

## Stow manually

```bash
# direct ~/.config/<name> targets (flat repo structure)
stow --target ~/.config/fastfetch  fastfetch
stow --target ~/.config/ghostty    ghostty
stow --target ~/.config/kitty      kitty
stow --target ~/.config/rofi       rofi
stow --target ~/.config/bat        bat
stow --target ~/.config/btop       btop
stow --target ~/.config/wallpapers wallpapers
stow --target ~/.config/ulauncher  ulauncher

# starship is a single file — stows directly into ~/.config/
stow --target ~/.config starship

# ~ target
stow --target ~ zsh

# custom target
stow --target ~/scripts/pvpn proton-vpn
```

## Kitty config

`kitty.conf` includes `custom.conf`. Theme colors live in `current-theme.conf` (Catppuccin Mocha). `session.conf` sets the startup state.

## Zsh plugins (via Zinit)

`zsh-autosuggestions`, `fast-syntax-highlighting`, `zsh-completions`, `zsh-you-should-use` — all self-installed on first shell launch.

Optional dep tools are guarded with `command -v` so the shell starts cleanly if any are missing.
