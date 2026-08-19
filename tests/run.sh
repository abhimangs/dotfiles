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
printf '\n\n\n\n\n'        > "$WORK/k-sel"      # selection came from --configs/--tools/--apps
printf '\n\n2\n\n\n\n\n'   > "$WORK/k-num"      # numbered menus: config 2, skip, skip
printf 'p\n\n\n\n\n'       > "$WORK/k-private"  # private mode, then straight to the plan
# The menu is driven by a *script* rather than a file of bytes: it puts the
# terminal in raw mode, which throws away anything already in the input queue,
# so its keys have to be sent once it is actually on screen. These wait for it.
cat > "$WORK/k-lib.sh" <<'FEED'
wait_for() {            # wait_for <text> — until it shows up in the transcript
    local n=300
    while (( n-- > 0 )); do
        grep -qs -- "$1" "$FEED_OUT" && return 0
        sleep 0.1
    done
    return 1
}
menu_up()   { wait_for 'ctrl-d review'; sleep 0.3; }
confirm()   { wait_for 'Proceed'; printf '\n'; sleep 1; }
FEED

cat > "$WORK/k-tui.sh" <<'FEED'
. "$WORK/k-lib.sh"
printf '\n\n'                       # privacy, existing configs
menu_up
printf ' '; sleep 0.3                # tick the row under the cursor
printf '\004'; sleep 0.4             # ctrl-d → review
printf '\004'                        # ctrl-d → accept
confirm
FEED

cat > "$WORK/k-tui-zsh.sh" <<'FEED'
. "$WORK/k-lib.sh"
printf '\n\n'
menu_up
printf '\033[B'; sleep 0.3            # down to bash
printf '\033[B'; sleep 0.3            # down to zsh
printf ' '; sleep 0.4                # tick it — starship and the tools follow
printf '\004'; sleep 0.4
printf '\004'
confirm
FEED

cat > "$WORK/k-tui-esc.sh" <<'FEED'
. "$WORK/k-lib.sh"
printf '\n\n'
menu_up
printf ' '; sleep 0.3
printf '\033'; sleep 1               # esc — cancels the whole run
FEED
printf '\n\ny\n\n\n\n'     > "$WORK/k-lock-yes" # ... then "yes, stop the updater"
printf '\n\nn\n\n\n\n'     > "$WORK/k-lock-no"  # ... then "no, leave it"
# --restore-bash skips every prompt above it and asks exactly one question.
printf '\n\n'          > "$WORK/k-restore"    # Proceed? → yes
printf 'n\n'           > "$WORK/k-restore-no" # Proceed? → no
printf '\n\033[B\n\n\n'    > "$WORK/k-del"       # keep · delete · then the plan

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
run ubuntu-headless ubuntu "$WORK/k-sel" \
    DOTFILES_CONFIGS="zsh,git" SSH_CONNECTION="10.0.0.2 22 10.0.0.1 22"
check   ubuntu-headless 0
want    ubuntu-headless 'Tools verified'                  'stow+fzf installed'
want    ubuntu-headless 'zsh needs these for its aliases' 'zsh pulls the toolchain'
want    ubuntu-headless 'adding starship'                 'zsh pulls starship'
want    ubuntu-headless 'ssh -O exit'                     'SSH multiplexing hint'
nowant  ubuntu-headless 'Failed \([1-9]'                  'nothing failed'

# 2. Same box, logged in as root, with no sudo at all.
run ubuntu-root ubuntu "$WORK/k-sel" DOTFILES_CONFIGS="zsh" STUB_FAKE_ROOT=1
check   ubuntu-root 0
want    ubuntu-root 'Running as root'                     'root path taken'
want    ubuntu-root 'Tools verified'                      'installs work as root'

# 3. Debian 12 on a terminal that cannot draw the menu (TERM=dumb, which is the
#    harness default) — the numbered lists have to carry the whole selection.
STUB_NO_FZF=1 run debian-nofzf debian "$WORK/k-num" STUB_NO_FZF=1
check   debian-nofzf 0
want    debian-nofzf 'cannot draw the menu'               'fallback taken'
want    debian-nofzf 'Choice \(e.g. 1 4'                  'numbered list drawn'
want    debian-nofzf 'Tools verified'                     'installs work'

# 4. A third-party repo is broken, so every apt-get update exits non-zero.
STUB_BROKEN_REPO=1 run ubuntu-badrepo ubuntu "$WORK/k-sel" \
    DOTFILES_CONFIGS="git" STUB_BROKEN_REPO=1
check   ubuntu-badrepo 0
want    ubuntu-badrepo 'did not refresh cleanly'                  'broken index reported'
want    ubuntu-badrepo 'Failing source is configured in'          'names the source file'
want    ubuntu-badrepo 'apt ready \(index refreshed with errors\)' 'success is qualified'
nowant  ubuntu-badrepo '\[ok\] apt ready$'                        'no bare success claim'

# 5. Arch desktop, colour + glyphs on a real pty — catches ${VAR} leaks.
# STUB_TERM and STUB_LANG have to be *prefixes*: the harness expands them in its
# own shell to build the child's TERM/LANG, so passing them as arguments only
# sets variables nothing reads.
STUB_TERM=xterm-256color STUB_LANG=en_US.UTF-8 run arch-desktop arch "$WORK/k-sel" \
    DOTFILES_CONFIGS="zsh,git"
check   arch-desktop 0
want    arch-desktop 'Tools verified'                     'pacman path works'

# 5b. Arch box that already has yay: it is used as-is, no paru is built.
STUB_YAY_ONLY=1 run arch-yay arch "$WORK/k-sel" \
    DOTFILES_CONFIGS="git" STUB_YAY_ONLY=1
check   arch-yay 0
want    arch-yay 'yay already installed'          'existing helper reused'
nowant  arch-yay 'installing paru'                'no bootstrap'
nowant  arch-yay 'Cloning'                        'nothing cloned from the AUR'

# 6. WSL: real Ubuntu userland, no Linux-side fonts worth installing.
run ubuntu-wsl ubuntu "$WORK/k-sel" DOTFILES_CONFIGS="zsh" WSL_DISTRO_NAME=Ubuntu
check   ubuntu-wsl 0
want    ubuntu-wsl 'WSL'                                  'WSL detected'

# 7. Private mode with a working git (uses git config --unset).
run ubuntu-private ubuntu "$WORK/k-private" DOTFILES_CONFIGS="fastfetch"
check   ubuntu-private 0
want    ubuntu-private 'private'                          'private selected'

# 8. Private mode where git does nothing when asked — the scrub must notice and
#    finish with sed rather than report a success it did not achieve.
STUB_DEAD_GIT=1 run ubuntu-private-deadgit ubuntu "$WORK/k-private" \
    DOTFILES_CONFIGS="fastfetch" STUB_DEAD_GIT=1
check   ubuntu-private-deadgit 0
nowant  ubuntu-private-deadgit 'Still present in'         'no leftover identity'

