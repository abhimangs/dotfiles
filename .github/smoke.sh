#!/usr/bin/env bash
# The root half of every container job in .github/workflows/ci.yml ("smoke" on
# each distro, and "omarchy"). Runs inside a plain distro image as root with
#   /repo  this checkout, read-only
#   /logs  where the transcripts go, so the workflow can upload them
# and does what a person's machine already has done to it: a user with
# passwordless sudo, and a copy of the repo that user owns. Then it hands over
# to smoke-user.sh, which runs as that user. Nothing here is per distro beyond
# installing sudo. Flavour switches: SMOKE_FLAVOR=omarchy | nix.
#
# What the stubbed suite cannot answer, this does: whether the names in
# PKG_MAP/APP_PKG still exist upstream, whether real pacman and real apt accept
# the flags they are handed, whether every vendor installer still works, and
# whether the installer's own detection agrees with what landed on disk.
set -uo pipefail

U=ci
H=/home/$U

step() { printf '\n\033[1m── %s\033[0m\n' "$1"; }
fail() { printf '\nFAIL: %s\n' "$1" >&2; exit 1; }

# Whatever happens, the user's transcripts leave the container: they die with it.
save_logs() {
    [ -d /logs ] || return 0
    cp -a "$H/smoke-logs/." /logs/ 2>/dev/null
    chmod -R a+rX /logs 2>/dev/null
    return 0
}
trap save_logs EXIT

step "sudo, the one thing a person's machine already has"
if [ "${SMOKE_FLAVOR:-}" = nix ]; then
    # nixos/nix is not a full NixOS image: give it an ID=nixos os-release so
    # install.sh takes the nix path, and make sure flakes work for the user.
    printf 'NAME="NixOS"\nID=nixos\nVERSION_ID=smoke\nPRETTY_NAME="NixOS (smoke)"\n' > /etc/os-release
    : > /etc/NIXOS
    # script(1) lives in util-linux; skip bashInteractive — the image already
    # has one and nix profile refuses the conflict.
    nix --extra-experimental-features 'nix-command flakes' profile install \
        nixpkgs#sudo nixpkgs#util-linux nixpkgs#shadow \
        nixpkgs#which nixpkgs#stow nixpkgs#findutils \
        || fail "could not install sudo/util-linux via nix"
    # Profile bin may not be first on PATH yet.
    case ":$PATH:" in *:/root/.nix-profile/bin:*) ;; *)
        PATH="/root/.nix-profile/bin:$PATH" ;; esac
    export PATH
    hash -r
elif command -v pacman >/dev/null; then
    # -Syu, not -Sy: a partial upgrade on a rolling distro is the thing the
    # installer's own pacman_install avoids.
    pacman -Syu --noconfirm --needed sudo || fail "could not install sudo"
elif command -v dnf >/dev/null; then
    # Fedora splits script(1) into util-linux-script; util-linux alone is not enough.
    dnf install -y sudo util-linux util-linux-script which passwd shadow-utils findutils \
        || fail "could not install sudo"
elif command -v apt-get >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq sudo || fail "could not install sudo"
    # No systemd in a container. proton-vpn-daemon's postinst runs systemctl
    # daemon-reload/enable/start, fails, and leaves dpkg half-configured, so
    # every apt install after it fails too. On a real machine that works; here
    # it is a no-op, diverted into place so it wins however the script finds
    # systemctl (a copy earlier on PATH did not) and stays put when systemd is
    # pulled in later: dpkg writes the real one to .real. Both spellings, since
    # bookworm's systemd still ships /bin/systemctl.
    for f in /usr/bin/systemctl /bin/systemctl; do
        dpkg-divert --local --divert "$f.real" --add "$f" >/dev/null || fail "dpkg-divert $f"
    done
    [ -e /usr/bin/systemctl ] && mv /usr/bin/systemctl /usr/bin/systemctl.real
    printf '#!/bin/sh\nexit 0\n' > /usr/bin/systemctl
    chmod 0755 /usr/bin/systemctl
else
    fail "no supported package manager (pacman/dnf/apt/nix) on this image"
fi

# script(1) is what gives install.sh the controlling terminal a CI step lacks.
# It is in util-linux on Arch/Fedora/nix and bsdutils (Essential) on Debian/Ubuntu.
command -v script >/dev/null || fail "script(1) is missing from this image"

if [ "${SMOKE_FLAVOR:-}" = omarchy ]; then
    # shellcheck source=omarchy.sh
    source /repo/.github/omarchy.sh
    omarchy_prepare
fi

step "a user with passwordless sudo and a repo copy of its own"
# NixOS/nix images may already have a `ci` user from a previous layer; -m is fine.
if ! id "$U" &>/dev/null; then
    useradd -m -s /bin/bash "$U" || fail "useradd failed"
fi
# CI has no one to type a password. The user is named, not put in a group, so
# this works on every distro whatever its admin group is called.
mkdir -p /etc/sudoers.d
echo "$U ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/ci-user
chmod 0440 /etc/sudoers.d/ci-user
# The checkout is read-only and belongs to the runner's uid; the symlinks stow
# makes should point somewhere the user owns, as they do on a real machine.
cp -a /repo "$H/dotfiles" && chown -R "$U:$U" "$H/dotfiles" || fail "could not copy the repo"
mkdir -p "$H/smoke-logs" && chown "$U:$U" "$H/smoke-logs"

if [ "${SMOKE_FLAVOR:-}" = omarchy ]; then omarchy_snapshot; fi

# On the nix image the daemon socket is world-usable; the user still needs the
# nix binary and flakes on PATH for install.sh's nix_install.
if [ "${SMOKE_FLAVOR:-}" = nix ]; then
    # Trusted user so nix profile install does not need root.
    mkdir -p /etc/nix
    grep -q "trusted-users" /etc/nix/nix.conf 2>/dev/null \
        || echo "trusted-users = root $U" >> /etc/nix/nix.conf
    grep -q "experimental-features" /etc/nix/nix.conf 2>/dev/null \
        || echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf
fi

step "smoke-user.sh, as $U"
# runuser -l is a login shell: profile.d runs, HOME and PATH are the user's,
# which is how Omarchy's /etc/profile.d/omarchy.sh reaches the installer too.
# The nix image may only have `su`.
_cmd=$(printf 'cd ~/dotfiles && env SMOKE_CONFIGS=%q SMOKE_TOOLS=%q SMOKE_APPS=%q bash .github/smoke-user.sh' \
    "${SMOKE_CONFIGS:-all}" "${SMOKE_TOOLS:-all}" "${SMOKE_APPS:-all}")
if command -v runuser >/dev/null; then
    runuser -l "$U" -c "$_cmd"
    rc=$?
else
    su - "$U" -c "$_cmd"
    rc=$?
fi
unset _cmd

if [ "${SMOKE_FLAVOR:-}" = omarchy ]; then
    omarchy_verify || rc=1
fi
exit "$rc"
