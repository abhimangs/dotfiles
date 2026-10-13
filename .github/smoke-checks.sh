#!/usr/bin/env bash
# Sourced by smoke-user.sh (and by nothing else in CI). Functions only, so the
# parsing can be rehearsed outside a container against the test harness's
# sandbox: source this, point cwd/HOME/PATH at a sandbox, call the check.
#
# Contract with the caller: cwd is the repo copy the installer runs from, HOME
# is the user's, $LOGS is a writable directory. Assertions accumulate in
# $PROBLEMS and are reported together by `verdict`, so one red run lists every
# broken thing instead of the first.

PROBLEMS=()
LOGS="${LOGS:-$HOME/smoke-logs}"
ALLOW_FILE="${ALLOW_FILE:-.github/smoke-allow.txt}"
mkdir -p "$LOGS"

step()  { printf '\n\033[1m── %s\033[0m\n' "$1"; }
pass()  { printf '  PASS  %s\n' "$1"; }
flunk() {               # flunk <what> [detail...]
    local what="$1"; shift
    printf '  FAIL  %s\n' "$what"
    local l; for l in "$@"; do printf '          %s\n' "$l"; done
    PROBLEMS+=("$what")
    # GitHub turns this into an annotation on the run's summary page.
    [ -n "${GITHUB_ACTIONS:-}" ] && printf '::error::%s\n' "$what"
    return 0
}
verdict() {
    echo
    if [ "${#PROBLEMS[@]}" -eq 0 ]; then echo "smoke: ok"; return 0; fi
    printf 'smoke: %d problem(s)\n' "${#PROBLEMS[@]}" >&2
    printf '  - %s\n' "${PROBLEMS[@]}" >&2
    return 1
}

# ── the allow-list ───────────────────────────────────────────────────────────
# One extended regex per line, then " # reason". A line is an entry only if it
# has both. Matched against the text of a failure (a label from the summary's
# "Failed (n):" row, or a key from the detection check). An allowed failure is
# still printed, as a warning, on every run — it is a known hole, not a pass.
allowed() {             # allowed <text> — prints the reason and succeeds if listed
    [ -f "$ALLOW_FILE" ] || return 1
    local line re why
    while IFS= read -r line; do
        case "$line" in ''|'#'*) continue ;; esac
        re="${line%% # *}"; why="${line#* # }"
        [ "$re" != "$line" ] && [ -n "$why" ] || continue
        if printf '%s' "$1" | grep -qE -- "^($re)$"; then
            printf '%s' "$why"; return 0
        fi
    done < "$ALLOW_FILE"
    return 1
}
warn_allowed() {        # warn_allowed <text> <reason>
    printf '  WARN  %s is allowed to fail: %s\n' "$1" "$2"
    [ -n "${GITHUB_ACTIONS:-}" ] && printf '::warning::%s is on the smoke allow-list: %s\n' "$1" "$2"
    return 0
}

# ── running the installer ────────────────────────────────────────────────────
# script(1) is what gives install.sh the controlling terminal a CI step lacks.
# --no-color --ascii make the transcript greppable and stable; the extra Enters
# are only there in case a prompt ever does appear.
# Sets RC, and leaves the cleaned transcript in $LOGS/<name>.log.
RC=0
run_logged() {          # run_logged <name> <install.sh args...>
    local name="$1"; shift
    printf '\n\n\n\n\n' | script -qec "bash install.sh $* --no-color --ascii" /dev/null \
        | tee "$LOGS/$name.raw"
    RC=${PIPESTATUS[1]}
    tr -d '\r' < "$LOGS/$name.raw" | sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g' > "$LOGS/$name.log"
}

