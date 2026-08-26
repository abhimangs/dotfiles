#!/usr/bin/env bash
# The lint step of .github/workflows/ci.yml, as a script — so the list of files
# lives in one place instead of once per step, and so it can be run by hand
# before pushing:
#
#   .github/lint.sh            # against the previous commit
#   .github/lint.sh origin/main
#
# Two passes, and they answer different questions. The error pass is the gate:
# these scripts predate any linting, so failing on style would mean a
# permanently red pipeline nobody reads. The advisory pass is everything else —
# reported as GitHub annotations, but only on lines this change actually
# touched. There are ~90 pre-existing findings; annotating all of them on every
# pull request is how a linter gets muted.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# zsh/.zshrc is excluded: shellcheck has no zsh dialect and would flag every
# setopt/zstyle/bindkey line. bash/.bashrc is sourced and has no shebang, hence
# its own invocation with -e SC2148.
FILES=(install.sh linux.sh doctor.sh .github/lint.sh .github/smoke.sh tests/*.sh)

# Two invocations, one status. Returning only the second's would have made the
# gate below pass with errors in install.sh — the one file it exists for.
# (The parameter list is spelled out rather than named after the linter: a
# comment opening with its name is read as a directive to it.)
shellcheck_all() {      # <flags...>
    local rc=0
    shellcheck "$@" -s bash "${FILES[@]}" || rc=$?
    shellcheck "$@" -s bash -e SC2148 bash/.bashrc || rc=$?
    return "$rc"
}

command -v shellcheck >/dev/null || { echo "lint: shellcheck is not installed" >&2; exit 127; }
shellcheck --version | sed -n '2p'

# ── advisory pass ────────────────────────────────────────────────────────────
# Non-zero here means "found something", which is the normal case.
shellcheck_all -f gcc > "${TMPDIR:-/tmp}/advisory.$$" 2>/dev/null
advisory="${TMPDIR:-/tmp}/advisory.$$"
trap 'rm -f "$advisory" "$advisory.changed"' EXIT

# Every line the diff added or altered, as file:line. A finding is pre-existing
# until someone edits the line it sits on.
base="${1:-${BASE_REF:-}}"
if [ -z "$base" ] || ! git rev-parse --verify -q "${base}^{commit}" >/dev/null; then
    base=$(git rev-parse --verify -q 'HEAD^' 2>/dev/null)
fi
if [ -n "$base" ]; then
    # -U0 so a hunk covers only the changed lines, not three lines of context
    # either side — context lines are by definition not what this change did.
    git diff -U0 "$base" HEAD 2>/dev/null | awk '
        /^\+\+\+ b\// { f = substr($0, 7); next }
        /^@@/ {
            # @@ -old,n +new,m @@ — the third field is the new-side range.
            split($3, h, ",")
            start = substr(h[1], 2) + 0
            count = (h[2] == "" ? 1 : h[2] + 0)
            for (i = 0; i < count; i++) print f ":" start + i
        }' > "$advisory.changed"
else
    : > "$advisory.changed"
fi

total=$(grep -c . "$advisory")
shown=0
while IFS= read -r finding; do
    [ -n "$finding" ] || continue
    where=$(printf '%s' "$finding" | cut -d: -f1,2)
    grep -qxF "$where" "$advisory.changed" || continue
    shown=$((shown + 1))
    [ -n "${GITHUB_ACTIONS:-}" ] || { printf '%s\n' "$finding"; continue; }
    printf '%s\n' "$finding" | sed -E \
        -e 's/^([^:]+):([0-9]+):([0-9]+): (note|warning|info): (.*)$/::warning file=\1,line=\2,col=\3::\5/' \
        -e 's/^([^:]+):([0-9]+):([0-9]+): error: (.*)$/::error file=\1,line=\2,col=\3::\4/'
done < "$advisory"

printf 'advisory: %s finding(s), %s on lines this change touched\n' "$total" "$shown"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "### shellcheck"
        echo
        echo "\`$total\` advisory finding(s) in total, \`$shown\` on lines this change touched."
    } >> "$GITHUB_STEP_SUMMARY"
fi

# ── the gate ─────────────────────────────────────────────────────────────────
# Last, so the annotations above are emitted even when this fails the step.
shellcheck_all -S error
