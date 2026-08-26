#!/usr/bin/env bash
# Scenario runner. Every scenario gets a throwaway HOME, a throwaway copy of
# the repo and the stub PATH — the real system is never touched.
#
# The copy under test has its absolute system paths (/etc/os-release,
# /etc/apt/…, /etc/shells, /usr/share/xsessions) rewritten to point inside the
# sandbox, so the distro, the apt sources and headlessness can be dictated.
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
        -e "s#/etc/shells#$etc/shells#g" \
        -e "s#/usr/share/xsessions#$share/xsessions#g" \
        -e "s#/usr/share/wayland-sessions#$share/wayland-sessions#g" \
        -e "s#/run/systemd/system#$run/systemd/system#g" \
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

build_root() {          # build_root <root> <distro>
    local root="$1" distro="$2"
    rm -rf "$root"; mkdir -p "$root/home" "$root/state" "$root/etc/apt/sources.list.d" "$root/share"
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
    cp -a "$REPO" "$root/home/dotfiles"
    rm -rf "$root/home/dotfiles/tests"
    # Local-only state, never part of a clone — and a landmine if it comes
    # along: an agent worktree under .claude/worktrees is a second full checkout
    # complete with README, LICENSE and git/.gitconfig, so private mode found
    # the author's name inside the sandbox and correctly failed eleven
    # assertions. The suite has to test the repo, not whatever is beside it.
    rm -rf "$root/home/dotfiles/.claude"
    : > "$root/state/installed"
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
        ubuntu) printf 'ID=ubuntu\nID_LIKE=debian\nVERSION_CODENAME=noble\nPRETTY_NAME="Ubuntu 24.04.1 LTS"\n' > "$root/etc/os-release"
                printf 'deb http://archive.ubuntu.com/ubuntu noble main\n' > "$root/etc/apt/sources.list" ;;
        debian) printf 'ID=debian\nVERSION_CODENAME=bookworm\nPRETTY_NAME="Debian GNU/Linux 12 (bookworm)"\n' > "$root/etc/os-release"
                printf 'deb http://deb.debian.org/debian bookworm main\n' > "$root/etc/apt/sources.list" ;;
    esac
    [ "${STUB_DEAD_PPA:-0}" = 1 ] && \
        printf 'Types: deb\nURIs: https://ppa.launchpadcontent.net/lazygit-team/release/ubuntu/\nSuites: noble\n' \
            > "$root/etc/apt/sources.list.d/lazygit-team-ubuntu-release-noble.sources"
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
PKGS

    # Invisible to pacman -Si, visible to paru/yay — so arch_install takes the
    # AUR fallback for it, which is how it installs on a real Arch box.
    printf 'vicinae-bin\n' > "$root/state/aur-only"

    sandbox_repo "$root"

    # Each scenario gets its own copy of the stub bin: packages "installed" by
    # one run must not be on PATH for the next, and a scenario can remove a
    # tool (STUB_NO_FZF) to exercise a fallback path.
    cp -a "$WORK/bin" "$root/bin"
    [ "${STUB_NO_FZF:-0}" = 1 ] && rm -f "$root/bin/fzf"
    [ "${STUB_YAY_ONLY:-0}" = 1 ] && rm -f "$root/bin/paru"
    # A box without unzip, which is neither distro's base install. bun's stub
    # installer refuses to run without it, so this is what makes ensure_unzip
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
    local cmd="stty rows $_rows cols $_cols 2>/dev/null; bash ./install.sh"
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
