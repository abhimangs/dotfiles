# dotfiles

Arch Linux, Debian, and Ubuntu dotfiles managed with [GNU Stow](https://www.gnu.org/software/stow/). Each top-level folder mirrors the path relative to its stow target so files symlink directly into place. Snap is never used — every install path goes through pacman/AUR, apt, an official vendor apt repo, or a direct upstream download.

## Quick start — fresh install

```bash
curl -fsSL https://abhiman.io/linux.sh | bash
```

Works on Arch Linux, Debian, and Ubuntu, as a normal user or as root. Every run moves any existing `~/dotfiles` to `~/dotfiles.bak` and replaces it with a fresh clone, so the checkout is always clean.

`linux.sh` is deliberately tiny and is hosted by hand at `abhiman.io/linux.sh`, so it is the one file that must not need changing: it installs `git` if it is missing, clones, and hands off. Distro detection, privileges, prompts and every install step live in `install.sh`, which the fresh clone always brings with it.

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
| `--restore-bash` | Undoes the zsh setup — rc files, the `.bashrc` hand-off hook and the login shell. Runs alone, skipping every menu |
| `--ascii` | Plain ASCII instead of box-drawing and Nerd Font glyphs |
| `--no-color` | No ANSI colour (`NO_COLOR` in the environment does the same) |
| `-h`, `--help` | Prints the above and exits |

Anything else is rejected with exit 2 rather than ignored — a mistyped `--dryrun`
would otherwise have run a real install.

Each flag has an environment equivalent — `DOTFILES_DRY_RUN`, `DOTFILES_GUI`, `DOTFILES_RESTORE_BASH`, `DOTFILES_ASCII`, `DOTFILES_NO_COLOR` — because the bootstrap ends in `exec ./install.sh` with no arguments, so flags cannot reach it through the curl path but the environment can:

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
| `bash/` | `~/.bashrc` | `bash` | apt — plain rc, no starship or plugins; see [Going back to bash](#going-back-to-bash) |
| `zsh/` | `~/.zshrc` | `zsh` | apt |
| `git/` | `~/.gitconfig` | `git` | apt |
| `proton-vpn/` | `~/scripts/pvpn/pvpn.zsh` | `proton-vpn-cli` | official ProtonVPN apt repo |

## Installer features

- **fzf TUI** — multi-select configs with a live preview pane
- **Dep tools menu** — select bat, eza, fd, zoxide, thefuck, lazygit, btop, tree (all of them come automatically with zsh — see below)
- **App menu** — select apps to install: Brave Origin Beta/Stable, Visual Studio Code, Claude Desktop†, Antigravity IDE\*, Claude Code CLI, Antigravity 2.0\*, Antigravity CLI, Codex CLI, OpenCode, Kimi Code CLI, Muse, Notion\*, Obsidian\*, VLC, Flatpak, Docker + Compose (\*Arch only, †Debian/Ubuntu only — see below)
- **Confirmation plan** — shows exactly what will be installed before proceeding
- **Backup rotation** — existing configs move to `.bak`, old `.bak` rotates to `.old.bak`
- **Private mode** — its own first question: remove the repo scaffolding *and* scrub your name, address and URLs from what stays (see below)
- **Idempotent** — safe to re-run; stow uses `-D` before re-stowing, and tools installed outside the package manager (starship, lazygit, the CLI installers) are detected rather than reinstalled
- **Repo before AUR** — on Arch every install checks the official repos first and only falls back to paru for AUR-only packages
- **paru** — installed automatically if missing on Arch (AUR helper)
- **Shell change** — switches the default shell to zsh when zsh is selected, falling back to `usermod` where `chsh` cannot authenticate
- **Reversible** — `~/.bashrc` is copied once before anything touches it, and `--restore-bash` puts it back byte for byte along with your login shell (see below)
- **Headless aware** — on a machine with no display server, GUI configs and apps are hidden (see below)
- **Retries** — a stale pacman db / apt index is refreshed and the install retried instead of failing; GitHub release lookups fall back to the release page when the API rate-limits

### Going back to bash

Selecting zsh changes your login shell and, if a session still comes up as bash,
adds a guarded block to `~/.bashrc` that hands it over to zsh. Both are undoable:

```bash
bash ~/dotfiles/install.sh --restore-bash
```

It shows what it will do and asks before doing any of it (`--dry-run` stops after
the preview). It removes the hand-off block, puts `~/.bashrc` back from the copy
taken before the first run, un-stows `~/.zshrc` and `starship.toml` restoring any
`.bak`, and sets your login shell back to bash — verifying the change by reading
`/etc/passwd` back rather than trusting `chsh`.

Through the curl bootstrap, where flags cannot be passed:

```bash
DOTFILES_RESTORE_BASH=1 curl -fsSL https://abhiman.io/linux.sh | bash
```

**The pristine copy.** The first run that touches `~/.bashrc` copies it to
`~/.bashrc.orig`, once and only once — a later run never overwrites it, so the
file you started with survives any number of re-installs. It is kept even when
you choose `delete` for existing configs, and it is *not* removed by a restore,
so restoring is repeatable. If you had no `~/.bashrc` at all, `~/.bashrc.none`
records that and a restore installs this repo's `bash/.bashrc` instead.

**Escape hatch.** If zsh is broken and you just need a bash shell:

```bash
DOTFILES_NO_ZSH=1 bash          # locally
DOTFILES_NO_ZSH=1 ssh you@host  # over SSH
```

The hand-off block also refuses to run for non-interactive shells (`scp`, `rsync`,
`ssh host cmd`) and verifies zsh actually starts before handing over — so a
half-installed zsh can no longer lock you out of a machine you reach only by SSH.

**Picking `bash` as a config** stows a plain `~/.bashrc`: aliases and sane
defaults, no starship, no zoxide, no fzf, no plugin manager, and a plain prompt
that renders on a serial console with no Nerd Font. If you pick both `bash` and
`zsh`, the hand-off block is skipped — asking for the bash config is taken as
meaning you want a working bash.

**An existing `~/.config/starship.toml` is never replaced.** The repo's is stowed
only when you do not already have one.

### Arch-only items

`rofi` (Arch ships 2.0 with Wayland support merged in; Debian/Ubuntu are still on 1.7.x X11-only), `notion` (no official Linux build — only unofficial wrappers exist), `obsidian` (in Arch `extra`; on Debian/Ubuntu it ships only as a vendor `.deb`/AppImage with no apt repo), and the Antigravity desktop app / IDE (Google's Debian/Ubuntu packaging is still a moving target upstream) are only offered on Arch. `antigravity-cli` is available everywhere via its official install script.

### Debian/Ubuntu-only items

`claude-desktop` runs the other way around — Anthropic ships an official apt repo (`downloads.claude.ai/claude-desktop/apt/stable`, amd64 + arm64) but there is no Arch package, so it only appears in the app menu on Debian/Ubuntu. The installer adds the signing key and repo, then installs it via apt.

### Selecting zsh installs the whole shell

Everything in `.zshrc` is guarded by `command -v`, so a missing tool means a silently absent feature rather than an error. Selecting `zsh` therefore also installs:

- **starship** — the entire prompt is `eval "$(starship init zsh)"`
- **bat, eza, fd, zoxide, thefuck, lazygit, btop, tree** — the `ls`/`ll`/`cat`/`z`/`lg`/`fuck` aliases and fzf's `Ctrl-T`/`Alt-C` integration

Anything already ticked is not added twice, and all of these remain selectable on their own if you are not using zsh.

### Exit status

`0` when everything asked for succeeded, `1` when anything landed in the `Failed` list. The summary prints either way. The bootstrap `exec`s the installer, so the status propagates through `curl … | bash` unchanged.

### Private mode

Privacy is its own question, asked before anything else, and it prints the exact list before you choose — nothing is a surprise afterwards. Answering `private` means the machine keeps no sign of where the configs came from or whose they are.

**Deleted outright** (repo scaffolding, no value once the configs are stowed):
`.git` `.github` `.gitignore` `.gitattributes` `README.md` `CLAUDE.md` `LICENSE` `linux.sh`

`.git` is the big one — it carries the remote URL, the whole commit history, and the author name and email on every commit. `linux.sh` carries the GitHub URL.

**Scrubbed in place** (live configs that must keep working):

| File | What is removed |
|------|-----------------|
| `git/.gitconfig` | `user.name`, `user.email` |
| `fastfetch/config.jsonc` | the author byline — name, GitHub handle, contact address |
| `install.sh` | any hosted bootstrap URL in its comments |

The byline and the URL are matched structurally, not by name, so the installer itself carries no identity to leak. The config folders and `install.sh` stay, so the stow symlinks keep resolving and it can be re-run.

What happens to *existing* configs is asked separately, straight after:

| Row | Effect |
|-----|--------|
| `backup` | Existing configs move to `.bak` |
| `delete` | Existing configs are wiped, no backup kept |

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

**Over SSH, check your connection multiplexing first.** If your client has `ControlMaster` enabled, reconnecting reuses a master opened *before* the shell changed, so you land back in bash and it looks like nothing happened. From your local machine:

```bash
ssh -O exit <host>    # drop the persisted master, then reconnect
```

The installer prints this automatically when it detects an SSH session. Failing that, `exec zsh` switches the current session immediately.

If a session still comes up as bash despite `/etc/passwd` being correct — which happens on some cloud images — the installer also drops a guarded hook in `~/.bashrc` that hands an interactive bash over to zsh. It is skipped inside zsh and for non-interactive shells, so it cannot loop or interfere with `scp`.

Note that it changes the shell for *the user running it*. Running as root sets root's shell, which is not what you want if you then SSH in as a different account.

### apt mirrors

Cloud images often ship a regional mirror that is slow, half-synced or retired, which makes every `apt-get` fail on 404s or hash mismatches. When the index cannot be refreshed and the failure looks mirror-level, the installer adds the canonical mirror alongside the existing sources — never replacing them, and skipped if it is already configured.

The Ubuntu host is chosen by architecture: `archive.ubuntu.com` serves amd64/i386, `ports.ubuntu.com` serves arm64 and the rest, and each 404s for the other's architectures. Debian uses `deb.debian.org`.

`apt-get update` exits non-zero when *any* configured source fails, so one dead third-party repo fails the whole refresh even though the distro archive updated fine and packages still install. Rather than claiming the index is ready, the installer prints the `E:`/`W:` lines apt produced, names the file the failing source is configured in, and carries on.

Everything privileged goes through `sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get …`. The `env` matters: the stock sudoers policy refuses `sudo VAR=value cmd` outright ("you are not allowed to set the following environment variables"), and `NEEDRESTART_SUSPEND` keeps needrestart from opening its service-restart dialog mid-install — or bouncing sshd underneath you on a VPS.

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
