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
# Field 5 (GECOS) is the account's real name and often more; this gets pasted publicly.
echo "passwd entry    : $(getent passwd "$(id -un)" | awk -F: -v OFS=: '{$5="";print}')"
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
# The trailing grep is what makes "<none>" reachable: a pipeline's status is
# its last command's, and sed succeeds on empty input.
grep -n 'zsh' /etc/shells 2>/dev/null | sed 's/^/  /' | grep . || echo "  <none>"
echo

echo "── why a login session might ignore passwd ───────────"
echo "sshd ForceCommand / shell overrides:"
grep -nEi '^[[:space:]]*(ForceCommand|Match|PermitUserEnvironment)' /etc/ssh/sshd_config 2>/dev/null | sed 's/^/  /' | grep . || echo "  <none>"
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
# Where this script actually is, not where it is usually cloned. Reporting
# "$HOME/dotfiles (MISSING)" while running from inside the checkout is the kind
# of wrong answer that sends someone debugging the wrong thing.
d="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
echo "dir             : $d $( [ -d "$d" ] && echo '(exists)' || echo '(MISSING)')"
echo "install.sh      : $( [ -f "$d/install.sh" ] && echo present || echo MISSING)"
echo "git metadata    : $( [ -e "$d/.git" ] && echo present || echo 'stripped (private mode)')"
echo "top level:"
# shellcheck disable=SC2012  # a flat, human-readable listing is the point here;
# find(1) output would be one path per line and much noisier to paste into a bug
# report, which is the only thing this script exists to produce.
ls -A "$d" 2>/dev/null | tr '\n' ' ' | sed 's/^/  /'; echo
echo

# ── install.sh's own lists ────────────────────────────────────────────
# These used to be hand-kept copies of CONFIGS, DEPS_LIST, the APP_UPDATE keys
# and CURL_APP_PATH, and they fell behind four times — micro, fresh,
# ccstatusline and pay-respects were each silently absent from this report for
# a while, which sends whoever pastes it debugging the wrong thing. Ask
# install.sh instead. `--list --porcelain` installs nothing, prompts for
# nothing and needs no terminal, so this stays a read-only script.
PORCELAIN=""
[ -f "$d/install.sh" ] && PORCELAIN="$(bash "$d/install.sh" --list --porcelain 2>/dev/null)"
pcl() { awk -F'\t' "$1" <<< "$PORCELAIN"; }
if [ -z "$PORCELAIN" ]; then
    echo "NOTE: install.sh --list --porcelain returned nothing — the config, tool"
    echo "      and CLI lists below are incomplete. That is itself worth reporting."
fi

