#!/usr/bin/env bash
# grub-theme.sh: puts the vortex GRUB theme in place, and takes it out again.
#
#   grub-theme.sh status       what is on this machine now (read-only; doctor.sh prints it)
#   grub-theme.sh plan         what install would change (read-only)
#   grub-theme.sh install      [--accept-menu-changes]
#   grub-theme.sh uninstall    [--accept-menu-changes]
#   grub-theme.sh verify       check that the theme in this repo is one GRUB can load
#
# install.sh drives it with --porcelain, which prints one "<kind>\t<head>\t<rest>"
# row per line, and with the one-word queries at the bottom (present, state,
# target, current, owned, uninstall-row). Run by hand, it asks sudo for what
# needs root, and works as root too.
#
# What it changes, and nothing else:
#   · copies the theme into GRUB's own directory (/boot/grub/themes/vortex, or
#     /boot/grub2/… on Fedora). Copied, not stowed: GRUB reads it from /boot
#     before anything else is mounted, and a vfat /boot holds no symlinks.
#   · GRUB_THEME, edited in place in /etc/default/grub, so the file still says
#     what is in effect.
#   · only where a theme could not be seen without it: a console-only
#     GRUB_TERMINAL_OUTPUT becomes gfxterm (on a machine with a display, never
#     a serial console), a hidden menu becomes visible (GRUB_TIMEOUT_STYLE=menu,
#     GRUB_TIMEOUT 0 → 5, Fedora's menu_auto_hide unset). A visible timeout is
#     never touched.
#   · a drop-in, /etc/default/grub.d/99-vortex-theme.cfg, only where another
#     drop-in would otherwise win over /etc/default/grub (grub-mkconfig reads
#     them after it where the distro patches that in: Debian, Ubuntu and Arch
#     do, Fedora does not; it is read off grub-mkconfig itself).
#   · grub-customizer leftovers: when an upgrade has put back a stock grub.d
#     script that one of its proxies replaced, the stock one is chmod -x'd.
#     Otherwise every rebuild would list those entries twice.
# Every change is recorded in /etc/default/grub.theme-undo, and uninstall puts
# each back where it was.
#
# grub.cfg is never rebuilt blind: the new one is built into a temp file and
# its menu compared with the current one. If an entry would disappear (Windows,
# when os-prober has been switched off since), show twice, or come out
# different (grub.cfg edited by hand after it was built), or a password written
# into grub.cfg would go, nothing is changed and everything already done is
# rolled back. --accept-menu-changes (or GRUB_THEME_ACCEPT_MENU_CHANGES=1)
# applies it anyway. The one hand edit carried over is extra --class options
# on an entry, which only choose its icon. The old grub.cfg is kept as
# grub.cfg.bak either way.
#
# Paths the suite points at a sandbox: DOTFILES_GRUB_ETC (/etc/default/grub),
# DOTFILES_GRUB_BOOT (/boot/grub), DOTFILES_GRUB_D (/etc/grub.d),
# DOTFILES_GRUB_EFIVARS (/sys/firmware/efi/efivars). install.sh passes
# GRUB_THEME_DISTRO and GRUB_THEME_HEADLESS; run by hand, they are detected.
#
# No `set -e`, like install.sh: every failure that matters is checked.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THEME_NAME="vortex"
THEME_SRC="$HERE/themes/$THEME_NAME"
# The names this theme shipped under before, and the tree_sum of every tree it
# shipped as. A directory under one of those names holding exactly one of those
# trees, or today's, is a stale copy of ours and goes once vortex is in.
# Anything else under those names is somebody's and stays.
OLD_NAMES=(grub-of-tsushima votex)
OLD_SUMS=(c13628bb246c1da62543aaefd742c9af581305bbbeb019676fe34157cc1b833e)
# Inside our copy in /boot: the tree_sum it was installed as. A copy whose
# files no longer add up to it was changed by hand, and is backed up, not
# overwritten.
MARKER=".installed"
VISIBLE_TIMEOUT=5

ETC="${DOTFILES_GRUB_ETC:-/etc/default/grub}"
ETC_D="$ETC.d"
GRUBD="${DOTFILES_GRUB_D:-/etc/grub.d}"
EFIVARS="${DOTFILES_GRUB_EFIVARS:-/sys/firmware/efi/efivars}"
UNDO="$ETC.theme-undo"
DROPIN="$ETC_D/99-$THEME_NAME-theme.cfg"
DROPIN_MARK="# Written by grub-theme.sh"
LOADER_INFO="LoaderInfo-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"

# grub.d/*.cfg are read in glob order; make ours sort the way grub-mkconfig's does.
export LC_COLLATE=C

PORCELAIN=0
ACCEPT=0
case "${GRUB_THEME_ACCEPT_MENU_CHANGES:-}" in 1|true|yes) ACCEPT=1 ;; esac
IS_ROOT=0; [ "$(id -u)" -eq 0 ] && IS_ROOT=1

# ── Output ───────────────────────────────────────────────────────────────────
# kinds: add (an action), change (replacing or switching something), remove,
# warn, error, ok (already right), info.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    _c_do=$'\e[32m' _c_ch=$'\e[33m' _c_er=$'\e[31m' _c_dim=$'\e[2m' _c_0=$'\e[0m'
else
    _c_do="" _c_ch="" _c_er="" _c_dim="" _c_0=""
fi
row() {                         # row <kind> <head> [rest]
    if [ "$PORCELAIN" -eq 1 ]; then
        printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}"
        return 0
    fi
    local c="$_c_dim" m="."
    case "$1" in
        add)    c="$_c_do"; m="+" ;;
        change) c="$_c_ch"; m="~" ;;
        remove) c="$_c_ch"; m="-" ;;
        warn)   c="$_c_ch"; m="!" ;;
        error)  c="$_c_er"; m="x" ;;
        ok)     m="=" ;;
    esac
    printf '  %s%s %s%s%s\n' "$c" "$m" "$2" "$_c_0" "${3:+ $_c_dim$3$_c_0}"
}
die() { row error "$1" "${2:-}"; exit 1; }

# ── Where things are ─────────────────────────────────────────────────────────
detect_distro() {
    if [ -n "${GRUB_THEME_DISTRO:-}" ]; then printf '%s' "$GRUB_THEME_DISTRO"; return; fi
    local id="" like=""
    if [ -r /etc/os-release ]; then
        id="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"'"'")"
        like="$(sed -n 's/^ID_LIKE=//p' /etc/os-release | tr -d '"'"'")"
    fi
    case " $id $like " in
        *" nixos "*)                 printf nix ;;
        *" arch "*|*" omarchy "*)    printf arch ;;
        *" fedora "*|*" rhel "*)     printf fedora ;;
        *" debian "*|*" ubuntu "*)   printf debian ;;
        *)                           printf other ;;
    esac
}
DISTRO="$(detect_distro)"

detect_headless() {
    case "${GRUB_THEME_HEADLESS:-}" in 0|1) printf '%s' "$GRUB_THEME_HEADLESS"; return ;; esac
    if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then printf 0; return; fi
    local d
    for d in /usr/share/xsessions /usr/share/wayland-sessions; do
        [ -d "$d" ] && find "$d" -name '*.desktop' -print -quit 2>/dev/null | grep -q . \
            && { printf 0; return; }
    done
    printf 1
}
HEADLESS="$(detect_headless)"

# PATH first, then the sbin directories: Debian keeps grub-mkconfig in
# /usr/sbin, which a normal user's PATH there leaves out.
find_tool() {                   # find_tool <name>...
    local b d
    for b in "$@"; do command -v "$b" 2>/dev/null && return 0; done
    for b in "$@"; do
        for d in /usr/sbin /sbin; do
            [ -x "$d/$b" ] && { printf '%s\n' "$d/$b"; return 0; }
        done
    done
    return 1
}
MKCONFIG="$(find_tool grub-mkconfig grub2-mkconfig)"
EDITENV="$(find_tool grub-editenv grub2-editenv)"

# Whether this grub-mkconfig reads /etc/default/grub.d/*.cfg after the main
# file. It is a shell script; the line that does it names the directory.
READS_DROPINS=0
[ -n "$MKCONFIG" ] && grep -q 'default/grub\.d' "$MKCONFIG" 2>/dev/null && READS_DROPINS=1

# /boot/grub on Arch, Debian and Ubuntu; /boot/grub2 on Fedora; /efi/grub or
# /boot/efi/grub where grub-install was given --boot-directory. A separate
# /boot that is in fstab but not mounted is GRUB's all the same, and is said so.
BOOT=""
BOOT_UNMOUNTED=0
find_boot() {
    if [ -n "${DOTFILES_GRUB_BOOT:-}" ]; then BOOT="$DOTFILES_GRUB_BOOT"; return 0; fi
    local d
    for d in /boot/grub /boot/grub2; do
        [ -d "$d" ] && { BOOT="$d"; return 0; }
    done
    for d in /efi/grub /boot/efi/grub; do
        [ -f "$d/grub.cfg" ] && { BOOT="$d"; return 0; }
    done
    if [ -r /etc/fstab ] && awk '$1 !~ /^#/ && $2 == "/boot" { f = 1 } END { exit !f }' /etc/fstab \
       && ! mountpoint -q /boot 2>/dev/null; then
        BOOT_UNMOUNTED=1
        case "$MKCONFIG" in *grub2-mkconfig) BOOT=/boot/grub2 ;; *) BOOT=/boot/grub ;; esac
        return 0
    fi
    return 1
}
find_boot

DEST="$BOOT/themes/$THEME_NAME"
THEME_FILE="$DEST/theme.txt"
CFG="$BOOT/grub.cfg"

# Installed and set up: grub-mkconfig, its settings file, and a boot directory
# that has had a grub.cfg written into it. Fedora's /boot/grub2 is 0700, so
# where it cannot be looked into, the directory has to do.
present() {
    [ "$DISTRO" = nix ] && return 1
    [ -n "$MKCONFIG" ] || return 1
    { [ -f "$ETC" ] || [ -L "$ETC" ]; } || return 1
    [ -n "$BOOT" ] || return 1
    [ "$BOOT_UNMOUNTED" -eq 1 ] && return 0
    [ ! -x "$BOOT" ] || [ -f "$CFG" ]
}

# ── Privileges ───────────────────────────────────────────────────────────────
# rootly <dir> <cmd…>: root's hands where <dir> needs them. Directly as root,
# or where the directory is ours anyway (the suite's sandbox); else sudo.
rootly() {
    local d="$1"; shift
    if [ "$IS_ROOT" -eq 1 ] || [ -w "$d" ]; then "$@"; else sudo "$@"; fi
}
# peek <path> <cmd…>: a read-only look, through sudo -n only where <path> is
# shut to us (Fedora's 0700 /boot/grub2). Never asks for a password: plan and
# status call it, and with no cached credential (a --dry-run) it is just a no.
peek() {
    local p="$1"; shift
    if [ "$IS_ROOT" -eq 1 ] || { [ -r "$p" ] && { [ ! -d "$p" ] || [ -x "$p" ]; }; }; then
        "$@"
    else
        sudo -n "$@" 2>/dev/null
    fi
}
# Whether anything below will need sudo, so it can ask once, up front, rather
# than in the middle of a rebuild.
needs_sudo() {
    [ "$IS_ROOT" -eq 1 ] && return 1
    [ -w "$BOOT" ] && [ -w "$(dirname "$ETC")" ] && return 1
    return 0
}
sudo_ready() {
    needs_sudo || return 0
    sudo -n true 2>/dev/null && return 0
    sudo -v
}

