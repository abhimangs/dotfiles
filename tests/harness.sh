#!/usr/bin/env bash
# Scenario runner. Every scenario gets a throwaway HOME, a throwaway copy of
# the repo and the stub PATH — the real system is never touched.
#
# The copy under test has its absolute system paths (/etc/os-release,
# /etc/apt/…, /etc/shells, /usr/share/xsessions) rewritten to point inside the
# sandbox, so the distro, the apt sources and headlessness can be dictated.
# /usr/local/bin becomes the scenario's own stub bin, which is on its PATH: a
# release tarball's binary lands where `command -v` will look for it.
# Only path literals change; every branch under test is the shipped one.
#
# Sourced by run.sh — not run directly.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-tests_XXXXXX")}"
PASS=0; FAIL=0

sandbox_repo() {        # sandbox_repo <root>
    local root="$1" f="$1/home/dotfiles/install.sh"
    local etc="$root/etc" share="$root/share" run="$root/run"
    sed -i \
        -e "s#/etc/os-release#$etc/os-release#g" \
        -e "s#/etc/arch-release#$etc/arch-release#g" \
        -e "s#/etc/apt#$etc/apt#g" \
        -e "s#/etc/yum.repos.d#$etc/yum.repos.d#g" \
        -e "s#/etc/nix#$etc/nix#g" \
        -e "s#/etc/shells#$etc/shells#g" \
        -e "s#/etc/pacman.conf#$etc/pacman.conf#g" \
        -e "s#/usr/share/xsessions#$share/xsessions#g" \
        -e "s#/usr/share/wayland-sessions#$share/wayland-sessions#g" \
        -e "s#/run/systemd/system#$run/systemd/system#g" \
        -e "s#/usr/local/bin#$root/bin#g" \
        -e "s#/opt/nvim#$root/opt/nvim#g" \
        "$f"
    # The replacement paths end in /etc/… themselves, so verify by counting the
    # sandboxed form rather than by absence of the original.
    [ "$(grep -c -- "$etc/os-release" "$f")" -ge 3 ] || { echo "harness: rewrite did not take"; exit 1; }
    bash -n "$f" || { echo "harness: rewrite broke syntax"; exit 1; }
}

# ── The seeded ~/.bashrc, as files ───────────────────────────────────────────
# Not a heredoc inside run(), because --restore-bash promises the original comes
# back *byte for byte* and only the exact seeded bytes can prove that. A second
# copy of this text in run.sh would drift the first time either is edited.
SEED_BASHRC="$WORK/seed/bashrc"
SEED_V1_HOOK="$WORK/seed/v1hook"
mkdir -p "$WORK/seed"
cat > "$SEED_BASHRC" <<'BRC'
# ~/.bashrc: the user's own, from before any of this ran
case $- in *i*) ;; *) return ;; esac
export EDITOR=nano
alias ll='ls -alF'
STUB_ORIGINAL_BASHRC=yes
BRC
# The hand-off block as an *older* install.sh wrote it: "dotfiles:" in the
# marker, which v2 dropped. Appended with no blank line before it, so a correct
# migration strips exactly these lines and what is left is SEED_BASHRC byte for
# byte — which turns "the pristine copy is hook-free" from a grep into a diff.
cat > "$SEED_V1_HOOK" <<'V1'
# >>> dotfiles: hand interactive bash to zsh >>>
if [ -z "${ZSH_VERSION:-}" ] && [ -t 1 ]; then
    exec zsh -l
fi
# <<< dotfiles: hand interactive bash to zsh <<<
V1

