#!/usr/bin/env bash
# Builds the stub PATH the scenarios run against. Nothing here may touch the
# real system: no stub ever executes a privileged command for real, and the
# few that wrap a real binary refuse to write outside the sandbox.
#
# Sourced by harness.sh — not run directly.
set -euo pipefail

BIN="$WORK/bin"
TPL="$WORK/tpl"
rm -rf "$BIN" "$TPL"; mkdir -p "$BIN" "$TPL"

w()  { cat > "$BIN/$1"; chmod +x "$BIN/$1"; }
# Templates are not on PATH. A package-manager stub copies one in when it
# "installs" that package, so `command -v fzf` is false until it is installed.
wt() { cat > "$TPL/$1"; chmod +x "$TPL/$1"; }

# ── sudo: a stock Debian/Ubuntu sudoers policy ───────────────────────────────
# env_reset without SETENV, so a leading VAR=value is refused outright. This is
# the failure that broke every apt install on a real VPS; keeping it here means
# a regression to `sudo VAR=value cmd` fails the suite instead of shipping.
w sudo <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
    case "$1" in
        -v|-n|-k|-E|-H) shift ;;
        -u) shift 2 ;;
        -*) shift ;;
        *) break ;;
    esac
done
[ $# -eq 0 ] && exit 0
for a in "$@"; do
    case "$a" in
        [A-Za-z_]*=*)
            echo "sudo: sorry, you are not allowed to set the following environment variables: ${a%%=*}" >&2
            exit 1 ;;
        *) break ;;
    esac