# 9. A dead PPA left by an earlier run breaks every refresh; ours to clean up.
STUB_DEAD_PPA=1 run ubuntu-deadppa ubuntu "$WORK/k-sel" \
    DOTFILES_CONFIGS="git" STUB_DEAD_PPA=1
check   ubuntu-deadppa 0
want    ubuntu-deadppa 'Removed a dead source from an earlier run' 'stale PPA cleaned up'
want    ubuntu-deadppa '\[ok\] apt ready$'                      'index healthy afterwards'

# 10. unattended-upgrades sitting on the dpkg lock, and the user says yes.
STUB_LOCKED=1 run ubuntu-locked-yes ubuntu "$WORK/k-lock-yes" \
    DOTFILES_CONFIGS="git" STUB_LOCKED=1
check   ubuntu-locked-yes 0
want    ubuntu-locked-yes 'Still locked by unattended-upgr'  'names the holder'
want    ubuntu-locked-yes 'the lock is the process, not the file' 'corrects the usual advice'
want    ubuntu-locked-yes 'Lock released'                    'holder stopped'
want    ubuntu-locked-yes 'Tools verified'                   'install proceeds'

# 11. Same, but the user declines — must fail cleanly, not thrash.
STUB_LOCKED=1 run ubuntu-locked-no ubuntu "$WORK/k-lock-no" \
    DOTFILES_CONFIGS="git" STUB_LOCKED=1
check   ubuntu-locked-no 1
want    ubuntu-locked-no 'Left running'                      'choice respected'
nowant  ubuntu-locked-no 'Stale package index'               'no pointless retry noise'

# 12. dpkg left half-configured by something that was force-quit.
STUB_DPKG_INTERRUPTED=1 run ubuntu-dpkg-broken ubuntu "$WORK/k-sel" \
    DOTFILES_CONFIGS="git" STUB_DPKG_INTERRUPTED=1
check   ubuntu-dpkg-broken 0
want    ubuntu-dpkg-broken 'dpkg was left half-configured'   'detected'
want    ubuntu-dpkg-broken 'Tools verified'                  'repaired and continued'

# 13. Picking bash stows the rc and keeps a pristine copy of the original.
run ubuntu-bash ubuntu "$WORK/k-sel" DOTFILES_CONFIGS="bash"
check   ubuntu-bash 0
want    ubuntu-bash 'pristine copy'   'says it is keeping one'
d="$WORK/run/ubuntu-bash/home"
[ -L "$d/.bashrc" ]      && note ubuntu-bash "~/.bashrc is stowed" || bad ubuntu-bash "~/.bashrc not stowed"
[ -f "$d/.bashrc.orig" ] && note ubuntu-bash "pristine copy kept"  || bad ubuntu-bash "no pristine copy"
grep -q 'hand interactive bash to zsh' "$d/.bashrc.orig" 2>/dev/null \
    && bad ubuntu-bash "pristine copy carries a hook" || note ubuntu-bash "pristine copy is hook-free"

# 14. bash and zsh together: the hand-off hook must not be written into the
#     rc we just stowed, which is a symlink into the checkout.
run ubuntu-bash-zsh ubuntu "$WORK/k-sel" DOTFILES_CONFIGS="bash,zsh"
check   ubuntu-bash-zsh 0
want    ubuntu-bash-zsh 'leaving ~/.bashrc as a working bash' 'hook skipped'
d="$WORK/run/ubuntu-bash-zsh/home/dotfiles/bash/.bashrc"
if [ -f "$d" ] && ! grep -q 'hand interactive bash to zsh' "$d"; then
    note ubuntu-bash-zsh "repo bash/.bashrc not written into"
else
    bad  ubuntu-bash-zsh "hook leaked into the repo's bash/.bashrc"
fi

# 15. An existing starship.toml is the user's, and is left where it is.
STUB_PRESEED_STARSHIP=1 run ubuntu-keepstar ubuntu "$WORK/k-sel" \
    DOTFILES_CONFIGS="starship"
check   ubuntu-keepstar 0
want    ubuntu-keepstar 'Keeping your existing' 'existing starship.toml kept'
if [ -f "$WORK/run/ubuntu-keepstar/home/.config/starship.toml" ] \
   && ! [ -L "$WORK/run/ubuntu-keepstar/home/.config/starship.toml" ] \
   && grep -q 'MINE' "$WORK/run/ubuntu-keepstar/home/.config/starship.toml"; then
    note ubuntu-keepstar "still their own file, untouched"
else
    bad  ubuntu-keepstar "their starship.toml was replaced"
fi

# 15a. A symlink at ~/.zshrc that is not ours. backup_file used to rm any
#      symlink outright — in backup mode, whose whole promise is that nothing
#      goes away without a .bak. Someone keeping their rc in a sync folder lost
#      the link and never saw a word about it.
STUB_PRESEED_FOREIGN_ZSHRC=1 run ubuntu-foreignlink ubuntu "$WORK/k-sel" \
    DOTFILES_CONFIGS="zsh"
check   ubuntu-foreignlink 0
d="$WORK/run/ubuntu-foreignlink/home"
if [ -L "$d/.zshrc.bak" ]; then
    note ubuntu-foreignlink "their symlink was moved aside, not deleted"
else
    bad  ubuntu-foreignlink "their ~/.zshrc symlink vanished with no .bak"
fi
if [ -f "$d/Sync/zshrc" ] && grep -q 'MINE' "$d/Sync/zshrc"; then
    note ubuntu-foreignlink "the file behind it is untouched"
else
    bad  ubuntu-foreignlink "the file the link pointed at was damaged"
fi
if [ -L "$d/.zshrc" ] && [ "$(readlink -f "$d/.zshrc")" != "$(readlink -f "$d/Sync/zshrc")" ]; then
    note ubuntu-foreignlink "and ours is stowed in its place"
else
    bad  ubuntu-foreignlink "the repo's .zshrc was not stowed"
fi

# 15b. Apps without dotfiles: the config menu is skippable, so nothing of the
#      user's is touched and the backup question is never asked.
run ubuntu-appsonly ubuntu "$WORK/k-sel" DOTFILES_APPS="docker"
check   ubuntu-appsonly 0
want    ubuntu-appsonly 'No configs selected'      'empty config menu accepted'
want    ubuntu-appsonly 'nothing names them'       'fonts skipped with no configs'
nowant  ubuntu-appsonly 'Nothing selected'         'run continues to the apps'
d="$WORK/run/ubuntu-appsonly/home"
[ -e "$d/.zshrc" ] || [ -e "$d/.config/starship.toml" ] \
    && bad ubuntu-appsonly "a config was stowed anyway" \
    || note ubuntu-appsonly "no config stowed"

# 15c. ... but three empty menus still means there is nothing to do.
run ubuntu-nothing ubuntu "$WORK/k-sel"
check   ubuntu-nothing 0
want    ubuntu-nothing 'Nothing selected'          'empty run stops'
nowant  ubuntu-nothing 'Installation plan'         'stops before the plan'