# ── A fake GRUB ──────────────────────────────────────────────────────────────
# /etc/default/grub, /etc/grub.d scripts that print menu entries, a grub.cfg
# already built from them, and the grub-mkconfig the distro ships (stubs.sh's
# templates: grub-mkconfig reads grub.d/*.cfg after the main file, as the
# Debian, Ubuntu and Arch builds do; Fedora's grub2-mkconfig reads one). Used by
# build_root, and on its own by the grub-theme.sh scenarios, which need no
# installer and no repo copy around them. Knobs, all off unless set:
#   STUB_GRUB=1|2            Arch-style | Fedora-style (grub2, console terminal, menu_auto_hide)
#   STUB_GRUB_OLD=1          this theme under its first name, active, beside a votex someone changed
#   STUB_GRUB_D=1            an Ubuntu cloud image's grub.d: console, timeout 0, another theme
#   STUB_GRUB_HIDDEN=1       Ubuntu's desktop default: GRUB_TIMEOUT_STYLE=hidden, GRUB_TIMEOUT=0
#   STUB_GRUB_CUSTOMIZER=1   grub-customizer's proxies, and the stock scripts an upgrade put back
#   STUB_GRUB_OSPROBER_OFF=1 Windows in grub.cfg from os-prober, switched off since
#   STUB_GRUB_LOADER=<text>  the LoaderInfo EFI variable ("GRUB 2.12", "systemd-boot 257")
# The file as the distro left it is kept in state/grub.orig, and the grub.d
# modes in state/grubd.orig, for the byte-for-byte uninstall checks.
grub_fixture() {        # grub_fixture <root> <distro>
    local root="$1" distro="$2" etc="$1/etc/default/grub" gd="$1/etc/grub.d" boot bin s
    mkdir -p "$root/etc/default" "$gd" "$root/efivars" "$root/bin" "$root/state"
    if [ "${STUB_GRUB:-0}" = 2 ]; then
        boot="$root/boot/grub2"; bin=grub2-mkconfig
        cp "$WORK/tpl/grub2-editenv" "$root/bin/"
        # What Fedora's installer writes, console terminal and all.
        printf '%s\n' \
            'GRUB_TIMEOUT=5' \
            "GRUB_DISTRIBUTOR=\"\$(sed 's, release .*\$,,g' /etc/system-release)\"" \
            'GRUB_DEFAULT=saved' \
            'GRUB_DISABLE_SUBMENU=true' \
            'GRUB_TERMINAL_OUTPUT="console"' \
            'GRUB_CMDLINE_LINUX="rhgb quiet"' \
            'GRUB_DISABLE_RECOVERY="true"' \
            'GRUB_ENABLE_BLSCFG=true' \
            > "$etc"
        mkdir -p "$boot"
        printf '# GRUB Environment Block\nmenu_auto_hide=1\nboot_success=1\n' > "$boot/grubenv"
    else
        boot="$root/boot/grub"; bin=grub-mkconfig
        printf '%s\n' \
            'GRUB_DEFAULT="0"' \
            'GRUB_TIMEOUT="5"' \
            'GRUB_TIMEOUT_STYLE="menu"' \
            '#GRUB_THEME="/path/to/gfxtheme"' \
            'GRUB_THEME="/boot/grub/themes/starfield/theme.txt"' \
            > "$etc"
        if [ "${STUB_GRUB_HIDDEN:-0}" = 1 ]; then
            sed -i -e 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' \
                   -e 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/' "$etc"
        fi
    fi
    mkdir -p "$boot"
    cp "$WORK/tpl/$bin" "$root/bin/$bin"

    # Scripts that print entries the way the real ones do.
    w_gd() { printf '#!/bin/sh\n%s\n' "$2" > "$gd/$1"; chmod +x "$gd/$1"; }
    if [ "${STUB_GRUB_CUSTOMIZER:-0}" = 1 ]; then
        mkdir -p "$gd/proxifiedScripts" "$gd/bin"
        for s in linux os-prober uefi-firmware custom; do w_gd "proxifiedScripts/$s" 'true'; done
        w_gd 10_linux_proxy "printf '#THIS IS A GRUB PROXY SCRIPT\nmenuentry \"Arch Linux\" {\n}\n'"
        w_gd 11_custom_proxy "printf 'menuentry \"Windows 11\" {\n}\n'"
        w_gd 31_linux_proxy "printf 'submenu \"Advanced Options\" {\n\tmenuentry \"Arch Linux, with Linux linux\" {\n\t}\n\tmenuentry \"UEFI Firmware Settings\" {\n\t}\n}\n'"
        w_gd 33_linux_xen 'true'
        w_gd 35_os-prober_proxy 'true'
        w_gd 36_uefi-firmware_proxy 'true'
        w_gd 41_custom 'true'
        # The stock scripts grub-customizer had moved away, back from an upgrade.
        w_gd 10_linux "printf \"menuentry 'Arch Linux' {\n}\nsubmenu 'Advanced options for Arch Linux' {\n\tmenuentry 'Arch Linux, with Linux linux' {\n\t}\n}\n\""
        w_gd 20_linux_xen 'true'
        w_gd 30_os-prober "printf \"menuentry 'Windows Boot Manager (on /dev/nvme0n1p1)' {\n}\n\""
        w_gd 30_uefi-firmware "printf \"menuentry 'UEFI Firmware Settings' {\n}\n\""
        w_gd 40_custom 'true'
        chmod -x "$gd/10_linux" "$gd/20_linux_xen" "$gd/30_os-prober" "$gd/30_uefi-firmware" "$gd/40_custom"
    else
        w_gd 10_linux "printf \"menuentry 'Arch Linux' {\n}\nsubmenu 'Advanced options for Arch Linux' {\n\tmenuentry 'Arch Linux, with Linux linux' {\n\t}\n}\n\""
        w_gd 30_uefi-firmware "printf \"menuentry 'UEFI Firmware Settings' {\n}\n\""
        w_gd 41_custom 'true'
        if [ "${STUB_GRUB_OSPROBER_OFF:-0}" = 1 ]; then
            w_gd 30_os-prober "[ \"\$GRUB_DISABLE_OS_PROBER\" = true ] || printf \"menuentry 'Windows Boot Manager (on /dev/sda1)' {\n}\n\""
            printf 'GRUB_DISABLE_OS_PROBER=false\n' >> "$etc"
        fi
    fi
    unset -f w_gd

    # This theme under the name it shipped as first, active, plus a votex
    # directory somebody changed. The first is a stale copy of ours and goes;
    # the second is not byte-for-byte anything we shipped, and stays.
    if [ "${STUB_GRUB_OLD:-0}" = 1 ]; then
        mkdir -p "$boot/themes"
        cp -R "$REPO/grub/themes/vortex" "$boot/themes/grub-of-tsushima"
        cp -R "$REPO/grub/themes/vortex" "$boot/themes/votex"
        printf 'mine\n' > "$boot/themes/votex/notes.txt"
        sed -i "s#^GRUB_THEME=.*#GRUB_THEME=\"$boot/themes/grub-of-tsushima/theme.txt\"#" "$etc"
    fi
    # An Ubuntu cloud image: grub.d puts the terminal on console and the
    # timeout at 0, and a theme package sets its own GRUB_THEME there too.
    if [ "${STUB_GRUB_D:-0}" = 1 ]; then
        mkdir -p "$etc.d"
        printf '%s\n' 'GRUB_TERMINAL=console' 'GRUB_TIMEOUT=0' > "$etc.d/50-cloudimg-settings.cfg"
        printf '%s\n' 'GRUB_THEME="/boot/grub/themes/mint/theme.txt"' > "$etc.d/60_mint-theme.cfg"
    fi
    if [ -n "${STUB_GRUB_LOADER:-}" ]; then
        { printf '\x06\x00\x00\x00'; printf '%s' "$STUB_GRUB_LOADER" | sed 's/./&\x00/g'; printf '\x00\x00'; } \
            > "$root/efivars/LoaderInfo-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"
    fi

    # The grub.cfg the machine starts with, built the way the real one was.
    STUB_STATE="$root/state" DOTFILES_GRUB_ETC="$etc" DOTFILES_GRUB_D="$gd" \
        "$root/bin/$bin" -o "$boot/grub.cfg" 2>/dev/null
    : > "$root/state/grub-mkconfig.log"
    # ...and then the upgrade that put grub-customizer's replaced scripts back.
    [ "${STUB_GRUB_CUSTOMIZER:-0}" = 1 ] \
        && chmod +x "$gd/10_linux" "$gd/20_linux_xen" "$gd/30_os-prober" "$gd/30_uefi-firmware" "$gd/40_custom"
    # ...or the os-prober switch-off since the last build.
    [ "${STUB_GRUB_OSPROBER_OFF:-0}" = 1 ] \
        && sed -i 's/^GRUB_DISABLE_OS_PROBER=false$/GRUB_DISABLE_OS_PROBER=true/' "$etc"
    cp -p "$etc" "$root/state/grub.orig"
    ( cd "$gd" && stat -c '%n %a' [0-9]* ) > "$root/state/grubd.orig"
    cp -p "$boot/grub.cfg" "$root/state/grub.cfg.orig"
}

