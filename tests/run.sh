#!/usr/bin/env bash
# Runs install.sh end to end against stubbed package managers, in a sandboxed
# HOME, on a real pty. Nothing outside the work directory is touched.
#
#   bash tests/run.sh
#
# Exit status is 0 only if every assertion passed.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-tests_XXXXXX")}"
export WORK
# KEEP_WORK=1 leaves the sandbox behind. A failing scenario is close to
# undebuggable without it: every assertion reads clean.txt, and clean.txt is
# inside the tree this trap removes.
if [ -n "${KEEP_WORK:-}" ]; then
    trap 'echo; echo "work dir kept: $WORK"' EXIT
else
    trap 'rm -rf "$WORK"' EXIT
fi

source "$HERE/stubs.sh"
# stubs.sh sets `set -e` so its own setup aborts on a failed heredoc or mkdir.
# It is *sourced*, though, so the flag would stay on for the rest of this file
# — and this file is a test runner: it expects commands to fail and asserts on
# how. Line 9 deliberately chose `-uo pipefail` without `-e`; restore that.
set +e
source "$HERE/harness.sh"

echo "work dir: $WORK"
echo

# Keystroke scripts. Prompt order:
#   privacy (1 key) · existing configs (1 key) · [menus] · Proceed?
printf '\n\n\n'        > "$WORK/k-fzf"      # menus answered by the fzf stub
printf '\n\n2\n\n\n\n' > "$WORK/k-num"      # numeric menu: item 2, skip, skip, proceed
printf 'p\n\n\n'       > "$WORK/k-private"  # private mode, then fzf menus
printf '\n\ny\n'       > "$WORK/k-lock-yes" # ... then "yes, stop the updater"
printf '\n\nn\n'       > "$WORK/k-lock-no"  # ... then "no, leave it"

echo "── static ───────────────────────────────────────────────"
for f in install.sh linux.sh doctor.sh; do
    if bash -n "$HERE/../$f" 2>/dev/null; then note "$f" "parses"; else bad "$f" "syntax error"; fi
done
if command -v zsh >/dev/null && zsh -n "$HERE/../zsh/.zshrc" 2>/dev/null; then
    note ".zshrc" "parses"
elif command -v zsh >/dev/null; then
    bad ".zshrc" "syntax error"
fi
if command -v fastfetch >/dev/null; then
    if fastfetch --config "$HERE/../fastfetch/config.jsonc" >/dev/null 2>&1; then
        note "fastfetch/config.jsonc" "parses"
    else
        bad "fastfetch/config.jsonc" "does not parse"
    fi
fi
echo

echo "── scenarios ────────────────────────────────────────────"

# 1. The VPS case: Ubuntu 24.04, headless, ordinary sudo user, strict sudoers.
run ubuntu-headless ubuntu "$WORK/k-fzf" \
    STUB_FZF_PICK1="zsh git" SSH_CONNECTION="10.0.0.2 22 10.0.0.1 22"
check   ubuntu-headless 0
want    ubuntu-headless 'Tools verified'                  'stow+fzf installed'
want    ubuntu-headless 'zsh needs these for its aliases' 'zsh pulls the toolchain'
want    ubuntu-headless 'adding starship'                 'zsh pulls starship'
want    ubuntu-headless 'ssh -O exit'                     'SSH multiplexing hint'
nowant  ubuntu-headless 'Failed \([1-9]'                  'nothing failed'

# 2. Same box, logged in as root, with no sudo at all.
run ubuntu-root ubuntu "$WORK/k-fzf" STUB_FZF_PICK1="zsh" STUB_FAKE_ROOT=1
check   ubuntu-root 0
want    ubuntu-root 'Running as root'                     'root path taken'
want    ubuntu-root 'Tools verified'                      'installs work as root'

# 3. Debian 12, no fzf available, numeric fallback menu.
STUB_NO_FZF=1 run debian-nofzf debian "$WORK/k-num" STUB_NO_FZF=1
check   debian-nofzf 0
want    debian-nofzf 'basic menu'                         'fallback menu used'
want    debian-nofzf 'Tools verified'                     'installs work'