# Replaces <dest>'s contents atomically, keeping its owner, mode and SELinux
# label: a copy of the attributes is filled in and renamed over it, so a full
# disk leaves the old file whole. (A cp -a of a mktemp file over
# /etc/default/grub once made it the user's, mode 0600 — and grub-mkconfig
# sources that file as root.)
put_file() {                    # put_file <src> <dest>
    local src="$1" dest="$2" dir new
    dir="$(dirname "$dest")"
    new="$dir/.$(basename "$dest").new"
    rootly "$dir" rm -f "$new"
    if [ -e "$dest" ]; then
        rootly "$dir" cp -a --attributes-only "$dest" "$new" 2>/dev/null \
            || rootly "$dir" cp "$dest" "$new" || return 1
    fi
    # shellcheck disable=SC2016
    if rootly "$dir" sh -c 'umask 022; cat "$1" > "$2"' _ "$src" "$new" \
       && rootly "$dir" mv -f "$new" "$dest"; then
        return 0
    fi
    rootly "$dir" rm -f "$new"
    return 1
}

# ── Settings ─────────────────────────────────────────────────────────────────
# Parsed, never sourced: these files are root's shell scripts. The last
# assignment wins, as it does when grub-mkconfig sources them.
_val=""
value_of() {                    # value_of <line>: sets _val, quotes off
    local v="${1#*=}"
    v="${v%$'\r'}"
    case "$v" in
        \"*) v="${v#\"}"; v="${v%%\"*}" ;;
        \'*) v="${v#\'}"; v="${v%%\'*}" ;;
        *)   v="${v%%[[:space:];#]*}" ;;
    esac
    _val="$v"
}
is_assign() {                   # is_assign <line> <KEY>
    [[ "$1" =~ ^[[:space:]]*(export[[:space:]]+)?$2= ]]
}

# The files grub-mkconfig takes settings from, in order — ours left out, so
# what the user's own setup says can be told apart from what we added.
user_files() {
    printf '%s\n' "$ETC"
    [ "$READS_DROPINS" -eq 1 ] || return 0
    local f
    for f in "$ETC_D"/*.cfg; do
        [ -f "$f" ] && [ "$f" != "$DROPIN" ] && printf '%s\n' "$f"
    done
    return 0
}
all_files() {
    user_files
    [ "$READS_DROPINS" -eq 1 ] && [ -f "$DROPIN" ] && printf '%s\n' "$DROPIN"
    return 0
}

# eff <KEY> [files…]: sets EF_FILE and EF_VAL from the winning assignment;
# 1 when nothing assigns it. Without files, the user's view (user_files).
EF_FILE="" EF_VAL=""
eff() {
    local key="$1" f line
    shift
    local -a files=("$@")
    [ "${#files[@]}" -gt 0 ] || mapfile -t files < <(user_files)
    EF_FILE="" EF_VAL=""
    for f in "${files[@]}"; do
        [ -r "$f" ] || continue
        while IFS= read -r line || [ -n "$line" ]; do
            if is_assign "$line" "$key"; then
                value_of "$line"
                EF_FILE="$f" EF_VAL="$_val"
            fi
        done < "$f"
    done
    [ -n "$EF_FILE" ]
}
eff_all() {                     # eff_all <KEY>: what grub-mkconfig will see, ours included
    local -a files
    mapfile -t files < <(all_files)
    eff "$1" "${files[@]}"
}

# Drop-ins that sort after ours and set <KEY>: those win even over our drop-in.
after_ours() {                  # after_ours <KEY>
    [ "$READS_DROPINS" -eq 1 ] || return 1
    local f line found=""
    for f in "$ETC_D"/*.cfg; do
        [ -f "$f" ] || continue
        [[ "$f" > "$DROPIN" ]] || continue
        while IFS= read -r line || [ -n "$line" ]; do
            is_assign "$line" "$1" && found="$f"
        done < "$f"
    done
    [ -n "$found" ] && printf '%s' "$found"
}

# What keeps any theme from loading: grub-mkconfig writes one only when
# gfxterm is an output terminal, and GRUB_TERMINAL, when set, is input and
# output both. Sets TB_VAR, TB_FILE, TB_VAL.
TB_VAR="" TB_FILE="" TB_VAL=""
terminal_blocked() {
    local v
    TB_VAR="" TB_FILE="" TB_VAL=""
    for v in GRUB_TERMINAL GRUB_TERMINAL_OUTPUT; do
        eff "$v" || continue
        [ -n "$EF_VAL" ] || continue
        case " $EF_VAL " in *" gfxterm "*) return 1 ;; esac
        TB_VAR="$v" TB_FILE="$EF_FILE" TB_VAL="$EF_VAL"
        return 0
    done
    return 1
}
# The one blocker cleared here: GRUB_TERMINAL_OUTPUT, on a machine with a
# display, with no serial console in it. GRUB_TERMINAL is a deliberate
# "text only" (Debian's own comment says so), and a serial console is a server.
terminal_fixable() {
    [ "$TB_VAR" = GRUB_TERMINAL_OUTPUT ] && [ "$HEADLESS" -eq 0 ] \
        && [[ " $TB_VAL " != *" serial "* ]]
}

# How the menu is kept off the screen. 00_header: GRUB_TIMEOUT_STYLE wins;
# without it a GRUB_HIDDEN_TIMEOUT (deprecated) hides it; a menu shown for 0
# seconds is not shown. Fedora's menu_auto_hide lives in grubenv.
FIX_STYLE=0 FIX_TIMEOUT=0 FIX_AUTOHIDE=0 STYLE_WAS="" TIMEOUT_WAS=""
menu_visibility() {
    local style="" hidden=""
    FIX_STYLE=0 FIX_TIMEOUT=0 FIX_AUTOHIDE=0 STYLE_WAS="" TIMEOUT_WAS=""
    eff GRUB_TIMEOUT_STYLE && style="$EF_VAL"
    eff GRUB_HIDDEN_TIMEOUT && hidden="$EF_VAL"
    if [ -n "$style" ]; then
        case "$style" in hidden|countdown) FIX_STYLE=1; STYLE_WAS="$style" ;; esac
    elif [ -n "$hidden" ]; then
        FIX_STYLE=1; STYLE_WAS="GRUB_HIDDEN_TIMEOUT=$hidden"
    fi
    if eff GRUB_TIMEOUT && [ "$EF_VAL" = 0 ]; then
        FIX_TIMEOUT=1; TIMEOUT_WAS=0
    fi
    if [ -n "$EDITENV" ] && peek "$BOOT" grep -qx 'menu_auto_hide=1' "$BOOT/grubenv" 2>/dev/null; then
        FIX_AUTOHIDE=1
    fi
}

# ── The theme's files ────────────────────────────────────────────────────────
# One hash over every file's path and contents (our marker left out), so a
# copy in /boot can be recognised without the repo's history.
# shellcheck disable=SC2016
TREE_LIST='cd "$1" && find . -type f ! -path ./.installed -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum'
tree_sum() {                    # tree_sum <dir> [here]
    local list
    if [ "${2:-}" = here ]; then
        list="$(sh -c "$TREE_LIST" _ "$1" 2>/dev/null)" || return 1
    else
        list="$(peek "$BOOT" sh -c "$TREE_LIST" _ "$1")" || return 1
    fi
    [ -n "$list" ] || return 1
    printf '%s\n' "$list" | sha256sum | cut -d' ' -f1
}
# The repo copy's sum, worked out the first time something asks: `present`,
# which install.sh asks on every run, has no use for it.
SRC_SUM=""
src_sum() { [ -n "$SRC_SUM" ] || SRC_SUM="$(tree_sum "$THEME_SRC" here)"; }

# absent | current | ours (an older copy we installed, untouched since) |
# modified (ours, changed by hand) | foreign (somebody's theme by that name) |
# unknown (cannot be read without sudo)
THEME_STATE=""
theme_state() {
    if [ "$BOOT_UNMOUNTED" -eq 1 ]; then THEME_STATE=absent; return; fi
    if ! peek "$BOOT" test -e "$DEST"; then
        if [ "$IS_ROOT" -eq 0 ] && ! { [ -r "$BOOT" ] && [ -x "$BOOT" ]; } && ! sudo -n true 2>/dev/null; then
            THEME_STATE=unknown
        else
            THEME_STATE=absent
        fi
        return
    fi
    if peek "$BOOT" diff -rq -x "$MARKER" "$THEME_SRC" "$DEST" >/dev/null 2>&1; then
        THEME_STATE=current; return
    fi
    local mark sum
    mark="$(peek "$BOOT" cat "$DEST/$MARKER" 2>/dev/null)"
    if [ -n "$mark" ]; then
        sum="$(tree_sum "$DEST")"
        if [ "$sum" = "$mark" ]; then THEME_STATE=ours; else THEME_STATE=modified; fi
    else
        THEME_STATE=foreign
    fi
}

# Copies of this theme under its earlier names, one path per line.
stale_dirs() {
    [ "$BOOT_UNMOUNTED" -eq 1 ] && return 0
    src_sum
    local n d s k
    for n in "${OLD_NAMES[@]}"; do
        d="$BOOT/themes/$n"
        peek "$BOOT" test -d "$d" || continue
        s="$(tree_sum "$d")" || continue
        for k in "${OLD_SUMS[@]}" "$SRC_SUM"; do
            [ -n "$k" ] && [ "$s" = "$k" ] && { printf '%s\n' "$d"; break; }
        done
    done
}

# True when a GRUB_THEME value names one of the stale directories given.
names_stale() {                 # names_stale <value> [<dir>…]
    local v="$1" d; shift
    for d in "$@"; do [ "$v" = "$d/theme.txt" ] && return 0; done
    return 1
}

# ── grub.cfg ─────────────────────────────────────────────────────────────────
cfg_generated() {               # cfg_generated <file>: written by grub-mkconfig
    peek "$1" head -n 8 "$1" 2>/dev/null | grep -q 'DO NOT EDIT THIS FILE'
}
# entry(line): 1 when the line opens a menuentry or submenu, setting EK (the
# kind), ET (the title) and EO (the rest of the line: options and the brace).
# shellcheck disable=SC2016
ENTRY_FN='
function entry(line,   s, q, i) {
    if (line !~ /^[[:space:]]*(menuentry|submenu)[[:space:]]/) return 0
    s = line
    EK = (s ~ /^[[:space:]]*submenu/) ? "submenu" : "menuentry"
    sub(/^[[:space:]]*(menuentry|submenu)[[:space:]]+/, "", s)
    q = substr(s, 1, 1)
    if (q == "\"" || q == "'"'"'") {
        s = substr(s, 2); i = index(s, q)
        if (i == 0) return 0
        ET = substr(s, 1, i - 1); EO = substr(s, i + 1)
    } else {
        i = match(s, /[[:space:]{]/)
        if (i == 0) { ET = s; EO = "" } else { ET = substr(s, 1, i - 1); EO = substr(s, i) }
    }
    return 1
}'
# Every entry and submenu title, one per line, "<kind>\t<title>".
# shellcheck disable=SC2016
TITLES_AWK="$ENTRY_FN"'
entry($0) { print EK "\t" ET }'
cfg_titles() { peek "$1" awk "$TITLES_AWK" "$1" 2>/dev/null; }
# Every entry as a rebuild has to reproduce it, "<kind>\t<title>\t<options>\t<commands>":
# the options on its first line, and a menuentry's own commands joined by \037,
# spacing evened out and comments left aside. A submenu's entries are their own rows.
# shellcheck disable=SC2016
ENTRIES_AWK="$ENTRY_FN"'
function norm(s) { gsub(/[[:space:]]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s); return s }
entry($0) { o = EO; sub(/[{][[:space:]]*$/, "", o); n++; K[n] = EK; T[n] = ET; O[n] = norm(o); B[n] = ""; next }
/^[[:space:]]*}[[:space:]]*$/ { if (n) { print K[n] "\t" T[n] "\t" O[n] "\t" B[n]; n-- } next }
n && K[n] == "menuentry" && !/^[[:space:]]*(#|$)/ { B[n] = B[n] (B[n] == "" ? "" : "\037") norm($0) }'
cfg_entries() { peek "$1" awk "$ENTRIES_AWK" "$1" 2>/dev/null; }
# entry_diff <old-entries> <new-entries>, over the entries both have once:
# "class\t<title>\t<kind>" when only the --class options on the first line
# differ (the icons), "changed\t<title>\t<what>" for anything else.
entry_diff() {
    awk -F'\t' '
        function declass(s) { s = " " s; gsub(/ --class[ =][^ ]+/, "", s); sub(/^ /, "", s); return s }
        NR == FNR { k = $1 FS $2; oc[k]++; oo[k] = $3; ob[k] = $4; next }
        { k = $1 FS $2; nc[k]++; no[k] = $3; nb[k] = $4 }
        END {
            for (k in nc) {
                if (nc[k] != 1 || oc[k] != 1) continue
                split(k, p, FS)
                if (ob[k] != nb[k])                    print "changed\t" p[2] "\tits commands"
                else if (oo[k] == no[k])               continue
                else if (declass(oo[k]) == declass(no[k])) print "class\t" p[2] "\t" p[1]
                else                                   print "changed\t" p[2] "\tits first line"
            }
        }' "$1" "$2" | LC_ALL=C sort
}
# carry_lines <keys-file> <old-cfg> <new-cfg>: the new grub.cfg, with the first
# line of each entry named in keys-file ("<kind>\t<title>") taken from the old.
carry_lines() {
    peek "$2" cat "$2" | awk -v keys="$1" "$ENTRY_FN"'
        BEGIN { while ((getline l < keys) > 0) want[l] = 1 }
        NR == FNR { if (entry($0) && ((EK "\t" ET) in want)) old[EK "\t" ET] = $0; next }
        entry($0) && ((EK "\t" ET) in old) { print old[EK "\t" ET]; next }
        { print }' - <(peek "$3" cat "$3")
}
# Password lines: without them after a rebuild the menu is open to anyone.
cfg_locks() {
    peek "$1" grep -E '^[[:space:]]*(set[[:space:]]+superusers=|password(_pbkdf2)?[[:space:]])' "$1" 2>/dev/null \
        | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' | LC_ALL=C sort -u
}
# The grub.d scripts that ran when it was built.
cfg_scripts() { peek "$1" sed -n 's|^### BEGIN \(.*\) ###$|\1|p' "$1" 2>/dev/null; }

# menu_diff <old-titles-file> <new-titles-file>: "removed|duplicated|added\t<title>"
menu_diff() {
    awk -F'\t' '
        NR == FNR { old[$0]++; next }
        { new[$0]++ }
        END {
            for (t in old) if (new[t] < old[t]) { split(t, p, "\t"); print "removed\t" p[2] }
            for (t in new) {
                split(t, p, "\t")
                if (new[t] > 1 && new[t] > old[t]) print "duplicated\t" p[2]
                else if (!(t in old)) print "added\t" p[2]
            }
        }' "$1" "$2" | LC_ALL=C sort -u
}

# grub-customizer's *_proxy scripts pipe a stock script through
# bin/grubcfg_proxy, a wrapper that hands it to grub-customizer's own filter
# (the renames, the hidden and moved entries) and, when that is gone because
# grub-customizer was uninstalled, passes everything through untouched. Every
# rebuild then shows each proxied entry once per proxy, under its stock name.
# Prints the filter's path when it is missing and a proxy would still run.
proxy_unfiltered() {
    local w="$GRUBD/bin/grubcfg_proxy" p f
    [ -f "$w" ] || return 1
    p="$(grep -oE "/[^[:space:]\"']*/grubcfg-proxy" "$w" | head -n 1)"
    if [ -z "$p" ] || [ -e "$p" ]; then return 1; fi
    for f in "$GRUBD"/*_proxy; do
        if [ -f "$f" ] && [ -x "$f" ]; then printf '%s' "$p"; return 0; fi
    done
    return 1
}

# ── grub-customizer leftovers ────────────────────────────────────────────────
# grub-customizer moves a stock script (10_linux) into proxifiedScripts/ and
# puts a proxy (10_linux_proxy) in its place, or renames one to reorder it
# (20_linux_xen → 33_linux_xen). A grub upgrade puts the stock file back,
# executable, and from then on every rebuild runs both. A script is such a
# duplicate when it did not run at the last build, its role (the name without
# NN_ and _proxy) is one that did, and it is a plain file (a symlink's target
# may be shared with the copy that did run). Prints "<script>\t<the one that ran>".
dupes() {
    [ -d "$GRUBD/proxifiedScripts" ] || return 0
    if [ "$BOOT_UNMOUNTED" -ne 0 ] || ! cfg_generated "$CFG"; then return 0; fi
    local -a ran
    local f r role rrole match
    mapfile -t ran < <(cfg_scripts "$CFG")
    [ "${#ran[@]}" -gt 0 ] || return 0
    for f in "$GRUBD"/[0-9]*; do
        if [ ! -f "$f" ] || [ -L "$f" ] || [ ! -x "$f" ]; then continue; fi
        match=""
        for r in "${ran[@]}"; do
            [ "$r" = "$f" ] && { match=ran; break; }
        done
        [ "$match" = ran ] && continue
        role="${f##*/}"; role="${role#[0-9][0-9]_}"; role="${role%_proxy}"
        for r in "${ran[@]}"; do
            case "$r" in "$GRUBD"/[0-9]*) ;; *) continue ;; esac
            rrole="${r##*/}"; rrole="${rrole#[0-9][0-9]_}"; rrole="${rrole%_proxy}"
            [ "$rrole" = "$role" ] && { printf '%s\t%s\n' "$f" "${r##*/}"; break; }
        done
    done
}