done
echo "sudo $*" >> "${STUB_STATE:?}/sudo.log"
case "$1" in
    rm)
        # only ever inside the scenario sandbox
        for a in "$@"; do
            case "$a" in
                -*|rm) ;;
                "${STUB_ROOT:?}"/*) ;;
                *) exit 0 ;;
            esac
        done
        exec "$@" ;;
    kill) exec "$@" ;;
    env|apt-get|apt|apt-cache|dpkg|dpkg-query|pacman|paru|pacman-key|systemctl|\
    add-apt-repository|chsh|usermod|flatpak|update-alternatives|tee|install)
        exec "$@" ;;
    *)  # never run anything else with pretend privileges
        exit 0 ;;
esac
EOF

# ── apt-get ──────────────────────────────────────────────────────────────────
w apt-get <<'EOF'
#!/usr/bin/env bash
st="${STUB_STATE:?}"
# Finding the subcommand means skipping options — including the value of the
# ones that take a separate argument. -o is the reason this is not a one-liner:
# real code calls `apt-get -o DPkg::Lock::Timeout=600 install …`, and the value
# does not start with a dash, so a naive scan reads it as the subcommand and
# every install silently becomes a no-op that still exits 0.
sub=""
skip=0
for a in "$@"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$a" in
        -o|--option|-c|--config-file|-t|--target-release) skip=1 ;;
        -*) ;;
        *)  sub="$a"; break ;;
    esac
done

if [ "$sub" = "install" ]; then
    [ "${DEBIAN_FRONTEND:-}" = "noninteractive" ] \
        || echo "STUBFAIL: apt-get install ran without DEBIAN_FRONTEND" >&2
    [ "${NEEDRESTART_SUSPEND:-}" = "1" ] \
        || echo "STUBFAIL: apt-get install ran without NEEDRESTART_SUSPEND" >&2
fi

lockpid=$(cat "$st/lockpid" 2>/dev/null || true)
if [ -n "$lockpid" ] && [ -d "/proc/$lockpid" ]; then
    echo "E: Could not get lock /var/lib/dpkg/lock. It is held by process $lockpid (unattended-upgr)" >&2
    echo "E: Unable to lock the administration directory (/var/lib/dpkg/), is another process using it?" >&2
    exit 100
fi
if [ -f "$st/dpkg-interrupted" ]; then
    echo "E: dpkg was interrupted, you must manually run 'sudo dpkg --configure -a' to correct the problem." >&2
    exit 100
fi

case "$sub" in
  update)
      dead=$(ls "${STUB_APT_SRCD:-/nonexistent}"/lazygit-team-* 2>/dev/null | head -1)
      if [ -n "$dead" ]; then
          echo "E: The repository 'https://ppa.launchpadcontent.net/lazygit-team/release/ubuntu noble Release' does not have a Release file." >&2
          exit 100
      fi
      if [ "${STUB_BROKEN_REPO:-0}" = "1" ]; then
          cat >&2 <<'ERR'
Err:5 https://apt.example.com/repo stable InRelease
  403  Forbidden [IP: 10.0.0.1 443]
W: Failed to fetch https://apt.example.com/repo/dists/stable/InRelease  403  Forbidden
E: Some index files failed to download. They have been ignored, or old ones used instead.
ERR
          exit 100
      fi
      exit 0 ;;
  install)
      rc=0
      optval=0
      for a in "$@"; do
          # Same trap as the subcommand scan above: the value of -o is not
          # dash-prefixed, so without this it is read as a package name and the
          # install fails with "Unable to locate package DPkg::Lock::Timeout=600".
          if [ "$optval" = 1 ]; then optval=0; continue; fi
          case "$a" in
              -o|--option|-c|--config-file|-t|--target-release) optval=1; continue ;;
          esac
          case "$a" in -*|install) continue ;; esac
          # A downloaded vendor .deb. The path is a mktemp name, so the package
          # it holds is whatever the curl stub last fetched.
          case "$a" in *.deb)
              [ -s "$st/deb_pkg" ] || continue
              p=$(cat "$st/deb_pkg")
              grep -qxF "$p" "$st/installed" 2>/dev/null || echo "$p" >> "$st/installed"
              continue ;;
          esac
          if grep -qxF "$a" "$st/available" 2>/dev/null; then
              grep -qxF "$a" "$st/installed" 2>/dev/null || echo "$a" >> "$st/installed"
              b="$a"
              case "$a" in fd-find) b=fdfind ;; esac
              [ "$b" = fzf ] && [ "${STUB_NO_FZF:-0}" = 1 ] && continue
              if [ ! -e "$STUB_BIN/$b" ]; then
                  if [ -x "${STUB_TPL:-}/$b" ]; then cp "$STUB_TPL/$b" "$STUB_BIN/$b"
                  else printf '#!/bin/sh\necho "%s stub"\n' "$b" > "$STUB_BIN/$b"; fi
                  chmod +x "$STUB_BIN/$b"
              fi
          else
              echo "E: Unable to locate package $a" >&2
              rc=100
          fi
      done
      exit $rc ;;
  *) exit 0 ;;
esac
EOF

w dpkg-query <<'EOF'
#!/usr/bin/env bash
p="${!#}"
grep -qxF "$p" "${STUB_STATE:?}/installed" 2>/dev/null || exit 1
echo -n installed
EOF

w dpkg <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    --print-architecture) echo "${STUB_ARCH:-amd64}" ;;
    --configure) rm -f "${STUB_STATE:?}/dpkg-interrupted"; exit 0 ;;
    -s) exit 1 ;;
    -i) exit 0 ;;
    *) exit 0 ;;
esac
EOF

w apt-cache            <<< '#!/bin/sh
exit 0'
w add-apt-repository   <<< '#!/bin/sh
exit 0'
# Logged, not merely swallowed: `systemctl --user enable …` runs unprivileged,
# so sudo.log — where every other service call in this suite is asserted — never
# sees it, and the user-unit branches would have been untestable.
#
# It also has to remember what it was told to start. A stub that answers 0 to
# everything makes `is-active` true for a unit nobody started, which is the one
# question the callers actually ask — and it silently turned "did we start it?"
# into "did we call systemctl at all?".
w systemctl <<'EOF'
#!/bin/sh
st="${STUB_STATE:?}"
echo "systemctl $*" >> "$st/systemctl.log"

verb=""; unit=""; now=0
for a in "$@"; do
    case "$a" in
        --now) now=1 ;;
        -*) ;;
        *)  if [ -z "$verb" ]; then verb="$a"
            elif [ -z "$unit" ]; then unit="$a"
            fi ;;
    esac
done
unit="${unit%.service}"

case "$verb" in
    start|restart)  [ -n "$unit" ] && echo "$unit" >> "$st/active" ;;
    enable)         [ "$now" = 1 ] && [ -n "$unit" ] && echo "$unit" >> "$st/active" ;;
    is-active)      grep -qxF "$unit" "$st/active" 2>/dev/null || exit 3 ;;
esac
exit 0
EOF

# Only the -x form install.sh uses, answered from a file a scenario writes.
# The stub PATH mirrors /usr/bin, so without this the *host's* process list
# decides which branch runs — and on a machine where vicinae is running, it
# does not take the branch the assertion is about.
w pgrep <<'EOF'
#!/bin/sh
st="${STUB_STATE:?}"
pat=""
for a in "$@"; do
    case "$a" in -*) ;; *) pat="$a" ;; esac
done
grep -qxF "$pat" "$st/processes" 2>/dev/null || exit 1
echo 4242
EOF
w pacman-key           <<< '#!/bin/sh
exit 0'
w fc-cache             <<< '#!/bin/sh
exit 0'
w fc-list              <<< '#!/bin/sh
exit 0'
w flatpak              <<< '#!/bin/sh
exit 0'
# Real unzip drops the archive's .ttf files into -d <dir>, and the check right
# after every font install looks for exactly that. As a flat no-op this made
# both Debian/Ubuntu font installs report failure — invisible until a scenario
# ran --gui, because a headless run skips fonts entirely and every config
# scenario in the suite was headless. Only the -d/'*.ttf' shape is honoured;
# every other call stays the no-op it was (ensure_unzip/bun only probe for it).
w unzip <<'EOF'
#!/usr/bin/env bash
dir=""; want_ttf=0
while [ $# -gt 0 ]; do
    case "$1" in
        -d) dir="$2"; shift 2 ;;
        '*.ttf') want_ttf=1; shift ;;
        *) shift ;;
    esac
done
if [ -n "$dir" ] && [ "$want_ttf" -eq 1 ]; then
    mkdir -p "$dir" && : > "$dir/StubFont.ttf"
fi
exit 0
EOF
w gpg <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *--show-keys*)
        f="${!#}"
        [ -s "$f" ] && echo "pub:-:::::::::::::::::"
        exit 0 ;;
    *--dearmor*) cat; exit 0 ;;
    *) cat > /dev/null; exit 0 ;;
esac
EOF
# Real enough to be worth asserting against: links a package's top-level
# entries into the target and -D removes links that point back into it. A bare
# `exit 0` meant no scenario ever produced a symlink, so nothing about stowing,
# backing up or restoring could actually be tested.
w stow <<'EOF'
#!/usr/bin/env bash
target=""; dir="."; del=0; pkgs=()
while [ $# -gt 0 ]; do
    case "$1" in
        --target)   target="$2"; shift 2 ;;
        --target=*) target="${1#*=}"; shift ;;
        --dir)      dir="$2"; shift 2 ;;
        --dir=*)    dir="${1#*=}"; shift ;;
        -D|--delete) del=1; shift ;;
        -R|--restow) del=0; shift ;;
        -*) shift ;;
        *)  pkgs+=("$1"); shift ;;
    esac
done
[ -n "$target" ] || target="$(dirname "$dir")"
rc=0
for p in "${pkgs[@]}"; do
    src="$dir/$p"
    [ -d "$src" ] || { rc=1; continue; }
    srcr="$(readlink -f "$src")"
    mkdir -p "$target"
    shopt -s nullglob dotglob
    for f in "$src"/*; do
        b="$(basename "$f")"
        t="$target/$b"
        if [ "$del" = 1 ]; then
            if [ -L "$t" ]; then
                case "$(readlink -f "$t" 2>/dev/null)" in
                    "$srcr"/*) rm -f "$t" ;;
                esac
            fi
        else
            # A real file in the way is a conflict, exactly as stow reports.
            if [ -e "$t" ] && [ ! -L "$t" ]; then rc=1; continue; fi
            rm -f "$t"
            ln -s "$f" "$t"
        fi
    done
    shopt -u nullglob dotglob
done
exit $rc
EOF

# ── Arch side ────────────────────────────────────────────────────────────────
w pacman <<'EOF'
#!/usr/bin/env bash
st="${STUB_STATE:?}"
# paru and yay are copies of this file. Names listed in state/aur-only are
# visible to them and invisible to pacman — which is the whole shape of
# arch_install (official repos first, AUR helper second) and the only way the
# suite can tell the two paths apart: without it every AUR package installs
# through the repo branch and the fallback is never taken.
have() {
    grep -qxF "$1" "$st/available" 2>/dev/null || return 1
    [ "${0##*/}" = pacman ] && grep -qxF "$1" "$st/aur-only" 2>/dev/null && return 1
    return 0
}
case "${1:-}" in
  -Q)  grep -qxF "${2:-}" "$st/installed" 2>/dev/null ;;
  -Si) have "${2:-}" ;;
  -S|-Sy|-Syu)
      rc=0
      for a in "$@"; do
          case "$a" in -*) continue ;; esac
          if have "$a"; then
              grep -qxF "$a" "$st/installed" 2>/dev/null || echo "$a" >> "$st/installed"
              # Only paru/yay can see an aur-only name, so reaching here with
              # one is proof the helper did it and not the repo branch.
              grep -qxF "$a" "$st/aur-only" 2>/dev/null && echo "$a" >> "$st/aur-installed"
              if [ ! -e "$STUB_BIN/$a" ]; then
                  if [ -x "${STUB_TPL:-}/$a" ]; then cp "$STUB_TPL/$a" "$STUB_BIN/$a"
                  else printf '#!/bin/sh\necho "%s stub"\n' "$a" > "$STUB_BIN/$a"; fi
                  chmod +x "$STUB_BIN/$a"
              fi
              [ "$a" = fzf ] && [ "${STUB_NO_FZF:-0}" = 1 ] && rm -f "$STUB_BIN/$a"
          else
              echo "error: target not found: $a" >&2; rc=1
          fi
      done
      exit $rc ;;
  *) exit 0 ;;