# 15d. Hermes: one curl installer, identical on all three distros, and a
#      headless SSH box is where it is most wanted — so it is never in
#      GUI_APPS and these runs are headless. The stub installer exits 1
#      unless --skip-setup reaches it, which is what would otherwise stall
#      the run on Hermes' interactive setup wizard.
for _d in arch debian ubuntu; do
    run   hermes-$_d "$_d" "$WORK/k-sel" DOTFILES_APPS="hermes" \
          SSH_CONNECTION="10.0.0.2 22 10.0.0.1 22"
    check hermes-$_d 0
    want  hermes-$_d 'Hermes Agent'  'hermes reached the summary'
    [ -x "$WORK/run/hermes-$_d/home/.local/bin/hermes" ] \
        && note hermes-$_d "hermes binary installed" \
        || bad  hermes-$_d "no hermes binary"
done
unset _d

# 15e. The Antigravity CLI installs itself as `agy`, so APP_BIN is the only
#      thing tying the two names together — and it was the one curl app with no
#      entry. A second pass over the same sandbox is what shows it: with the
#      binary already in ~/.local/bin, an empty APP_BIN means an empty probe,
#      which never matches, so the run redownloads and reruns the vendor
#      installer — the same blind spot that skips the post-install check.
run     agy-first ubuntu "$WORK/k-sel" DOTFILES_APPS="antigravity-cli"
check   agy-first 0
[ -x "$WORK/run/agy-first/home/.local/bin/agy" ] \
    && note agy-first "installed as agy, not as antigravity-cli" \
    || bad  agy-first "no agy binary"
rerun   agy-again agy-first "$WORK/k-sel" DOTFILES_APPS="antigravity-cli"
check   agy-again 0
want    agy-again 'Antigravity CLI already installed' 'the plan finds agy on PATH'
nowant  agy-again 'Downloading installer'             'no second run of the installer'

# 15f. A GitHub-release .deb is an unsigned binary going into a root install,
#      so where upstream publishes a checksum it is checked. sinelaw/fresh is
#      the one of the four that does; the curl stub serves it for that repo
#      only, exactly as the real releases do.
run     debian-deb-sha debian "$WORK/k-sel" DOTFILES_CONFIGS="fresh"
check   debian-deb-sha 0
nowant  debian-deb-sha 'Checksum mismatch'            'a matching checksum is silent'
grep -qxF fresh-editor "$WORK/run/debian-deb-sha/state/installed" \
    && note debian-deb-sha "verified .deb installed" \
    || bad  debian-deb-sha "verification blocked a good .deb"

# 15g. Same run with the served checksum pointing at other bytes — a tampered
#      or truncated download. This is the assertion the whole change exists
#      for: apt must never be handed that file.
STUB_BAD_SHA=1 run debian-deb-badsha debian "$WORK/k-sel" \
    DOTFILES_CONFIGS="fresh" STUB_BAD_SHA=1
check   debian-deb-badsha 1
want    debian-deb-badsha 'Checksum mismatch'          'mismatch is reported, not swallowed'
want    debian-deb-badsha 'Refusing to install'        'and says what it did about it'
grep -qxF fresh-editor "$WORK/run/debian-deb-badsha/state/installed" \
    && bad  debian-deb-badsha "apt installed the .deb anyway" \
    || note debian-deb-badsha "nothing was installed"
# 15h. The rest of the curl apps, in one pass. Each installs into its own bin
#      dir — the reason CURL_APP_PATH exists at all — and each of the real ones
#      appends a PATH block to ~/.zshrc unless it is handed the opt-out that
#      APP_CURL_ARGS/APP_CURL_ENV carries. ~/.zshrc is a stow symlink into the
#      checkout by the time the apps loop runs, so that write lands on a tracked
#      dotfile; the stub installers do it whenever the opt-out is missing, which
#      is what makes "no rc file was touched" an assertion rather than a hope.
run     curlapps ubuntu "$WORK/k-sel" DOTFILES_CONFIGS="zsh" \
        DOTFILES_APPS="claude-code,codex-cli,opencode,kimi-code,muse,bun"
check   curlapps 0
d="$WORK/run/curlapps/home"
for b in .local/bin/claude .local/bin/codex .opencode/bin/opencode \
         .kimi-code/bin/kimi .local/bin/muse .bun/bin/bun; do
    [ -x "$d/$b" ] && note curlapps "${b##*/} installed in ${b%/*}" \
                   || bad  curlapps "no ${b##*/} at ~/$b"
done
nowant  curlapps 'is not on PATH'    'every installer produced its binary'
nowant  curlapps 'Failed \('         'nothing failed'
# Both rc files and the checkout behind the symlink, in one sweep — an append
# to ~/.zshrc follows it into the repo copy, which is the damage that matters.
if grep -rqs 'STUB PATH BLOCK\|STUB COMPLETIONS' "$d"; then
    bad  curlapps "an installer edited a shell rc — an opt-out did not arrive"
else
    note curlapps "no installer touched a shell rc"
fi

# Second pass over the same sandbox: found where they were left, not reinstalled.
rerun   curlapps-again curlapps "$WORK/k-sel" \
        DOTFILES_APPS="claude-code,codex-cli,opencode,kimi-code,muse,bun"
check   curlapps-again 0
want    curlapps-again 'Claude Code CLI already installed' 'found in ~/.local/bin'
want    curlapps-again 'OpenCode already installed'        'found in ~/.opencode/bin'
want    curlapps-again 'Kimi Code CLI already installed'   'found in ~/.kimi-code/bin'
want    curlapps-again 'Bun already installed'             'found in ~/.bun/bin'
nowant  curlapps-again 'Downloading installer'             'no installer runs twice'

# 15i. bun is the one curl app with a prerequisite of its own: the installer
#      unpacks a zip, so ensure_unzip has to run first, and unzip is in neither
#      distro's base install. Apps only — the font step wants unzip too, and
#      with no config selected it never runs, so this stays about bun. The stub
#      installer exits 1 without unzip, so a dropped ensure_unzip fails here.
STUB_NO_UNZIP=1 run bun-unzip ubuntu "$WORK/k-sel" DOTFILES_APPS="bun"
check   bun-unzip 0
grep -qxF unzip "$WORK/run/bun-unzip/state/installed" \
    && note bun-unzip "ensure_unzip installed it first" \
    || bad  bun-unzip "unzip was never installed"
[ -x "$WORK/run/bun-unzip/home/.bun/bin/bun" ] \
    && note bun-unzip "bun installed" || bad bun-unzip "no bun binary"

