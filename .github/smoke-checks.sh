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
        done < <(printf '%s' "$items" | sed 's/, /\n/g')
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
    while IFS=$'\t' read -r sec name _probe where _flags dir; do
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
        || flunk "$1: doctor.sh does not say 'no drift'" "$(grep -iA8 drift "$f" | head -12)"
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
