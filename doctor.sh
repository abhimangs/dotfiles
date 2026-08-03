#!/usr/bin/env bash
# Collects everything needed to explain why the login shell is not what the
# installer set, plus general state of the dotfiles install. Read-only: it
# changes nothing. Run it and paste the whole output.
#
#   bash ~/dotfiles/doctor.sh

echo "════════ dotfiles doctor ════════"
echo "date            : $(date -Is 2>/dev/null)"
echo

echo "── identity ──────────────────────────────────────────"
echo "whoami          : $(id -un) (uid $(id -u))"
echo "HOME            : $HOME"
echo "SUDO_USER       : ${SUDO_USER:-<unset>}"
echo

echo "── shell: what the system thinks vs what is running ──"
echo "passwd entry    : $(getent passwd "$(id -un)")"
echo "login shell     : $(getent passwd "$(id -un)" | cut -d: -f7)"
echo "\$SHELL          : ${SHELL:-<unset>}"
echo "running shell   : $(ps -p $$ -o comm= 2>/dev/null)"
echo "parent process  : $(ps -p "${PPID:-0}" -o comm= 2>/dev/null)"
echo "zsh on PATH     : $(command -v zsh || echo '<none>')"
echo "zsh resolved    : $(command -v zsh >/dev/null && readlink -f "$(command -v zsh)" || echo '-')"
echo "zsh runs        : $(zsh -c 'echo yes' 2>/dev/null || echo 'NO — zsh fails to start')"
echo "zsh version     : $(zsh --version 2>/dev/null || echo '-')"
echo
echo "/etc/shells zsh lines:"
grep -n 'zsh' /etc/shells 2>/dev/null | sed 's/^/  /' || echo "  <none>"
echo