# Runs grub/grub-theme.sh against a grub_fixture sandbox, the transcript in
# <root>/clean.txt so want/nowant read it like a scenario's; rc in <root>/rc.
gt() {                  # gt <name> <distro> <headless 0|1> <grub-theme.sh args…>
    local name="$1" distro="$2" headless="$3" root="$WORK/run/$1" boot
    shift 3
    boot="$root/boot/grub"; [ "${STUB_GRUB:-0}" = 2 ] && boot="$root/boot/grub2"
    local rc=0
    env -i HOME="$root/home" PATH="$root/bin:$WORK/sysbin" LANG=C TERM=dumb \
        STUB_STATE="$root/state" \
        DOTFILES_GRUB_ETC="$root/etc/default/grub" DOTFILES_GRUB_BOOT="$boot" \
        DOTFILES_GRUB_D="$root/etc/grub.d" DOTFILES_GRUB_EFIVARS="$root/efivars" \
        GRUB_THEME_DISTRO="$distro" GRUB_THEME_HEADLESS="$headless" \
        ${GT_ENV[@]+"${GT_ENV[@]}"} \
        bash "$REPO/grub/grub-theme.sh" "$@" > "$root/out.txt" 2>&1 || rc=$?
    echo "$rc" > "$root/rc"
    cp "$root/out.txt" "$root/clean.txt"
}
gt_box() {              # gt_box <name> <distro>: a fresh fake GRUB, nothing else
    local root="$WORK/run/$1"
    rm -rf "$root"; mkdir -p "$root/home" "$root/bin"
    grub_fixture "$root" "$2"
}

