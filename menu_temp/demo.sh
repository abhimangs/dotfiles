#!/usr/bin/env bash
# Menu design gallery — throwaway. Nothing here is wired into install.sh.
#
#   bash demo.sh          pick a design from a list, try it, come back
#   bash demo.sh 4        run design 4 directly
#   bash demo.sh all      run all ten back to back
#
# Delete the whole menu_temp/ folder when you have picked one.

set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/demo.sh"
export SELF
source "$(dirname "$SELF")/menus.sh"

# fzf calls back into this script for the preview panes.
case "${1:-}" in
    --detail) shift; detail "$@"; exit 0 ;;
    --plan)   shift; plan   "$@"; exit 0 ;;
    --cart)   shift; cart   "$@"; exit 0 ;;
esac

DESIGNS=(
"1|classic+|today's menu, tightened: border label, footer keys, inline count"
"2|preview|details pane on the right — package, stow target, state, files"
"3|grouped|category headings: terminals / shells / desktop / tools"
"4|cards|two-line entries with a divider, more air per item"
"5|state|right-hand column: already installed vs new"
"6|wizard|full screen, every section boxed, 'step 1 of 3'"
"7|minimal|no boxes, one rule, ghost text, lots of air"
"8|plan pane|bottom pane showing the steps that config will run"
"9|banner|ASCII wordmark inside the frame, above the list"
"10|live cart|selections collect in a pane on the right as you toggle"
)

run_one() {
    local n="$1"
    case "$n" in
        1) d1_classic ;;   2) d2_preview ;;  3) d3_grouped ;;
        4) d4_cards ;;     5) d5_state ;;    6) d6_wizard ;;
        7) d7_minimal ;;   8) d8_planpane ;; 9) d9_banner ;;
        10) d10_cart ;;
        *) echo "no design $n"; return 1 ;;
    esac
}

show_result() {
    local n="$1"; shift
    printf '\n  %s\n' "${MAUVE}${B}design ${n}${R} ${DIM}returned:${R}"
    if [ "$#" -eq 0 ]; then
        printf '  %s\n\n' "${DIM}(nothing)${R}"
    else
        printf '  %s\n\n' "${GREEN}$*${R}"
    fi
}

case "${1:-}" in
    "")
        while true; do
            clear
            printf '\n  %s\n' "${MAUVE}${B}menu designs${R}  ${DIM}· pick one to try, ctrl-c to stop${R}"
            printf '  %s\n\n' "${DIM}each opens the real config list — toggle with enter, confirm with ctrl-j${R}"
            choice=$(
                for d in "${DESIGNS[@]}"; do
                    printf '%s%2s%s  %s%-11s%s %s%s%s\n' \
                        "$MAUVE" "$(f "$d" 1)" "$R" \
                        "${B}${TEXT}" "$(f "$d" 2)" "$R" \
                        "$DIM" "$(f "$d" 3)" "$R"
                done | fzf --ansi --height=45% --reverse --border=rounded \
                    --border-label=" gallery " --border-label-pos=3 \
                    --color="$FZF_CLR" --highlight-line \
                    --prompt="  " --pointer="❯" --info=hidden \
                    --footer="enter to open a design" \
                | sed -e 's/\x1b\[[0-9;]*m//g' | grep -oE '^ *[0-9]+' | tr -d ' '
            )
            [ -z "$choice" ] && { echo; exit 0; }
            mapfile -t picked < <(run_one "$choice" | keys_of)
            show_result "$choice" "${picked[@]}"
            printf '  %s' "${DIM}enter for the gallery, q to quit: ${R}"
            read -r k </dev/tty
            [[ "$k" == q* ]] && { echo; exit 0; }
        done
        ;;
    all)
        for n in 1 2 3 4 5 6 7 8 9 10; do
            mapfile -t picked < <(run_one "$n" | keys_of)
            show_result "$n" "${picked[@]}"
        done
        ;;
    *)
        mapfile -t picked < <(run_one "$1" | keys_of)
        show_result "$1" "${picked[@]}"
        ;;
esac