esac
EOF
cp "$BIN/pacman" "$BIN/paru"
# yay takes the same flags; scenarios that want a yay-only box delete paru.
cp "$BIN/pacman" "$BIN/yay"

# ── curl ─────────────────────────────────────────────────────────────────────
# Connectivity probes succeed; vendor install scripts are synthesised so the
# tool they claim to install actually appears; downloads to a file produce one.
w curl <<'EOF'
#!/usr/bin/env bash
url=""; out=""; next_out=0
for a in "$@"; do
    if [ "$next_out" = 1 ]; then out="$a"; next_out=0; continue; fi
    case "$a" in
        -o|--output) next_out=1 ;;
        -*o) case "$a" in -*[!-]o) next_out=1 ;; esac ;;
        http*) url="$a" ;;
    esac
done
case "$url" in *deb.debian.org|*archive.ubuntu.com) exit 0 ;; esac
if [ -n "$out" ]; then
    # Keyring/signing-key fetches need real (non-empty) bytes — apt_install_keyring
    # rejects an empty download before gpg ever sees it. .deb files and font zips
    # stay empty stand-ins; every vendor *installer script* is served for real,
    # because the applications loop runs them and an empty file is a no-op that
    # exits 0 — which is indistinguishable from a working install, and is what
    # let every one of these apps go untested.
    #
    # Each one drops its binary where the real installer puts it (which is why
    # CURL_APP_PATH exists) and appends a PATH block to ~/.zshrc unless it was
    # handed its opt-out. That write is the point: ~/.zshrc is a stow symlink
    # into the checkout, so a real installer doing it edits a tracked dotfile,
    # and a scenario asserting the rc file is clean is the only thing that can
    # prove APP_CURL_ARGS/APP_CURL_ENV/CURL_APP_PATH reached the installer.
    case "$url" in
        */gpg|*.asc) printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\nSTUBKEY\n-----END PGP PUBLIC KEY BLOCK-----\n' > "$out" ;;
        *.deb)
            : > "$out"
            # Vendor .deb: the -o path is a mktemp name that says nothing, but the
            # URL is the real <pkg>_<ver>_<arch>.deb. Hand the name to the apt stub,
            # which only sees the temp file.
            b=${url##*/}; printf '%s\n' "${b%%_*}" > "${STUB_STATE:?}/deb_pkg"
            # ... and hash whatever was just written, so the .sha256 served
            # below is by construction the right one for this file. A literal
            # constant here would be the hash of an empty file, and would go
            # stale the day this branch writes anything into it.
            sha256sum "$out" | cut -d' ' -f1 > "${STUB_STATE:?}/deb_sha" ;;
        *nousresearch.com*)
            # The one vendor installer served for real, because Hermes is the
            # one with an argument that matters: without --skip-setup it ends
            # in an interactive wizard that would stop the run dead. Refusing
            # here is what makes a dropped flag a test failure.
            cat > "$out" <<'HERMES_SH'