build_root() {          # build_root <root> <distro>
    local root="$1" distro="$2"
    rm -rf "$root"; mkdir -p "$root/home" "$root/state" \
        "$root/etc/apt/sources.list.d" "$root/etc/yum.repos.d" "$root/etc/nix" "$root/share"
    # "systemd is the init here", which every service branch tests for. It used
    # to be read off the *host*: the suite passed on a systemd laptop and would
    # have quietly skipped those branches anywhere else. STUB_NO_SYSTEMD is the
    # other box — a container, WSL without systemd, a non-systemd distro.
    [ "${STUB_NO_SYSTEMD:-0}" = 1 ] || mkdir -p "$root/run/systemd/system"
    # What the stub pgrep sees. Empty unless a scenario says otherwise — the
    # host's own process list must never be the answer. Unquoted deliberately:
    # a scenario may name more than one process, and the stub matches whole
    # lines, so each has to land on its own.
    # shellcheck disable=SC2086
    printf '%s\n' ${STUB_RUNNING:-} > "$root/state/processes"
    # Which units the stub systemctl answers `is-active` for before this run
    # starts anything. Same shape and same reason as STUB_RUNNING: a session
    # that reaches graphical-session.target and one that never does are two
    # different boxes, and the host's own targets must not decide which.
    # shellcheck disable=SC2086
    printf '%s\n' ${STUB_ACTIVE:-} > "$root/state/active"
    cp -a "$REPO" "$root/home/dotfiles"
    rm -rf "$root/home/dotfiles/tests"
    # Local-only state, never part of a clone — and a landmine if it comes
    # along: an agent worktree under .claude/worktrees is a second full checkout
    # complete with README, LICENSE and git/.gitconfig, so private mode found
    # the author's name inside the sandbox and correctly failed eleven
    # assertions. The suite has to test the repo, not whatever is beside it.
    rm -rf "$root/home/dotfiles/.claude"
    : > "$root/state/installed"
    mkdir -p "$root/opt"
    printf '/bin/sh\n/bin/bash\n' > "$root/etc/shells"

    # Every Debian/Ubuntu home ships one, and the bash scenarios need something
    # real to snapshot. Distinctive enough that a restore can be checked for it.
    if [ "${STUB_NO_BASHRC:-0}" != 1 ]; then
        cp -p "$SEED_BASHRC" "$root/home/.bashrc"
        # A machine an older version of this installer already ran on. Without
        # one of these the migration branch is never taken and a regression that
        # stacks a second block on top of the first ships unnoticed.
        [ "${STUB_V1_HOOK:-0}" = 1 ] && cat "$SEED_V1_HOOK" >> "$root/home/.bashrc"
    fi
    # ~/.zshrc as a symlink the user made themselves — into a sync folder, another
    # checkout, wherever. Not ours, so it must be moved aside like a real file
    # rather than removed. The target carries a marker so the test can prove the
    # file behind the link survived too, not just the link.
    if [ "${STUB_PRESEED_FOREIGN_ZSHRC:-0}" = 1 ]; then
        mkdir -p "$root/home/Sync"
        printf '# MINE — reached through a symlink the user made\n' > "$root/home/Sync/zshrc"
        ln -s "Sync/zshrc" "$root/home/.zshrc"
    fi
    # A starship.toml the user wrote themselves, which must survive untouched.
    if [ "${STUB_PRESEED_STARSHIP:-0}" = 1 ]; then
        mkdir -p "$root/home/.config"
        printf '# MINE — hand written, must not be replaced\nformat = "$directory$character"\n' \
            > "$root/home/.config/starship.toml"
    fi

    case "$distro" in
        arch)   : > "$root/etc/arch-release"
                printf 'ID=arch\nNAME="Arch Linux"\nPRETTY_NAME="Arch Linux"\n' > "$root/etc/os-release" ;;
        # Omarchy: /etc/arch-release stays (the filesystem package owns it) but
        # os-release is rewritten to ID=omarchy, so only ID_LIKE says "arch".
        omarchy) : > "$root/etc/arch-release"
                printf 'NAME="Omarchy"\nID=omarchy\nID_LIKE=arch\n' > "$root/etc/os-release" ;;
        ubuntu) printf 'ID=ubuntu\nID_LIKE=debian\nVERSION_CODENAME=noble\nPRETTY_NAME="Ubuntu 24.04.1 LTS"\n' > "$root/etc/os-release"
                printf 'deb http://archive.ubuntu.com/ubuntu noble main\n' > "$root/etc/apt/sources.list" ;;
        debian) printf 'ID=debian\nVERSION_CODENAME=%s\nPRETTY_NAME="Debian GNU/Linux 12 (%s)"\n' \
                    "${STUB_DEBIAN_CODENAME:-bookworm}" "${STUB_DEBIAN_CODENAME:-bookworm}" > "$root/etc/os-release"
                printf 'deb http://deb.debian.org/debian %s main\n' "${STUB_DEBIAN_CODENAME:-bookworm}" > "$root/etc/apt/sources.list" ;;
        fedora) printf 'ID=fedora\nVERSION_ID=42\nPRETTY_NAME="Fedora Linux 42"\n' > "$root/etc/os-release" ;;
        nix)    printf 'NAME="NixOS"\nID=nixos\nVERSION_ID=25.05\nPRETTY_NAME="NixOS"\n' > "$root/etc/os-release"
                : > "$root/etc/NIXOS" ;;
    esac
    [ "${STUB_DEAD_PPA:-0}" = 1 ] && \
        printf 'Types: deb\nURIs: https://ppa.launchpadcontent.net/lazygit-team/release/ubuntu/\nSuites: noble\n' \
            > "$root/etc/apt/sources.list.d/lazygit-team-ubuntu-release-noble.sources"
    [ "${STUB_FLAKY_DOCKER:-0}" = 1 ] && \
        printf 'deb [signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable\n' \
            > "$root/etc/apt/sources.list.d/docker.list"
    [ "${STUB_BROKEN_REPO:-0}" = 1 ] && \
        printf 'deb https://apt.example.com/repo stable main\n' \
            > "$root/etc/apt/sources.list.d/thirdparty.list"

    cat > "$root/state/available" <<'PKGS'