# ── Other things worth saying ────────────────────────────────────────────────
# The loader this boot went through. GRUB 2.12+ reports itself through the
# same EFI variable systemd-boot does, so anything else in it means the menu
# this theme draws is not the one on screen.
loader_info() {
    local f="$EFIVARS/$LOADER_INFO"
    [ -r "$f" ] || return 1
    tail -c +5 "$f" 2>/dev/null | tr -d '\0'
}

# major.minor of a GRUB version string: "2:2.16-1" and "GRUB 2.14" alike.
grub_series() { printf '%s' "$1" | sed -nE 's/^[^0-9]*([0-9]+:)?([0-9]+\.[0-9]+).*/\2/p'; }
MKCONFIG_SERIES=""
mkconfig_series() {
    [ -n "$MKCONFIG_SERIES" ] || [ -z "$MKCONFIG" ] \
        || MKCONFIG_SERIES="$(grub_series "$("$MKCONFIG" --version 2>/dev/null | awk '{ print $NF }')")"
}

# A boot loader older than the grub-mkconfig writing its grub.cfg: the
# package was upgraded and grub-install not run again (Arch does not run it
# for you). The loader keeps its old modules, and the new grub.cfg can ask for
# what they do not have. Prints "<loader series>	<mkconfig series>".
loader_mismatch() {
    local li ls
    li="$(loader_info)" || return 1
    [[ "$li" == GRUB* ]] || return 1
    ls="$(grub_series "$li")"
    mkconfig_series
    [ -n "$ls" ] && [ -n "$MKCONFIG_SERIES" ] && [ "$ls" != "$MKCONFIG_SERIES" ] || return 1
    printf '%s\t%s' "$ls" "$MKCONFIG_SERIES"
}

# The grub-install line that puts the loader back in step, when it can be
# worked out for certain. Arch only: Debian, Ubuntu and Fedora reinstall the
# loader from the package itself. The EFI partition is the one GRUB says it
# booted from (LoaderDevicePartUUID, or DOTFILES_GRUB_ESP), holding exactly
# one EFI/<id>/grub*.efi; --no-nvram replaces those files in place and leaves
# the firmware's boot entries and their order alone. Prints "secureboot"
# instead when Secure Boot is on: a signed chain (shim, sbctl) is reinstalled
# the way it was set up, never with a plain grub-install.
grub_install_cmd() {
    [ "$DISTRO" = arch ] || return 1
    local esp="${DOTFILES_GRUB_ESP:-}" part f target bd=""
    local -a loaders=()
    if [ "$(od -An -tu1 -j4 -N1 "$EFIVARS/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c" 2>/dev/null | tr -d ' ')" = 1 ]; then
        printf 'secureboot'; return 0
    fi
    if [ -z "$esp" ]; then
        part="$(tail -c +5 "$EFIVARS/LoaderDevicePartUUID-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f" 2>/dev/null | tr -d '\0' | tr '[:upper:]' '[:lower:]')"
        [ -n "$part" ] || return 1
        esp="$(findmnt -rno TARGET -S "PARTUUID=$part" 2>/dev/null | head -n 1)"
    fi
    [ -n "$esp" ] && [ -d "$esp" ] || return 1
    mapfile -t loaders < <(find "$esp" -mindepth 3 -maxdepth 3 -type f -ipath "$esp/efi/*/grub*.efi" 2>/dev/null)
    [ "${#loaders[@]}" -eq 1 ] || return 1
    f="${loaders[0]}"
    case "$(printf '%s' "${f##*/}" | tr '[:upper:]' '[:lower:]')" in
        grubx64.efi)  target=x86_64-efi ;;
        grubia32.efi) target=i386-efi ;;
        grubaa64.efi) target=arm64-efi ;;
        *) return 1 ;;
    esac
    [ "$BOOT" = /boot/grub ] || bd=" --boot-directory=$(printf '%q' "${BOOT%/*}")"
    f="${f%/*}"
    printf 'sudo grub-install --target=%s --efi-directory=%q --bootloader-id=%q%s --no-nvram' \
        "$target" "$esp" "${f##*/}" "$bd"
}