# 15j. Devin is the curl app that installs cleanly and *then* fails: its
#      installer ends by running `devin setup`, an interactive login with no
#      flag to skip it, which exits non-zero the moment it is cancelled. The
#      binary is on disk and the exit status says failure, so the run has to
#      believe the binary. The stub reproduces both halves, and reads a line
#      from stdin as well — which only produces anything if </dev/null failed
#      to reach it, i.e. if a real run would have stalled on that login. Arch
#      and Ubuntu because a missing APP_TYPE_DEB entry is the way this lands on
#      `apt install devin` instead; Debian takes the identical branch.
for _d in arch ubuntu; do
    run    devin-$_d "$_d" "$WORK/k-sel" DOTFILES_APPS="devin" \
           SSH_CONNECTION="10.0.0.2 22 10.0.0.1 22"
    check  devin-$_d 0
    want   devin-$_d 'Devin CLI installed'  'a cancelled login is not a failed install'
    nowant devin-$_d 'Failed \('            'and nothing reached the failure list'
    [ -x "$WORK/run/devin-$_d/home/.local/bin/devin" ] \
        && note devin-$_d "devin binary installed" \
        || bad  devin-$_d "no devin binary"
done
unset _d
rerun   devin-again devin-ubuntu "$WORK/k-sel" DOTFILES_APPS="devin"
check   devin-again 0
want    devin-again 'Devin CLI already installed' 'found in ~/.local/bin'
nowant  devin-again 'Downloading installer'       'no second run of the installer'

echo
echo "── the menu ─────────────────────────────────────────────"
# The menu draws itself, so these drive it by keystroke on a real pty. TERM has
# to say the terminal can draw; every other scenario leaves it at dumb, which is
# what keeps them on the numbered lists.
STUB_TERM=xterm-256color STUB_LANG=en_US.UTF-8 run tui-tick ubuntu "$WORK/k-tui.sh"
check   tui-tick 0
want    tui-tick 'Choose what to install'      'the menu ran'
want    tui-tick 'Configs: .*fastfetch'        'space ticked the row under the cursor'
nowant  tui-tick 'Choice \(e.g.'               'the numbered list was not used'
nowant  tui-tick 'Cancelled'                   'ctrl-d twice accepted'

# Ticking zsh has to pull starship and the tools in the menu itself, not in a
# message after it closes.
STUB_TERM=xterm-256color STUB_LANG=en_US.UTF-8 run tui-zsh ubuntu "$WORK/k-tui-zsh.sh"
check   tui-zsh 0
want    tui-zsh 'Configs: .*zsh'               'cursor moved to zsh and ticked it'
want    tui-zsh 'Configs: .*starship'          'starship came with it'
want    tui-zsh 'Dep tools: .*bat.*eza'        'the toolchain came with it'
nowant  tui-zsh 'zsh needs these for its aliases' 'ticked in the menu, not bolted on after'

# esc is a cancel, not a skip: nothing installed, nothing asked afterwards.
STUB_TERM=xterm-256color STUB_LANG=en_US.UTF-8 run tui-esc ubuntu "$WORK/k-tui-esc.sh"
check   tui-esc 0
want    tui-esc 'Cancelled'                    'esc stops the run'
nowant  tui-esc 'Installation plan'            'no plan after a cancel'
d="$WORK/run/tui-esc/home"
[ -e "$d/.zshrc" ] || [ -e "$d/.gitconfig" ] \
    && bad tui-esc "something was installed after a cancel" \
    || note tui-esc "nothing touched"

# Typing filters the menu you are in, and ticking works on what is left.
cat > "$WORK/k-tui-search.sh" <<'FEED'
. "$WORK/k-lib.sh"
printf '\n\n'
menu_up
printf 'git'; sleep 0.5               # filter down to one row
printf ' '; sleep 0.4                 # tick it
printf '\004'; sleep 0.4
printf '\004'
confirm
FEED
STUB_TERM=xterm-256color STUB_LANG=en_US.UTF-8 run tui-search ubuntu "$WORK/k-tui-search.sh"
check   tui-search 0
want    tui-search 'Configs: git$'             'search narrowed it to git and ticked that'

# ctrl-a takes the whole menu you are looking at, and nothing from the others.
cat > "$WORK/k-tui-all.sh" <<'FEED'
. "$WORK/k-lib.sh"
printf '\n\n'
menu_up
printf '\033[C'; sleep 0.5            # right → tools
printf '\001'; sleep 0.5             # ctrl-a → all of them
printf '\004'; sleep 0.4
printf '\004'
confirm
FEED
STUB_TERM=xterm-256color STUB_LANG=en_US.UTF-8 run tui-all ubuntu "$WORK/k-tui-all.sh"
check   tui-all 0
want    tui-all 'Dep tools: .*bat.*eza.*fd.*zoxide.*pay-respects.*lazygit.*btop.*tree' 'every tool ticked'
want    tui-all 'No configs selected'          'and nothing from the other menus'

# --ascii: no box-drawing characters, no Nerd Font glyphs, same menu.
RUN_ARGS=--ascii STUB_TERM=xterm-256color STUB_LANG=en_US.UTF-8 \
    run tui-ascii ubuntu "$WORK/k-tui.sh"
check   tui-ascii 0
want    tui-ascii 'Configs: .*fastfetch'       'the menu works in ascii mode'
nowant  tui-ascii '─'                          'no box-drawing characters anywhere'

# An 80x24 window: the boxes have to shrink, not overflow.
STUB_TTY_ROWS=24 STUB_TTY_COLS=80 STUB_TERM=xterm-256color STUB_LANG=en_US.UTF-8 \
    run tui-narrow ubuntu "$WORK/k-tui.sh"
check   tui-narrow 0
want    tui-narrow 'Configs: .*fastfetch'      'usable on a small terminal'

# A pty with no size at all must fall back rather than draw a broken frame.
STUB_NO_SIZE=1 STUB_TERM=xterm-256color run tui-nosize ubuntu "$WORK/k-num" STUB_NO_SIZE=1
check   tui-nosize 0
want    tui-nosize 'cannot draw the menu'      'declined to draw'
want    tui-nosize 'Choice \(e.g. 1 4'         'numbered list instead'

# bat and btop carry a theme as well as a binary, so picking them touches
# ~/.config — which delete mode removes with no .bak. The plan has to say so
# before the Proceed prompt, not after the fact.
STUB_PRESEED_BTOP=1 RUN_ARGS="--dry-run --tools=btop" run dep-config-plan ubuntu "$WORK/k-del"
check   dep-config-plan 0
want    dep-config-plan 'delete.*~/.config/btop'   'the plan warns before deleting a dep config'
want    dep-config-plan 'stow → ~/.config/btop'    'and says it stows the theme'

echo
echo "── selection flags ──────────────────────────────────────"
# --configs/--tools/--apps skip the menu entirely, which is what makes an
# unattended run possible — and what the rest of this suite drives.
RUN_ARGS="--configs=git --tools=bat --apps=docker" run flags-argv ubuntu "$WORK/k-sel"
check   flags-argv 0
want    flags-argv 'Selection given on the command line' 'flags path taken'
want    flags-argv 'Configs: .*git'            'config from --configs'
want    flags-argv 'Dep tools: .*bat'          'tool from --tools'
nowant  flags-argv 'Choice \(e.g.'             'no menu drawn'