#!/bin/sh
case " $* " in
    *" --skip-setup "*) ;;
    *) echo "STUBFAIL: hermes installer would open its setup wizard" >&2; exit 1 ;;
esac
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\necho hermes stub\n' > "$HOME/.local/bin/hermes"
chmod +x "$HOME/.local/bin/hermes"
HERMES_SH
            ;;
        *cli.devin.ai/*)
            # Served for real because Devin's installer is the one that ends by
            # launching an interactive login and then exits non-zero when it is
            # cancelled — the binary is on disk, the status says failure. This
            # reproduces both halves: it exits 1 after a clean install, and it
            # checks what it was handed on stdin — the wizard reads it, so a run
            # that does not redirect it would stall against the real installer.
            cat > "$out" <<'DEVIN_SH'
#!/bin/sh
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\necho devin stub "$@"\n' > "$HOME/.local/bin/devin"
chmod +x "$HOME/.local/bin/devin"
[ "$(readlink /proc/self/fd/0 2>/dev/null)" = /dev/null ] \
    || echo "STUBFAIL: devin installer was handed the run's own stdin" >&2
echo "Error: Login canceled" >&2
exit 1
DEVIN_SH
            ;;
        *antigravity*)
            # Served for real too, because the name is the whole point: this
            # installer writes `agy`, nothing resembling the app key, so a run
            # that never produces the binary is exactly what a missing APP_BIN
            # entry looks like from the outside.
            cat > "$out" <<'AGY_SH'
#!/bin/sh
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\necho agy stub "$@"\n' > "$HOME/.local/bin/agy"
chmod +x "$HOME/.local/bin/agy"
AGY_SH
            ;;
        *claude.ai/install.sh)
            cat > "$out" <<'CLAUDE_SH'
#!/bin/sh
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\necho claude stub "$@"\n' > "$HOME/.local/bin/claude"
chmod +x "$HOME/.local/bin/claude"
CLAUDE_SH
            ;;
        *chatgpt.com/codex/*)
            # No opt-out flag of its own: the only thing stopping the PATH block
            # is codex seeing ~/.local/bin already on PATH, i.e. CURL_APP_PATH.
            cat > "$out" <<'CODEX_SH'
#!/bin/sh
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) echo '# STUB PATH BLOCK (codex)' >> "$HOME/.zshrc" ;;
esac
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/codex" <<'CODEX_BIN'
#!/bin/sh
echo "codex stub $*"
if [ "${STUB_UPDATE_FAILS:-0}" = 1 ] && [ "$1" = update ]; then exit 1; fi
exit 0
CODEX_BIN
chmod +x "$HOME/.local/bin/codex"
CODEX_SH
            ;;
        *cursor.com/install)
            cat > "$out" <<'CURSOR_SH'
#!/bin/sh
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) echo '# STUB PATH BLOCK (cursor)' >> "$HOME/.zshrc" ;;
esac
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\necho agent stub "$@"\n' > "$HOME/.local/bin/agent"
chmod +x "$HOME/.local/bin/agent"
CURSOR_SH
            ;;
        *opencode.ai/install)
            cat > "$out" <<'OPENCODE_SH'
#!/bin/sh
case " $* " in
    *" --no-modify-path "*) ;;
    *) echo '# STUB PATH BLOCK (opencode)' >> "$HOME/.zshrc" ;;
esac
mkdir -p "$HOME/.opencode/bin"
printf '#!/bin/sh\necho opencode stub\n' > "$HOME/.opencode/bin/opencode"
chmod +x "$HOME/.opencode/bin/opencode"
OPENCODE_SH
            ;;
        *code.kimi.com/*)
            cat > "$out" <<'KIMI_SH'
#!/bin/sh
[ "${KIMI_NO_MODIFY_PATH:-}" = 1 ] || echo '# STUB PATH BLOCK (kimi)' >> "$HOME/.zshrc"
mkdir -p "$HOME/.kimi-code/bin"
printf '#!/bin/sh\necho kimi stub\n' > "$HOME/.kimi-code/bin/kimi"
chmod +x "$HOME/.kimi-code/bin/kimi"
KIMI_SH
            ;;
        *dev.meta.ai/*)
            cat > "$out" <<'MUSE_SH'
#!/bin/sh
[ "${MUSE_NO_MODIFY_PATH:-}" = 1 ] || echo '# STUB PATH BLOCK (muse)' >> "$HOME/.zshrc"
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\necho muse stub\n' > "$HOME/.local/bin/muse"
chmod +x "$HOME/.local/bin/muse"
MUSE_SH
            ;;
        *x.ai/cli/*)
            # Grok writes its PATH block to the rc file $SHELL names with no
            # guard at all — not a flag, not an "already on PATH" check — so
            # SHELL=/bin/sh is the only thing standing between it and the
            # tracked zsh/.zshrc it reaches through the stow symlink. Second
            # write, second guard: it symlinks grok and `agent` into whatever
            # PATH dir it can find unless its own bin dir is already there.
            cat > "$out" <<'GROK_SH'
#!/bin/sh
# The real installer only symlinks into a candidate that already exists and
# is writable, and a grok-only sandbox has no ~/.local/bin yet — so make one,
# or the branch this is here to catch cannot be taken at all.
mkdir -p "$HOME/.grok/bin" "$HOME/.local/bin"
printf '#!/bin/sh\necho grok stub\n' > "$HOME/.grok/bin/grok"
cp "$HOME/.grok/bin/grok" "$HOME/.grok/bin/agent"
chmod +x "$HOME/.grok/bin/grok" "$HOME/.grok/bin/agent"
case "${SHELL##*/}" in
    zsh|bash) echo '# STUB PATH BLOCK (grok)' >> "$HOME/.${SHELL##*/}rc" ;;