# 4. A third-party repo is broken, so every apt-get update exits non-zero.
STUB_BROKEN_REPO=1 run ubuntu-badrepo ubuntu "$WORK/k-fzf" \
    STUB_FZF_PICK1="git" STUB_BROKEN_REPO=1
check   ubuntu-badrepo 0
want    ubuntu-badrepo 'did not refresh cleanly'                  'broken index reported'
want    ubuntu-badrepo 'Failing source is configured in'          'names the source file'
want    ubuntu-badrepo 'apt ready \(index refreshed with errors\)' 'success is qualified'
nowant  ubuntu-badrepo '\[ok\] apt ready$'                        'no bare success claim'

# 5. Arch desktop, colour + glyphs on a real pty — catches ${VAR} leaks.
run arch-desktop arch "$WORK/k-fzf" \
    STUB_FZF_PICK1="zsh git" STUB_TERM=xterm-256color STUB_LANG=en_US.UTF-8
check   arch-desktop 0
want    arch-desktop 'Tools verified'                     'pacman path works'

# 6. WSL: real Ubuntu userland, no Linux-side fonts worth installing.
run ubuntu-wsl ubuntu "$WORK/k-fzf" STUB_FZF_PICK1="zsh" WSL_DISTRO_NAME=Ubuntu
check   ubuntu-wsl 0
want    ubuntu-wsl 'WSL'                                  'WSL detected'

# 7. Private mode with a working git (uses git config --unset).
run ubuntu-private ubuntu "$WORK/k-private" STUB_FZF_PICK1="fastfetch"
check   ubuntu-private 0
want    ubuntu-private 'private'                          'private selected'

# 8. Private mode where git does nothing when asked — the scrub must notice and
#    finish with sed rather than report a success it did not achieve.
STUB_DEAD_GIT=1 run ubuntu-private-deadgit ubuntu "$WORK/k-private" \
    STUB_FZF_PICK1="fastfetch" STUB_DEAD_GIT=1
check   ubuntu-private-deadgit 0
nowant  ubuntu-private-deadgit 'Still present in'         'no leftover identity'

# 9. A dead PPA left by an earlier run breaks every refresh; ours to clean up.
STUB_DEAD_PPA=1 run ubuntu-deadppa ubuntu "$WORK/k-fzf" \
    STUB_FZF_PICK1="git" STUB_DEAD_PPA=1
check   ubuntu-deadppa 0
want    ubuntu-deadppa 'Removed a dead source from an earlier run' 'stale PPA cleaned up'
want    ubuntu-deadppa '\[ok\] apt ready$'                      'index healthy afterwards'

# 10. unattended-upgrades sitting on the dpkg lock, and the user says yes.
STUB_LOCKED=1 run ubuntu-locked-yes ubuntu "$WORK/k-lock-yes" \
    STUB_FZF_PICK1="git" STUB_LOCKED=1
check   ubuntu-locked-yes 0
want    ubuntu-locked-yes 'Still locked by unattended-upgr'  'names the holder'
want    ubuntu-locked-yes 'the lock is the process, not the file' 'corrects the usual advice'
want    ubuntu-locked-yes 'Lock released'                    'holder stopped'
want    ubuntu-locked-yes 'Tools verified'                   'install proceeds'

# 11. Same, but the user declines — must fail cleanly, not thrash.
STUB_LOCKED=1 run ubuntu-locked-no ubuntu "$WORK/k-lock-no" \
    STUB_FZF_PICK1="git" STUB_LOCKED=1
check   ubuntu-locked-no 1
want    ubuntu-locked-no 'Left running'                      'choice respected'
nowant  ubuntu-locked-no 'Stale package index'               'no pointless retry noise'

