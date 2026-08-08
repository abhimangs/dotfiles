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
#
# Both single-key prompts come first for a reason: `read -n 1` switches the tty
# to raw mode and the pending input queue is dropped with it, so a keystroke
# written minutes earlier is gone by the time a later pick2 asks for it.
# Trailing Enters are padding: `script` delivers EOF to exactly one read and
# blocks every one after it, so a file that runs out one prompt early hangs for
# the full timeout instead of failing an assertion. Every prompt past the last
# meaningful key defaults to yes on Enter.
printf '\n\n\n\n\n'        > "$WORK/k-fzf"      # menus answered by the fzf stub
printf '\n\n2\n\n\n\n\n'   > "$WORK/k-num"      # numeric menu: config 2, skip, skip
printf 'p\n\n\n\n\n'       > "$WORK/k-private"  # private mode, then fzf menus
printf '\n\ny\n\n\n\n'     > "$WORK/k-lock-yes" # ... then "yes, stop the updater"
printf '\n\nn\n\n\n\n'     > "$WORK/k-lock-no"  # ... then "no, leave it"
# --restore-bash skips every prompt above it and asks exactly one question.
printf '\n\n'          > "$WORK/k-restore"    # Proceed? → yes
printf 'n\n'           > "$WORK/k-restore-no" # Proceed? → no

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

# 5b. Arch box that already has yay: it is used as-is, no paru is built.
STUB_YAY_ONLY=1 run arch-yay arch "$WORK/k-fzf" \
    STUB_FZF_PICK1="git" STUB_YAY_ONLY=1
check   arch-yay 0
want    arch-yay 'yay already installed'          'existing helper reused'
nowant  arch-yay 'installing paru'                'no bootstrap'
nowant  arch-yay 'Cloning'                        'nothing cloned from the AUR'

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

# 15b. Apps without dotfiles: the config menu is skippable, so nothing of the
#      user's is touched and the backup question is never asked.
run ubuntu-appsonly ubuntu "$WORK/k-fzf" STUB_FZF_PICK3="docker"
check   ubuntu-appsonly 0
want    ubuntu-appsonly 'No configs selected'      'empty config menu accepted'
want    ubuntu-appsonly 'nothing names them'       'fonts skipped with no configs'
nowant  ubuntu-appsonly 'Nothing selected'         'run continues to the apps'
d="$WORK/run/ubuntu-appsonly/home"
[ -e "$d/.zshrc" ] || [ -e "$d/.config/starship.toml" ] \
    && bad ubuntu-appsonly "a config was stowed anyway" \
    || note ubuntu-appsonly "no config stowed"

# 15c. ... but three empty menus still means there is nothing to do.
run ubuntu-nothing ubuntu "$WORK/k-fzf"
check   ubuntu-nothing 0
want    ubuntu-nothing 'Nothing selected'          'empty run stops'
nowant  ubuntu-nothing 'Installation plan'         'stops before the plan'

echo
echo "── docker app selection ─────────────────────────────────"
# 16. Docker: the first-ever exercise of the "applications" fzf menu in this
#     suite (no earlier scenario picked one, so this also proves the menu
#     itself works, not just docker). Arch takes the plain pacman path —
#     docker, docker-compose and docker-buildx are all in the official repo,
#     no bespoke bootstrap needed.
run arch-docker arch "$WORK/k-fzf" STUB_FZF_PICK1="git" STUB_FZF_PICK3="docker"
check   arch-docker 0
want    arch-docker 'Docker \+ Compose.*done' 'app reported installed'
d="$WORK/run/arch-docker"
for p in docker docker-compose docker-buildx; do
    grep -qxF "$p" "$d/state/installed" \
        && note arch-docker "$p installed" || bad arch-docker "$p missing"
done
grep -q 'usermod -aG docker' "$d/state/sudo.log" \
    && note arch-docker "user added to docker group" || bad arch-docker "no usermod call"
grep -q 'systemctl enable --now docker' "$d/state/sudo.log" \
    && note arch-docker "docker.service enabled" || bad arch-docker "no systemctl enable call"