# ── what a plan or an install transcript must not say ────────────────────────
# The plan has no row for "this package does not exist" — it says "install X"
# for anything not installed — so a renamed package is only caught by the real
# install. What the plan can say is that something is known to be unbuildable.
check_plan() {          # check_plan <name>
    local f="$LOGS/$1.log" hits
    [ "$RC" -eq 0 ] && pass "$1: exits 0" || flunk "$1: exited $RC"
    grep -q 'dry run' "$f" && pass "$1: reached the plan" || flunk "$1: never reached the plan"
    hits=$(grep -niE "will fail|not found|cannot be found|can't be found|unavailable|no such package|unable to locate|not available" "$f" | head -20)
    [ -z "$hits" ] && pass "$1: no row says a package cannot be resolved" \
        || flunk "$1: rows that say something cannot be resolved" "$hits"
}

# Failure wording is install.sh's summary: "Failed (n): a, b", the unattended
# AUR signature skip, a self-update that failed, and bash's own report of a
# crash inside install.sh. (Not "command not found": vendor scripts print it
# for their own probes.)
check_install() {       # check_install <name>
    local f="$LOGS/$1.log" line items it why unallowed=0 l
    line=$(grep -E 'Failed \([0-9]+\):' "$f" | head -1)
    if [ -n "$line" ]; then
        items=$(printf '%s' "$line" | sed -E 's/.*Failed \([0-9]+\): *//')
        while IFS= read -r it; do
            [ -n "$it" ] || continue
            if why=$(allowed "$it"); then warn_allowed "$it" "$why"
            else unallowed=1; flunk "$1: $it failed to install"; fi
        # %s\n: read drops a last line with no newline, which made a single
        # failed item pass as "only allow-listed failures".
        done < <(printf '%s\n' "$items" | sed 's/, /\n/g')
    fi
    if [ "$RC" -eq 0 ]; then pass "$1: exits 0"
    elif [ -n "$line" ] && [ "$unallowed" -eq 0 ]; then pass "$1: exit $RC, but only for allow-listed failures"
    else flunk "$1: exited $RC"; fi
    for l in 'Installed WITHOUT signature verification' 'Update failed, kept the installed version' \
             'Nothing was installed' 'unbound variable' 'install\.sh: line [0-9]+'; do
        grep -qE -- "$l" "$f" && flunk "$1: transcript says '$l'" "$(grep -nE -- "$l" "$f" | head -3)"
    done
    return 0
}

# ── detection ────────────────────────────────────────────────────────────────
porcelain() { bash install.sh --list --porcelain; }

# The names a section is expected to contain: everything the machine offers when
# the selection was "all", otherwise the list as given.
expected_names() {      # expected_names <config|tool|app> <selection> <porcelain-file>
    if [ "$2" = all ]; then awk -F'\t' -v s="$1" '$1==s {print $2}' "$3"
    else printf '%s' "$2" | tr ', ' '\n\n' | grep .; fi
}

# What the installer itself says is installed. `--X=installed` is the update
# run's keyword: it goes through item_probe and item_installed (and, for
# configs, config_state), which is exactly the code under test. The dry run
# prints the resulting selection; configs and tools by key, apps by label.
detected_line() {       # detected_line <heading> <file>
    sed -n "s/.*[^A-Za-z]$1: //p" "$2" | head -1 | sed 's/, /\n/g' | grep .
}

