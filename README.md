# dotfiles

Arch Linux, Debian, and Ubuntu dotfiles managed with [GNU Stow](https://www.gnu.org/software/stow/). Each top-level folder mirrors the path relative to its stow target so files symlink directly into place. Snap is never used — every install path goes through pacman/AUR, apt, an official vendor apt repo, or a direct upstream download.

## Quick start — fresh install

```bash
curl -fsSL https://abhiman.io/linux.sh | bash
```

Works on Arch Linux, Debian, and Ubuntu — the script detects your distro and hands off to `install.sh`. Every run backs up any existing `~/dotfiles` and replaces it with a fresh clone, so the checkout is always clean.

> **One caveat on root-only images.** `linux.sh` caches sudo credentials as its first step and stops if `sudo` is missing — which is the case on many minimal root VPS images. `install.sh` itself runs fine as root without sudo, so on such a machine either install sudo first (`apt install sudo`) or skip the bootstrap and clone manually as shown below.

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
| `--ascii` | Plain ASCII instead of box-drawing and Nerd Font glyphs |
| `--no-color` | No ANSI colour (`NO_COLOR` in the environment does the same) |

Each flag has an environment equivalent — `DOTFILES_DRY_RUN`, `DOTFILES_GUI`, `DOTFILES_ASCII`, `DOTFILES_NO_COLOR` — because the bootstrap ends in `exec ./install.sh` with no arguments, so flags cannot reach it through the curl path but the environment can:

```bash
DOTFILES_DRY_RUN=1 curl -fsSL https://abhiman.io/linux.sh | bash
```

Colour and glyphs are also dropped automatically where they cannot render: `TERM=dumb`/`linux`/`vt*`, a non-UTF-8 locale, or output that is not a terminal. That is what makes the installer readable over a plain SSH session or on a VT console.

Run it as your own user (`bash install.sh`) or as root — not with `sudo`; see [Running as root](#running-as-root-or-as-a-sudo-user) below.

## What's included

| Config | Stow target | Arch package | Debian/Ubuntu |
|--------|------------|---------|---------|
| `fastfetch/` | `~/.config/fastfetch/` | `fastfetch` | apt / PPA / GitHub `.deb` |
| `ghostty/` | `~/.config/ghostty/` | `ghostty` | official install script |
| `kitty/` | `~/.config/kitty/` | `kitty` | apt |
| `rofi/` | `~/.config/rofi/` | `rofi` | **Arch only** — Debian/Ubuntu still ship the 1.7.x X11-only build |
| `starship/` | `~/.config/starship.toml` | `starship` | apt / official install script — **pulled in automatically with zsh**, which draws its whole prompt with it |
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
- **Private mode** — third option in the first menu: delete existing configs *and* strip the repo traces from `~/dotfiles` afterwards (see below)
- **Idempotent** — safe to re-run; stow uses `-D` before re-stowing, and tools installed outside the package manager (starship, lazygit, the CLI installers) are detected rather than reinstalled
- **Repo before AUR** — on Arch every install checks the official repos first and only falls back to paru for AUR-only packages
- **paru** — installed automatically if missing on Arch (AUR helper)
- **Shell change** — switches the default shell to zsh when zsh is selected, falling back to `usermod` where `chsh` cannot authenticate
- **Headless aware** — on a machine with no display server, GUI configs and apps are hidden (see below)
- **Retries** — a stale pacman db / apt index is refreshed and the install retried instead of failing; GitHub release lookups fall back to the release page when the API rate-limits

### Arch-only items

`rofi` (Arch ships 2.0 with Wayland support merged in; Debian/Ubuntu are still on 1.7.x X11-only), `notion` (no official Linux build — only unofficial wrappers exist), `obsidian` (in Arch `extra`; on Debian/Ubuntu it ships only as a vendor `.deb`/AppImage with no apt repo), and the Antigravity desktop app / IDE (Google's Debian/Ubuntu packaging is still a moving target upstream) are only offered on Arch. `antigravity-cli` is available everywhere via its official install script.

### Debian/Ubuntu-only items

`claude-desktop` runs the other way around — Anthropic ships an official apt repo (`downloads.claude.ai/claude-desktop/apt/stable`, amd64 + arm64) but there is no Arch package, so it only appears in the app menu on Debian/Ubuntu. The installer adds the signing key and repo, then installs it via apt.

### Private mode

The first menu offers three ways to handle what is already on the machine:

| Row | Effect |
|-----|--------|
| `backup` | Existing configs move to `.bak` |
| `delete` | Existing configs are wiped, no backup kept |
| `private` | **Toggle**, independent of the above — also strips every trace that `~/dotfiles` is a clone |

`backup`/`delete` are the mode; `private` is a checkbox on top of whichever you pick, so `backup + strip repo traces` is a valid combination. Space acts on the highlighted row, or use `b`, `d`, `p` directly.

`private` removes `.git` (remote URL, full history, author name and email), `.github`, `.gitignore`, `.gitattributes`, `README.md`, `CLAUDE.md`, `LICENSE` and `linux.sh` — the last of which carries the GitHub URL. The config folders and `install.sh` stay, so the stow symlinks keep resolving and you can re-run the installer any time with `bash ~/dotfiles/install.sh` — no clone needed. Only pulling *new changes* from GitHub needs one.

It refuses to run against anything that does not look like the checkout (no `install.sh`, or a path equal to `/` or `$HOME`).

Two things it deliberately does not touch, because they are live configs rather than repo metadata: the byline comment in `fastfetch/config.jsonc`, and `user.name`/`user.email` in `git/.gitconfig`. Edit those yourself if the machine should not carry your name.

### Headless servers

The installer checks `DISPLAY`, `WAYLAND_DISPLAY`, the systemd default target and the installed session files. With no display server it drops the GUI entries from both menus — terminal emulators (`ghostty`, `kitty`), the launchers (`rofi`, `ulauncher`), and every GUI app (browsers, editors, Notion, Obsidian, Claude Desktop, VLC) — since none of them can run and each pulls in a large X/GTK dependency tree. What remains is the part that makes sense on a server: `zsh`, `starship`, `git`, `fastfetch`, `protonvpn`, the dep tools and the CLI agents.

Pass `--gui` to override the detection.

<a id="running-as-root-or-as-a-sudo-user"></a>**Running as root, or as a sudo user.** Both are supported. VPS and container images usually log you in as root, often with no `sudo` installed at all — the installer detects that and runs privileged commands directly, no password prompt. As a normal user it asks for sudo once and caches it.

What is *not* supported is `sudo bash install.sh`: under sudo the configs would be stowed into root's home, or into yours owned by root, depending on the sudoers policy. The installer detects that case and tells you which of the two supported ways to use instead.

One caveat on Arch: `makepkg` refuses to build as root, so paru cannot be bootstrapped there. Repo packages install normally and AUR-only items (ulauncher, Notion, Brave, VS Code, Antigravity, the Maple font) are reported as skipped. For AUR support on Arch, create a normal user with sudo rights and run the installer as that user.

**Shell change.** `chsh` authenticates through PAM and refuses on accounts with no local password (SSH-key-only login) — and can exit 0 without changing anything at all. The installer therefore reads `/etc/passwd` back after each attempt, falls through to `usermod` if the entry did not change, and only reports success once the shell really is zsh; otherwise it prints the exact command to run. The change applies at the next login — or run `exec zsh` to switch the current session immediately.

If a session still comes up as bash despite `/etc/passwd` being correct — which happens on some cloud images — the installer also drops a guarded hook in `~/.bashrc` that hands an interactive bash over to zsh. It is skipped inside zsh and for non-interactive shells, so it cannot loop or interfere with `scp`.

Note that it changes the shell for *the user running it*. Running as root sets root's shell, which is not what you want if you then SSH in as a different account.

### apt mirrors

Cloud images often ship a regional mirror that is slow, half-synced or retired, which makes every `apt-get` fail on 404s or hash mismatches. When the index cannot be refreshed and the failure looks mirror-level, the installer adds the canonical mirror alongside the existing sources — never replacing them, and skipped if it is already configured.

The Ubuntu host is chosen by architecture: `archive.ubuntu.com` serves amd64/i386, `ports.ubuntu.com` serves arm64 and the rest, and each 404s for the other's architectures. Debian uses `deb.debian.org`.

### WSL

Ubuntu and Debian under WSL work as-is: the apt path is used, and with no display server the GUI configs and apps are hidden automatically (WSLg sets `DISPLAY`, so they reappear if you have it).

The one difference is fonts. Your terminal on WSL is a Windows program, so a font installed into the Linux filesystem has no effect — the installer detects WSL and tells you to install JetBrainsMono Nerd Font and Maple Mono on the Windows side and select them in Windows Terminal or VS Code.

### Architectures

amd64 and arm64 are fully supported on all three distros; 32-bit ARM (`armhf`/`armel`) and `i386` work for everything that publishes builds for them. Upstream projects name these inconsistently — fastfetch ships `armv7l`/`armv6l`, lazygit ships `armv6`/`32-bit` — so the installer translates Debian's architecture names to whatever each project actually publishes.

## Theme

[Catppuccin Mocha](https://github.com/catppuccin/catppuccin) throughout: ghostty, kitty, starship, bat, btop.

Fonts are installed on every run, whatever you select — the configs reference them by name, so picking only zsh or starship used to leave a terminal with no font to render. They are skipped where they cannot do anything: no display server, or WSL. ghostty uses JetBrainsMono Nerd Font, kitty uses Maple Mono:

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