stow
fzf
zsh
git
bat
eza
fd
fd-find
zoxide
lazygit
btop
tree
fastfetch
curl
gnupg
software-properties-common
starship
base-devel
pay-respects-bin
docker
docker-compose
docker-buildx
docker-ce
docker-ce-cli
containerd.io
docker-buildx-plugin
docker-compose-plugin
proton-vpn-cli
protonvpn-cli
kitty
ghostty
micro
rofi
ulauncher
vlc
flatpak
obsidian
unzip
vicinae-bin
deepseek-harness-bin
stably-orca-bin
slack-desktop
discord-canary
obs-studio
v4l2loopback-dkms
qt6-wayland
zoom
github-cli
gh
ripgrep
git-delta
tmux
neovim
jq
ncdu
yazi
atuin
lazydocker
zed
uv
bitwarden
bitwarden-bin
claude-desktop
keepassxc
syncthing
localsend-bin
libayatana-appindicator3-1
fresh-editor
mpv
fontconfig
brave-origin
brave-origin-beta
code
code-insiders
PKGS

    # Invisible to pacman -Si, visible to paru/yay — so arch_install takes the
    # AUR fallback for them, which is how they install on a real Arch box.
    printf 'vicinae-bin\nzoom\ndeepseek-harness-bin\nstably-orca-bin\nslack-desktop\ndiscord-canary\nlocalsend-bin\nbitwarden-bin\nclaude-desktop\n' > "$root/state/aur-only"

    sandbox_repo "$root"

    # Each scenario gets its own copy of the stub bin: packages "installed" by
    # one run must not be on PATH for the next, and a scenario can remove a
    # tool (STUB_NO_FZF) to exercise a fallback path.
    cp -a "$WORK/bin" "$root/bin"
    # After the stub bin is in place: the fixture copies its grub-mkconfig
    # into it, and runs it once to build the grub.cfg the machine starts with.
    { [ "${STUB_GRUB:-0}" = 1 ] || [ "${STUB_GRUB:-0}" = 2 ]; } && grub_fixture "$root" "$distro"
    [ "${STUB_NO_FZF:-0}" = 1 ] && rm -f "$root/bin/fzf"
    [ "${STUB_YAY_ONLY:-0}" = 1 ] && rm -f "$root/bin/paru"
    # No AUR helper at all, and no stow: the two things the plan now lists as
    # "first" and the run installs only after Proceed, only when needed.
    [ "${STUB_NO_AUR:-0}" = 1 ] && rm -f "$root/bin/paru" "$root/bin/yay"
    [ "${STUB_NO_STOW:-0}" = 1 ] && rm -f "$root/bin/stow"
    # The bootstrap for real: an AUR clone is a mkdir, and makepkg puts the
    # helper stub named by its build dir on PATH (or fails, with
    # STUB_AUR_BUILD=fail). Every other git call is the host's.
    if [ -n "${STUB_AUR_BUILD:-}" ]; then
        printf '#!/bin/sh\n[ "$1" = clone ] && case "$2" in https://aur.archlinux.org/*) echo "$2" >> "$STUB_STATE/aur-clones"; exec mkdir -p "$3" ;; esac\nexec "%s/sysbin/git" "$@"\n' "$WORK" > "$root/bin/git"
        if [ "$STUB_AUR_BUILD" = fail ]; then
            printf '#!/bin/sh\nexit 1\n' > "$root/bin/makepkg"
        else
            printf '#!/bin/sh\nh=${PWD##*/}\ncp "%s/bin/yay" "$STUB_BIN/${h%%%%-bin}"\n' "$WORK" > "$root/bin/makepkg"
        fi
        chmod +x "$root/bin/git" "$root/bin/makepkg"
    fi
    # A paru that is on PATH and cannot start: paru-bin built against an older
    # libalpm than pacman ships, which is what CI's Arch image ran into.
    # What OpenAI's ChatGPT script leaves when its pacman prompt is declined:
    # its repo in pacman.conf (and so chatgpt-bin installable). sudo never runs
    # the script itself here.
    if [ "${STUB_OAI_REPO:-0}" = 1 ]; then
        echo 'Include = /etc/pacman.d/openai-chatgpt.conf' >> "$root/etc/pacman.conf"
        echo chatgpt-bin >> "$root/state/available"
    fi
    if [ "${STUB_PARU_BROKEN:-0}" = 1 ]; then
        rm -f "$root/bin/yay"
        printf 'paru-bin\nparu-bin-debug\n' >> "$root/state/installed"
        printf '#!/bin/sh\necho "paru: error while loading shared libraries: libalpm.so.15: cannot open shared object file: No such file or directory" >&2\nexit 127\n' > "$root/bin/paru"
        chmod +x "$root/bin/paru"
    fi
    # A box without unzip, which is neither distro's base install. bun's stub
    # installer refuses to run without it, so this is what makes ensure_cmd unzip
    # something the suite can see.
    [ "${STUB_NO_UNZIP:-0}" = 1 ] && rm -f "$root/bin/unzip"
    [ "${STUB_DEAD_GIT:-0}" = 1 ] && {
        printf '#!/bin/sh\nexit 0\n' > "$root/bin/git"; chmod +x "$root/bin/git"; }

    # A process that really exists, so the lock handling has a live pid to see
    # and to signal. It is ours and nothing else can be affected.
    if [ "${STUB_LOCKED:-0}" = 1 ]; then
        sleep 600 & echo $! > "$root/state/lockpid"
    fi
    [ "${STUB_DPKG_INTERRUPTED:-0}" = 1 ] && : > "$root/state/dpkg-interrupted"
    # A real ~/.config/btop with a real file in it, so the delete/backup branch
    # for a dep tool's config is actually reachable.
    [ "${STUB_PRESEED_BTOP:-0}" = 1 ] && {
        mkdir -p "$root/home/.config/btop"
        echo 'color_theme = "mine"' > "$root/home/.config/btop/btop.conf"; }
    return 0
}