# 12. dpkg left half-configured by something that was force-quit.
STUB_DPKG_INTERRUPTED=1 run ubuntu-dpkg-broken ubuntu "$WORK/k-fzf" \
    STUB_FZF_PICK1="git" STUB_DPKG_INTERRUPTED=1
check   ubuntu-dpkg-broken 0
want    ubuntu-dpkg-broken 'dpkg was left half-configured'   'detected'
want    ubuntu-dpkg-broken 'Tools verified'                  'repaired and continued'

# 13. Picking bash stows the rc and keeps a pristine copy of the original.
run ubuntu-bash ubuntu "$WORK/k-fzf" STUB_FZF_PICK1="bash"
check   ubuntu-bash 0
want    ubuntu-bash 'pristine copy'   'says it is keeping one'
d="$WORK/run/ubuntu-bash/home"
[ -L "$d/.bashrc" ]      && note ubuntu-bash "~/.bashrc is stowed" || bad ubuntu-bash "~/.bashrc not stowed"
[ -f "$d/.bashrc.orig" ] && note ubuntu-bash "pristine copy kept"  || bad ubuntu-bash "no pristine copy"
grep -q 'hand interactive bash to zsh' "$d/.bashrc.orig" 2>/dev/null \
    && bad ubuntu-bash "pristine copy carries a hook" || note ubuntu-bash "pristine copy is hook-free"

# 14. bash and zsh together: the hand-off hook must not be written into the
#     rc we just stowed, which is a symlink into the checkout.
run ubuntu-bash-zsh ubuntu "$WORK/k-fzf" STUB_FZF_PICK1="bash zsh"
check   ubuntu-bash-zsh 0
want    ubuntu-bash-zsh 'leaving ~/.bashrc as a working bash' 'hook skipped'
d="$WORK/run/ubuntu-bash-zsh/home/dotfiles/bash/.bashrc"
if [ -f "$d" ] && ! grep -q 'hand interactive bash to zsh' "$d"; then
    note ubuntu-bash-zsh "repo bash/.bashrc not written into"
else
    bad  ubuntu-bash-zsh "hook leaked into the repo's bash/.bashrc"
fi

# 15. An existing starship.toml is the user's, and is left where it is.
STUB_PRESEED_STARSHIP=1 run ubuntu-keepstar ubuntu "$WORK/k-fzf" \
    STUB_FZF_PICK1="starship"
check   ubuntu-keepstar 0
want    ubuntu-keepstar 'Keeping your existing' 'existing starship.toml kept'
if [ -f "$WORK/run/ubuntu-keepstar/home/.config/starship.toml" ] \
   && ! [ -L "$WORK/run/ubuntu-keepstar/home/.config/starship.toml" ] \
   && grep -q 'MINE' "$WORK/run/ubuntu-keepstar/home/.config/starship.toml"; then
    note ubuntu-keepstar "still their own file, untouched"
else
    bad  ubuntu-keepstar "their starship.toml was replaced"
fi