# A typo in an unattended run must stop, not quietly install nothing.
RUN_ARGS="--configs=zshh" run flags-typo ubuntu "$WORK/k-sel"
check   flags-typo 2
want    flags-typo 'Unknown config'            'named the bad value'
want    flags-typo 'available:'                'listed the real ones'

# --dry-run with a named selection: the whole plan, nothing written.
RUN_ARGS="--dry-run --configs=zsh --apps=docker" run flags-dry ubuntu "$WORK/k-sel"
check   flags-dry 0
want    flags-dry 'Installation plan'          'the plan was printed'
want    flags-dry 'dry run'                    'and stopped there'
d="$WORK/run/flags-dry/home"
[ -e "$d/.zshrc" ] && bad flags-dry "a dry run stowed something" \
                   || note flags-dry "nothing written"

# "all" is the shorthand the numbered list has always had.
run flags-all ubuntu "$WORK/k-sel" DOTFILES_CONFIGS="all"
check   flags-all 0
want    flags-all 'Configs: .*fastfetch.*zsh'  'all of them selected'
# Regression: the Debian branch used to re-declare CONFIGS as a second literal
# list, which silently dropped every config added after it was written.
want    flags-all 'Configs: .*micro.*fresh'    'including the ones added last'
nowant  flags-all 'Failed \('                  'nothing failed'

echo
echo "── docker app selection ─────────────────────────────────"
# 16. Docker: the first-ever exercise of the "applications" fzf menu in this
#     suite (no earlier scenario picked one, so this also proves the menu
#     itself works, not just docker). Arch takes the plain pacman path —
#     docker, docker-compose and docker-buildx are all in the official repo,
#     no bespoke bootstrap needed.
run arch-docker arch "$WORK/k-sel" DOTFILES_CONFIGS="git" DOTFILES_APPS="docker"
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
run debian-docker debian "$WORK/k-sel" DOTFILES_CONFIGS="git" DOTFILES_APPS="docker"
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

# 18b. $USER is not a reliable answer to "who am I": it is unset under cron,
#      `docker exec` and some non-login shells — the reason the zsh arm asks the
#      kernel instead. The group add trusted it anyway, so on those boxes
#      `usermod -aG docker ""` failed behind a `|| true` and the transcript
#      still said the user had been added.
run docker-nouser arch "$WORK/k-sel" DOTFILES_CONFIGS="git" DOTFILES_APPS="docker" USER=
check docker-nouser 0
if grep -qE "usermod -aG docker $(id -un)( |$)" "$WORK/run/docker-nouser/state/sudo.log"; then
    note docker-nouser "asked the kernel who we are, not \$USER"
else
    bad  docker-nouser "added an empty username to the docker group"
fi
want docker-nouser "$(id -un) added to the docker group" 'and named the real account'

# 18. Ubuntu: same repo bootstrap, but the ubuntu host + noble codename, so a
#     copy-paste of the debian URL would go undetected without this.
run ubuntu-docker ubuntu "$WORK/k-sel" DOTFILES_CONFIGS="git" DOTFILES_APPS="docker"
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
run     restore-zsh ubuntu "$WORK/k-sel" DOTFILES_CONFIGS="zsh"
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
run     restore-env ubuntu "$WORK/k-sel" DOTFILES_CONFIGS="zsh"
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
STUB_NO_BASHRC=1 run restore-nobashrc ubuntu "$WORK/k-sel" DOTFILES_CONFIGS="zsh"
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
STUB_V1_HOOK=1 run restore-v1hook ubuntu "$WORK/k-sel" DOTFILES_CONFIGS="zsh"
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

# 21. A ~/.zshrc symlink that is not ours. The undo used to unstow on a bare
#     -L, so it `rm`'d any symlink it found there: someone who tried this repo
#     and went back to pointing ~/.zshrc at their own dotfiles lost the link,
#     with no .bak and not one word said. This is the recovery command — it is
#     the last place that should take a file it did not make. The starship
#     branch four lines below it had checked the target all along.
build_root "$WORK/run/restore-foreign" ubuntu
mkdir -p "$WORK/run/restore-foreign/home/mydots"
printf '# my own zshrc, from before any of this\n' > "$WORK/run/restore-foreign/home/mydots/zshrc"
ln -s "$WORK/run/restore-foreign/home/mydots/zshrc" "$WORK/run/restore-foreign/home/.zshrc"
RUN_ARGS=--restore-bash install_pass "$WORK/run/restore-foreign" \
    "$WORK/run/restore-foreign" "$WORK/k-restore"
check restore-foreign 0
rb_f="$WORK/run/restore-foreign/home"
if [ -L "$rb_f/.zshrc" ] && [ "$(readlink "$rb_f/.zshrc")" = "$rb_f/mydots/zshrc" ]; then
    note restore-foreign "left a ~/.zshrc symlink that is not ours alone"
else
    bad  restore-foreign "deleted the user's own ~/.zshrc symlink"
fi
want restore-foreign 'your own symlink, not ours' 'and said why it was left'

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

# Same thing with the menu on screen. The menu takes the alternate screen and
# turns off echo, and it must not own the EXIT trap to undo that — this script
# already traps EXIT for the sudo keepalive and the temp dir, and the menu
# replacing it left the rest of the run with no cleanup at all.
# build_root, not a hand-rolled sandbox: this one has to get *past* the apt
# bootstrap to reach the menu, which means the stub package list has to be
# seeded the same way every other scenario seeds it.
ipt2="$WORK/run/interrupt-menu"
build_root "$ipt2" ubuntu
mkfifo "$ipt2/keys"
( exec 3>"$ipt2/keys"; printf '\n\n' >&3; sleep 8; printf '\003' >&3; sleep 15; exec 3>&- ) &
holder2=$!
irc2=0
( cd "$ipt2/home/dotfiles" && env -i ${ENV_SIGDFL[@]+"${ENV_SIGDFL[@]}"} \
    HOME="$ipt2/home" USER="$(id -un)" \
    PATH="$WORK/bin:$WORK/sysbin" TERM=xterm-256color LANG=en_US.UTF-8 SHELL=/bin/bash \
    STUB_STATE="$ipt2/state" STUB_BIN="$WORK/bin" STUB_ROOT="$ipt2" \
    timeout 60 script -qec "stty rows 40 cols 150 2>/dev/null; bash ./install.sh" /dev/null \
        < "$ipt2/keys" > "$ipt2/out.txt" 2>&1 ) || irc2=$?