esac
case ":$PATH:" in
    *":$HOME/.grok/bin:"*) ;;
    *) ln -sf "$HOME/.grok/bin/grok"  "$HOME/.local/bin/grok"
       ln -sf "$HOME/.grok/bin/agent" "$HOME/.local/bin/agent" ;;
esac
GROK_SH
            ;;
        *mistral.ai/vibe/*)
            # Mistral is a wrapper, so the rc-file writer is one level down:
            # it installs uv when uv is missing, and uv's installer appends its
            # PATH line to .profile, .bashrc, .zshrc and .zshenv alike — the
            # third of those being the stow symlink into the checkout. Only
            # UV_NO_MODIFY_PATH=1 stops it, and it gets there by inheritance
            # through the wrapper's `sh "$installer"`, which is the whole thing
            # this is here to catch. Written flat rather than as two nested
            # installers, since inheritance is the only step between them.
            cat > "$out" <<'VIBE_SH'
#!/usr/bin/env bash
mkdir -p "$HOME/.local/bin"
if [ -z "${UV_NO_MODIFY_PATH:-}" ]; then
    for rc in .profile .bashrc .zshrc .zshenv; do
        echo '# STUB PATH BLOCK (uv)' >> "$HOME/$rc"
    done
fi
printf '#!/bin/sh\necho uv stub\n'   > "$HOME/.local/bin/uv"
printf '#!/bin/sh\necho vibe stub\n' > "$HOME/.local/bin/vibe"
cp "$HOME/.local/bin/vibe" "$HOME/.local/bin/vibe-acp"
chmod +x "$HOME/.local/bin/uv" "$HOME/.local/bin/vibe" "$HOME/.local/bin/vibe-acp"
VIBE_SH
            ;;
        *openrouter.ai/labs/ori/*)
            # ori has no opt-out flag: it writes its PATH block to the rc file
            # $SHELL names — and asks sudo for a /usr/local/bin symlink — unless
            # its install dir (~/.local/bin by default) is already on the PATH it
            # inherited, i.e. unless CURL_APP_PATH put it there. Same shape as
            # codex, and the only thing between it and the tracked zsh/.zshrc.
            cat > "$out" <<'ORI_SH'
#!/bin/sh
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) echo '# STUB PATH BLOCK (ori)' >> "$HOME/.zshrc" ;;
esac
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\necho ori stub "$@"\n' > "$HOME/.local/bin/ori"
chmod +x "$HOME/.local/bin/ori"
ORI_SH
            ;;
        *bun.com/install)
            # Three contracts in one installer: it unpacks a zip, so ensure_unzip
            # has to have run; its PATH block is guarded by ~/.bun/bin being on
            # PATH (CURL_APP_PATH); and `bun completions` writes to the rc file of
            # whatever $SHELL names, which is what SHELL=/bin/sh is for — a shell
            # it has no completions to write.
            cat > "$out" <<'BUN_SH'
#!/bin/sh
command -v unzip >/dev/null 2>&1 \
    || { echo "STUBFAIL: bun installer ran without unzip" >&2; exit 1; }
case ":$PATH:" in
    *":$HOME/.bun/bin:"*) ;;
    *) echo '# STUB PATH BLOCK (bun)' >> "$HOME/.zshrc" ;;
esac
case "${SHELL##*/}" in
    zsh|bash) echo '# STUB COMPLETIONS (bun)' >> "$HOME/.${SHELL##*/}rc" ;;