echo
echo "── interrupt ────────────────────────────────────────────"
# Ctrl-C has to stop the run. A trap that only cleans up does not: bash runs
# the handler and carries on, which is how a wait loop became unkillable.
ipt="$WORK/run/interrupt"
rm -rf "$ipt"; mkdir -p "$ipt/home" "$ipt/state" "$ipt/etc/apt/sources.list.d" "$ipt/share"
cp -a "$REPO" "$ipt/home/dotfiles"; rm -rf "$ipt/home/dotfiles/tests"
printf 'ID=ubuntu\nID_LIKE=debian\nVERSION_CODENAME=noble\n' > "$ipt/etc/os-release"
printf '/bin/sh\n' > "$ipt/etc/shells"; : > "$ipt/state/installed"
sandbox_repo "$ipt"
mkfifo "$ipt/keys"
# A real Ctrl-C, not a signal aimed at a pid: hold the fifo open, then write
# the interrupt character into the pty and let its line discipline turn that
# into SIGINT for the foreground process group — exactly what a keyboard does.
# `pkill -f 'bash ./install.sh'` matched script(1) too, so the two raced and
# the installer usually died by timeout instead of by the trap under test.
( exec 3>"$ipt/keys"; sleep 4; printf '\003' >&3; sleep 15; exec 3>&- ) &
holder=$!
# Foreground, deliberately, and with SIGINT forced back to its default.
#
# A non-interactive shell sets SIGINT to SIG_IGN in any child it starts
# asynchronously, and bash will not un-ignore a signal that was already ignored
# when it started — `trap _interrupt INT` becomes a silent no-op. That applies
# to everything below this shell, so it bites twice: once if the pty session is
# backgrounded here, and again if the whole suite was itself started in the
# background (nohup, &, most CI runners). The second one is invisible and makes
# this test pass interactively while failing in CI, which is worse than either.
# env(1) resets the disposition for the process it execs, which fixes both.
ENV_SIGDFL=()
env --default-signal=INT true 2>/dev/null && ENV_SIGDFL=(--default-signal=INT)
irc=0
( cd "$ipt/home/dotfiles" && env -i ${ENV_SIGDFL[@]+"${ENV_SIGDFL[@]}"} \
    HOME="$ipt/home" USER="$(id -un)" \
    PATH="$WORK/bin:$WORK/sysbin" TERM=dumb LANG=C SHELL=/bin/bash \
    STUB_STATE="$ipt/state" STUB_BIN="$WORK/bin" STUB_ROOT="$ipt" \
    timeout 60 script -qec "bash ./install.sh" /dev/null \
        < "$ipt/keys" > "$ipt/out.txt" 2>&1 ) || irc=$?
kill "$holder" 2>/dev/null
if [ "$irc" = 130 ]; then note interrupt "Ctrl-C exits 130"; else bad interrupt "Ctrl-C gave exit $irc"; fi
if grep -q 'Interrupted' "$ipt/out.txt"; then note interrupt "says so"; else bad interrupt "no message"; fi

echo
echo "── private-mode residue ─────────────────────────────────"
# Whatever identity the checked-in .gitconfig carries must be gone afterwards,
# along with this repo's own URL and the host the bootstrap is served from.
# All three are derived from the files, never hardcoded here.
#
# Note what is deliberately NOT asserted: a bare 'github.com/'. The configs are
# full of upstream URLs — zinit, catppuccin, nerd-fonts, fastfetch's schema —
# and the installer needs them to download anything at all. Private mode
# removes the URL that says whose this is, not every URL in the tree.
mapfile -t IDENT < <(sed -nE 's/^[[:space:]]*(name|email)[[:space:]]*=[[:space:]]*//p' \
    "$REPO/git/.gitconfig" 2>/dev/null)
# owner/repo out of linux.sh's REPO=, and the bootstrap host out of the README
REPO_SLUG="$(sed -nE 's#^REPO=https?://github\.com/([^/]+/[^/ ]+)\.git.*#\1#p' \
    "$REPO/linux.sh" 2>/dev/null | head -1)"
BOOT_HOST="$(grep -ohE '[A-Za-z0-9.-]+/linux\.sh' "$REPO/README.md" 2>/dev/null \
    | sed 's#/linux\.sh$##' | sort -u | head -1)"
for scen in ubuntu-private ubuntu-private-deadgit; do
    d="$WORK/run/$scen/home/dotfiles"
    for pat in "${IDENT[@]}" "$REPO_SLUG" "$BOOT_HOST"; do
        [ -n "$pat" ] || continue
        if grep -rqiF -- "$pat" "$d" 2>/dev/null; then
            bad  "$scen" "'$pat' still present"
        else
            note "$scen" "'$pat' removed"
        fi
    done
    if [ -f "$d/install.sh" ] && bash -n "$d/install.sh" 2>/dev/null; then
        note "$scen" "scrubbed install.sh still parses"
    else
        bad  "$scen" "scrubbed install.sh broken"
    fi
done

echo
echo "─────────────────────────────────────────────────────────"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