# Entries an os-prober section put in the current grub.cfg, when os-prober
# will not run at the next rebuild: the menu diff would stop the install, and
# the plan says so first.
osprober_loss() {
    [ "$BOOT_UNMOUNTED" -eq 0 ] || return 1
    # Only what is certain: whether an unset GRUB_DISABLE_OS_PROBER means off
    # differs between distro patches, and the menu diff catches it anyway.
    local off=0 why=""
    eff GRUB_DISABLE_OS_PROBER && [ "$EF_VAL" = true ] && { off=1; why="GRUB_DISABLE_OS_PROBER=true"; }
    [ "$off" -eq 0 ] && ! find_tool os-prober >/dev/null && { off=1; why="os-prober is not installed"; }
    [ "$off" -eq 1 ] || return 1
    local titles
    titles="$(peek "$CFG" awk '/^### BEGIN .*os-prober/ { on = 1 } /^### END/ { on = 0 } on' "$CFG" 2>/dev/null \
        | awk "$TITLES_AWK" | cut -f2 | paste -sd, - | sed 's/,/, /g')"
    [ -n "$titles" ] || return 1
    printf '%s\t%s' "$titles" "$why"
}

# ── Analysis: everything plan and install need, read-only ────────────────────
FATAL=() NOTES=() STALE=() DUPES=()
MAIN_NEW="" MAIN_REC="" DROPIN_NEW="" MAIN_CHANGED=0 DROPIN_CHANGED=0 DROPIN_REMOVE=0
THEME_IN_EFFECT=0 BLOCKED=0 TERM_FIX=0 REBUILD=0 PREV_THEME=""
SET_KEYS=() SET_VALS=()
TMPS=()
# Sets _tmp. Not printed: TMPS must grow in this shell, not in a $(…) copy.
_tmp=""
new_tmp() { _tmp="$(mktemp)"; TMPS+=("$_tmp"); }
cleanup_tmps() { [ "${#TMPS[@]}" -gt 0 ] && rm -rf "${TMPS[@]}" 2>/dev/null; TMPS=(); }
trap cleanup_tmps EXIT

# format_line <old-line-or-empty> <KEY> <VALUE>: the line we write, in the
# replaced line's indentation, export and quoting. Never with a CR, even in a
# CRLF file: sh would keep it in the value, and GRUB would look for a theme
# called "theme.txt\r". The line it replaces comes back with its CR on uninstall.
format_line() {
    local old="${1%$'\r'}" key="$2" val="$3" pre="" q='"'
    if [ -n "$old" ]; then
        pre="${old%%"$key"=*}"
        case "${old#*"$key"=}" in
            \"*) q='"' ;;
            \'*) q="'" ;;
            *)   [[ "$val" =~ ^[A-Za-z0-9_./:-]+$ ]] && q="" ;;
        esac
    fi
    printf '%s%s=%s%s%s' "$pre" "$key" "$q" "$val" "$q"
}

# True when <file> is not empty and does not end in a newline.
no_eol() { [ -s "$1" ] && [ -n "$(tail -c 1 "$1" | tr -d '\n')" ]; }

# Builds the new /etc/default/grub (MAIN_NEW) and its undo records (MAIN_REC)
# from SET_KEYS/SET_VALS: the last active assignment of each key is replaced;
# a key the file does not assign is appended, unless a drop-in decides it
# anyway (then the drop-in carries it). Records: "ours\t<line>" followed by
# "was\t<line>" or "added". A replaced line that named a stale copy of this
# theme is recorded as added: uninstall must not point GRUB at a directory
# that is gone.
build_main() {
    local -a lines last
    local i k line n noeol=0 appended=0
    new_tmp; MAIN_NEW="$_tmp"
    new_tmp; MAIN_REC="$_tmp"
    MAIN_CHANGED=0
    no_eol "$ETC" && noeol=1
    mapfile -t lines < "$ETC"
    for k in "${!SET_KEYS[@]}"; do last[k]=-1; done
    for i in "${!lines[@]}"; do
        for k in "${!SET_KEYS[@]}"; do
            is_assign "${lines[i]}" "${SET_KEYS[k]}" && last[k]=$i
        done
    done
    for k in "${!SET_KEYS[@]}"; do
        i="${last[k]}"
        if [ "$i" -ge 0 ]; then
            value_of "${lines[i]}"
            [ "$_val" = "${SET_VALS[k]}" ] && continue
            line="$(format_line "${lines[i]}" "${SET_KEYS[k]}" "${SET_VALS[k]}")"
            printf 'ours\t%s\n' "$line" >> "$MAIN_REC"
            if [ "${SET_KEYS[k]}" = GRUB_THEME ] && names_stale "$_val" "${STALE[@]}"; then
                printf 'added\n' >> "$MAIN_REC"
            else
                printf 'was\t%s\n' "${lines[i]}" >> "$MAIN_REC"
            fi
            lines[i]="$line"
            MAIN_CHANGED=1
        elif ! eff "${SET_KEYS[k]}" || [ "$EF_FILE" = "$ETC" ]; then
            line="$(format_line "" "${SET_KEYS[k]}" "${SET_VALS[k]}")"
            n="${#lines[@]}"
            lines[n]="$line"
            # A file that ended without a newline gets one before our line;
            # "added<tab>noeol" lets uninstall take it away again.
            if [ "$noeol" -eq 1 ] && [ "$appended" -eq 0 ]; then
                printf 'ours\t%s\nadded\tnoeol\n' "$line" >> "$MAIN_REC"
            else
                printf 'ours\t%s\nadded\n' "$line" >> "$MAIN_REC"
            fi
            appended=1
            MAIN_CHANGED=1
        fi
    done
    [ "${#lines[@]}" -gt 0 ] && printf '%s\n' "${lines[@]}" > "$MAIN_NEW"
    # Only replaced lines: the file keeps ending the way it did.
    if [ "$noeol" -eq 1 ] && [ "$appended" -eq 0 ]; then
        truncate -s -1 "$MAIN_NEW"
    fi
}

# The drop-in: every key whose winner, with the new main file, would still be
# another drop-in. Empty when none is needed (and an old one of ours goes).
build_dropin() {
    local k body=""
    local -a files
    DROPIN_NEW="" DROPIN_CHANGED=0 DROPIN_REMOVE=0
    if [ "$READS_DROPINS" -eq 1 ]; then
        files=("$MAIN_NEW")
        local f
        for f in "$ETC_D"/*.cfg; do [ -f "$f" ] && [ "$f" != "$DROPIN" ] && files+=("$f"); done
        for k in "${!SET_KEYS[@]}"; do
            if eff "${SET_KEYS[k]}" "${files[@]}" && [ "$EF_VAL" != "${SET_VALS[k]}" ]; then
                body+="$(format_line "" "${SET_KEYS[k]}" "${SET_VALS[k]}")"$'\n'
            fi
        done
    fi
    if [ -n "$body" ]; then
        new_tmp; DROPIN_NEW="$_tmp"
        {
            printf '%s for the %s GRUB theme. Read after /etc/default/grub,\n' "$DROPIN_MARK" "$THEME_NAME"
            printf '# so it wins over another drop-in that sets the same names.\n'
            printf '# "grub-theme.sh uninstall" removes it, and puts everything else back.\n'
            printf '%s' "$body"
        } > "$DROPIN_NEW"
        if ! [ -f "$DROPIN" ] || ! cmp -s "$DROPIN_NEW" "$DROPIN"; then DROPIN_CHANGED=1; fi
    elif [ -f "$DROPIN" ] && grep -qF "$DROPIN_MARK" "$DROPIN"; then
        DROPIN_REMOVE=1
    fi
}

analyse() {
    FATAL=() NOTES=() STALE=() DUPES=() SET_KEYS=() SET_VALS=()
    THEME_IN_EFFECT=0 BLOCKED=0 TERM_FIX=0 REBUILD=0 PREV_THEME=""
    present || { FATAL+=("GRUB is not installed and set up here"); return 1; }
    if [ "$BOOT_UNMOUNTED" -eq 1 ]; then
        FATAL+=("/boot is in /etc/fstab but not mounted — mount it and run this again")
        return 1
    fi
    if [ -L "$ETC" ]; then
        FATAL+=("$ETC is a link to $(readlink "$ETC") — not edited through a link; set GRUB_THEME=\"$THEME_FILE\" there yourself")
        return 1
    fi
    [ -r "$ETC" ] || { FATAL+=("$ETC cannot be read"); return 1; }
    src_sum
    if findmnt -no OPTIONS --target "$BOOT" 2>/dev/null | tr ',' '\n' | grep -qx ro; then
        FATAL+=("$(findmnt -no TARGET --target "$BOOT") is mounted read-only")
    fi
    [ -n "$SRC_SUM" ] || FATAL+=("the theme is missing from $THEME_SRC")

    theme_state
    mapfile -t STALE < <(stale_dirs)
    mapfile -t DUPES < <(dupes)
    local filt
    if filt="$(proxy_unfiltered)"; then
        local from=""; [ "$DISTRO" = arch ] && from=" from the AUR"
        FATAL+=("grub-customizer's filter $filt is gone (grub-customizer was uninstalled), but its *_proxy scripts still build the menu — any rebuild would show entries twice and lose its renames. To keep this menu exactly as it is, reinstall grub-customizer$from (its filter is all that is needed, the app need not be opened), then run this again")
    fi

    eff_all GRUB_THEME && PREV_THEME="$EF_VAL"
    [ "$PREV_THEME" = "$THEME_FILE" ] && THEME_IN_EFFECT=1

    SET_KEYS+=(GRUB_THEME); SET_VALS+=("$THEME_FILE")
    if terminal_blocked; then
        if terminal_fixable; then
            TERM_FIX=1
            SET_KEYS+=(GRUB_TERMINAL_OUTPUT); SET_VALS+=(gfxterm)
        else
            BLOCKED=1
        fi
    fi
    # A menu made visible for a theme that cannot load anyway is only a slower boot.
    menu_visibility
    if [ "$BLOCKED" -eq 0 ]; then
        [ "$FIX_STYLE" -eq 1 ] && { SET_KEYS+=(GRUB_TIMEOUT_STYLE); SET_VALS+=(menu); }
        [ "$FIX_TIMEOUT" -eq 1 ] && { SET_KEYS+=(GRUB_TIMEOUT); SET_VALS+=("$VISIBLE_TIMEOUT"); }
    else
        FIX_STYLE=0 FIX_TIMEOUT=0 FIX_AUTOHIDE=0
    fi

    build_main
    build_dropin

    if [ "$THEME_STATE" != current ] || [ "$MAIN_CHANGED" -eq 1 ] \
       || [ "$DROPIN_CHANGED" -eq 1 ] || [ "$DROPIN_REMOVE" -eq 1 ]; then
        REBUILD=1
    fi

    # Room for the copy: the old one is moved aside, not deleted, until the
    # new one is in.
    if [ "$THEME_STATE" != current ]; then
        local need avail
        need="$(du -sk "$THEME_SRC" 2>/dev/null | cut -f1)"
        avail="$(df -Pk "$BOOT" 2>/dev/null | awk 'NR == 2 { print $4 }')"
        if [ -n "$need" ] && [ -n "$avail" ] && [ "$avail" -lt $((need + 1024)) ]; then
            FATAL+=("not enough room in $(df -P "$BOOT" | awk 'NR == 2 { print $6 }'): the theme needs ${need}K, ${avail}K is free")
        fi
    fi

    local li lm
    if li="$(loader_info)" && [ -n "$li" ] && [[ "$li" != GRUB* ]]; then
        NOTES+=("warn"$'\t'"this boot went through $li, not GRUB"$'\t'"— the theme shows only when GRUB is what boots")
    fi
    if lm="$(loader_mismatch)"; then
        local how fix
        how="$(grub_install_cmd)" || how=""
        case "$how" in
            "")         fix="run grub-install again so the loader matches the grub.cfg it reads (not done here: it needs your --target and --efi-directory)" ;;
            secureboot) fix="reinstall it so the loader matches the grub.cfg it reads, the way it was signed (Secure Boot is on: sbctl or shim, never a plain grub-install); not done here" ;;
            *)          fix="bring the loader up to date (not done here): $how — it replaces the GRUB files in place and leaves the firmware's boot entries alone" ;;
        esac
        NOTES+=("warn"$'\t'"GRUB ${lm%%$'\t'*} booted this machine, but grub-mkconfig is ${lm#*$'\t'}"$'\t'"— $fix")
    fi
    [ "${#FATAL[@]}" -eq 0 ]
}

# Rows for the plan, from the analysis.
plan_rows() {
    local d k i v f
    if [ "${#FATAL[@]}" -gt 0 ]; then
        for v in "${FATAL[@]}"; do row error "cannot install:" "$v"; done
        return 1
    fi
    for d in "${STALE[@]}"; do row remove "remove $d" "— this theme under its earlier name"; done
    case "$THEME_STATE" in
        absent|unknown) row add "copy the theme" "→ $DEST" ;;
        ours)     row add "update the theme" "in $DEST" ;;
        modified) row change "back up $DEST → $THEME_NAME.bak" "— changed by hand since it was installed"
                  row add "copy the theme" "→ $DEST" ;;
        foreign)  row change "back up $DEST → $THEME_NAME.bak" "— a different theme by that name"
                  row add "copy the theme" "→ $DEST" ;;
    esac
    if [ "$THEME_IN_EFFECT" -eq 0 ]; then
        if [ -n "$PREV_THEME" ] && ! names_stale "$PREV_THEME" "${STALE[@]}"; then
            row change "replaces the current theme" "$PREV_THEME"
        fi
        row add "set GRUB_THEME" "→ $THEME_FILE ($THEME_NAME)"
    fi
    if [ "$TERM_FIX" -eq 1 ]; then
        row change "GRUB_TERMINAL_OUTPUT $TB_VAL → gfxterm" "— no theme loads on a console-only terminal"
    fi
    [ "$FIX_STYLE" -eq 1 ] && row change "GRUB_TIMEOUT_STYLE → menu" "— was $STYLE_WAS; a hidden menu shows no theme"
    [ "$FIX_TIMEOUT" -eq 1 ] && row change "GRUB_TIMEOUT 0 → $VISIBLE_TIMEOUT" "— a menu shown for 0 seconds is not shown"
    [ "$FIX_AUTOHIDE" -eq 1 ] && row change "unset menu_auto_hide in grubenv" "— Fedora shows the menu only after a failed boot otherwise"
    if [ "$DROPIN_CHANGED" -eq 1 ]; then
        row add "write $DROPIN" "— another drop-in in $ETC_D would win over $ETC"
    elif [ "$DROPIN_REMOVE" -eq 1 ]; then
        row remove "remove $DROPIN" "— no longer needed"
    fi
    for d in "${DUPES[@]}"; do
        IFS=$'\t' read -r f v <<< "$d"
        row change "disable ${f##*/}" "— $v builds that part of the menu; a grub upgrade put the stock script back"
    done
    if [ "$REBUILD" -eq 1 ]; then
        row add "rebuild grub.cfg" "— checked against the current menu first; the current one is kept as grub.cfg.bak"
    elif [ "$THEME_STATE" = current ] && [ "$THEME_IN_EFFECT" -eq 1 ]; then
        row ok "theme already in place" "($THEME_NAME)"
    fi
    notes_rows
    if [ "$FIX_STYLE" -eq 0 ] && [ "$FIX_TIMEOUT" -eq 0 ]; then
        row info "timeout and menu entries are left as they are"
    else
        row info "menu entries are left as they are"
    fi
    return 0
}