esac
mkdir -p "$HOME/.bun/bin"
printf '#!/bin/sh\necho bun stub\n' > "$HOME/.bun/bin/bun"
chmod +x "$HOME/.bun/bin/bun"
BUN_SH
            ;;
        *) : > "$out" ;;
    esac
    exit 0
fi
# The per-asset checksum install_release_deb looks for, served only for
# sinelaw/fresh — that is the split upstream really has, and fastfetch,
# Ulauncher and pay-respects publishing none is what keeps the "no checksum, go
# ahead and install" path under test in every other Debian scenario. Their
# .sha256 falls through to the 404 at the bottom of this file, like a real one.
# STUB_BAD_SHA serves a well-formed hash of something else, which is what a
# tampered or truncated .deb looks like from here.
case "$url" in
    *sinelaw/fresh/*.deb.sha256)
        if [ "${STUB_BAD_SHA:-0}" = 1 ]; then
            h=0000000000000000000000000000000000000000000000000000000000000000
        else
            h=$(cat "${STUB_STATE:?}/deb_sha" 2>/dev/null)
        fi
        b=${url##*/}
        printf '%s  %s\n' "$h" "${b%.sha256}"
        exit 0 ;;
esac
# github_latest_asset_url's first probe. One asset, named the way a release
# actually names one, so the caller's arch/extension pattern has to match.
case "$url" in
    *api.github.com/repos/*/releases/latest)
        repo=${url#*api.github.com/repos/}; repo=${repo%/releases/latest}
        case "$repo" in
            sinelaw/fresh)    pkg=fresh-editor ;;
            cli/cli)          pkg=gh ;;
            dandavison/delta) pkg=git-delta ;;
            *)             pkg=${repo#*/} ;;
        esac
        # delta really does publish two assets whose names both end in
        # _<arch>.deb, with the musl one listed first — which is what makes
        # "first match wins" pick the wrong package. Served in that order.
        [ "$repo" = dandavison/delta ] && \
            printf '"browser_download_url": "https://github.com/%s/releases/download/v1.0/git-delta-musl_1.0_%s.deb"\n' \
                "$repo" "${STUB_ARCH:-amd64}"
        printf '"browser_download_url": "https://github.com/%s/releases/download/v1.0/%s_1.0_%s.deb"\n' \
            "$repo" "$pkg" "${STUB_ARCH:-amd64}"
        exit 0 ;;