kill "$holder2" 2>/dev/null
if [ "$irc2" = 130 ]; then note interrupt-menu "Ctrl-C in the menu exits 130"
else bad interrupt-menu "Ctrl-C gave exit $irc2"; fi
if grep -q 'Interrupted' "$ipt2/out.txt"; then note interrupt-menu "says so"
else bad interrupt-menu "no message"; fi
if grep -q $'\033\[?1049l' "$ipt2/out.txt"; then note interrupt-menu "alternate screen released"
else bad interrupt-menu "left the terminal on the alternate screen"; fi
if grep -q 'ctrl-d review' "$ipt2/out.txt"; then note interrupt-menu "the menu was up when it happened"
else bad interrupt-menu "menu never drew, so this proved nothing"; fi

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
    # Identity is only half the promise. A folder still holding a shellcheck
    # config and an .editorconfig is legibly a checkout whatever .git says, and
    # that is what "no sign that ~/dotfiles came from a repo" was leaving behind.
    # tests/ is on the same list and takes the same code path as .github, but it
    # cannot be asserted here: build_root strips it from the staged copy.
    for f in .editorconfig .shellcheckrc; do
        if [ -e "$d/$f" ]; then bad  "$scen" "$f survived"
        else                    note "$scen" "$f removed"; fi
    done
    # The deliberate exception, asserted so it does not get tidied onto the
    # delete list later: doctor.sh names nobody and is the only way to work out
    # what went wrong on a machine that now has no repo to compare against.
    if [ -f "$d/doctor.sh" ]; then note "$scen" "doctor.sh kept"
    else                           bad  "$scen" "doctor.sh deleted"; fi
    if [ -f "$d/install.sh" ] && bash -n "$d/install.sh" 2>/dev/null; then
        note "$scen" "scrubbed install.sh still parses"
    else
        bad  "$scen" "scrubbed install.sh broken"
    fi
done

echo
echo "── ccstatusline ─────────────────────────────────────────"
# The one config with no package behind it on either distro: Claude Code runs
# it as `bunx -y ccstatusline@latest`, so selecting it pulls bun in as an app —
# and the curl stub installs a real one, so these runs go all the way through.
RUN_ARGS="--configs=ccstatusline" run ccstatusline ubuntu "$WORK/k-sel"
check   ccstatusline 0
want    ccstatusline 'adding bun'            'pulls bun in on its own'
want    ccstatusline 'statusline wired up'   'wires Claude Code up on its own'
nowant  ccstatusline 'apt-get install bun'   'never tries to apt bun'
# The whole point of the pull: selecting only the config must still leave a
# machine that can render. A statusline wired to a bunx that is not installed
# is a blank status line, which is exactly what shipped and had to be fixed.
want    ccstatusline 'Bun'                   'bun reaches the applications step'
nowant  ccstatusline 'tick Bun in the apps'  'never tells the user to go do it'
# Each step has to close its own box, or the next header opens inside it.
if [ "$(grep -c 'Statusline ready' "$WORK/run/ccstatusline/clean.txt")" -ge 1 ]; then
    note ccstatusline "the statusline step closes its box"
else
    bad  ccstatusline "statusline step left its box unterminated"
fi

d="$WORK/run/ccstatusline/home"
if [ -L "$d/.config/ccstatusline/settings.json" ]; then
    note ccstatusline "settings.json stowed as a symlink"
else
    bad  ccstatusline "settings.json is not a symlink into the repo"
fi
# The file has to survive the trip: a statusline whose JSON does not parse is
# the failure mode that shows up only once Claude Code renders it.
if [ -r "$d/.config/ccstatusline/settings.json" ] \
   && python3 -c "import json,sys; json.load(open(sys.argv[1]))" \
        "$d/.config/ccstatusline/settings.json" 2>/dev/null; then
    note ccstatusline "stowed settings.json is valid JSON"
else
    bad  ccstatusline "stowed settings.json is missing or not valid JSON"
fi
# Created from nothing when Claude Code has never run on this machine.
if python3 - "$d/.claude/settings.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if "ccstatusline" in d["statusLine"]["command"] else 1)
PY
then note ccstatusline "settings.json created with the statusLine"
else bad  ccstatusline "no statusLine written into ~/.claude/settings.json"
fi

# ── the part that must never go wrong ────────────────────────────────────────
# ~/.claude/settings.json is the user's, not this repo's. These three scenarios
# are the ways an installer ruins someone's day: eating their other settings,
# silently replacing a statusline they wrote, and mangling a file it could not
# parse. Each seeds the file first, then asserts what survived.
mkdir -p "$WORK/seed"

# 1. A populated settings.json keeps every unrelated key, exactly.
build_root "$WORK/run/ccsl-keep" ubuntu
mkdir -p "$WORK/run/ccsl-keep/home/.claude"
cat > "$WORK/run/ccsl-keep/home/.claude/settings.json" <<'JSON'
{
  "model": "opus",
  "permissions": { "defaultMode": "auto" },
  "enabledPlugins": { "somebody@somewhere": true },
  "theme": "dark"
}
JSON
RUN_ARGS="--configs=ccstatusline" install_pass \
    "$WORK/run/ccsl-keep" "$WORK/run/ccsl-keep" "$WORK/k-sel"
check ccsl-keep 0
if python3 - "$WORK/run/ccsl-keep/home/.claude/settings.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d["model"] == "opus",                        "model lost"
assert d["permissions"]["defaultMode"] == "auto",   "permissions lost"
assert d["enabledPlugins"]["somebody@somewhere"],   "plugins lost"
assert d["theme"] == "dark",                        "theme lost"
assert "ccstatusline" in d["statusLine"]["command"], "statusLine not written"
PY
then note ccsl-keep "every unrelated key survived the merge"
else bad  ccsl-keep "the merge dropped or corrupted existing settings"
fi
if [ -f "$WORK/run/ccsl-keep/home/.claude/settings.json.orig" ]; then
    note ccsl-keep "kept a pristine copy of the original"
else
    bad  ccsl-keep "no .orig copy taken before editing"
fi

# 2. Somebody else's statusline is left exactly as it was.
build_root "$WORK/run/ccsl-foreign" ubuntu
mkdir -p "$WORK/run/ccsl-foreign/home/.claude"
cat > "$WORK/run/ccsl-foreign/home/.claude/settings.json" <<'JSON'
{ "statusLine": { "type": "command", "command": "~/bin/my-own-statusline.sh" } }
JSON
cp "$WORK/run/ccsl-foreign/home/.claude/settings.json" "$WORK/seed/foreign.json"
RUN_ARGS="--configs=ccstatusline" install_pass \
    "$WORK/run/ccsl-foreign" "$WORK/run/ccsl-foreign" "$WORK/k-sel"
check  ccsl-foreign 0
want   ccsl-foreign 'Left your existing statusLine alone' 'says it stood back'
if cmp -s "$WORK/seed/foreign.json" "$WORK/run/ccsl-foreign/home/.claude/settings.json"; then
    note ccsl-foreign "a hand-written statusLine is byte-identical afterwards"
else
    bad  ccsl-foreign "overwrote a statusLine it did not put there"
fi

# 3. Unparseable JSON is reported and left alone — never rewritten from scratch.
build_root "$WORK/run/ccsl-broken" ubuntu
mkdir -p "$WORK/run/ccsl-broken/home/.claude"
printf '{ "model": "opus", oops not json\n' \
    > "$WORK/run/ccsl-broken/home/.claude/settings.json"