echo "── stowed symlinks ───────────────────────────────────"
# Same rule install.sh follows: XDG_CONFIG_HOME decides where configs live,
# and unset means ~/.config. Reporting the wrong directory is exactly the kind
# of answer that sends whoever pastes this output debugging the wrong thing.
XDG_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
# ~ only for $HOME itself or a path under it: a bare prefix match turned
# /home/abhik/.config into ~k/.config when HOME=/home/abhi.
case "$XDG_CONFIG" in
    "$HOME")   XDG_SHOWN="~" ;;
    "$HOME"/*) XDG_SHOWN="~/${XDG_CONFIG#"$HOME"/}" ;;
    *)         XDG_SHOWN="$XDG_CONFIG" ;;
esac
# Single-file targets are symlinks; ~/.config/<app> is a real directory by
# design, with stow linking the files inside it — so look one level in.
for t in "$HOME/.zshrc" "$HOME/.gitconfig" "$XDG_CONFIG/starship.toml" \
         "$HOME/scripts/pvpn/pvpn.zsh"; do
    if [ -L "$t" ]; then
        printf "  %-26s -> %-30s %s\n" "${t#"$HOME"/}" "$(readlink "$t")" \
            "$( [ -e "$t" ] && echo '[ok]' || echo '[BROKEN]')"
    elif [ -e "$t" ]; then
        printf "  %-26s %s\n" "${t#"$HOME"/}" "(real file — NOT stowed)"
    else
        printf "  %-26s %s\n" "${t#"$HOME"/}" "(absent)"
    fi
done
# Every entry that stows into a directory under $XDG_CONFIG — configs, dep
# tools and apps alike — is a record whose sixth field names that directory.
# By its directory, not its menu name: the neovim app stows into nvim, and
# asking about ~/.config/neovim would report a working config as absent.
# wallpapers is the one name that is in no array: the installer stows it as a
# side effect of ghostty/kitty, so it is named here and nowhere else. Not "d"
# as the loop variable: that is the checkout dir set above, and reusing it
# destroyed it for everything below.
for cfg in $(pcl '$1!="var" && $6!="-" && $6!="" {print $6}') wallpapers; do
    t="$XDG_CONFIG/$cfg"
    # Absent, not skipped. The single-file loop above says "(absent)" and this
    # one silently printed nothing, so a config that never got stowed looked
    # identical to one that is not in the list at all — and "why is my kitty
    # config not loading" is the exact question this section answers.
    if [ ! -e "$t" ]; then
        printf "  %-26s %s\n" "${XDG_SHOWN#\~/}/$cfg" "(absent)"
        continue
    fi
    n=$(find "$t" -maxdepth 1 -type l 2>/dev/null | wc -l)
    broken=$(find "$t" -maxdepth 1 -xtype l 2>/dev/null | wc -l)
    printf "  %-26s %s\n" "${XDG_SHOWN#\~/}/$cfg" "$n symlink(s) inside$( [ "$broken" -gt 0 ] && echo ", $broken BROKEN")"
done
echo

echo "── drift ─────────────────────────────────────────────"
# Two ways a stowed config stops being ours without anyone asking: a tool
# replaces a link with a plain file (Omarchy's font setter does), or writes
# through a link into the checkout (omarchy-refresh-config does). Read-only.
# "Installed" = at least one file of the package resolves into this checkout;
# the single-file packages are the five stow targets that are not a directory.
_pkgs=()
for cfg in $(pcl '$1!="var" && $6!="-" && $6!="" {print $6}') wallpapers; do
    _pkgs+=("$cfg:$XDG_CONFIG/$cfg")
done
_pkgs+=("bash:$HOME" "zsh:$HOME" "git:$HOME" "starship:$XDG_CONFIG" "proton-vpn:$HOME/scripts/pvpn")
_drift=0 _stowed=()
for _e in "${_pkgs[@]}"; do
    _pkg="${_e%%:*}" _dst="${_e#*:}"
    [ -d "$d/$_pkg" ] || continue
    _bad=() _ok=0
    while IFS= read -r -d '' _f; do
        _rel="${_f#"$d/$_pkg/"}"; _t="$_dst/$_rel"
        if [ -e "$_t" ] && [[ "$(readlink -f "$_t")" == "$d"/* ]]; then _ok=1
        elif [ -L "$_t" ] && [ ! -e "$_t" ]; then _bad+=("$_pkg/$_rel is a broken link, not our link")
        elif [ -L "$_t" ]; then _bad+=("$_pkg/$_rel is a link elsewhere (-> $(readlink "$_t")), not our link")
        elif [ -e "$_t" ]; then _bad+=("$_pkg/$_rel is a plain file, not our link — something replaced it (Omarchy's font setter does this)")
        else _bad+=("$_pkg/$_rel is missing from $_dst"); fi
    done < <(find "$d/$_pkg" -type f -print0 2>/dev/null)
    [ "$_ok" -eq 1 ] || continue
    _stowed+=("$_pkg")
    for _m in "${_bad[@]}"; do echo "  $_m"; _drift=1; done
done
if [ ! -e "$d/.git" ]; then
    echo "  uncommitted-change check unavailable (no .git here — private mode strips it)"
elif [ "${#_stowed[@]}" -gt 0 ]; then
    while IFS= read -r _pkg; do
        echo "  uncommitted changes in $_pkg/ — something wrote through a link (omarchy-refresh-config does this)"
        _drift=1
    done < <(git -C "$d" status --porcelain -- "${_stowed[@]}" 2>/dev/null | cut -c4- | sed 's/^"//' | cut -d/ -f1 | sort -u)
fi
[ "$_drift" -eq 0 ] && echo "  no drift$([ -e "$d/.git" ] || echo " (links only)")"
echo

# Omarchy ships its own copy of several of the files this repo stows, and
# which of the two a given path is changes what a bug report means. Printed only
# where Omarchy is, so every other machine's output is unchanged.
if [ -n "${OMARCHY_PATH:-}" ] || [ -d /usr/share/omarchy ] || command -v omarchy-version &>/dev/null; then
    echo "── omarchy ───────────────────────────────────────────"
    echo "version         : $(omarchy-version 2>/dev/null || echo '-')"
    echo "OMARCHY_PATH    : ${OMARCHY_PATH:-<unset in this shell>}"
    echo "mise            : $(command -v mise || echo '<none>')"
    echo "mise activated  : $( [ -n "${MISE_SHELL:-}" ] && echo "yes ($MISE_SHELL)" || echo 'no (shims only, if at all)' )"
    echo "EDITOR / BROWSER: ${EDITOR:-<unset>} / ${BROWSER:-<unset>}"
    # "ours" = a symlink that resolves into this checkout, directly or one level
    # inside a config directory (the way stow lays them out).
    for t in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.gitconfig" "$XDG_CONFIG/git/config" \
             "$XDG_CONFIG/starship.toml" "$XDG_CONFIG/ghostty" "$XDG_CONFIG/kitty" \
             "$XDG_CONFIG/alacritty" "$XDG_CONFIG/btop" "$XDG_CONFIG/tmux" "$XDG_CONFIG/lazygit"; do
        if [ ! -e "$t" ] && [ ! -L "$t" ]; then who="absent"
        elif [ -L "$t" ] && [[ "$(readlink -f "$t")" == "$d"/* ]]; then who="ours (link into the checkout)"
        elif [ -d "$t" ] && find "$t" -maxdepth 1 -type l -exec readlink -f {} + 2>/dev/null | grep -q "^$d/"; then who="ours (stowed inside)"
        else who="not ours (Omarchy's or yours)"; fi
        printf "  %-26s %s\n" "${t/#$HOME\//}" "$who"
    done
    echo
fi

echo "── tools ─────────────────────────────────────────────"
echo "git version     : $(git --version 2>/dev/null || echo '<not installed>')"
# Name the file, never the value: this output gets pasted into public bug reports.
_gid_missing=0
for k in name email; do
    o=$(git config --global --includes --show-origin --get "user.$k" 2>/dev/null | head -n1 | cut -f1)
    o=${o#file:}
    if [ -n "$o" ]; then o="set (${o/#$HOME\//\~/})"; else o="NOT SET"; _gid_missing=1; fi
    printf "%-16s: %s\n" "git user.$k" "$o"
done
[ "$_gid_missing" -eq 0 ] || echo "  fix: git config --file ~/.gitconfig.local user.email you@example.com   (and user.name; NOT --global, which writes through the ~/.gitconfig link into the repo)"
# install.sh's own CURL_APP_PATH. bun lands in ~/.bun/bin, which is not on the
# PATH of a non-login shell — without this it reports as missing on a machine
# where it is installed and working. The fallback is the two directories that
# matter most, for the case where install.sh could not be read at all.
CURL_APP_PATH="$(pcl '$1=="var" && $2=="CURL_APP_PATH" {print $3}')"
[ -n "$CURL_APP_PATH" ] || CURL_APP_PATH="$HOME/.local/bin:$HOME/.bun/bin"
# Debian/Ubuntu ship these two under other names, and the ~/.local/bin shims
# install.sh adds are best-effort — it reports "installed as batcat; could not
# add the bat shim" and carries on. So "found, wrong name" is a real state and
# a completely different problem from "not installed", which is exactly what
# someone runs this script to tell apart.
# ripgrep is here for a different reason: its binary is rg on every distro, so
# finding rg is normal and reporting it as a missing shim would be a lie in a
# file whose whole job is to be pasted into a bug report. delta needs no entry
# at all — package and binary are both delta.
declare -A ALT_BIN=([bat]=batcat [fd]=fdfind [ripgrep]=rg)
declare -A ALT_SHIM=([bat]=1 [fd]=1)
# The dep tools come from install.sh; the handful before them are this
# script's own choice — what the installer itself needs to work at all, plus
# the two editors and the runtime the statusline renders through. Each name is
# printed once: fzf is on both lists now it is a tool, and so could anything
# else that becomes one.
declare -A _seen=()
for c in stow fzf git zsh starship fastfetch micro fresh bun \
         $(pcl '$1=="tool" {print $2}'); do
    [ -n "${_seen[$c]:-}" ] && continue
    _seen[$c]=1
    p="$(PATH="$CURL_APP_PATH:$PATH" command -v "$c")"
    if [ -z "$p" ] && [ -n "${ALT_BIN[$c]:-}" ]; then
        p="$(PATH="$CURL_APP_PATH:$PATH" command -v "${ALT_BIN[$c]}")"
        if [ -n "$p" ]; then
            if [ -n "${ALT_SHIM[$c]:-}" ]; then
                p="$p  (Debian name — no $c shim)"
            else
                p="$p  (installs as ${ALT_BIN[$c]})"
            fi
        fi
    fi
    printf "  %-12s %s\n" "$c" "${p:--}"
done
echo

echo "── curl-installed CLIs ───────────────────────────────"
# Same problem the tools loop above exists to catch, for a different set of
# binaries: install.sh's interactive curl apps (the APP_UPDATE keys — the ones
# with a "run it like this" line) each land in their own per-app bin dir, not
# a package manager's, so "on PATH right now" and "actually installed" can
# disagree here too. bun is already in the tools loop above (it is a runtime,
# not one of these); tailscale is left to the package manager.
# name and binary both come from install.sh — "interactive" is the flag it
# puts on an app that has an APP_UPDATE entry, which is the same set that
# earns the "run it like this" line. Matched as one member of the comma set,
# not the whole field: an app that also carried a config would print
# "interactive,hasconfig" and silently drop out of this list.
while IFS=$'\t' read -r app bin; do
    [ -n "$app" ] || continue
    p="$(PATH="$CURL_APP_PATH:$PATH" command -v "$bin")"
    printf "  %-16s %s\n" "$app" "${p:--}"
done < <(pcl '$1=="app" && $5 ~ /(^|,)interactive(,|$)/ {print $2 "\t" $3}')
echo

echo "── ccstatusline (Claude Code statusLine) ─────────────"
# The config only stows a settings file; what actually renders the line is
# `bunx ccstatusline` run by Claude Code out of ~/.claude/settings.json. So the
# two things worth knowing are what that key says and whether bun can be found.
cc_statusline_cmd() {
    # No hand-parsing of that JSON, for the same reason install.sh refuses to:
    # if it does not parse, the installer leaves it alone and so does this.
    python3 -I -c 'import json,sys
v = json.load(open(sys.argv[1])).get("statusLine")
print((v.get("command", "<statusLine with no command>") if isinstance(v, dict) else v) if v else "<no statusLine key>")' \
        "$1" 2>/dev/null || echo "<unparseable JSON, or no python3 — install.sh will not touch it either>"
}
_cc="$HOME/.claude/settings.json"
if [ -f "$_cc" ]; then
    echo "settings.json   : $_cc"
    echo "statusLine      : $(cc_statusline_cmd "$_cc")"
    echo "pristine copy   : $( [ -f "$_cc.orig" ] && echo "$_cc.orig" || echo 'not taken yet')"
else
    echo "settings.json   : absent ($_cc)"
fi
# Lowest scope wins here: a managed statusLine outranks the user one above, so
# a correctly wired settings.json can still render something else entirely.
_cc_managed="${CC_MANAGED_SETTINGS:-/etc/claude-code/managed-settings.json}"
[ -f "$_cc_managed" ] && echo "managed override: $(cc_statusline_cmd "$_cc_managed")  ($_cc_managed)"
echo "bun             : $(PATH="$CURL_APP_PATH:$PATH" command -v bun || echo '- — the statusline cannot render without it')"
echo

echo "── fonts ─────────────────────────────────────────────"
echo "fc-cache        : $(command -v fc-cache || echo '<not installed>')"
if command -v fc-list >/dev/null 2>&1; then
    _fc="$(fc-list 2>/dev/null)"
    echo "JetBrainsMono   : $(grep -ci jetbrainsmono <<< "$_fc") faces"
    echo "Maple Mono      : $(grep -ci 'maple' <<< "$_fc") faces"
else
    echo "  fontconfig not installed (expected on a headless server)"
fi
echo

echo "── GRUB theme ────────────────────────────────────────"
# grub-theme.sh's own read-only report: which loader booted, what GRUB_THEME
# and the terminal are, whether the copy in /boot matches, and any
# grub-customizer leftovers that would change the menu at the next rebuild.
# It never asks for a password: what only root may read is said to be so.
if [ -f "$d/grub/grub-theme.sh" ]; then
    bash "$d/grub/grub-theme.sh" status 2>&1
else
    echo "  grub/grub-theme.sh not in this checkout"
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