esac
case "$url" in
    *starship.rs/install.sh) tool=starship ;;
    *opencode.ai/install)    tool=opencode ;;
    *code.kimi.com*)         tool=kimi ;;
    *antigravity*)           tool=agy ;;
    *)                       tool="" ;;
esac
if [ -n "$tool" ]; then
    printf '#!/bin/sh\nmkdir -p "$HOME/.local/bin"\nprintf "#!/bin/sh\\necho %s stub\\n" > "$HOME/.local/bin/%s"\nchmod +x "$HOME/.local/bin/%s"\n' "$tool" "$tool" "$tool"
    exit 0
fi
exit 1
EOF

# ── shell / account plumbing ─────────────────────────────────────────────────
w chsh <<'EOF'
#!/usr/bin/env bash
sh=""
while [ $# -gt 0 ]; do
    case "$1" in -s) sh="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "$sh" ] || { echo "chsh: no shell given" >&2; exit 1; }
echo "$sh" > "${STUB_STATE:?}/login_shell"
EOF
w usermod <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
    case "$1" in -s) echo "$2" > "${STUB_STATE:?}/login_shell"; shift 2 ;; *) shift ;; esac
done
EOF
w getent <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = passwd ] || exit 1
sh=$(cat "${STUB_STATE:?}/login_shell" 2>/dev/null || echo /bin/bash)
echo "${2:-$USER}:x:1000:1000::${HOME}:${sh}"
EOF

