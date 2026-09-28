#!/usr/bin/env bash
# Runs inside a plain distro image, as root, with this repo mounted at /repo.
# Called only by the "smoke" job in .github/workflows/ci.yml.
#
# What the stubbed suite cannot answer: whether the names in PKG_MAP/APP_PKG
# still exist upstream, whether real pacman and real apt accept the flags they
# are handed, and whether stow actually lands where show_plan promised. This
# runs the installer against a real package manager to find out.
#
# Root is the container's default and a documented supported way to run this —
# it takes the "Running as root — sudo not needed" branch, which nothing else
# exercises end to end either.
set -uo pipefail

step() { printf '\n\033[1m── %s\033[0m\n' "$1"; }
fail() { printf '\nFAIL: %s\n' "$1" >&2; exit 1; }

# script(1) is what gives install.sh a controlling terminal — a CI step has
# none, and the installer refuses to run without one. It needs no bootstrap on
# any of these images: Arch has it in util-linux (in `base`), Debian and Ubuntu
# in bsdutils, which is Essential. Nothing else here is installed by hand
# either — apt_install refreshes its own index, which is the point.
command -v script >/dev/null || fail "script(1) is missing from this image"

run_installer() {       # run_installer <flags>
    # Every run here names its selection, so nothing is asked: the privacy
    # and existing-configs questions and the Proceed? prompt all answer
    # themselves. The newlines are only there in case one ever does not.
    printf '\n\n\n\n\n' | script -qec "bash install.sh $1" /dev/null
}

step "planning every entry (--dry-run)"
# --dry-run stops at the plan and installs nothing — the apt refresh, paru and
# stow all wait for Proceed now — but it gets there through real distro
# detection and a real package lookup (pacman -Si on Arch) for every config,
# tool and app offered on this distro.
run_installer "--dry-run --configs=all --tools=all --apps=all" | tee /tmp/plan.log
grep -q 'dry run' /tmp/plan.log || fail "the dry run never reached the plan"

step "installing two entries for real"
run_installer "--configs=git --tools=bat" | tee /tmp/install.log

step "checking the filesystem, not the transcript"
# The transcript says what the installer believes; these say what happened.
[ -L "$HOME/.gitconfig" ] || fail "~/.gitconfig is not a symlink"
link=$(readlink -f "$HOME/.gitconfig")
[ "$link" = /repo/git/.gitconfig ] || fail "~/.gitconfig points at $link"
# bat is batcat on Debian/Ubuntu, which is the whole reason PKG_BIN and
# ensure_bat_shim exist — either name is a pass.
command -v bat >/dev/null || command -v batcat >/dev/null \
    || fail "neither bat nor batcat is on PATH"

step "doctor.sh on a real box"
# The tool the README tells people to paste into a bug report. It installs
# nothing and prompts for nothing, so the only thing that can go wrong is the
# thing worth catching: it falling over on a distro it claims to support.
bash doctor.sh || fail "doctor.sh exited non-zero"

echo
echo "smoke: ok"