check_detected() {      # check_detected <configs> <tools> <apps>  (each: all | a,b | empty)
    local pf="$LOGS/porcelain.txt" f="$LOGS/detect.log" sec sel head exp got miss n_exp n_got
    porcelain > "$pf" || { flunk "install.sh --list --porcelain failed"; return 0; }
    local saved=$RC
    run_logged detect "--dry-run --configs=installed --tools=installed --apps=installed" >/dev/null
    local rc=$RC; RC=$saved
    [ "$rc" -eq 0 ] || flunk "detection: the --configs=installed dry run exited $rc"
    for sec in config tool app; do
        case $sec in config) sel=$1; head=Configs ;; tool) sel=$2; head='Dep tools' ;; app) sel=$3; head=Apps ;; esac
        [ -n "$sel" ] && [ "$sel" != - ] || continue
        exp=$(expected_names "$sec" "$sel" "$pf" | sort -u)
        got=$(detected_line "$head" "$f" | sort -u)
        n_exp=$(printf '%s\n' "$exp" | grep -c .); n_got=$(printf '%s\n' "$got" | grep -c .)
        if [ "$sec" = app ]; then
            # Detected apps come back as labels. Counts decide; on a shortfall,
            # name the culprits by asking for each one on its own.
            if [ "$n_got" -ge "$n_exp" ]; then pass "detected: $n_got of $n_exp apps"
            else
                miss=""
                local a lab
                while IFS= read -r a; do
                    run_logged "detect-$a" "--dry-run --apps=$a" >/dev/null
                    lab=$(detected_line Apps "$LOGS/detect-$a.log")
                    printf '%s\n' "$got" | grep -qxF -- "$lab" || miss="$miss $a"
                done <<< "$exp"
                RC=$saved
                report_missing apps "$miss" "$n_got" "$n_exp"
            fi
        else
            miss=$(comm -23 <(printf '%s\n' "$exp") <(printf '%s\n' "$got") | tr '\n' ' ')
            if [ -z "${miss// /}" ]; then pass "detected: all $n_exp ${sec}s"
            else report_missing "${sec}s" "$miss" "$n_got" "$n_exp"; fi
        fi
    done
}
report_missing() {      # report_missing <what> "<keys>" <got> <exp>
    local k left=""
    for k in $2; do
        if why=$(allowed "$k"); then warn_allowed "$k" "$why"; else left="$left $k"; fi
    done
    [ -z "${left// /}" ] && pass "detected: $1, bar allow-listed" \
        || flunk "installed but not detected ($1; the installer detected $3, expected $4):${left}"
}