# One invocation of install.sh inside an already-built sandbox.
#   install_pass <root> <outdir> <keys-file> [VAR=value ...]
#
# The sandbox and the transcript are separate arguments on purpose. --restore-bash
# only means anything after an install has happened, so those scenarios run the
# installer twice against ONE $HOME — and each pass needs its own out.txt, or the
# second silently overwrites the evidence the first pass is asserted on.
#
# $RUN_ARGS (set as a prefix on the run/rerun call) is appended to the command
# line, which is the only way a scenario can reach a flag: install.sh parses "$@"
# and the harness used to hardcode an empty one.
# Keystrokes come either from a plain file — written once, up front — or from a
# script, which is fed live and can wait for the installer to reach a prompt.
# The menu needs the second kind: it puts the terminal in raw mode, and that
# discards whatever was already sitting in the input queue, so anything typed
# ahead of it is simply gone.
feed_keys() {           # feed_keys <keys-file> <transcript>
    if [ "${1##*.}" = "sh" ]; then
        FEED_OUT="$2" bash "$1"
    else
        cat "$1"
    fi
}

install_pass() {        # install_pass <root> <outdir> <keys-file> [VAR=value ...]
    local root="$1" out="$2" keys="$3"; shift 3
    mkdir -p "$out"
    # A pty inherits its size from the terminal that made it, and CI (and this
    # runner) often has none — which leaves it 0x0 and makes the menu correctly
    # decide it cannot draw. Give every scenario a real window.
    local _rows="${STUB_TTY_ROWS:-40}" _cols="${STUB_TTY_COLS:-150}"
    # STUB_NO_SIZE reproduces a pty nobody ever set a size on — a CI runner, or
    # a detached session. The menu has to decline to draw on one.
    [ "${STUB_NO_SIZE:-0}" = 1 ] && { _rows=0; _cols=0; }
    # SIGPIPE ignored, as the GitHub Actions runner starts every job: a signal
    # ignored on entry stays ignored in bash, so a write to a pipe whose reader
    # left (a `break` out of `done < <(…)`) prints "write error: Broken pipe"
    # there instead of dying quietly. Passing here and failing on CI is what
    # that difference cost, so the suite runs the way CI does.
    local cmd="trap '' PIPE; stty rows $_rows cols $_cols 2>/dev/null; bash ./install.sh"
    [ -n "${RUN_ARGS:-}" ] && cmd="$cmd ${RUN_ARGS}"

    # script(1) gives the installer a real pty, so /dev/tty resolves and the
    # keystroke file is delivered through it — the same path a human types on.
    # `|| rc=$?` is not decoration. A bare subshell here is a plain command, so
    # a non-zero exit — install.sh genuinely failing, timeout killing the pty,
    # or the one scenario that is *supposed* to exit 1 — kills the whole run on
    # the spot under errexit, before this rc is ever recorded and before any
    # check/want prints. That is what made the suite stop dead after the
    # scenarios header with no output at all.
    local rc=0
    ( cd "$root/home/dotfiles" \
      && env -i \
        HOME="$root/home" \
        USER="$(id -un)" LOGNAME="$(id -un)" \
        PATH="$root/bin:$WORK/sysbin" \
        TERM="${STUB_TERM:-dumb}" LANG="${STUB_LANG:-C}" \
        SHELL=/bin/bash \
        STUB_STATE="$root/state" STUB_BIN="$root/bin" STUB_TPL="$WORK/tpl" \
        STUB_ROOT="$root" STUB_APT_SRCD="$root/etc/apt/sources.list.d" \
        DOTFILES_GRUB_ETC="$root/etc/default/grub" DOTFILES_GRUB_BOOT="$root/boot/grub" \
        DOTFILES_GRUB_D="$root/etc/grub.d" DOTFILES_GRUB_EFIVARS="$root/efivars" \
        "$@" \
        FEED_OUT="$out/out.txt" \
        timeout 60 script -qec "$cmd" /dev/null \
            < <(feed_keys "$keys" "$out/out.txt") > "$out/out.txt" 2>&1 ) || rc=$?
    echo "$rc" > "$out/rc"

    [ -f "$root/state/lockpid" ] && kill "$(cat "$root/state/lockpid")" 2>/dev/null
    # The pty gives CRLF line endings; assertions anchored with $ need them gone.
    sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/\r$//' "$out/out.txt" > "$out/clean.txt"
}