# Why the theme would still not be seen, and the rest worth knowing.
notes_rows() {
    local n o
    if [ "$BLOCKED" -eq 1 ]; then
        local why
        if [ "$TB_VAR" = GRUB_TERMINAL ]; then why="it sets input and output together; GRUB_TERMINAL_OUTPUT=gfxterm is what a theme needs"
        elif [[ " $TB_VAL " == *" serial "* ]]; then why="left alone: it carries a serial console"
        else why="left alone on a machine with no display"
        fi
        row warn "the theme will not show:" "$TB_VAR=\"$TB_VAL\" in $TB_FILE — $why"
    fi
    if o="$(after_ours GRUB_THEME)"; then
        row warn "the theme will not show:" "$o sets GRUB_THEME and sorts after $DROPIN"
    fi
    if o="$(osprober_loss)"; then
        IFS=$'\t' read -r n o <<< "$o"
        row warn "rebuilding would drop: $n" "— $o; the install stops rather than lose them"
    fi
    if [ "$BOOT_UNMOUNTED" -eq 0 ] && ! cfg_generated "$CFG" && peek "$CFG" test -f "$CFG"; then
        row warn "grub.cfg was not written by grub-mkconfig" "— a rebuild replaces it; the install stops if any entry would be lost"
    fi
    if command -v grub-customizer >/dev/null 2>&1; then
        row info "grub-customizer is installed" "— saving in it rewrites $ETC and can set another theme"
    fi
    for n in "${NOTES[@]}"; do
        IFS=$'\t' read -r k o v <<< "$n"
        row "$k" "$o" "$v"
    done
}

# ── Install ──────────────────────────────────────────────────────────────────
# Everything changed so far, undone in reverse if the rebuild fails or is
# refused, or the run is interrupted.
TX=()
tx_add() { TX+=("$1"); }
tx_rollback() {
    local i a b c
    for ((i = ${#TX[@]} - 1; i >= 0; i--)); do
        IFS=$'\t' read -r a b c <<< "${TX[i]}"
        case "$a" in
            restore)  put_file "$c" "$b" ;;                         # restore <dest> <saved copy>
            unlink)   rootly "$(dirname "$b")" rm -f "$b" ;;        # unlink <file we created>
            chmodx)   rootly "$GRUBD" chmod +x "$b" ;;              # chmodx <script>
            rmtree)   rootly "$BOOT" rm -rf "$b" ;;                 # rmtree <dir we created>
            untree)   rootly "$BOOT" rm -rf "$b"; rootly "$BOOT" mv "$c" "$b" ;;   # untree <dest> <aside>
        esac
    done
    TX=()
}
tx_commit() {
    local i a b c
    for i in "${!TX[@]}"; do
        IFS=$'\t' read -r a b c <<< "${TX[i]}"
        [ "$a" = untree ] && [ -n "$c" ] && rootly "$BOOT" rm -rf "$c"
    done
    TX=()
}
on_signal() { tx_rollback; row error "interrupted" "— everything changed so far was put back"; exit 130; }

# tx_save <file>: keep a copy of <file> so a rollback can put it back.
tx_save() {
    new_tmp
    peek "$1" cat "$1" > "$_tmp" || return 1
    tx_add "restore"$'\t'"$1"$'\t'"$_tmp"
}

# .bak rotation, the repo's convention: an existing .bak becomes .old.bak.
backup_aside() {                # backup_aside <path>
    local p="$1" dir; dir="$(dirname "$p")"
    if rootly "$dir" test -e "$p.bak" || rootly "$dir" test -L "$p.bak"; then
        rootly "$dir" rm -rf "$p.old.bak"
        rootly "$dir" mv "$p.bak" "$p.old.bak"
    fi
    rootly "$dir" cp -a "$p" "$p.bak" 2>/dev/null || rootly "$dir" cp -R "$p" "$p.bak"
}

copy_theme() {
    local parent stage aside=""
    parent="$(dirname "$DEST")"
    stage="$parent/.$THEME_NAME.new"
    rootly "$BOOT" mkdir -p "$parent" || return 1
    rootly "$BOOT" rm -rf "$stage"
    # cp -R, not -a: nothing in /boot should keep the repo owner's uid, and on
    # a vfat /boot -a printed "failed to preserve ownership" for every file.
    rootly "$BOOT" cp -R "$THEME_SRC" "$stage" || { rootly "$BOOT" rm -rf "$stage"; return 1; }
    printf '%s\n' "$SRC_SUM" | rootly "$BOOT" tee "$stage/$MARKER" >/dev/null
    case "$THEME_STATE" in
        modified|foreign)
            backup_aside "$DEST" || { rootly "$BOOT" rm -rf "$stage"; return 1; }
            if [ "$THEME_STATE" = modified ]; then
                row change "backed up $DEST" "→ $THEME_NAME.bak — changed by hand since it was installed"
            else
                row change "backed up $DEST" "→ $THEME_NAME.bak — a different theme by that name"
            fi ;;
    esac
    if rootly "$BOOT" test -e "$DEST"; then
        aside="$parent/.$THEME_NAME.old"
        rootly "$BOOT" rm -rf "$aside"
        rootly "$BOOT" mv "$DEST" "$aside" || { rootly "$BOOT" rm -rf "$stage"; return 1; }
        tx_add "untree"$'\t'"$DEST"$'\t'"$aside"
    else
        tx_add "rmtree"$'\t'"$DEST"
    fi
    rootly "$BOOT" mv "$stage" "$DEST"
}

# Merges this run's records into the undo file: records whose "ours" line is
# no longer in the file (changed by hand since) are dropped, then the new ones
# go after the rest.
write_undo() {                  # write_undo <main-file-after> <extra records…>
    local after="$1" t line pend="" keep
    shift
    new_tmp; t="$_tmp"
    printf '# grub-theme.sh: what "uninstall" puts back. One change per record.\n' > "$t"
    if [ -f "$UNDO" ]; then
        local -A left=()
        while IFS= read -r line || [ -n "$line" ]; do
            left["$line"]=$(( ${left["$line"]:-0} + 1 ))
        done < "$after"
        keep=0
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                '#'*) ;;
                ours$'\t'*)
                    pend="${line#ours$'\t'}"
                    keep=0
                    if [ "${left["$pend"]:-0}" -gt 0 ]; then
                        left["$pend"]=$(( left["$pend"] - 1 ))
                        keep=1
                        printf '%s\n' "$line" >> "$t"
                    fi ;;
                was$'\t'*|added|added$'\t'*) [ "$keep" -eq 1 ] && printf '%s\n' "$line" >> "$t" ;;
                *) printf '%s\n' "$line" >> "$t" ;;
            esac
        done < "$UNDO"
    fi
    [ -s "$MAIN_REC" ] && cat "$MAIN_REC" >> "$t"
    local r
    for r in "$@"; do
        grep -qxF "$r" "$t" || printf '%s\n' "$r" >> "$t"
    done
    if [ "$(grep -vc '^#' "$t")" -eq 0 ]; then
        [ -f "$UNDO" ] && { tx_save "$UNDO"; rootly "$(dirname "$UNDO")" rm -f "$UNDO"; }
        return 0
    fi
    if [ -f "$UNDO" ]; then
        cmp -s "$t" "$UNDO" && return 0
        tx_save "$UNDO"
    else
        tx_add "unlink"$'\t'"$UNDO"
    fi
    put_file "$t" "$UNDO"
}