# ── the filesystem ───────────────────────────────────────────────────────────
# Every config the installer says it stowed: at least one link into this repo
# copy, none dangling. The path comes from porcelain: field 4 for a config, and
# for a tool or app with a theme the directory in field 6.
check_links() {         # check_links <repo-copy> <configs> <tools> <apps>  (selections, as for check_detected)
    local repo="$1" pf="$LOGS/porcelain.txt" sec name _probe where _flags dir t n bad=0 l sel
    [ -s "$pf" ] || porcelain > "$pf"
    local -A want=()
    for sec in config tool app; do
        case $sec in config) sel=$2 ;; tool) sel=$3 ;; app) sel=$4 ;; esac
        [ -n "$sel" ] && [ "$sel" != - ] || continue
        while IFS= read -r name; do want["$sec/$name"]=1; done < <(expected_names "$sec" "$sel" "$pf")
    done
    while IFS=$'\t' read -r sec name _probe where _flags dir _how; do
        [ -n "${want["$sec/$name"]:-}" ] || continue
        t=""
        case $sec in
            config) [ "$where" != - ] && t="${where/#\~/$HOME}" ;;
            tool|app) [ "$dir" != - ] && t="${XDG_CONFIG_HOME:-$HOME/.config}/$dir/" ;;
        esac
        [ -n "$t" ] || continue
        n=0
        if [ -L "${t%/}" ] && [[ "$(readlink -f "${t%/}")" == "$repo"/* ]]; then n=1
        elif [ -d "$t" ]; then
            while IFS= read -r l; do
                if [[ "$(readlink -f "$l")" == "$repo"/* ]]; then n=$((n+1))
                elif [ ! -e "$l" ]; then flunk "$sec $name: dangling link $l"; bad=1; fi
            done < <(find "$t" -type l)
        elif [ -L "$t" ] && [[ "$(readlink -f "$t")" == "$repo"/* ]]; then n=1
        fi
        [ "$n" -gt 0 ] || { flunk "$sec $name: nothing at ${t} resolves into $repo"; bad=1; }
    done < "$pf"
    [ "$bad" -eq 0 ] && pass "every stowed config resolves into $repo"
}

check_doctor() {        # check_doctor <name>
    local f="$LOGS/$1.log"
    bash doctor.sh > "$f" 2>&1 && pass "$1: doctor.sh exits 0" || flunk "$1: doctor.sh exited non-zero"
    grep -q 'no drift' "$f" && pass "$1: doctor.sh reports no drift" \
        || flunk "$1: doctor.sh does not say 'no drift'" "$(grep -iA8 drift "$f" | head -12)" \
            "what changed in the repo copy:" "$(git -C "$HOME/dotfiles" status --porcelain 2>&1 | head -20)" \
            "$(git -C "$HOME/dotfiles" diff 2>&1 | head -40)"
}

# After a full install the plan for the same selection must have nothing left
# to install. This is the plan's own detection (pkg_installed_snapshot), a
# second opinion on the keyword check above.
check_nothing_left() {  # check_nothing_left <name>
    local f="$LOGS/$1.log" hits
    hits=$(grep -nE '^ *\| +\. install ' "$f" | head -20)
    [ -z "$hits" ] && pass "$1: the plan has nothing left to install" \
        || flunk "$1: the plan still wants to install" "$hits"
}

# A second run must not install anything new. "Installing <x>..." as a substep
# is what a package install prints; the headings, and the config headers (an
# info line, not a substep), are not installs.
check_no_new_installs() {   # check_no_new_installs <name>
    local f="$LOGS/$1.log" hits
    hits=$(grep -E '^ *\| +> .*Installing ' "$f" \
        | grep -vE 'Installing (dep tools|applications|native|micro plugins|an AUR|build dep|prebuilt)' | head -20)
    [ -z "$hits" ] && pass "$1: installed nothing new" \
        || flunk "$1: a second run installed something" "$hits"
}

# The entries a selection names, as "section/name" keys of the caller's WANT.
want_keys() {           # want_keys <configs> <tools> <apps>
    local pf="$LOGS/porcelain.txt" sec sel name
    [ -s "$pf" ] || porcelain > "$pf"
    WANT=()
    for sec in config tool app; do
        case $sec in config) sel=$1 ;; tool) sel=$2 ;; app) sel=$3 ;; esac
        [ -n "$sel" ] && [ "$sel" != - ] || continue
        while IFS= read -r name; do WANT["$sec/$name"]=1; done < <(expected_names "$sec" "$sel" "$pf")
    done
}

pkg_files() {           # pkg_files <package> — every path it installed, or nothing
    if command -v pacman >/dev/null; then pacman -Qlq "$1" 2>/dev/null
    else dpkg -L "$1" 2>/dev/null; fi
}

# Installed is not working: paru-bin installed cleanly and could not start
# (libalpm.so.15). Every ELF executable an entry put on the machine has to find
# all of its shared libraries. ldd, so nothing is run and no display is needed,
# which is what lets the GUI apps be checked too. A library the package ships
# itself does not count as missing: Zoom and Slack point LD_LIBRARY_PATH at
# their own copies from a launcher. A curl CLI has no package, so its binary is
# run with --version instead; any exit but "cannot execute" (126/127) passes.
check_starts() {        # check_starts <configs> <tools> <apps>
    local pf="$LOGS/porcelain.txt" sec name probe where _f _d _h f b out rc lib n=0 skipped=()
    local -A WANT=() own=()
    want_keys "$1" "$2" "$3"
    local cpath; cpath=$(awk -F'\t' '$1=="var" && $2=="CURL_APP_PATH"{print $3}' "$pf")
    while IFS=$'\t' read -r sec name probe where _f _d _h; do
        [ -n "${WANT["$sec/$name"]:-}" ] || continue
        if [ "$where" = curl ]; then
            if ! b=$(PATH="$PATH:$cpath" command -v "$probe"); then flunk "$sec $name: $probe is not on PATH"; continue; fi
            out=$(timeout 30 "$b" --version </dev/null 2>&1); rc=$?
            if [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ] || grep -q 'error while loading shared libraries' <<< "$out"; then
                flunk "$sec $name: $b cannot start (exit $rc)" "$(head -3 <<< "$out")"
            fi
            n=$((n+1)); continue
        fi
        mapfile -t files < <(pkg_files "$probe")
        # A tarball or install-script tool has no package: its binary it is.
        if [ "${#files[@]}" -eq 0 ]; then
            b=$(PATH="$PATH:$cpath" command -v "$probe") || { skipped+=("$name"); continue; }
            files=("$(readlink -f "$b")")
        fi
        own=()
        for f in "${files[@]}"; do [ -n "${f##*/}" ] && own["${f##*/}"]=1; done
        for f in "${files[@]}"; do
            # Programs, not libraries: Arch installs plugin .so files
            # executable, and their optional dependencies are optional.
            case "${f##*/}" in *.so|*.so.*) continue ;; esac
            [ -f "$f" ] && [ -x "$f" ] && [ "$(head -c4 "$f" 2>/dev/null | tr -d '\0')" = $'\x7fELF' ] || continue
            while read -r lib; do
                [ -n "${own[$lib]:-}" ] && continue
                flunk "$sec $name: $f needs $lib, which is not installed"
            done < <(ldd "$f" 2>/dev/null | awk '/=> not found/{print $1}')
        done
        n=$((n+1))
    done < "$pf"
    pass "checked that $n entries' programs can load (ldd, or --version for a curl CLI)"
    [ "${#skipped[@]}" -eq 0 ] || printf '  NOTE  no package or binary to check for: %s\n' "${skipped[*]}"
}