# ── id: lets a scenario pretend to be a root login ───────────────────────────
w id <<'EOF'
#!/usr/bin/env bash
if [ "${STUB_FAKE_ROOT:-0}" = 1 ]; then
    case "${1:-}" in
        -u)  echo 0 ;;
        -un) echo root ;;
        *)   echo "uid=0(root) gid=0(root) groups=0(root)" ;;
    esac
    exit 0
fi
exec /usr/bin/id "$@"
EOF

# The root path replaces sudo with env, bypassing the sudo stub entirely, so
# these have to refuse system paths on their own.
for c in tee mkdir chmod install; do
    real="$(command -v "$c")"
    cat > "$BIN/$c" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
    case "\$a" in /etc/*|/usr/*|/var/*|/opt/*) cat > /dev/null 2>/dev/null; exit 0 ;; esac
done
exec "$real" "\$@"
EOF
    chmod +x "$BIN/$c"
done

# ── templates ────────────────────────────────────────────────────────────────
# fzf picks whatever the scenario asked for, per invocation (configs, deps, apps)
wt fzf <<'EOF'
#!/usr/bin/env bash
st="${STUB_STATE:?}"
n=$(( $(cat "$st/fzf_calls" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$st/fzf_calls"
var="STUB_FZF_PICK$n"
pick="${!var:-}"
while IFS= read -r line; do
    key="${line%%[[:space:]]*}"
    for p in $pick; do
        [ "$key" = "$p" ] && { printf '%s\n' "$line"; break; }
    done
done
EOF
# git "installed" by a package manager has to be the real thing: the bootstrap
# clones with it moments later.
wt git <<'EOF'
#!/bin/sh
exec /usr/bin/git "$@"
EOF

# ── a system bin mirror without fzf, the AUR helpers or unzip ────────────────
# so "fzf is not installed yet" is actually true inside a scenario — and so a
# host that happens to have paru, yay or unzip cannot leak one into a sandbox
# that is meant to be without it (the stub PATH provides its own).
SYS="$WORK/sysbin"
rm -rf "$SYS"; mkdir -p "$SYS"
for f in /usr/bin/*; do
    b="${f##*/}"
    case "$b" in fzf|paru|yay|unzip) continue ;; esac
    ln -sf "$f" "$SYS/$b"
done