# 17. Debian: needs the full repo bootstrap first — GPG key, sources.list.d
#     entry, apt update — before docker-ce is even installable. This is also
#     the first scenario to exercise apt_install_keyring end to end.
run debian-docker debian "$WORK/k-fzf" STUB_FZF_PICK1="git" STUB_FZF_PICK3="docker"
check   debian-docker 0
want    debian-docker 'Docker \+ Compose.*done' 'app reported installed'
d="$WORK/run/debian-docker"
for p in docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; do
    grep -qxF "$p" "$d/state/installed" \
        && note debian-docker "$p installed" || bad debian-docker "$p missing"
done
src="$d/etc/apt/sources.list.d/docker.list"
if [ -f "$src" ] && grep -q 'download.docker.com/linux/debian' "$src" && grep -q 'bookworm' "$src"; then
    note debian-docker "docker.list points at the debian repo + codename"
else
    bad  debian-docker "docker.list missing or wrong host/codename"
fi
[ -s "$d/etc/apt/keyrings/docker.asc" ] \
    && note debian-docker "keyring written" || bad debian-docker "keyring missing"
grep -q 'usermod -aG docker' "$d/state/sudo.log" \
    && note debian-docker "user added to docker group" || bad debian-docker "no usermod call"
grep -q 'systemctl enable --now docker' "$d/state/sudo.log" \
    && note debian-docker "docker.service enabled" || bad debian-docker "no systemctl enable call"

# 18. Ubuntu: same repo bootstrap, but the ubuntu host + noble codename, so a
#     copy-paste of the debian URL would go undetected without this.
run ubuntu-docker ubuntu "$WORK/k-fzf" STUB_FZF_PICK1="git" STUB_FZF_PICK3="docker"
check   ubuntu-docker 0
d="$WORK/run/ubuntu-docker"
src="$d/etc/apt/sources.list.d/docker.list"
if [ -f "$src" ] && grep -q 'download.docker.com/linux/ubuntu' "$src" && grep -q 'noble' "$src"; then
    note ubuntu-docker "docker.list points at the ubuntu repo + codename"
else
    bad  ubuntu-docker "docker.list missing or wrong host/codename"
fi

echo
echo "── restore bash ─────────────────────────────────────────"
# --restore-bash is the undo for the zsh setup, and the last thing between a
# botched zsh install and a box you cannot get a usable shell on over SSH. It
# only means anything after an install has happened, so every scenario here runs
# install.sh twice against ONE sandbox: `run` builds it, `rerun` re-enters the
# root the first pass left behind, and RUN_ARGS carries the flag in.

# 16. The ordinary undo. The bar is not "close enough" — the rc the user wrote
#     has to come back byte for byte, and the pristine copy has to survive it,
#     or the second attempt at an undo has nothing to work from.
run     restore-zsh ubuntu "$WORK/k-fzf" STUB_FZF_PICK1="zsh"
check   restore-zsh 0
rb_zsh="$WORK/run/restore-zsh/home"
grep -q 'hand interactive bash to zsh (v2)' "$rb_zsh/.bashrc" 2>/dev/null \
    && note restore-zsh "install wrote the v2 hook" \
    || bad  restore-zsh "no hook written — the undo below would prove nothing"

#     Dry run first, and on this sandbox rather than a fresh one: a dry run over
#     a machine with nothing to undo cannot tell you whether it writes. Compared
#     as a full checksum manifest, not a list of paths a human thought of — the
#     failure that matters in a mode whose whole contract is "no writes" is the
#     write nobody went looking for.
manifest "$rb_zsh" > "$WORK/mf-dry-before"
RUN_ARGS="--restore-bash --dry-run" rerun restore-dry restore-zsh "$WORK/k-restore"
check   restore-dry 0
want    restore-dry 'Restore bash'                  'plan is printed'
want    restore-dry 'remove.*hand-off block'        'plan names the real work'
want    restore-dry 'dry run'                       'says nothing changed'
nowant  restore-dry 'Proceed\?'                     'never prompts'
manifest "$rb_zsh" > "$WORK/mf-dry-after"
cmp -s "$WORK/mf-dry-before" "$WORK/mf-dry-after" \
    && note restore-dry "sandbox HOME is untouched" \
    || bad  restore-dry "dry run wrote to HOME"