cp "$WORK/run/ccsl-broken/home/.claude/settings.json" "$WORK/seed/broken.json"
RUN_ARGS="--configs=ccstatusline" install_pass \
    "$WORK/run/ccsl-broken" "$WORK/run/ccsl-broken" "$WORK/k-sel"
check  ccsl-broken 0
want   ccsl-broken 'not valid JSON'  'reports the file it could not read'
if cmp -s "$WORK/seed/broken.json" "$WORK/run/ccsl-broken/home/.claude/settings.json"; then
    note ccsl-broken "left the unparseable file exactly as it found it"
else
    bad  ccsl-broken "modified a settings.json it could not parse"
fi

# 3b. Selecting Claude Code itself is the other trigger — the app is the thing
# that renders the statusline, so installing it wires the statusline up too,
# with no config selected at all.
RUN_ARGS="--apps=claude-code" run ccsl-app ubuntu "$WORK/k-sel"
check ccsl-app 0
want  ccsl-app 'statusline wired up'  'installing Claude Code wires it up'
# ~/.claude/settings.json is not a stow target, so the plan has to name the
# write before it happens. Only the ccstatusline config used to say it, which
# left this path editing a file nothing had mentioned.
want  ccsl-app 'point Claude Code at ccstatusline' 'the plan names the settings.json write'
if python3 - "$WORK/run/ccsl-app/home/.claude/settings.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if "ccstatusline" in d["statusLine"]["command"] else 1)
PY
then note ccsl-app "statusLine written from the apps path"
else bad  ccsl-app "apps path did not wire the statusline"
fi

# 4. Running twice changes nothing the second time. "Already in there" has to
# mean the file is not rewritten at all — not rewritten to identical content,
# which would still churn mtime and reformat anything hand-edited.
cp "$WORK/run/ccsl-keep/home/.claude/settings.json" "$WORK/seed/afterfirst.json"
RUN_ARGS="--configs=ccstatusline" rerun ccsl-again ccsl-keep "$WORK/k-sel"
check ccsl-again 0
want  ccsl-again 'already wired up'  'second run is a no-op'
if cmp -s "$WORK/seed/afterfirst.json" "$WORK/run/ccsl-keep/home/.claude/settings.json"; then
    note ccsl-again "already-wired settings.json is left byte-identical"
else
    bad  ccsl-again "rewrote a settings.json that was already correct"
fi
if ls "$WORK/run/ccsl-keep/home/.claude/".settings.json.new_* >/dev/null 2>&1; then
    bad  ccsl-again "left a staging temp file behind in ~/.claude"
else
    note ccsl-again "no staging temp file left behind"
fi

# 5. A managed statusLine outranks user settings, so the merge still happens but
# must not be reported as the statusline that will actually render.
build_root "$WORK/run/ccsl-managed" ubuntu
mkdir -p "$WORK/run/ccsl-managed/etc/claude-code"
cat > "$WORK/run/ccsl-managed/etc/claude-code/managed-settings.json" <<'JSON'
{ "statusLine": { "type": "command", "command": "/opt/corp/statusline" } }
JSON
RUN_ARGS="--configs=ccstatusline" install_pass \
    "$WORK/run/ccsl-managed" "$WORK/run/ccsl-managed" "$WORK/k-sel" \
    CC_MANAGED_SETTINGS="$WORK/run/ccsl-managed/etc/claude-code/managed-settings.json"
check ccsl-managed 0
want  ccsl-managed 'managed statusLine overrides it'  'says the write will not win'
if python3 - "$WORK/run/ccsl-keep/home/.claude/settings.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d["model"] == "opus" and "ccstatusline" in d["statusLine"]["command"] else 1)
PY
then note ccsl-again "settings still intact after a second pass"
else bad  ccsl-again "the second pass damaged settings.json"
fi

echo
echo "── protonvpn: the symlinks under ~/scripts ──────────────"
# ~/scripts is a directory plenty of people already have, and pointing it at a
# synced folder or a second drive is an ordinary thing to do. This arm used to
# `rm` any symlink it found at ~/scripts or ~/scripts/pvpn before stowing — no
# .bak, no message, in backup mode too. The link is the only record of where
# they wanted it, and it was the one arm the "stop deleting symlinks that are
# not ours" pass missed.

# 1. A foreign ~/scripts is left exactly where it points, and the stow goes
#    through it into the real directory.
build_root "$WORK/run/pvpn-scripts" ubuntu
mkdir -p "$WORK/run/pvpn-scripts/home/elsewhere"
ln -s "$WORK/run/pvpn-scripts/home/elsewhere" "$WORK/run/pvpn-scripts/home/scripts"
install_pass "$WORK/run/pvpn-scripts" "$WORK/run/pvpn-scripts" "$WORK/k-sel" \
    DOTFILES_CONFIGS="protonvpn"
check pvpn-scripts 0
h="$WORK/run/pvpn-scripts/home"
if [ -L "$h/scripts" ] && [ "$(readlink "$h/scripts")" = "$h/elsewhere" ]; then
    note pvpn-scripts "left ~/scripts pointing where the user put it"
else
    bad  pvpn-scripts "deleted or replaced the user's own ~/scripts symlink"
fi
if [ -L "$h/elsewhere/pvpn/pvpn.zsh" ]; then
    note pvpn-scripts "stowed through the link into the real directory"
else
    bad  pvpn-scripts "pvpn.zsh did not land through the ~/scripts link"
fi

# 2. A foreign ~/scripts/pvpn is moved aside, not deleted — the same treatment
#    backup_file gives every other symlink that is not ours.
build_root "$WORK/run/pvpn-dir" ubuntu
mkdir -p "$WORK/run/pvpn-dir/home/scripts" "$WORK/run/pvpn-dir/home/mine"
ln -s "$WORK/run/pvpn-dir/home/mine" "$WORK/run/pvpn-dir/home/scripts/pvpn"
install_pass "$WORK/run/pvpn-dir" "$WORK/run/pvpn-dir" "$WORK/k-sel" \
    DOTFILES_CONFIGS="protonvpn"
check pvpn-dir 0
h="$WORK/run/pvpn-dir/home"
if [ -L "$h/scripts/pvpn.bak" ] && [ "$(readlink "$h/scripts/pvpn.bak")" = "$h/mine" ]; then
    note pvpn-dir "the foreign pvpn symlink was backed up, not deleted"
else
    bad  pvpn-dir "lost the user's ~/scripts/pvpn symlink"
fi
if [ -L "$h/scripts/pvpn/pvpn.zsh" ]; then
    note pvpn-dir "and ours stowed into a real directory in its place"
else
    bad  pvpn-dir "pvpn.zsh was not stowed after the backup"
fi
want pvpn-dir 'is your own symlink, not ours' 'the plan warned before touching it'

