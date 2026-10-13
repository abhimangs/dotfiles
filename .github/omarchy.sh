#!/usr/bin/env bash
# Sourced by smoke.sh when SMOKE_FLAVOR=omarchy. Not run on its own.
#
# Question: do these dotfiles coexist with Omarchy (github.com/omacom/omarchy,
# Arch + Hyprland; v4 is a pacman package) on a user Omarchy has set up?
#
# How faithful, and where it stops. Omarchy 4 ships from its own signed pacman
# repo (pkgs.omarchy.org/stable, key 40DFB630FF42BCFFB047046CF0134EE680CAC571;
# the repo stanza is default/pacman/pacman-stable.conf upstream). Its
# `omarchy-settings` package is the part that touches a user: /etc/skel (the
# .bashrc and ~/.config files a new Omarchy account starts from), the
# /etc/os-release rewrite and /etc/profile.d/omarchy.sh. This installs exactly
# that package from that repo with that key, then smoke.sh creates the user with
# `useradd -m`, which copies /etc/skel the way Omarchy's installer does.
# NOT installed: the `omarchy` meta package (120 MB, Hyprland, SDDM, Docker,
# Chromium...; its hooks need systemd and a bootloader) and the first-login
# omarchy-provision-user step, so the /usr/bin/omarchy-* commands are absent.
# A GitHub runner has no KVM for Omarchy's own full-ISO test either.

# Pinned: a key that changes should be a person's decision, not a download's.
OMARCHY_KEY=40DFB630FF42BCFFB047046CF0134EE680CAC571
OMARCHY_SKEL_PATHS=(.config/tmux .config/lazygit .config/btop .config/starship.toml)

omarchy_prepare() {     # as root, before the user exists
    step "trusting the Omarchy packaging key"
    # A key off the network is only as good as the comparison against the pinned
    # fingerprint, so make it explicit rather than trusting the keyserver.
    curl -fsSL "https://keys.openpgp.org/vks/v1/by-fingerprint/$OMARCHY_KEY" -o /tmp/omarchy.asc \
        || fail "could not fetch the Omarchy key"
    local got
    got=$(gpg --show-keys --with-colons /tmp/omarchy.asc | awk -F: '/^fpr:/ {print $10; exit}')
    [ "$got" = "$OMARCHY_KEY" ] || fail "key fingerprint is $got, expected $OMARCHY_KEY"
    pacman-key --add /tmp/omarchy.asc || fail "pacman-key --add failed"
    pacman-key --lsign-key "$OMARCHY_KEY" || fail "pacman-key --lsign-key failed"

    step "adding the [omarchy] repository and installing omarchy-settings"
    # Upstream's stanza, minus its mirror fallback. Arch's global SigLevel is
    # Required DatabaseOptional, which is what upstream ends on.
    # shellcheck disable=SC2016  # $arch is pacman's, not ours
    printf '\n[omarchy]\nServer = https://pkgs.omarchy.org/stable/$arch\n' >> /etc/pacman.conf
    pacman -Syu --noconfirm --needed omarchy-keyring omarchy-settings \
        || fail "installing omarchy-settings from the Omarchy repo failed"
    local ver
    ver=$(pacman -Q omarchy-settings | awk '{print $2}')
    echo "omarchy-settings $ver"
    # Not pinned to a patch release: the repo only carries the current one, so a
    # pin would go red on every Omarchy release for no reason. A new *major* is
    # what may move /etc/skel or the bashrc contract.
    case "$ver" in 4.*) ;; *) fail "omarchy-settings $ver: expected 4.x, re-read omarchy.sh" ;; esac
}

omarchy_snapshot() {    # as root, once the user exists: what Omarchy gave them
    step "what Omarchy gave this user"
    grep -q '^ID_LIKE=arch' /etc/os-release || fail "/etc/os-release has no ID_LIKE=arch"
    grep -q env-bootstrap "$H/.bashrc" || fail "the new user's .bashrc is not Omarchy's"
    # If upstream stops seeding one of these, the .bak assertions below would
    # pass vacuously, so say so instead.
    local p
    for p in "${OMARCHY_SKEL_PATHS[@]}"; do
        [ -e "$H/$p" ] || fail "Omarchy no longer seeds ~/$p: update OMARCHY_SKEL_PATHS"
    done
    mkdir -p /tmp/omarchy-before
    cp -a "$H/.bashrc" /tmp/omarchy-before/.bashrc
    for p in "${OMARCHY_SKEL_PATHS[@]}"; do
        mkdir -p "/tmp/omarchy-before/$(dirname "$p")"
        cp -a "$H/$p" "/tmp/omarchy-before/$p"
    done
}