RUN_ARGS=--restore-bash rerun restore-undo restore-zsh "$WORK/k-restore"
check   restore-undo 0
want    restore-undo 'bash restored'                'reports success'
nowant  restore-undo 'Tools verified'               'short-circuits before the installer'
cmp -s "$SEED_BASHRC" "$rb_zsh/.bashrc" \
    && note restore-undo "~/.bashrc is byte-identical to the original" \
    || bad  restore-undo "~/.bashrc came back changed"
grep -q 'hand interactive bash to zsh' "$rb_zsh/.bashrc" 2>/dev/null \
    && bad  restore-undo "hook block still in ~/.bashrc" \
    || note restore-undo "no hook left behind"
[ -f "$rb_zsh/.bashrc.orig" ] \
    && note restore-undo "pristine copy kept, so this is repeatable" \
    || bad  restore-undo "pristine copy consumed by the restore"
{ [ -L "$rb_zsh/.zshrc" ] || [ -e "$rb_zsh/.zshrc" ]; } \
    && bad  restore-undo "~/.zshrc still stowed" \
    || note restore-undo "~/.zshrc unstowed"
# The passwd change is the step that locks people out, so it is asserted on the
# stub's own record rather than on a line of output claiming it happened.
lsh="$(cat "$WORK/run/restore-zsh/state/login_shell" 2>/dev/null)"
[ "$(basename "${lsh:-none}")" = bash ] \
    && note restore-undo "login shell is back to bash" \
    || bad  restore-undo "login shell is ${lsh:-unset}"

# 17. Someone who is not sure the first one worked runs it again. A second pass
#     has to be a no-op — the pristine copy is deliberately kept, so re-running
#     must not turn that into a way to end up with a *different* rc than the
#     first pass produced.
RUN_ARGS=--restore-bash rerun restore-again restore-zsh "$WORK/k-restore"
check   restore-again 0
nowant  restore-again 'remove the zsh hand-off block' 'nothing left to strip'
cmp -s "$SEED_BASHRC" "$rb_zsh/.bashrc" \
    && note restore-again "still byte-identical after a second run" \
    || bad  restore-again "second run changed ~/.bashrc"

# 18. On the documented curl bootstrap the flag physically cannot get through:
#     `curl | bash` hands bash the script on stdin, so there is no argv for
#     linux.sh to forward, whatever it does with "$@". The env var is the only
#     door, and it has to open onto exactly the same code. Declining comes first
#     on this sandbox, since "n" only proves anything while there is still
#     something left to lose.
run     restore-env ubuntu "$WORK/k-fzf" STUB_FZF_PICK1="zsh"
check   restore-env 0
rb_env="$WORK/run/restore-env/home"
manifest "$rb_env" > "$WORK/mf-decline-before"
RUN_ARGS=--restore-bash rerun restore-declined restore-env "$WORK/k-restore-no"
check   restore-declined 0
want    restore-declined 'Proceed\?'                'the prompt was reached'
nowant  restore-declined 'Restoring bash'           'n stops before any write'
manifest "$rb_env" > "$WORK/mf-decline-after"
cmp -s "$WORK/mf-decline-before" "$WORK/mf-decline-after" \
    && note restore-declined "sandbox HOME is untouched" \
    || bad  restore-declined "a declined restore still wrote to HOME"

rerun   restore-envvar restore-env "$WORK/k-restore" DOTFILES_RESTORE_BASH=1
check   restore-envvar 0
want    restore-envvar 'Restore bash'               'env var takes the restore path'
nowant  restore-envvar 'Tools verified'             'short-circuits before the installer'
cmp -s "$SEED_BASHRC" "$rb_env/.bashrc" \
    && note restore-envvar "~/.bashrc is byte-identical to the original" \
    || bad  restore-envvar "env var path restored something else"