echo
echo "── distro list parity ───────────────────────────────────"
# The Debian branch may only *remove* from CONFIGS. It used to re-declare the
# array as a second hand-written literal, which silently dropped every config
# added after that line was written — micro and fresh were both invisible on
# Debian/Ubuntu until someone noticed. This diffs the two menus whatever they
# hold, so the next config added is covered without editing this test: the only
# permitted difference is rofi.
RUN_ARGS="--dry-run --gui" run parity-arch   arch   "$WORK/k-sel" DOTFILES_CONFIGS="all"
RUN_ARGS="--dry-run --gui" run parity-debian ubuntu "$WORK/k-sel" DOTFILES_CONFIGS="all"

# Every config is in this plan, so it is also the cheapest place to hold the
# two ~/.config arms that carry an extra line to their name. ulauncher shares
# the common arm now — dropping its autostart row is what folding it in could
# quietly have done.
want parity-arch 'enable autostart'    'the ulauncher plan still names autostart'
want parity-arch 'launch: rofi'        'and rofi still names its launch command'

for side in arch debian; do
    sed -n 's/.*Configs: //p' "$WORK/run/parity-$side/clean.txt" | head -1 \
        | tr ' ' '\n' | sed '/^$/d' | sort -u > "$WORK/parity-$side.lst"
done
if [ ! -s "$WORK/parity-arch.lst" ] || [ ! -s "$WORK/parity-debian.lst" ]; then
    bad parity-configs "no config list in one of the transcripts"
else
    only_arch=$(comm -23 "$WORK/parity-arch.lst" "$WORK/parity-debian.lst" | xargs)
    only_deb=$( comm -13 "$WORK/parity-arch.lst" "$WORK/parity-debian.lst" | xargs)
    if [ "$only_arch" = "rofi" ]; then
        note parity-configs "Debian list is the Arch list minus rofi"
    else
        bad  parity-configs "Arch-only configs: ${only_arch:-none}, wanted rofi"
    fi
    if [ -z "$only_deb" ]; then
        note parity-configs "and holds nothing Arch does not"
    else
        bad  parity-configs "Debian-only configs: $only_deb"
    fi
fi

echo
echo "── doctor.sh mirrors install.sh ─────────────────────────"
# doctor.sh's two loops are hand-kept copies of install.sh's arrays, and they
# have fallen behind before — micro, fresh, ccstatusline and pay-respects were
# all missing at once. Its whole job is to be pasted into a bug report, so a
# config it does not report sends whoever reads that after the wrong thing.
# Nothing enforced it; adding a config is now the thing that fails here.
doc_src="$HERE/../doctor.sh"
inst_src="$HERE/../install.sh"
mapfile -t doc_cfgs  < <(sed -n 's/^for cfg in \(.*\); do$/\1/p' "$doc_src" | tr ' ' '\n' | sed '/^$/d')
mapfile -t doc_tools < <(sed -n 's/^for c in \(.*\); do$/\1/p'   "$doc_src" | tr ' ' '\n' | sed '/^$/d')
if [ "${#doc_cfgs[@]}" -ge 8 ] && [ "${#doc_tools[@]}" -ge 8 ]; then
    note doctor-lists "both loops extracted from doctor.sh"
else
    bad  doctor-lists "extraction matched almost nothing — not looking at doctor.sh"
fi

# The ~/.config/<name> half of CONFIGS. Derived from the array rather than
# hand-listed here as well, minus the five that stow to ~ or ~/scripts and so
# are reported by the symlink block above that loop instead. A config added to
# either group trips this until doctor.sh is told about it.
doc_missing=()
for c in $(sed -n 's/^CONFIGS=(\(.*\))$/\1/p' "$inst_src" | tr ' ' '\n' \
           | grep -vxE 'bash|zsh|git|starship|protonvpn'); do
    printf '%s\n' "${doc_cfgs[@]}" | grep -qx "$c" || doc_missing+=("$c")
done
if [ "${#doc_missing[@]}" -eq 0 ]; then
    note doctor-configs "every ~/.config config is in doctor.sh's loop"
else
    bad  doctor-configs "doctor.sh never reports: ${doc_missing[*]}"
fi

doc_missing=()
for c in $(sed -n 's/^DEPS_LIST=(\(.*\))$/\1/p' "$inst_src" | tr ' ' '\n'); do
    printf '%s\n' "${doc_tools[@]}" | grep -qx "$c" || doc_missing+=("$c")
done
if [ "${#doc_missing[@]}" -eq 0 ]; then
    note doctor-tools "every dep tool is in doctor.sh's tools loop"
else
    bad  doctor-tools "doctor.sh never looks for: ${doc_missing[*]}"
fi

# Duplicated verbatim, on purpose — doctor.sh installs nothing and sources
# nothing. A drifted copy is how bun in ~/.bun/bin gets reported missing on a
# machine where it is installed and working.
doc_path=$( sed -n 's/^CURL_APP_PATH=//p' "$doc_src"  | head -1)
inst_path=$(sed -n 's/^CURL_APP_PATH=//p' "$inst_src" | head -1)
if [ -n "$doc_path" ] && [ "$doc_path" = "$inst_path" ]; then
    note doctor-path "CURL_APP_PATH is identical in both"
else
    bad  doctor-path "CURL_APP_PATH drifted: doctor ${doc_path:-<none>} vs install ${inst_path:-<none>}"
fi

echo
echo "── menu column invariants ───────────────────────────────"
# tui_pad pads with printf '%-*s', which counts BYTES, and truncates with
# ${var:0:n}, which counts CHARACTERS. So one non-ASCII character in a name or
# a label shifts every column to the right of it, and a Nerd Font glyph is
# worse again — two columns wide, one character, three bytes. CLAUDE.md states
# the rule; nothing enforced it, and you found out by looking at a bent menu.
#
# Only what tui_pad actually pads is checked: the item names, which come from
# these three arrays and from APP_LABEL. Descriptions are deliberately NOT
# here — they are never handed to printf as a padded field. tui_draw truncates
# them with ${desc:0:n} and passes ${#desc} to tui_box_row, which pads with
# spaces it counts itself, so characters and columns agree and the · and →
# already in them are fine.
menu_src="$HERE/../install.sh"
menu_lines=$(grep -hE '^(CONFIGS|DEPS_LIST|APPS_LIST)(\+?=)\(|^APP_LABEL\[' "$menu_src")
# A grep that matches nothing passes for free, so pin the floor: this is well
# under today's count and only trips if the extraction itself breaks.
if [ "$(printf '%s\n' "$menu_lines" | grep -c .)" -ge 20 ]; then
    note menu-ascii "menu strings extracted from install.sh"
else
    bad  menu-ascii "extraction matched almost nothing — the test is not looking at the menu"
fi
menu_bad=$(printf '%s\n' "$menu_lines" | LC_ALL=C grep -nP '[\x80-\xFF]' | head -3)
if [ -z "$menu_bad" ]; then
    note menu-ascii "every padded name and label is ASCII"
else
    bad  menu-ascii "non-ASCII would bend the columns: $(printf '%s' "$menu_bad" | tr '\n' ' ')"
fi

echo
echo "─────────────────────────────────────────────────────────"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
