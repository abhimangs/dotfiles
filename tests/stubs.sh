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
    add-apt-repository|chsh|usermod|flatpak|update-alternatives)
        exec "$@" ;;
    *)  # never run anything else with pretend privileges
        exit 0 ;;
esac
EOF

# ── apt-get ──────────────────────────────────────────────────────────────────
w apt-get <<'EOF'
#!/usr/bin/env bash
st="${STUB_STATE:?}"
sub=""
for a in "$@"; do case "$a" in -*) ;; *) sub="$a"; break ;; esac; done

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
      for a in "$@"; do
          case "$a" in -*|install) continue ;; esac
          case "$a" in *.deb) continue ;; esac
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
w systemctl            <<< '#!/bin/sh
exit 0'
w pacman-key           <<< '#!/bin/sh
exit 0'
w fc-cache             <<< '#!/bin/sh
exit 0'
w fc-list              <<< '#!/bin/sh
exit 0'
w flatpak              <<< '#!/bin/sh
exit 0'
w unzip                <<< '#!/bin/sh
exit 0'
w gpg                  <<< '#!/bin/sh
cat > /dev/null; exit 0'
# The installer only checks stow'\''s exit status, so this is enough for it.
w stow                 <<< '#!/bin/sh
exit 0'

# ── Arch side ────────────────────────────────────────────────────────────────
w pacman <<'EOF'
#!/usr/bin/env bash
st="${STUB_STATE:?}"
case "${1:-}" in
  -Q)  grep -qxF "${2:-}" "$st/installed" 2>/dev/null ;;
  -Si) grep -qxF "${2:-}" "$st/available" 2>/dev/null ;;
  -S|-Sy|-Syu)
      rc=0
      for a in "$@"; do
          case "$a" in -*) continue ;; esac
          if grep -qxF "$a" "$st/available" 2>/dev/null; then
              grep -qxF "$a" "$st/installed" 2>/dev/null || echo "$a" >> "$st/installed"
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
if [ -n "$out" ]; then : > "$out"; exit 0; fi
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

# ── a system bin mirror without fzf ──────────────────────────────────────────
# so "fzf is not installed yet" is actually true inside a scenario
SYS="$WORK/sysbin"
rm -rf "$SYS"; mkdir -p "$SYS"
for f in /usr/bin/*; do
    b="${f##*/}"
    case "$b" in fzf) continue ;; esac
    ln -sf "$f" "$SYS/$b"
done
