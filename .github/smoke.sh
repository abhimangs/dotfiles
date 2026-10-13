#!/usr/bin/env bash
# The root half of every container job in .github/workflows/ci.yml ("smoke" on
# each distro, and "omarchy"). Runs inside a plain distro image as root with
#   /repo  this checkout, read-only
#   /logs  where the transcripts go, so the workflow can upload them
# and does what a person's machine already has done to it: a user with
# passwordless sudo, and a copy of the repo that user owns. Then it hands over
# to smoke-user.sh, which runs as that user. Nothing here is per distro beyond
# installing sudo, and the one flavour switch is SMOKE_FLAVOR=omarchy.
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

# script(1) is what gives install.sh the controlling terminal a CI step lacks.
# It is in util-linux on Arch and bsdutils (Essential) on Debian and Ubuntu.
command -v script >/dev/null || fail "script(1) is missing from this image"

step "sudo, the one thing a person's machine already has"
if command -v pacman >/dev/null; then
    # -Syu, not -Sy: a partial upgrade on a rolling distro is the thing the
    # installer's own pacman_install avoids.
    pacman -Syu --noconfirm --needed sudo || fail "could not install sudo"
else
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
fi

if [ "${SMOKE_FLAVOR:-}" = omarchy ]; then
    # shellcheck source=omarchy.sh
    source /repo/.github/omarchy.sh
    omarchy_prepare
fi

step "a user with passwordless sudo and a repo copy of its own"
useradd -m -s /bin/bash "$U" || fail "useradd failed"
# CI has no one to type a password. The user is named, not put in a group, so
# this works on every distro whatever its admin group is called.
echo "$U ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/ci-user
chmod 0440 /etc/sudoers.d/ci-user
# The checkout is read-only and belongs to the runner's uid; the symlinks stow
# makes should point somewhere the user owns, as they do on a real machine.
cp -a /repo "$H/dotfiles" && chown -R "$U:$U" "$H/dotfiles" || fail "could not copy the repo"
mkdir -p "$H/smoke-logs" && chown "$U:$U" "$H/smoke-logs"

if [ "${SMOKE_FLAVOR:-}" = omarchy ]; then omarchy_snapshot; fi

step "smoke-user.sh, as $U"
# runuser -l is a login shell: profile.d runs, HOME and PATH are the user's,
# which is how Omarchy's /etc/profile.d/omarchy.sh reaches the installer too.
runuser -l "$U" -c "$(printf 'cd ~/dotfiles && env SMOKE_CONFIGS=%q SMOKE_TOOLS=%q SMOKE_APPS=%q bash .github/smoke-user.sh' \
    "${SMOKE_CONFIGS:-all}" "${SMOKE_TOOLS:-all}" "${SMOKE_APPS:-all}")"
rc=$?

if [ "${SMOKE_FLAVOR:-}" = omarchy ]; then
    omarchy_verify || rc=1
fi
exit "$rc"