echo "── why a login session might ignore passwd ───────────"
echo "sshd ForceCommand / shell overrides:"
grep -nEi '^[[:space:]]*(ForceCommand|Match|PermitUserEnvironment)' /etc/ssh/sshd_config 2>/dev/null | sed 's/^/  /' || echo "  <none>"
for f in /etc/ssh/sshd_config.d/*.conf; do
    [ -f "$f" ] && grep -nEi '^[[:space:]]*(ForceCommand|Match)' "$f" 2>/dev/null | sed "s|^|  $f:|"
done
echo "authorized_keys command= restrictions:"
if [ -f "$HOME/.ssh/authorized_keys" ]; then
    echo "  count: $(grep -c 'command=' "$HOME/.ssh/authorized_keys" 2>/dev/null)"
else
    echo "  <no authorized_keys>"
fi
echo "cloud-init present : $(command -v cloud-init >/dev/null && echo yes || echo no)"
_virt="$(systemd-detect-virt 2>/dev/null)"; echo "container/VM       : ${_virt:-unknown}"
echo

echo "── bashrc hand-over hook ─────────────────────────────"
if [ -f "$HOME/.bashrc" ]; then
    # Matches both marker versions: v1 said "dotfiles: <tag>", v2 dropped that
    # word and appended "(v2)".
    if grep -qE '^# >>> (dotfiles: )?hand interactive bash to zsh' "$HOME/.bashrc"; then
        echo "hook present    : yes"
        if grep -q '(v2) >>>' "$HOME/.bashrc"; then
            echo "hook version    : v2 (hardened)"
        else
            echo "hook version    : v1 — re-run install.sh to upgrade it"
        fi
        grep -n -A4 -E '^# >>> (dotfiles: )?hand interactive' "$HOME/.bashrc" | sed 's/^/  /'
    else
        echo "hook present    : NO"
    fi
    echo "pristine copy   : $( [ -f "$HOME/.bashrc.orig" ] && echo "$HOME/.bashrc.orig" \
        || { [ -f "$HOME/.bashrc.none" ] && echo 'none — there was no ~/.bashrc' || echo 'not taken yet'; } )"
    echo "bashrc is       : $( [ -L "$HOME/.bashrc" ] && echo "a symlink -> $(readlink -f "$HOME/.bashrc")" || echo 'a real file' )"
    echo "bashrc early-return for non-interactive:"
    grep -n 'case \$-' "$HOME/.bashrc" 2>/dev/null | head -2 | sed 's/^/  /'
else
    echo "no ~/.bashrc"
fi
echo

echo "── dotfiles checkout ─────────────────────────────────"
d="$HOME/dotfiles"
echo "dir             : $d $( [ -d "$d" ] && echo '(exists)' || echo '(MISSING)')"
echo "install.sh      : $( [ -f "$d/install.sh" ] && echo present || echo MISSING)"
echo "git metadata    : $( [ -d "$d/.git" ] && echo present || echo 'stripped (private mode)')"
echo "top level:"
# shellcheck disable=SC2012  # a flat, human-readable listing is the point here;
# find(1) output would be one path per line and much noisier to paste into a bug
# report, which is the only thing this script exists to produce.
ls -A "$d" 2>/dev/null | tr '\n' ' ' | sed 's/^/  /'; echo
echo

echo "── stowed symlinks ───────────────────────────────────"
# Single-file targets are symlinks; ~/.config/<app> is a real directory by
# design, with stow linking the files inside it — so look one level in.
for t in "$HOME/.zshrc" "$HOME/.gitconfig" "$HOME/.config/starship.toml"; do
    if [ -L "$t" ]; then
        printf "  %-26s -> %-30s %s\n" "${t#"$HOME"/}" "$(readlink "$t")" \
            "$( [ -e "$t" ] && echo '[ok]' || echo '[BROKEN]')"
    elif [ -e "$t" ]; then
        printf "  %-26s %s\n" "${t#"$HOME"/}" "(real file — NOT stowed)"
    else
        printf "  %-26s %s\n" "${t#"$HOME"/}" "(absent)"
    fi
done
for d in fastfetch kitty ghostty rofi btop bat ulauncher wallpapers; do
    t="$HOME/.config/$d"
    [ -e "$t" ] || continue
    n=$(find "$t" -maxdepth 1 -type l 2>/dev/null | wc -l)
    broken=$(find "$t" -maxdepth 1 -xtype l 2>/dev/null | wc -l)
    printf "  %-26s %s\n" ".config/$d" "$n symlink(s) inside$( [ "$broken" -gt 0 ] && echo ", $broken BROKEN")"
done
echo

echo "── tools ─────────────────────────────────────────────"
for c in stow fzf git zsh starship fastfetch bat eza fd zoxide lazygit btop tree; do
    printf "  %-10s %s\n" "$c" "$(command -v "$c" || echo '-')"
done
echo

echo "── fonts ─────────────────────────────────────────────"
echo "fc-cache        : $(command -v fc-cache || echo '<not installed>')"
if command -v fc-list >/dev/null 2>&1; then
    echo "JetBrainsMono   : $(fc-list 2>/dev/null | grep -ci jetbrainsmono) faces"
    echo "Maple Mono      : $(fc-list 2>/dev/null | grep -ci 'maple') faces"
else
    echo "  fontconfig not installed (expected on a headless server)"
fi
echo

echo "── environment the installer keys off ────────────────"
echo "DISPLAY         : ${DISPLAY:-<unset>}"
echo "WAYLAND_DISPLAY : ${WAYLAND_DISPLAY:-<unset>}"
echo "systemd default : $(systemctl get-default 2>/dev/null || echo '<no systemctl>')"
echo "session files   : $(find /usr/share/xsessions /usr/share/wayland-sessions -name '*.desktop' 2>/dev/null | wc -l)"
echo "TERM            : ${TERM:-<unset>}"
echo "locale          : ${LC_ALL:-${LC_CTYPE:-${LANG:-<unset>}}}"
echo "WSL             : ${WSL_DISTRO_NAME:-no} / $(grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null && echo 'kernel says microsoft' || echo 'kernel normal')"
echo "arch            : $(dpkg --print-architecture 2>/dev/null || uname -m)"
echo "distro          : $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
echo
echo "════════ end ════════"