run() {                 # run <name> <distro> <keys-file> [VAR=value ...]
    local name="$1" distro="$2" keys="$3"; shift 3
    build_root "$WORK/run/$name" "$distro"
    install_pass "$WORK/run/$name" "$WORK/run/$name" "$keys" "$@"
}

# Run install.sh again in the sandbox <in> was built in, without rebuilding it —
# the state the first pass left behind is the whole point. The transcript lands
# under <name>, so check/want/nowant address the two passes separately while the
# filesystem assertions all read $WORK/run/<in>/home.
#
#   RUN_ARGS=--restore-bash rerun myscen-undo myscen "$WORK/k-restore"
rerun() {               # rerun <name> <in> <keys-file> [VAR=value ...]
    local name="$1" in="$2" keys="$3"; shift 3
    install_pass "$WORK/run/$in" "$WORK/run/$name" "$keys" "$@"
}

check() {               # check <name> <expected-rc>
    # NB: separate statements — words in a single `local` are all expanded
    # before any assignment happens, so `out=…$name…` would see the old value.
    local name="$1"
    local wanted="$2"
    local out="$WORK/run/$name/clean.txt"
    local rc
    rc=$(cat "$WORK/run/$name/rc")
    local bad=0; local -a msg=()
    [ "$rc" = "$wanted" ] || { bad=1; msg+=("exit $rc wanted $wanted"); }
    grep -q 'STUBFAIL'                         "$out" && { bad=1; msg+=("stub assertion"); }
    grep -q 'not allowed to set the following' "$out" && { bad=1; msg+=("sudo env rejection"); }
    grep -qE 'install\.sh: line [0-9]+'        "$out" && { bad=1; msg+=("bash error"); }
    grep -q 'command not found'                "$out" && { bad=1; msg+=("command not found"); }
    grep -q 'unbound variable'                 "$out" && { bad=1; msg+=("unbound variable"); }
    grep -qE '\$\{(G|C)_[A-Z_]+\}'             "$out" && { bad=1; msg+=("literal var leak"); }
    if [ "$bad" = 0 ]; then
        printf '  PASS  %-26s exit %s\n' "$name" "$rc"; PASS=$((PASS+1))
    else
        printf '  FAIL  %-26s %s\n' "$name" "${msg[*]}"; FAIL=$((FAIL+1))
    fi
}