# 19. A container or a minimal image with no ~/.bashrc at all. The installer
#     creates one to hold the hook, so the undo cannot strip the hook and call
#     it done — that leaves a file the machine never had and no bash config in
#     it. .bashrc.none is how the restore knows there is no original to put back
#     and that bash/.bashrc is what belongs there instead.
STUB_NO_BASHRC=1 run restore-nobashrc ubuntu "$WORK/k-fzf" STUB_FZF_PICK1="zsh"
check   restore-nobashrc 0
rb_none="$WORK/run/restore-nobashrc/home"
[ -f "$rb_none/.bashrc.none" ] \
    && note restore-nobashrc "absence recorded as ~/.bashrc.none" \
    || bad  restore-nobashrc "no ~/.bashrc.none written"
[ -e "$rb_none/.bashrc.orig" ] \
    && bad  restore-nobashrc "invented a pristine copy of a file that never existed" \
    || note restore-nobashrc "no bogus pristine copy"
RUN_ARGS=--restore-bash rerun restore-nobashrc-undo restore-nobashrc "$WORK/k-restore"
check   restore-nobashrc-undo 0
want    restore-nobashrc-undo 'there was no ~/.bashrc to restore' 'plan takes the repo path'
grep -q 'hand interactive bash to zsh' "$rb_none/.bashrc" 2>/dev/null \
    && bad  restore-nobashrc-undo "hook block still in ~/.bashrc" \
    || note restore-nobashrc-undo "no hook left behind"
# Stripping the hook out of the file the installer created leaves the file
# itself behind (1 byte, the newline the block was appended after), and stow
# refuses to write over a real file — so `stow_home bash` in restore_bash's
# `repo` branch would conflict and lose while the run still printed "bash
# restored". restore_bash clears that leftover first; this is what holds it to it.
if [ -e "$rb_none/.bashrc" ] && cmp -s "$rb_none/.bashrc" "$REPO/bash/.bashrc"; then
    note restore-nobashrc-undo "repo bash/.bashrc laid down"
else
    bad  restore-nobashrc-undo \
        "left a $(wc -c <"$rb_none/.bashrc" 2>/dev/null || echo 0)-byte ~/.bashrc, not bash/.bashrc"
fi

# 20. Every machine an earlier version of this installer touched already carries
#     a v1 block. Stacking a v2 one on top gives bash two execs and gives the
#     undo one range to strip, so the surviving half keeps handing every session
#     to zsh forever — with the flag that was supposed to stop it reporting
#     success. The pristine copy is taken on this same run, and it is write-once:
#     if it captures the v1 block, the wrong file is preserved permanently.
STUB_V1_HOOK=1 run restore-v1hook ubuntu "$WORK/k-fzf" STUB_FZF_PICK1="zsh"
check   restore-v1hook 0
rb_v1="$WORK/run/restore-v1hook/home"
v2n=$(grep -c '^# >>> hand interactive bash to zsh (v2) >>>' "$rb_v1/.bashrc" 2>/dev/null)
v1n=$(grep -c '^# >>> dotfiles: hand interactive bash to zsh >>>' "$rb_v1/.bashrc" 2>/dev/null)
[ "${v2n:-0}" = 1 ] \
    && note restore-v1hook "exactly one v2 block" \
    || bad  restore-v1hook "${v2n:-0} v2 blocks in ~/.bashrc"
[ "${v1n:-0}" = 0 ] \
    && note restore-v1hook "v1 block migrated, not stacked" \
    || bad  restore-v1hook "v1 block still underneath"
cmp -s "$SEED_BASHRC" "$rb_v1/.bashrc.orig" \
    && note restore-v1hook "pristine copy is the rc from before any hook" \
    || bad  restore-v1hook "pristine copy captured a hook"
RUN_ARGS=--restore-bash rerun restore-v1hook-undo restore-v1hook "$WORK/k-restore"
check   restore-v1hook-undo 0
cmp -s "$SEED_BASHRC" "$rb_v1/.bashrc" \
    && note restore-v1hook-undo "~/.bashrc is byte-identical to the pre-v1 original" \
    || bad  restore-v1hook-undo "~/.bashrc came back changed"

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
