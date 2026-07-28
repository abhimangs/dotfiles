# dotfiles

Arch Linux, Debian, and Ubuntu dotfiles managed with [GNU Stow](https://www.gnu.org/software/stow/). Each top-level folder mirrors the path relative to its stow target so files symlink directly into place. Snap is never used — every install path goes through pacman/AUR, apt, an official vendor apt repo, or a direct upstream download.

## Quick start — fresh install

```bash
curl -fsSL https://abhiman.io/linux.sh | bash
```

Works on Arch Linux, Debian, and Ubuntu — the script detects your distro and hands off to `install.sh`. Every run backs up any existing `~/dotfiles` and replaces it with a fresh clone, so the checkout is always clean.

Or clone manually:

```bash
git clone https://github.com/abhimangs/dotfiles.git ~/dotfiles
cd ~/dotfiles
bash install.sh
```

### Flags

| Flag | Effect |
|------|--------|
| `--dry-run` | Walks the menus and prints the full plan, then exits without changing anything |
| `--gui` | Forces the desktop menus on a machine detected as headless (e.g. provisioning a box before its desktop environment is up) |

## What's included

| Config | Stow target | Arch package | Debian/Ubuntu |
|--------|------------|---------|---------|
| `fastfetch/` | `~/.config/fastfetch/` | `fastfetch` | apt / PPA / GitHub `.deb` |
| `ghostty/` | `~/.config/ghostty/` | `ghostty` | official install script |
| `kitty/` | `~/.config/kitty/` | `kitty` | apt |
| `rofi/` | `~/.config/rofi/` | `rofi` | **Arch only** — Debian/Ubuntu still ship the 1.7.x X11-only build |
| `starship/` | `~/.config/starship.toml` | `starship` | apt / official install script |
| `ulauncher/` | `~/.config/ulauncher/` | `ulauncher` *(AUR)* | PPA (Ubuntu) / GitHub `.deb` (Debian) |
| `bat/` | `~/.config/bat/` | `bat` *(dep)* | apt (`batcat`, shimmed to `bat`) |
| `btop/` | `~/.config/btop/` | `btop` *(dep)* | apt |
| `wallpapers/` | `~/.config/wallpapers/` | — | — |
| `zsh/` | `~/.zshrc` | `zsh` | apt |
| `git/` | `~/.gitconfig` | `git` | apt |
| `proton-vpn/` | `~/scripts/pvpn/pvpn.zsh` | `proton-vpn-cli` | official ProtonVPN apt repo |

## Installer features

- **fzf TUI** — multi-select configs with a live preview pane
- **Dep tools menu** — select bat, eza, fd, zoxide, thefuck, lazygit, btop, tree
- **App menu** — select apps to install: Brave Origin Beta/Stable, Visual Studio Code, Claude Desktop†, Antigravity IDE\*, Claude Code CLI, Antigravity 2.0\*, Antigravity CLI, Codex CLI, OpenCode, Kimi Code CLI, Notion\*, Obsidian\*, VLC, Flatpak (\*Arch only, †Debian/Ubuntu only — see below)
- **Confirmation plan** — shows exactly what will be installed before proceeding
- **Backup rotation** — existing configs move to `.bak`, old `.bak` rotates to `.old.bak`
- **Idempotent** — safe to re-run; stow uses `-D` before re-stowing, and tools installed outside the package manager (starship, lazygit, the CLI installers) are detected rather than reinstalled
- **paru** — installed automatically if missing on Arch (AUR helper)
- **Shell change** — switches the default shell to zsh when zsh is selected, falling back to `usermod` where `chsh` cannot authenticate
- **Headless aware** — on a machine with no display server, GUI configs and apps are hidden (see below)
- **Retries** — a stale pacman db / apt index is refreshed and the install retried instead of failing; GitHub release lookups fall back to the release page when the API rate-limits

### Arch-only items

`rofi` (Arch ships 2.0 with Wayland support merged in; Debian/Ubuntu are still on 1.7.x X11-only), `notion` (no official Linux build — only unofficial wrappers exist), `obsidian` (in Arch `extra`; on Debian/Ubuntu it ships only as a vendor `.deb`/AppImage with no apt repo), and the Antigravity desktop app / IDE (Google's Debian/Ubuntu packaging is still a moving target upstream) are only offered on Arch. `antigravity-cli` is available everywhere via its official install script.

### Debian/Ubuntu-only items

`claude-desktop` runs the other way around — Anthropic ships an official apt repo (`downloads.claude.ai/claude-desktop/apt/stable`, amd64 + arm64) but there is no Arch package, so it only appears in the app menu on Debian/Ubuntu. The installer adds the signing key and repo, then installs it via apt.

### Headless servers

The installer checks `DISPLAY`, `WAYLAND_DISPLAY`, the systemd default target and the installed session files. With no display server it drops the GUI entries from both menus — terminal emulators (`ghostty`, `kitty`), the launchers (`rofi`, `ulauncher`), and every GUI app (browsers, editors, Notion, Obsidian, Claude Desktop, VLC) — since none of them can run and each pulls in a large X/GTK dependency tree. What remains is the part that makes sense on a server: `zsh`, `starship`, `git`, `fastfetch`, `protonvpn`, the dep tools and the CLI agents.

Pass `--gui` to override the detection.

Shell changes work on cloud images too: `chsh` authenticates through PAM and refuses on accounts with no local password (SSH-key-only login), so the installer falls back to `usermod`.

## Theme

[Catppuccin Mocha](https://github.com/catppuccin/catppuccin) throughout: ghostty, kitty, starship, bat, btop.

Fonts (both auto-installed with ghostty, kitty, or rofi) — ghostty uses JetBrainsMono Nerd Font, kitty uses Maple Mono:

| Font | Arch | Debian/Ubuntu |
|------|------|---------------|
| JetBrainsMono Nerd Font | `ttf-jetbrains-mono-nerd` | [nerd-fonts](https://github.com/ryanoasis/nerd-fonts) release zip → `~/.local/share/fonts/JetBrainsMono/` |
| Maple Mono | `maplemono-ttf` *(AUR)* | [maple-font](https://github.com/subframe7536/maple-font) release zip → `~/.local/share/fonts/MapleMono/` |

Neither is packaged in apt, so on Debian/Ubuntu both are pulled straight from their GitHub releases (`fontconfig` is installed first if the image doesn't have it).

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
stow --target ~ git

# custom target
stow --target ~/scripts/pvpn proton-vpn
```

## Kitty config

`kitty.conf` includes `custom.conf`. Theme colors live in `current-theme.conf` (Catppuccin Mocha). `session.conf` sets the startup state.

## Zsh plugins (via Zinit)

`zsh-autosuggestions`, `fast-syntax-highlighting`, `zsh-completions`, `zsh-you-should-use` — all self-installed on first shell launch.

Optional dep tools are guarded with `command -v` so the shell starts cleanly if any are missing.
