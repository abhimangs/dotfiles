#!/usr/bin/env bash
# The user half of the smoke job: runs as the unprivileged account smoke.sh
# made, from its own copy of the repo, the way a person runs the installer.
# Everything is installed for real and then looked for, on disk and by the
# installer's own detection. See smoke-checks.sh for the assertions.
#
# Scope: the container is headless, so install.sh strips GUI_CONFIGS and
# GUI_APPS by itself. "all" therefore means every config, tool and CLI app a
# headless box can take. The dry run is the one place --gui is passed, so every
# entry, GUI ones included, is at least planned.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
REPO="$(pwd -P)"
# shellcheck source=smoke-checks.sh
source .github/smoke-checks.sh

CONFIGS="${SMOKE_CONFIGS:-all}" TOOLS="${SMOKE_TOOLS:-all}" APPS="${SMOKE_APPS:-all}"
SEL="--configs=$CONFIGS --tools=$TOOLS --apps=$APPS"

step "planning every entry, GUI ones included (--dry-run --gui)"
run_logged plan "--dry-run --gui --configs=all --tools=all --apps=all"
check_plan plan

step "installing for real ($SEL --backup-mode=backup)"
run_logged install "$SEL --backup-mode=backup"
check_install install
# Headless is what makes "all" mean "everything a container can take".
bash install.sh --list | tail -n 3 | sed 's/^/  /'

step "does the installer see what it just installed"
check_detected "$CONFIGS" "$TOOLS" "$APPS"
run_logged plan-after "--dry-run $SEL"
check_nothing_left plan-after

step "the filesystem, not the transcript"
check_links "$REPO" "$CONFIGS" "$TOOLS" "$APPS"
[ "$(readlink -f "$HOME/.gitconfig")" = "$REPO/git/.gitconfig" ] \
    && pass "~/.gitconfig points into the repo copy" || flunk "~/.gitconfig does not point at $REPO/git/.gitconfig"
# bat is batcat on Debian/Ubuntu; either name is a pass.
{ command -v bat || command -v batcat; } >/dev/null && pass "bat is on PATH" || flunk "neither bat nor batcat is on PATH"
if [ "$CONFIGS" = all ] || [[ ",$CONFIGS," == *,bash,* ]]; then
    # With the bash config selected ~/.bashrc is ours and the zsh hand-off is
    # deliberately not written (zsh_hook_wanted).
    [ "$(readlink -f "$HOME/.bashrc")" = "$REPO/bash/.bashrc" ] \
        && pass "~/.bashrc is the repo's" || flunk "~/.bashrc is not the repo's bash/.bashrc"
    grep -q '>>>.*>>>' "$HOME/.bashrc" && flunk "the zsh hand-off was written into a bash config that is ours"
fi
check_doctor doctor

step "the same install again: nothing new, nothing broken"
run_logged install2 "$SEL --backup-mode=backup"
check_install install2
check_no_new_installs install2
check_doctor doctor2

# A vendor installer's own log, for the failure annotation to point at.
cp ~/.hermes/logs/install.log "$LOGS/hermes-install.log" 2>/dev/null

verdict