# Builds grub.cfg into a temp directory and checks it. Sets CAND and BUILD_OUT.
CAND="" BUILD_OUT=""
build_candidate() {
    local dir
    if [ "$IS_ROOT" -eq 1 ] || [ -w "$BOOT" ]; then dir="$(mktemp -d)"; else dir="$(sudo mktemp -d)"; fi
    [ -n "$dir" ] || return 1
    TMPS+=("$dir")
    CAND="$dir/grub.cfg"
    BUILD_OUT="$(rootly "$BOOT" "$MKCONFIG" -o "$CAND" 2>&1)"
}
# The temp dir is root's under sudo; cleanup_tmps runs as us.
drop_candidate() {
    [ -n "$CAND" ] || return 0
    rootly "$BOOT" rm -rf "$(dirname "$CAND")"
    CAND=""
}

# Puts the checked candidate in place, the old grub.cfg kept as grub.cfg.bak.
apply_candidate() {
    backup_aside "$CFG" || return 1
    put_file "$CAND" "$CFG" || return 1
    # grub-mkconfig's own rule: a grub.cfg holding a password hash is root's only.
    if rootly "$BOOT" grep -q '^password' "$CFG" 2>/dev/null; then
        rootly "$BOOT" chmod 400 "$CFG" 2>/dev/null
    fi
    return 0
}

# Compares the candidate's menu with the current one. 0 when it may go in.
# Besides entries lost or doubled, an entry that comes out different is a
# change too: grub.cfg was edited by hand after it was built (a kernel option,
# a hotkey), or a setting was changed and never applied. The one edit carried
# over is extra --class options, which only pick an entry's icon.
check_menu() {
    local old new diff line kind title what lost="" dup="" added="" changed="" kept="" keys locks
    new_tmp; old="$_tmp"
    new_tmp; new="$_tmp"
    cfg_titles "$CFG" > "$old"
    cfg_titles "$CAND" > "$new"
    diff="$(menu_diff "$old" "$new")"
    while IFS=$'\t' read -r kind title; do
        [ -n "$kind" ] || continue
        case "$kind" in
            removed)    lost+="${lost:+, }$title" ;;
            duplicated) dup+="${dup:+, }$title" ;;
            added)      added+="${added:+, }$title" ;;
        esac
    done <<< "$diff"
    cfg_entries "$CFG" > "$old"
    cfg_entries "$CAND" > "$new"
    new_tmp; keys="$_tmp"
    while IFS=$'\t' read -r kind title what; do
        case "$kind" in
            class)   printf '%s\t%s\n' "$what" "$title" >> "$keys"; kept+="${kept:+, }$title" ;;
            changed) changed+="${changed:+, }$title ($what)" ;;
        esac
    done < <(entry_diff "$old" "$new")
    if [ -n "$kept" ]; then
        carry_lines "$keys" "$CFG" "$CAND" > "$new"
        rootly "$BOOT" cp "$new" "$CAND" || return 1
        row info "kept from the current grub.cfg:" "the icon class of $kept (added by hand after it was built)"
    fi
    locks="$(LC_ALL=C comm -23 <(cfg_locks "$CFG") <(cfg_locks "$CAND"))"
    [ -n "$added" ] && row info "new in the menu:" "$added"
    [ -z "$lost" ] && [ -z "$dup" ] && [ -z "$changed" ] && [ -z "$locks" ] && return 0
    [ -n "$lost" ] && row warn "the rebuilt menu would lose:" "$lost"
    [ -n "$dup" ] && row warn "the rebuilt menu would show twice:" "$dup"
    [ -n "$changed" ] && row warn "the rebuilt menu would change:" "$changed — grub.cfg was edited by hand after it was built, or a setting was never applied"
    [ -n "$locks" ] && row warn "the rebuilt grub.cfg would drop its password:" "$(printf '%s' "$locks" | cut -d' ' -f1-2 | paste -sd, - | sed 's/,/, /g') — added to grub.cfg by hand; /etc/grub.d/40_custom keeps it across rebuilds"
    if [ "$ACCEPT" -eq 1 ]; then
        row info "applied anyway (--accept-menu-changes)" "— the old one is $CFG.bak"
        return 0
    fi
    return 1
}

# The proof: grub-mkconfig names the theme it loads, and the new grub.cfg sets it.
theme_loaded() {
    peek "$CAND" grep -q "^[[:space:]]*set theme=.*/themes/$THEME_NAME/theme\.txt" "$CAND" 2>/dev/null \
        || [[ "$BUILD_OUT" == *"$THEME_FILE"* ]]
}

do_install() {
    analyse
    if [ "${#FATAL[@]}" -gt 0 ]; then
        local f; for f in "${FATAL[@]}"; do row error "cannot install:" "$f"; done
        return 1
    fi
    verify_theme >/dev/null || { row error "the theme in $THEME_SRC is broken" "— grub-theme.sh verify says why"; return 1; }
    if [ "$REBUILD" -eq 0 ] && [ "${#STALE[@]}" -eq 0 ] && [ "${#DUPES[@]}" -eq 0 ] && [ "$FIX_AUTOHIDE" -eq 0 ]; then
        row ok "GRUB theme already in place" "($THEME_NAME)"
        notes_rows
        return 0
    fi
    sudo_ready || { row error "sudo is needed for $BOOT and $ETC"; return 1; }
    trap on_signal INT TERM

    local d f v rec=()
    for d in "${DUPES[@]}"; do
        IFS=$'\t' read -r f v <<< "$d"
        rec+=("chmod"$'\t'"$f")
    done
    [ "$FIX_AUTOHIDE" -eq 1 ] && rec+=("grubenv"$'\t'"menu_auto_hide=1")
    [ "$DROPIN_CHANGED" -eq 1 ] && rec+=("dropin"$'\t'"$DROPIN")

    # The record goes first: a change made with nothing to undo it from is the
    # one thing uninstall could not recover from.
    if ! write_undo "$MAIN_NEW" "${rec[@]}"; then
        tx_rollback; row error "could not write $UNDO"; return 1
    fi
    for d in "${DUPES[@]}"; do
        IFS=$'\t' read -r f v <<< "$d"
        if rootly "$GRUBD" chmod -x "$f"; then
            tx_add "chmodx"$'\t'"$f"
            row change "disabled ${f##*/}" "— $v already builds that part of the menu"
        fi
    done
    if [ "$THEME_STATE" != current ]; then
        if ! copy_theme; then
            tx_rollback; row error "could not copy the theme to $DEST"; return 1
        fi
        row add "copied the theme" "→ $DEST"
    fi
    if [ "$MAIN_CHANGED" -eq 1 ]; then
        tx_save "$ETC"
        put_file "$MAIN_NEW" "$ETC" || { tx_rollback; row error "could not write $ETC"; return 1; }
    fi
    if [ "$DROPIN_CHANGED" -eq 1 ]; then
        if [ -f "$DROPIN" ]; then tx_save "$DROPIN"
        else tx_add "unlink"$'\t'"$DROPIN"; rootly "$(dirname "$ETC")" mkdir -p "$ETC_D"; fi
        put_file "$DROPIN_NEW" "$DROPIN" || { tx_rollback; row error "could not write $DROPIN"; return 1; }
    elif [ "$DROPIN_REMOVE" -eq 1 ]; then
        tx_save "$DROPIN"
        rootly "$ETC_D" rm -f "$DROPIN"
    fi

    if [ "$REBUILD" -eq 1 ]; then
        if ! build_candidate; then
            row error "grub-mkconfig failed" "— nothing was changed"
            printf '%s\n' "$BUILD_OUT" | tail -n 5 | while IFS= read -r v; do row info "$v"; done
            drop_candidate; tx_rollback; return 1
        fi
        if [ "$BLOCKED" -eq 0 ] && ! after_ours GRUB_THEME >/dev/null && ! theme_loaded; then
            row error "grub-mkconfig did not load the theme" "— nothing was changed"
            no_theme_why
            drop_candidate; tx_rollback; return 1
        fi
        if ! check_menu; then
            row error "stopped: the menu would change" "— nothing was changed. To apply anyway: bash $HERE/grub-theme.sh install --accept-menu-changes"
            drop_candidate; tx_rollback; return 1
        fi
        if ! apply_candidate; then
            row error "could not write $CFG" "— nothing was changed"
            drop_candidate; tx_rollback; return 1
        fi
        drop_candidate
    fi
    trap - INT TERM
    tx_commit

    [ "$THEME_IN_EFFECT" -eq 0 ] && row add "GRUB_THEME" "→ $THEME_FILE"
    [ "$TERM_FIX" -eq 1 ] && row change "GRUB_TERMINAL_OUTPUT" "→ gfxterm"
    [ "$FIX_STYLE" -eq 1 ] && row change "GRUB_TIMEOUT_STYLE" "→ menu (was $STYLE_WAS)"
    [ "$FIX_TIMEOUT" -eq 1 ] && row change "GRUB_TIMEOUT" "→ $VISIBLE_TIMEOUT (was 0)"
    [ "$DROPIN_CHANGED" -eq 1 ] && row add "wrote $DROPIN"
    [ "$DROPIN_REMOVE" -eq 1 ] && row remove "removed $DROPIN"
    if [ "$FIX_AUTOHIDE" -eq 1 ]; then
        if rootly "$BOOT" "$EDITENV" "$BOOT/grubenv" unset menu_auto_hide; then
            row change "menu_auto_hide" "unset in grubenv"
        else
            row warn "could not unset menu_auto_hide" "— the menu stays hidden after good boots"
        fi
    fi
    [ "$REBUILD" -eq 1 ] && row add "rebuilt grub.cfg" "— the old one is grub.cfg.bak"
    for d in "${STALE[@]}"; do
        rootly "$BOOT" rm -rf "$d" && row remove "removed $d" "— this theme under its earlier name"
    done
    notes_rows
    if [ "$FIX_STYLE" -eq 0 ] && [ "$FIX_TIMEOUT" -eq 0 ]; then
        row info "timeout and menu entries were left as they are"
    else
        row info "menu entries were left as they are"
    fi
    return 0
}

# A theme grub-mkconfig did not take, and nothing known in the way: say what
# it printed, and the one usual cause — no font for gfxterm to start with.
no_theme_why() {
    local font=""
    eff_all GRUB_FONT && font="$EF_VAL"
    if [ -z "$font" ]; then
        local p found=0
        for p in /usr/share/grub /usr/share/grub2 "$BOOT" "$BOOT/fonts"; do
            for f in unicode unifont ascii; do [ -e "$p/$f.pf2" ] && found=1; done
        done
        [ "$found" -eq 1 ] || row info "no GRUB font found" "— gfxterm needs unicode.pf2 (grub-install puts one in $BOOT/fonts)"
    fi
    printf '%s\n' "$BUILD_OUT" | tail -n 5 | while IFS= read -r v; do [ -n "$v" ] && row info "$v"; done
}

# ── Uninstall ────────────────────────────────────────────────────────────────
owned() {
    present || return 1
    [ -f "$UNDO" ] && return 0
    [ -f "$DROPIN" ] && grep -qF "$DROPIN_MARK" "$DROPIN" 2>/dev/null && return 0
    peek "$BOOT" test -f "$DEST/$MARKER"
}