# Run under a terminal, as a person would: an interactive shell without one
# prints job-control noise that is not ours. A terminal also sets TERM, which a
# CI step does not, and zsh-you-should-use's tput calls complain without it.
tty_out() { TERM=xterm-256color timeout 600 script -qec "$1" /dev/null </dev/null 2>&1 | tr -d '\r' | sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g'; }

# Linked is not loaded: each config, read by the version of its program this
# distro actually installed (Debian 12's tmux, kitty and Neovim are years
# behind Arch's). Only programs that can read their config without a display;
# Alacritty, WezTerm, rofi and ulauncher are covered by check_starts alone.
check_configs_load() {
    local x="${XDG_CONFIG_HOME:-$HOME/.config}" out bat rc
    # Where the curl CLIs and per-user installs (kitty.app) put their binaries,
    # none of which existed when this login shell set PATH.
    local PATH="$PATH:$(awk -F'\t' '$1=="var" && $2=="CURL_APP_PATH"{print $3}' "$LOGS/porcelain.txt")"
    if [ -L "$HOME/.zshrc" ] && command -v zsh >/dev/null; then
        tty_out 'zsh -i -c exit' >/dev/null     # the first start clones Zinit and its plugins
        out=$(tty_out 'zsh -i -c exit')
        [ -z "$out" ] && pass "zsh: our .zshrc starts silently" || flunk "zsh: a warm start of our .zshrc prints" "$(head -10 <<< "$out")"
    fi
    if [ -L "$HOME/.bashrc" ]; then
        out=$(tty_out 'bash -i -c exit' | grep -E 'command not found|No such file|syntax error|unbound variable|[Ee]rror')
        [ -z "$out" ] && pass "bash: our .bashrc starts without errors" || flunk "bash: our .bashrc prints errors" "$(head -10 <<< "$out")"
    fi
    if [ -e "$x/nvim/init.lua" ] && command -v nvim >/dev/null; then
        timeout 600 nvim --headless '+Lazy! sync' +qa >/dev/null 2>&1   # plugins install on the first start
        out=$(timeout 120 nvim --headless +qa 2>&1)
        [ -z "$out" ] && pass "nvim: init.lua loads in $(nvim --version | head -1)" || flunk "nvim: init.lua prints on a warm start" "$(head -10 <<< "$out")"
    fi
    if [ -e "$x/tmux/tmux.conf" ] && command -v tmux >/dev/null; then
        out=$(timeout 30 tmux -L smoke -f /dev/null start-server \; source-file "$x/tmux/tmux.conf" 2>&1)
        rc=$?; tmux -L smoke kill-server 2>/dev/null
        [ "$rc" -eq 0 ] && [ -z "$out" ] && pass "tmux: tmux.conf loads in $(tmux -V)" || flunk "tmux: tmux.conf does not load in $(tmux -V)" "$out"
    fi
    if [ -e "$x/kitty/kitty.conf" ] && command -v kitty >/dev/null; then
        out=$(timeout 60 kitty +runpy 'import sys; from kitty.config import load_config; load_config(sys.argv[-1])' "$x/kitty/kitty.conf" 2>&1)
        [ -z "$out" ] && pass "kitty: kitty.conf loads in $(kitty --version)" || flunk "kitty: kitty.conf has lines $(kitty --version) rejects" "$(head -10 <<< "$out")"
    fi
    if [ -e "$x/ghostty/config" ] && command -v ghostty >/dev/null; then
        out=$(timeout 60 ghostty +validate-config 2>&1) && [ -z "$out" ] \
            && pass "ghostty: config validates" || flunk "ghostty: +validate-config rejects our config" "$(head -10 <<< "$out")"
    fi
    if [ -L "$x/starship.toml" ] && command -v starship >/dev/null; then
        out=$(timeout 60 starship prompt 2>&1 >/dev/null | grep -v 'timed out')
        [ -z "$out" ] && pass "starship: starship.toml loads" || flunk "starship: starship.toml warns" "$(head -10 <<< "$out")"
    fi
    if [ -e "$x/fastfetch/config.jsonc" ] && command -v fastfetch >/dev/null; then
        out=$(timeout 60 fastfetch --pipe 2>&1 >/dev/null)
        [ -z "$out" ] && pass "fastfetch: config loads" || flunk "fastfetch: config prints errors" "$(head -10 <<< "$out")"
    fi
    bat=$(command -v bat || command -v batcat)
    if [ -e "$x/bat/config" ] && [ -n "$bat" ]; then
        out=$(echo x | timeout 60 "$bat" --paging=never 2>&1 >/dev/null)
        [ -z "$out" ] && pass "bat: config and theme load" || flunk "bat: config or theme rejected" "$(head -10 <<< "$out")"
    fi
    if [ -L "$HOME/.gitconfig" ]; then
        git config --global --list >/dev/null 2>&1 && pass "git: .gitconfig parses" || flunk "git: .gitconfig does not parse"
    fi
}

# What each entry actually is on this distro, for the per-distro table: the
# package manager's version, or the binary's own --version for anything
# installed outside it (curl CLIs, release tarballs, kitty.app).
record_versions() {     # record_versions <configs> <tools> <apps>
    local pf="$LOGS/porcelain.txt" sec name probe where _f _d _h v b
    local -A WANT=()
    want_keys "$1" "$2" "$3"
    local cpath; cpath=$(awk -F'\t' '$1=="var" && $2=="CURL_APP_PATH"{print $3}' "$pf")
    : > "$LOGS/versions.txt"
    while IFS=$'\t' read -r sec name probe where _f _d _h; do
        [ -n "${WANT["$sec/$name"]:-}" ] || continue
        v=""
        if [ "$where" != curl ]; then
            if command -v pacman >/dev/null; then v=$(pacman -Q "$probe" 2>/dev/null | awk '{print $2}')
            else v=$(dpkg-query -W -f '${Version}' "$probe" 2>/dev/null); fi
        fi
        if [ -z "$v" ] && b=$(PATH="$PATH:$cpath" command -v "$probe"); then
            v=$(timeout 15 "$b" --version </dev/null 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
        fi
        printf '%s\t%s\t%s\n' "$sec" "$name" "${v:--}" >> "$LOGS/versions.txt"
    done < "$pf"
}