want() {                # want <name> <regex> <description>
    if grep -qE "$2" "$WORK/run/$1/clean.txt"; then
        printf '  PASS  %-26s %s\n' "$1" "$3"; PASS=$((PASS+1))
    else
        printf '  FAIL  %-26s %s\n' "$1" "$3"; FAIL=$((FAIL+1))
    fi
}

nowant() {              # nowant <name> <regex> <description>
    if grep -qE "$2" "$WORK/run/$1/clean.txt"; then
        printf '  FAIL  %-26s %s\n' "$1" "$3"; FAIL=$((FAIL+1))
    else
        printf '  PASS  %-26s %s\n' "$1" "$3"; PASS=$((PASS+1))
    fi
}

note() { printf '  PASS  %-26s %s\n' "$1" "$2"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %-26s %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# Everything about a tree that a write would disturb: type, mode, size, mtime,
# symlink target, and the contents of every regular file. Two manifests compare
# equal only if nothing was created, removed, rewritten or re-pointed.
#
# This is what "--dry-run changes nothing" has to mean. Spot-checking the two or
# three files a scenario expects to be touched cannot catch the failure that
# actually matters — some unrelated write, in a mode whose entire contract is
# that there are none.
manifest() {            # manifest <dir>
    ( cd "$1" 2>/dev/null || exit 0
      find . -mindepth 1 -printf '%y %m %s %T@ %p -> %l\n' | LC_ALL=C sort
      find . -type f -printf '%p\0' | LC_ALL=C sort -z \
          | xargs -0 -r sha256sum 2>/dev/null | LC_ALL=C sort )
}