uninstall_row() {
    local what=() line
    if [ -f "$UNDO" ]; then
        while IFS= read -r line; do
            case "$line" in
                ours$'\t'*) line="${line#ours$'\t'}"; line="${line%%=*}"; line="${line#"${line%%[![:space:]]*}"}"; line="${line#export }"
                            [[ " ${what[*]} " == *" $line "* ]] || what+=("$line") ;;
                chmod$'\t'*) what+=("${line##*/} (executable again)") ;;
                grubenv$'\t'*) what+=("menu_auto_hide") ;;
            esac
        done < "$UNDO"
    fi
    local s="${what[*]}"
    printf '%s' "${s:+${s// /, } back as they were, }$DEST deleted, grub.cfg rebuilt (menu entries stay)"
}

do_uninstall() {
    if ! owned; then
        row ok "nothing to undo" "— the theme was not installed by this script"
        return 0
    fi
    local -a lines recs
    local i line r new changed=0 drop=0 kind val noeol=0
    [ -f "$UNDO" ] && mapfile -t recs < "$UNDO"
    # FIFO per exact line: the first record for a line text maps to the first
    # place it appears, which is where it was written.
    local -a q_ours=() q_was=()
    for ((i = 0; i < ${#recs[@]}; i++)); do
        case "${recs[i]}" in
            ours$'\t'*)
                q_ours+=("${recs[i]#ours$'\t'}")
                r="${recs[i+1]:-}"
                case "$r" in
                    was$'\t'*)    q_was+=("w${r#was$'\t'}") ;;
                    added$'\t'noeol) q_was+=("-n") ;;
                    *)            q_was+=("-") ;;
                esac ;;
        esac
    done
    new_tmp; new="$_tmp"
    mapfile -t lines < "$ETC"
    local -a used=()
    for line in "${lines[@]}"; do
        kind=""
        for i in "${!q_ours[@]}"; do
            [ -z "${used[i]:-}" ] && [ "${q_ours[i]}" = "$line" ] && { kind="${q_was[i]}"; used[i]=1; break; }
        done
        if [ -z "$kind" ]; then printf '%s\n' "$line" >> "$new"; continue; fi
        changed=1
        case "$kind" in
            -)  ;;
            -n) noeol=1 ;;
            *)  printf '%s\n' "${kind#w}" >> "$new" ;;
        esac
    done
    # Ending the way it did before: no newline if it had none.
    { [ "$noeol" -eq 1 ] || no_eol "$ETC"; } && [ -s "$new" ] && truncate -s -1 "$new"
    [ -f "$DROPIN" ] && grep -qF "$DROPIN_MARK" "$DROPIN" && drop=1

    sudo_ready || { row error "sudo is needed for $BOOT and $ETC"; return 1; }
    trap on_signal INT TERM
    if [ "$changed" -eq 1 ]; then
        [ -s "$new" ] || : > "$new"
        tx_save "$ETC"
        put_file "$new" "$ETC" || { tx_rollback; row error "could not write $ETC"; return 1; }
    fi
    if [ "$drop" -eq 1 ]; then
        tx_save "$DROPIN"
        rootly "$ETC_D" rm -f "$DROPIN"
    fi
    # grub.cfg still naming our theme (rebuilt since by hand, or not) is
    # rebuilt too: removing the directory under it would blank the menu.
    local rebuild=0
    { [ "$changed" -eq 1 ] || [ "$drop" -eq 1 ]; } && rebuild=1
    peek "$CFG" grep -q "/themes/$THEME_NAME/theme\.txt" "$CFG" 2>/dev/null && rebuild=1
    if [ "$rebuild" -eq 1 ]; then
        if ! build_candidate; then
            row error "grub-mkconfig failed" "— nothing was changed"
            printf '%s\n' "$BUILD_OUT" | tail -n 5 | while IFS= read -r val; do row info "$val"; done
            drop_candidate; tx_rollback; return 1
        fi
        if ! check_menu; then
            row error "stopped: the menu would change" "— nothing was changed. To apply anyway: bash $HERE/grub-theme.sh uninstall --accept-menu-changes"
            drop_candidate; tx_rollback; return 1
        fi
        if ! apply_candidate; then
            row error "could not write $CFG" "— nothing was changed"
            drop_candidate; tx_rollback; return 1
        fi
        # Something else still names our directory (a hand-made drop-in): it stays.
        if peek "$CAND" grep -q "/themes/$THEME_NAME/theme\.txt" "$CAND" 2>/dev/null; then
            KEEP_DEST=1
        fi
        drop_candidate
    fi
    trap - INT TERM
    tx_commit
    [ "$changed" -eq 1 ] && row change "put $ETC back" "— the lines this script replaced"
    [ "$drop" -eq 1 ] && row remove "removed $DROPIN"
    # After the rebuild, so the grub.cfg just built is the menu as it was.
    for r in "${recs[@]}"; do
        case "$r" in
            chmod$'\t'*)
                r="${r#chmod$'\t'}"
                [ -f "$r" ] && rootly "$GRUBD" chmod +x "$r" && row change "${r##*/} is executable again" "— as before the install" ;;
            grubenv$'\t'*)
                r="${r#grubenv$'\t'}"
                [ -n "$EDITENV" ] && rootly "$BOOT" "$EDITENV" "$BOOT/grubenv" set "$r" && row change "grubenv: $r" "— as before the install" ;;
        esac
    done
    if [ "${KEEP_DEST:-0}" -eq 1 ]; then
        row warn "kept $DEST" "— something besides this script still sets it as GRUB_THEME"
    elif peek "$BOOT" test -e "$DEST"; then
        theme_state
        if [ "$THEME_STATE" = modified ] || [ "$THEME_STATE" = foreign ]; then
            backup_aside "$DEST" && row change "kept a copy" "$DEST.bak — it was changed by hand"
        fi
        rootly "$BOOT" rm -rf "$DEST" && row remove "removed $DEST"
    fi
    [ -f "$UNDO" ] && rootly "$(dirname "$UNDO")" rm -f "$UNDO"
    [ "$rebuild" -eq 1 ] && row add "rebuilt grub.cfg" "— the old one is grub.cfg.bak"
    return 0
}

# ── Status ───────────────────────────────────────────────────────────────────
do_status() {
    if [ "$DISTRO" = nix ]; then echo "GRUB: NixOS builds grub.cfg from configuration.nix — not handled here"; return 0; fi
    if [ -z "$MKCONFIG" ]; then echo "GRUB: not installed (no grub-mkconfig)"; return 0; fi
    local ver li
    ver="$("$MKCONFIG" --version 2>/dev/null | awk '{ print $NF }')"
    echo "GRUB: ${MKCONFIG##*/} ${ver:-?}, settings $ETC, boot directory ${BOOT:-none}$(
        [ -n "$BOOT" ] && printf ' (%s)' "$(findmnt -no FSTYPE --target "$BOOT" 2>/dev/null)")"
    present || { echo "  not set up here (no grub.cfg written yet)"; return 0; }
    [ "$BOOT_UNMOUNTED" -eq 1 ] && { echo "  /boot is in /etc/fstab but not mounted"; return 0; }
    li="$(loader_info)" && echo "  this boot: ${li:-unknown}"
    local lm how
    if lm="$(loader_mismatch)"; then
        echo "  loader ${lm%%$'\t'*} is older than grub-mkconfig ${lm#*$'\t'}: grub-install has not been run since the upgrade"
        how="$(grub_install_cmd)" || how=""
        case "$how" in
            "") ;;
            secureboot) echo "    Secure Boot is on: reinstall it the way it was signed (sbctl or shim)" ;;
            *) echo "    to update it: $how" ;;
        esac
    fi
    [ "$READS_DROPINS" -eq 1 ] && echo "  reads $ETC_D/*.cfg after $ETC"
    if eff_all GRUB_THEME; then echo "  GRUB_THEME=$EF_VAL ($EF_FILE)"; else echo "  GRUB_THEME not set"; fi
    theme_state
    case "$THEME_STATE" in
        absent)   echo "  $THEME_NAME: not installed" ;;
        current)  echo "  $THEME_NAME: installed, same as the repo" ;;
        ours)     echo "  $THEME_NAME: installed, an older version" ;;
        modified) echo "  $THEME_NAME: installed, changed by hand since" ;;
        foreign)  echo "  $THEME_NAME: a different theme by that name is in $DEST" ;;
        unknown)  echo "  $THEME_NAME: $BOOT cannot be read without sudo" ;;
    esac
    local s; for s in $(stale_dirs); do echo "  stale copy under an earlier name: $s"; done
    if terminal_blocked; then echo "  terminal: $TB_VAR=$TB_VAL ($TB_FILE) — no theme can load"; else echo "  terminal: gfxterm"; fi
    menu_visibility
    if [ "$FIX_STYLE" -eq 1 ] || [ "$FIX_TIMEOUT" -eq 1 ] || [ "$FIX_AUTOHIDE" -eq 1 ]; then
        echo "  menu: hidden at boot${STYLE_WAS:+ ($STYLE_WAS)}${TIMEOUT_WAS:+ (GRUB_TIMEOUT=0)}$([ "$FIX_AUTOHIDE" -eq 1 ] && echo ' (menu_auto_hide=1)')"
    else
        eff GRUB_TIMEOUT && echo "  menu: visible, GRUB_TIMEOUT=$EF_VAL"
    fi
    if cfg_generated "$CFG"; then
        if peek "$CFG" grep -q '^[[:space:]]*set theme=' "$CFG" 2>/dev/null; then
            echo "  grub.cfg: built by grub-mkconfig, loads $(peek "$CFG" sed -n 's/^[[:space:]]*set theme=//p' "$CFG" | head -n 1)"
        else
            echo "  grub.cfg: built by grub-mkconfig, no theme in it"
        fi
    elif peek "$CFG" test -f "$CFG"; then
        echo "  grub.cfg: not written by grub-mkconfig"
    else
        echo "  grub.cfg: cannot be read without sudo"
    fi
    local d; while IFS=$'\t' read -r s d; do
        [ -n "$s" ] && echo "  grub-customizer leftover: ${s##*/} would run beside $d at the next rebuild"
    done < <(dupes)
    if d="$(proxy_unfiltered)"; then
        echo "  grub-customizer: its filter $d is gone, but its proxy scripts still build the menu — a rebuild would show entries twice"
    fi
    [ -f "$UNDO" ] && echo "  undo record: $UNDO ($(grep -vc '^#' "$UNDO") lines)"
    [ -f "$DROPIN" ] && echo "  drop-in: $DROPIN"
    return 0
}

