#!/usr/bin/env bash
# Runs inside archlinux:base, as root, with this repo mounted at /repo.
# Called only by the "omarchy" job in .github/workflows/ci.yml.
#
# Question: do these dotfiles coexist with Omarchy (github.com/basecamp/omarchy,
# Arch + Hyprland, v4 is a pacman package) on a user Omarchy has set up?
#
# How faithful, and where it stops. Omarchy 4 ships from its own signed pacman
# repo (pkgs.omarchy.org/stable, key 40DFB630FF42BCFFB047046CF0134EE680CAC571,
# repo stanza from default/pacman/pacman-stable.conf upstream). Its
# `omarchy-settings` package is the part that touches a user: /etc/skel (the
# .bashrc and ~/.config files a new Omarchy account starts from), the
# /etc/os-release rewrite and /etc/profile.d/omarchy.sh. This installs exactly
# that package from that repo with that key, then creates the user with
# `useradd -m`, which copies /etc/skel the way Omarchy's installer does.
# NOT installed: the `omarchy` meta package (120 MB, Hyprland, SDDM, Docker,
# Chromium...; its hooks need systemd and a bootloader) and the first-login
# omarchy-provision-user step, so the /usr/bin/omarchy-* commands are absent.
# A GitHub runner has no KVM for Omarchy's own full-ISO test either.
set -uo pipefail

# Pinned: a key that changes should be a person's decision, not a download's.
OMARCHY_KEY=40DFB630FF42BCFFB047046CF0134EE680CAC571
OMARCHY_USER=omarch

step() { printf '\n\033[1m── %s\033[0m\n' "$1"; }
fail() { printf '\nFAIL: %s\n' "$1" >&2; exit 1; }

step "trusting the Omarchy packaging key"
# A key off the network is only as good as the comparison against the pinned
# fingerprint, so make it explicit rather than trusting the keyserver's answer.
curl -fsSL "https://keys.openpgp.org/vks/v1/by-fingerprint/$OMARCHY_KEY" -o /tmp/omarchy.asc \
    || fail "could not fetch the Omarchy key"
got=$(gpg --show-keys --with-colons /tmp/omarchy.asc | awk -F: '/^fpr:/ {print $10; exit}')
[ "$got" = "$OMARCHY_KEY" ] || fail "key fingerprint is $got, expected $OMARCHY_KEY"
pacman-key --add /tmp/omarchy.asc || fail "pacman-key --add failed"
pacman-key --lsign-key "$OMARCHY_KEY" || fail "pacman-key --lsign-key failed"

step "adding the [omarchy] repository and installing omarchy-settings"
# Upstream's stanza, minus its mirror fallback. The global SigLevel in Arch's
# pacman.conf is Required DatabaseOptional, which is what upstream ends on.
printf '\n[omarchy]\nServer = https://pkgs.omarchy.org/stable/$arch\n' >> /etc/pacman.conf
# -Syu, not -Sy: a partial upgrade on a rolling distro is the thing apt_install
# and pacman_install already avoid. sudo and stow are the installer's own needs.
pacman -Syu --noconfirm --needed omarchy-keyring omarchy-settings sudo \
    || fail "installing omarchy-settings from the Omarchy repo failed"
ver=$(pacman -Q omarchy-settings | awk '{print $2}')
echo "omarchy-settings $ver"
# Not pinned to a patch release: the repo only carries the current one, so a
# pin would turn red on every Omarchy release for no reason. A new *major* is
# the thing that may move /etc/skel or the bashrc contract.
case "$ver" in 4.*) ;; *) fail "omarchy-settings $ver: expected 4.x, re-read this file" ;; esac

step "creating the Omarchy user from /etc/skel"
useradd -m -G wheel -s /bin/bash "$OMARCHY_USER" || fail "useradd failed"
# CI has no one to type a password; the ISO's account sudoes with one.
echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/ci-wheel
chmod 0440 /etc/sudoers.d/ci-wheel
H=/home/$OMARCHY_USER
# A private copy of the repo, owned by the user: the mount belongs to the
# runner's uid, and the symlinks stow makes should point somewhere the user owns.
cp -a /repo "$H/dotfiles" && chown -R "$OMARCHY_USER:$OMARCHY_USER" "$H/dotfiles"

step "what Omarchy gave this user"
grep -q '^ID_LIKE=arch' /etc/os-release || fail "/etc/os-release has no ID_LIKE=arch"
grep -q env-bootstrap "$H/.bashrc" || fail "the new user's .bashrc is not Omarchy's"
# The paths our configs are about to collide with. If upstream drops one, the
# backup assertions below would pass vacuously, so say so instead.
for p in tmux lazygit btop starship.toml; do
    [ -e "$H/.config/$p" ] || fail "Omarchy no longer seeds ~/.config/$p: update this job"
done
mkdir -p /tmp/omarchy-before
cp -a "$H/.bashrc" /tmp/omarchy-before/bashrc
for p in tmux lazygit btop starship.toml; do cp -a "$H/.config/$p" "/tmp/omarchy-before/$p"; done

step "smoke.sh, as the Omarchy user"
# zsh is the config that edits ~/.bashrc, so it is the one that can break
# Omarchy's; starship.toml and tmux/lazygit/btop are the ones Omarchy ships too.
runuser -l "$OMARCHY_USER" -c "cd ~/dotfiles && SMOKE_REPO=\$HOME/dotfiles \
    SMOKE_INSTALL='--configs=git,starship,zsh --tools=bat,tmux,lazygit,btop' \
    bash .github/smoke.sh" || fail "smoke.sh failed for the Omarchy user"

step "checking that the two coexist"
# Omarchy's files are moved aside, not lost: .bak holds exactly what skel gave.
for p in tmux lazygit btop starship.toml; do
    [ -L "$H/.config/$p.bak" ] && fail "$p.bak is a symlink"
    diff -r "/tmp/omarchy-before/$p" "$H/.config/$p.bak" >/dev/null \
        || fail "~/.config/$p.bak is not Omarchy's original"
done
[ "$(readlink -f "$H/.config/starship.toml")" = "$H/dotfiles/starship/starship.toml" ] \
    || fail "starship.toml is not our symlink"
[ "$(readlink -f "$H/.config/tmux/tmux.conf")" = "$H/dotfiles/tmux/tmux.conf" ] \
    || fail "tmux.conf is not our symlink"
# zsh was selected, so the hand-off hook was appended, to Omarchy's file, which
# is a regular file, not a symlink, and starts exactly as it did.
[ -L "$H/.bashrc" ] && fail "~/.bashrc became a symlink"
grep -q '^# >>> .*(v2) >>>' "$H/.bashrc" || fail "no zsh hand-off block in ~/.bashrc"
head -n "$(wc -l < /tmp/omarchy-before/bashrc)" "$H/.bashrc" | cmp -s - /tmp/omarchy-before/bashrc \
    || fail "Omarchy's .bashrc lines were altered"
cmp -s "$H/.bashrc.orig" /tmp/omarchy-before/bashrc || fail "~/.bashrc.orig is not Omarchy's original"
# The environment Omarchy sets up still reaches a login shell.
out=$(runuser -l "$OMARCHY_USER" -c 'bash -lc "echo \$OMARCHY_PATH"')
[ "$out" = /usr/share/omarchy ] || fail "OMARCHY_PATH is '$out' in a login shell"
# Distro detection: Omarchy rewrites os-release to ID=omarchy ID_LIKE=arch, and
# the installer must still have taken the Arch path (pacman owns the packages).
pacman -Q tmux >/dev/null || fail "tmux was not installed through pacman"

echo
echo "omarchy: ok"
