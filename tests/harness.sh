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
    local etc="$root/etc" share="$root/share"
    sed -i \
        -e "s#/etc/os-release#$etc/os-release#g" \
        -e "s#/etc/arch-release#$etc/arch-release#g" \
        -e "s#/etc/apt#$etc/apt#g" \
        -e "s#/etc/shells#$etc/shells#g" \
        -e "s#/usr/share/xsessions#$share/xsessions#g" \
        -e "s#/usr/share/wayland-sessions#$share/wayland-sessions#g" \
        "$f"
    # The replacement paths end in /etc/… themselves, so verify by counting the
    # sandboxed form rather than by absence of the original.
    [ "$(grep -c -- "$etc/os-release" "$f")" -ge 3 ] || { echo "harness: rewrite did not take"; exit 1; }
    bash -n "$f" || { echo "harness: rewrite broke syntax"; exit 1; }
}

run() {                 # run <name> <distro> <keys-file> [VAR=value ...]
    local name="$1" distro="$2" keys="$3"; shift 3
    local root="$WORK/run/$name"
    rm -rf "$root"; mkdir -p "$root/home" "$root/state" "$root/etc/apt/sources.list.d" "$root/share"
    cp -a "$REPO" "$root/home/dotfiles"
    rm -rf "$root/home/dotfiles/tests"
    : > "$root/state/installed"
    printf '/bin/sh\n/bin/bash\n' > "$root/etc/shells"

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
thefuck
starship
base-devel
PKGS

    sandbox_repo "$root"

    # Each scenario gets its own copy of the stub bin: packages "installed" by
    # one run must not be on PATH for the next, and a scenario can remove a
    # tool (STUB_NO_FZF) to exercise a fallback path.
    cp -a "$WORK/bin" "$root/bin"
    [ "${STUB_NO_FZF:-0}" = 1 ] && rm -f "$root/bin/fzf"
    [ "${STUB_DEAD_GIT:-0}" = 1 ] && {
        printf '#!/bin/sh\nexit 0\n' > "$root/bin/git"; chmod +x "$root/bin/git"; }

    # A process that really exists, so the lock handling has a live pid to see
    # and to signal. It is ours and nothing else can be affected.
    if [ "${STUB_LOCKED:-0}" = 1 ]; then
        sleep 600 & echo $! > "$root/state/lockpid"
    fi
    [ "${STUB_DPKG_INTERRUPTED:-0}" = 1 ] && : > "$root/state/dpkg-interrupted"

    # script(1) gives the installer a real pty, so /dev/tty resolves and the
    # keystroke file is delivered through it — the same path a human types on.
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
        timeout 45 script -qec "bash ./install.sh" /dev/null \
            < "$keys" > "$root/out.txt" 2>&1 )
    echo $? > "$root/rc"

    [ -f "$root/state/lockpid" ] && kill "$(cat "$root/state/lockpid")" 2>/dev/null
    # The pty gives CRLF line endings; assertions anchored with $ need them gone.
    sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/\r$//' "$root/out.txt" > "$root/clean.txt"
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