# ── Verify: the theme itself ─────────────────────────────────────────────────
# What GRUB's own readers accept, checked here so a theme that would come up
# blank is caught in the repo rather than at boot.
pf2_name() {                    # pf2_name <file>: the font's NAME section
    local hex i=0 tag len
    hex="$(od -An -tx1 -v -N 512 "$1" | tr -d ' \n')"
    while [ $((i + 16)) -le ${#hex} ]; do
        tag="${hex:i:8}"; len=$((16#${hex:i+8:8}))
        if [ "$tag" = 4e414d45 ]; then
            printf '%b' "$(printf '%s' "${hex:i+16:len*2}" | sed 's/00$//; s/../\\x&/g')"
            return 0
        fi
        [ "$tag" = 44415441 ] && return 1
        i=$((i + 16 + len * 2))
    done
    return 1
}
png_problem() {                 # png_problem <file>: why GRUB's PNG reader refuses it, if it does
    # grub-core/video/readers/png.c: RGB or RGBA at 8 or 16 bits, a palette
    # at 4 or 8, never greyscale, never interlaced.
    local -a b
    read -ra b <<< "$(od -An -tu1 -v -N 29 "$1" | tr '\n' ' ')"
    [ "${#b[@]}" -ge 29 ] || { echo "too short to be a PNG"; return 0; }
    [ "${b[*]:0:8}" = "137 80 78 71 13 10 26 10" ] || { echo "not a PNG"; return 0; }
    case "${b[25]}" in
        2|6) case "${b[24]}" in 8|16) ;; *) echo "${b[24]}-bit colour (GRUB reads 8 or 16)"; return 0 ;; esac ;;
        3)   case "${b[24]}" in 4|8) ;;  *) echo "${b[24]}-bit palette (GRUB reads 4 or 8)"; return 0 ;; esac ;;
        0|4) echo "greyscale (GRUB reads colour and palette PNGs only)"; return 0 ;;
        *)   echo "colour type ${b[25]}"; return 0 ;;
    esac
    [ "${b[28]}" -eq 0 ] || { echo "interlaced (GRUB cannot read interlaced PNGs)"; return 0; }
    return 1
}
jpeg_problem() {                # jpeg_problem <file>: why GRUB's JPEG reader refuses it, if it does
    # grub-core/video/readers/jpeg.c, read up to the first scan: a baseline
    # frame (SOF0) at 8 bits, 1 or 3 components numbered 1-3, only the first
    # subsampled (at most 2x2), quantisation tables 0-1 at 8 bits, Huffman
    # tables 0-1 of each class, each defined once. Other frame types are
    # skipped as unknown, and the image then has no size.
    local f="$1" off=2 size m len j t n k seen=" " sof=0
    local -a b s
    size="$(wc -c < "$f")"
    read -ra b <<< "$(od -An -tu1 -N 2 "$f")"
    if [ "${b[0]:-}" != 255 ] || [ "${b[1]:-}" != 216 ]; then echo "not a JPEG"; return 0; fi
    while [ $((off + 4)) -le "$size" ]; do
        read -ra b <<< "$(od -An -tu1 -j "$off" -N 4 "$f" | tr '\n' ' ')"
        [ "${b[0]}" = 255 ] || { echo "damaged: no marker at byte $off"; return 0; }
        m="${b[1]}"
        [ "$m" = 255 ] && { off=$((off + 1)); continue; }
        [ "$m" = 217 ] && { echo "no image data"; return 0; }
        len=$((b[2] * 256 + b[3]))
        [ "$len" -ge 2 ] || { echo "damaged at byte $off"; return 0; }
        case "$m" in 192|196|219)
            read -ra s <<< "$(od -An -tu1 -v -j $((off + 4)) -N $((len - 2)) "$f" | tr '\n' ' ')" ;;
        esac
        case "$m" in
            192)
                [ "$sof" -eq 0 ] || { echo "two frame headers"; return 0; }
                [ "${#s[@]}" -ge $((6 + 3 * ${s[5]:-0})) ] || { echo "damaged frame header"; return 0; }
                sof=1
                [ "${s[0]}" = 8 ] || { echo "${s[0]}-bit samples (GRUB reads 8)"; return 0; }
                [ "${s[5]}" = 1 ] || [ "${s[5]}" = 3 ] || { echo "${s[5]} colour components (GRUB reads 1 or 3)"; return 0; }
                for ((k = 0; k < s[5]; k++)); do
                    t="${s[$((7 + 3 * k))]}"
                    case "${s[$((6 + 3 * k))]}" in 1|2|3) ;; *) echo "components not numbered 1-3"; return 0 ;; esac
                    if [ "${s[$((6 + 3 * k))]}" = 1 ]; then
                        if [ $((t >> 4)) -lt 1 ] || [ $((t >> 4)) -gt 2 ] || [ $((t & 15)) -lt 1 ] || [ $((t & 15)) -gt 2 ]; then
                            echo "subsampled $((t >> 4))x$((t & 15)) (GRUB reads up to 2x2)"; return 0
                        fi
                    else
                        [ "$t" = 17 ] || { echo "colour subsampled (GRUB subsamples brightness only: 4:2:0, 4:2:2 or 4:4:4)"; return 0; }
                    fi
                    [ "${s[$((8 + 3 * k))]}" -le 1 ] || { echo "more than two quantisation tables"; return 0; }
                done ;;
            194) echo "progressive (GRUB reads baseline JPEGs only)"; return 0 ;;
            193|195|197|198|199|201|202|203|205|206|207)
                echo "not baseline (frame type $(printf '0x%X' "$m"); GRUB reads SOF0 only)"; return 0 ;;
            219)                # DQT
                for ((j = 0; j < ${#s[@]}; )); do
                    t="${s[$j]}"
                    [ $((t >> 4)) -eq 0 ] || { echo "16-bit quantisation tables (GRUB reads 8-bit)"; return 0; }
                    [ $((t & 15)) -le 1 ] || { echo "more than two quantisation tables"; return 0; }
                    j=$((j + 65))
                done ;;
            196)                # DHT
                for ((j = 0; j < ${#s[@]}; )); do
                    t="${s[$j]}"
                    [ $((t & 15)) -le 1 ] || { echo "more than two Huffman tables of a kind"; return 0; }
                    k="$(((t >> 4) & 1))-$((t & 15))"
                    [[ "$seen" == *" $k "* ]] && { echo "a Huffman table defined twice"; return 0; }
                    seen+="$k "
                    n=0; for ((k = 1; k <= 16; k++)); do n=$((n + s[j + k])); done
                    j=$((j + 17 + n))
                done ;;
            218)                # SOS: the header is over
                [ "$sof" -eq 1 ] || { echo "no frame header (SOF0) before the image data"; return 0; }
                return 1 ;;
        esac
        off=$((off + 2 + len))
    done
    echo "ends before the image data"
    return 0
}
verify_theme() {
    local t="$THEME_SRC/theme.txt" errs=0 f p name names fonts img dup
    err() { row error "$1" "${2:-}"; errs=$((errs + 1)); }
    [ -f "$t" ] || { err "no theme.txt in $THEME_SRC"; return 1; }
    # Every image theme.txt names: exact files, and *_pixmap_style patterns,
    # which need at least one of the nine slices GRUB looks for.
    while IFS= read -r img; do
        if [[ "$img" == *'*'* ]]; then
            local found=0 s
            for s in c n s e w ne nw se sw; do [ -f "$THEME_SRC/${img/\*/$s}" ] && found=1; done
            [ "$found" -eq 1 ] || err "no image for $img"
        else
            [ -f "$THEME_SRC/$img" ] || err "theme.txt names $img, which is not there"
        fi
    done < <(grep -oE '"[^"]+\.(png|jpe?g|tga)"' "$t" | tr -d '"' | sort -u)
    while IFS= read -r -d '' f; do
        p="$(png_problem "$f")" && err "${f#"$THEME_SRC"/}:" "$p"
    done < <(find "$THEME_SRC" -type f -iname '*.png' -print0)
    while IFS= read -r -d '' f; do
        p="$(jpeg_problem "$f")" && err "${f#"$THEME_SRC"/}:" "$p"
    done < <(find "$THEME_SRC" -type f \( -iname '*.jpg' -o -iname '*.jpeg' \) -print0)
    # theme_loader.c refuses a value it does not know, and the whole theme
    # with it: GRUB comes up in text mode.
    local key ok v
    for key in "desktop-image-scale-method:stretch crop padding fitwidth fitheight" \
               "desktop-image-h-align:left center right" "desktop-image-v-align:top center bottom"; do
        ok="${key#*:}"; key="${key%%:*}"
        while IFS= read -r v; do
            [[ " $ok " == *" $v "* ]] || err "theme.txt: $key \"$v\"" "is not one GRUB knows ($ok)"
        done < <(sed -nE "s/^[[:space:]]*${key}[[:space:]]*:[[:space:]]*\"?([^\"]*)\"?[[:space:]]*\$/\\1/p" "$t")
    done
    # Every font theme.txt asks for must be one of the .pf2 files beside it,
    # by the name inside the file, or GRUB quietly falls back to its own.
    names=""
    for f in "$THEME_SRC"/*.pf2; do
        [ -f "$f" ] || continue
        name="$(pf2_name "$f")" || { err "${f##*/}:" "not a PF2 font"; continue; }
        names+="$name"$'\n'
    done
    fonts="$(grep -oE '(font|-font|_font)[[:space:]]*[:=][[:space:]]*"[^"]+"' "$t" | sed -E 's/.*"([^"]+)"/\1/' | sort -u)"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "$f" in "Unifont Regular 16"|"Unknown Regular 16") continue ;; esac
        grep -qxF "$f" <<< "$names" || err "theme.txt asks for the font \"$f\"," "which no .pf2 here is"
    done <<< "$fonts"
    # A vfat /boot folds case: two names that differ only in case collide.
    dup="$(cd "$THEME_SRC" && find . | tr '[:upper:]' '[:lower:]' | sort | uniq -d)"
    [ -z "$dup" ] || err "names that collide on a vfat /boot:" "$(printf '%s' "$dup" | paste -sd' ' -)"
    dup="$(cd "$THEME_SRC" && find . -name '*[:*?"<>|\\]*')"
    [ -z "$dup" ] || err "names a vfat /boot cannot hold:" "$(printf '%s' "$dup" | paste -sd' ' -)"
    [ "$errs" -eq 0 ] || return 1
    row ok "theme verified" "— $(du -sh "$THEME_SRC" | cut -f1), $(printf '%s' "$names" | grep -c .) fonts, every image readable by GRUB"
}

# ── Main ─────────────────────────────────────────────────────────────────────
cmd="${1:-status}"; shift || true
for a in "$@"; do
    case "$a" in
        --porcelain)           PORCELAIN=1 ;;
        --accept-menu-changes) ACCEPT=1 ;;
        *) echo "grub-theme.sh: unknown option $a" >&2; exit 2 ;;
    esac
done

case "$cmd" in
    status)        do_status ;;
    plan)          analyse; plan_rows ;;
    install)       do_install ;;
    uninstall)     do_uninstall ;;
    verify)        verify_theme ;;
    present)       present ;;
    target)        printf '%s\n' "$THEME_FILE" ;;
    state)         # linked | yours | new, for install.sh's menu
        present || { echo new; exit 0; }
        theme_state
        if eff_all GRUB_THEME; then
            if [ "$EF_VAL" = "$THEME_FILE" ] && [ "$THEME_STATE" = current ]; then echo linked; else echo yours; fi
        else
            echo new
        fi ;;
    current)       # nothing left to do
        analyse || exit 1
        [ "$REBUILD" -eq 0 ] && [ "${#STALE[@]}" -eq 0 ] && [ "${#DUPES[@]}" -eq 0 ] && [ "$FIX_AUTOHIDE" -eq 0 ] ;;
    owned)         owned ;;
    uninstall-row) uninstall_row; echo ;;
    -h|--help|help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) echo "grub-theme.sh: unknown command $cmd (status, plan, install, uninstall, verify)" >&2; exit 2 ;;
esac