# Reads the user's transcript and home after the run. Collects every problem
# rather than stopping at the first.
omarchy_verify() {      # as root, after smoke-user.sh
    step "coexistence with Omarchy"
    local bad=0 p log="$H/smoke-logs/install.log"
    flunk_() { printf '  FAIL  %s\n' "$1"; bad=1; }
    ok_() { printf '  PASS  %s\n' "$1"; }

    # Omarchy's own files were moved aside, not lost: .bak holds exactly what
    # /etc/skel gave. (~/.bashrc is the bash config's to replace, so it is in
    # the same list.)
    for p in "${OMARCHY_SKEL_PATHS[@]}" .bashrc; do
        if [ -L "$H/$p.bak" ]; then flunk_ "~/$p.bak is a symlink"
        elif diff -r "/tmp/omarchy-before/$p" "$H/$p.bak" >/dev/null 2>&1; then ok_ "~/$p.bak is Omarchy's original"
        else flunk_ "~/$p.bak is not Omarchy's original (or missing)"; fi
    done
    [ "$(readlink -f "$H/.config/starship.toml")" = "$H/dotfiles/starship/starship.toml" ] \
        && ok_ "starship.toml is ours" || flunk_ "starship.toml is not our symlink"
    [ "$(readlink -f "$H/.config/tmux/tmux.conf")" = "$H/dotfiles/tmux/tmux.conf" ] \
        && ok_ "tmux.conf is ours" || flunk_ "tmux.conf is not our symlink"
    [ "$(readlink -f "$H/.bashrc")" = "$H/dotfiles/bash/.bashrc" ] \
        && ok_ "~/.bashrc is ours" || flunk_ "~/.bashrc is not our symlink"
    cmp -s "$H/.bashrc.orig" /tmp/omarchy-before/.bashrc \
        && ok_ "~/.bashrc.orig is Omarchy's original" || flunk_ "~/.bashrc.orig is not Omarchy's original"

    # The environment Omarchy sets up still reaches its shells: a login shell
    # (profile.d) and an interactive one (our .bashrc sources Omarchy's rc).
    local out
    out=$(runuser -l "$U" -c 'bash -lc "echo \$OMARCHY_PATH"' 2>/dev/null | tail -n1)
    [ "$out" = /usr/share/omarchy ] && ok_ "login shell: OMARCHY_PATH=$out" || flunk_ "login shell: OMARCHY_PATH is '$out'"
    out=$(runuser -l "$U" -c 'bash -ic "echo \$OMARCHY_PATH" 2>/dev/null' | tail -n1)
    [ "$out" = /usr/share/omarchy ] && ok_ "interactive shell: OMARCHY_PATH=$out" || flunk_ "interactive shell: OMARCHY_PATH is '$out'"

    # os-release says omarchy; the installer must still have taken the Arch path.
    grep -q '^ID=omarchy' /etc/os-release && ok_ "/etc/os-release is Omarchy's (ID=omarchy)" \
        || flunk_ "/etc/os-release is not Omarchy's"
    pacman -Q tmux >/dev/null 2>&1 && ok_ "tmux came through pacman" || flunk_ "tmux was not installed through pacman"

    # The strings the plan prints on Omarchy. Fragments without dashes: --ascii
    # changes how those render.
    local s
    for s in "replaces Omarchy's themed copy" "replaces Omarchy's stock starship.toml"; do
        grep -qF -- "$s" "$log" && ok_ "plan says: $s" || flunk_ "plan never says: $s"
    done
    # Once in the plan and once in the summary.
    local n
    n=$(grep -cF "Omarchy's refresh and font commands copy over" "$log")
    [ "$n" -ge 2 ] && ok_ "write-through warning: plan and summary ($n)" \
        || flunk_ "write-through warning appears $n time(s), expected plan and summary"

    return "$bad"
}
