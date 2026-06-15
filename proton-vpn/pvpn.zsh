# pvpn — ProtonVPN CLI wrapper
# Catppuccin Mocha · zero-drop switching · kill-switch safe

# ── Catppuccin Mocha true-color ──────────────────────────────────
_R='\033[0m' _B='\033[1m' _D='\033[2m'

_mc_text='\033[38;2;205;214;244m'
_mc_sub='\033[38;2;166;173;200m'
_mc_ov='\033[38;2;127;132;156m'
_mc_surf='\033[38;2;69;71;90m'
_mc_mauve='\033[38;2;203;166;247m'
_mc_blue='\033[38;2;137;180;250m'
_mc_sapp='\033[38;2;116;199;236m'
_mc_green='\033[38;2;166;227;161m'
_mc_peach='\033[38;2;250;179;135m'
_mc_red='\033[38;2;243;139;168m'
_mc_yellow='\033[38;2;249;226;175m'
_mc_teal='\033[38;2;148;226;213m'
_mc_lav='\033[38;2;180;190;254m'
_mc_pink='\033[38;2;245;194;231m'

# ── State ────────────────────────────────────────────────────────
_PVPN_DIR="${XDG_RUNTIME_DIR:-/tmp}/pvpn"
_PVPN_LVL="$_PVPN_DIR/level"
_PVPN_LAST="$_PVPN_DIR/last"
_PVPN_TS="$_PVPN_DIR/ts"
mkdir -p "$_PVPN_DIR"

# Active level lives in _PVPN_LVL (cleared on intentional `pvpn off`).
# _PVPN_LAST persists across off/drops so `pvpn reconnect` can always restore.
_pvpn_set_level()   { printf '%s' "$1" > "$_PVPN_LVL"; printf '%s' "$1" > "$_PVPN_LAST"; }
_pvpn_get_level()   { [[ -f "$_PVPN_LVL" ]] && printf '%s' "$(<"$_PVPN_LVL")" || printf '—'; }
_pvpn_get_last()    { [[ -f "$_PVPN_LAST" ]] && printf '%s' "$(<"$_PVPN_LAST")" || printf '—'; }
_pvpn_set_time()    { date +%s > "$_PVPN_TS"; }
_pvpn_clear_state() { printf '—' > "$_PVPN_LVL"; rm -f "$_PVPN_TS"; }

_pvpn_uptime() {
    [[ ! -f "$_PVPN_TS" ]] && { printf '—'; return; }
    local e=$(( $(date +%s) - $(<"$_PVPN_TS") ))
    local h=$(( e/3600 )) m=$(( (e%3600)/60 )) s=$(( e%60 ))
    (( h > 0 )) && printf '%dh %02dm' $h $m || printf '%dm %02ds' $m $s
}

# Parallel dual IP fetch
_pvpn_get_ips() {
    local t4a t4b t6; t4a=$(mktemp); t4b=$(mktemp); t6=$(mktemp)
    # Both IPv4 endpoints race in parallel — whichever responds first wins
    curl -s --max-time 8 -4 https://api.ipify.org  2>/dev/null | tr -d '[:space:]' > "$t4a" &
    local pa=$!
    curl -s --max-time 8 -4 https://ifconfig.me    2>/dev/null | tr -d '[:space:]' > "$t4b" &
    local pb=$!
    curl -s --max-time 8 -6 https://api6.ipify.org 2>/dev/null | tr -d '[:space:]' > "$t6"  &
    local p6=$!
    wait $pa $pb $p6
    # Pick first non-empty IPv4 result
    local ip4; ip4=$(<"$t4a")
    [[ -z "$ip4" ]] && ip4=$(<"$t4b")
    local ip6; ip6=$(<"$t6")
    rm -f "$t4a" "$t4b" "$t6"
    printf '%s\t%s' "${ip4:-—}" "${ip6:-—}"
}

# Country code → flag emoji
_pvpn_flag() {
    local cc="${1:u}"
    [[ ${#cc} -ne 2 ]] && return
    local a=$(( $(printf '%d' "'${cc[1]}") - 65 + 127462 ))
    local b=$(( $(printf '%d' "'${cc[2]}") - 65 + 127462 ))
    printf "\\U$(printf '%08X' $a)\\U$(printf '%08X' $b)"
}

# ── Rendering helpers ────────────────────────────────────────────

_pvpn_div() {
    printf "  ${_mc_surf}────────────────────────────────────────────${_R}\n"
}

# Two-column row: fixed column widths, no double-printing.
# $1=label1  $2=raw-value1  $3=ansi-color-for-val1
# $4=label2  $5=raw-value2  $6=ansi-color-for-val2
# Col1 value padded to 24 chars, labels 8 chars.
_pvpn_row() {
    local L1="$1" V1="$2" C1="$3"
    local L2="$4" V2="$5" C2="$6"
    local pad=$(( 24 - ${#V1} ))
    (( pad < 1 )) && pad=1
    printf "  ${_mc_sub}%-8s${_R}  ${C1}%s${_R}%*s${_mc_sub}%-9s${_R}  ${C2}%s${_R}\n" \
        "$L1" "$V1" "$pad" "" "$L2" "$V2"
}

_pvpn_row1() {
    # Single-column row
    printf "  ${_mc_sub}%-8s${_R}  ${2}%s${_R}\n" "$1" "$3"
}

# Return ANSI color code only (no value, no reset) — used with _pvpn_row
_pvpn_load_col() {
    local n; n=$(printf '%s' "$1" | tr -d '%' | tr -d ' ')
    [[ -z "$n" || ! "$n" =~ ^[0-9]+$ ]] && printf '%s' "$_mc_ov" && return
    (( n >= 80 )) && printf '%s' "$_mc_red"    && return
    (( n >= 50 )) && printf '%s' "$_mc_yellow" && return
    printf '%s' "$_mc_green"
}

_pvpn_cval_col() {
    case "$1" in
        off|disabled) printf '%s' "$_mc_red"   ;;
        —|"")         printf '%s' "$_mc_ov"    ;;
        *)            printf '%s' "$_mc_green"  ;;
    esac
}

_pvpn_level_col() {
    case "$1" in
        ghost)   printf '%s' "${_mc_mauve}${_B}"  ;;
        home)    printf '%s' "${_mc_sapp}${_B}"   ;;
        fast)    printf '%s' "${_mc_green}${_B}"  ;;
        tor)     printf '%s' "${_mc_peach}${_B}"  ;;
        —|"")    printf '%s' "$_mc_ov"             ;;
        *)       printf '%s' "${_mc_teal}${_B}"   ;;
    esac
}

# ── Kill-switch safe config apply ────────────────────────────────
_pvpn_is_connected() { protonvpn status 2>&1 | grep -qi '^status: connected'; }
_pvpn_current_ks()   { protonvpn config list 2>&1 | grep -i 'kill-switch' | awk '{print $NF}'; }

_pvpn_ensure_ks() {
    local want="$1" have; have=$(_pvpn_current_ks)
    if [[ "$have" != "$want" ]] && _pvpn_is_connected; then
        printf "  ${_mc_yellow}⚠  kill-switch value changing — brief reconnect${_R}\n"
        protonvpn disconnect > /dev/null 2>&1
    fi
    protonvpn config set kill-switch "$want" > /dev/null 2>&1
}

_pvpn_apply() {
    # $1=kill-switch  $2=netshield  $3=ipv6  $4=vpn-accel  $5=port-fw  $6=nat  $7=custom-dns
    _pvpn_ensure_ks "$1"
    # Fire all remaining config sets in parallel — each takes ~1s, no reason to wait
    # setopt NO_MONITOR suppresses "[1] done ..." job notifications in zsh
    {
        setopt LOCAL_OPTIONS NO_MONITOR
        protonvpn config set netshield       "$2" > /dev/null 2>&1 &
        protonvpn config set ipv6            "$3" > /dev/null 2>&1 &
        protonvpn config set vpn-accelerator "$4" > /dev/null 2>&1 &
        protonvpn config set port-forwarding "$5" > /dev/null 2>&1 &
        protonvpn config set moderate-nat    "$6" > /dev/null 2>&1 &
        protonvpn config set custom-dns      "$7" > /dev/null 2>&1 &
        wait
    }
}

_pvpn_do_connect() {
    local level="$1"; shift
    local attempt
    for attempt in 1 2 3; do
        if protonvpn connect "$@"; then
            _pvpn_set_level "$level"
            _pvpn_set_time
            return 0
        fi
        if (( attempt < 3 )); then
            printf "  ${_mc_yellow}⚠  attempt %d failed — retrying...${_R}\n" "$attempt"
        fi
    done
    printf "\n  ${_mc_red}✗  connection failed after 3 attempts${_R}\n\n"
    return 1
}

# Single-column labeled row: label (fixed 10 chars) + colored value
_pvpn_line() {
    local label="$1" col="$2" val="$3"
    printf "  ${_mc_sub}%-10s${_R}  ${col}%s${_R}\n" "$label" "$val"
}

# ── Compact connect success message ─────────────────────────────
_pvpn_connect_ok() {
    printf "\n  ${_mc_teal}✓${_R}  %b  ${_mc_ov}connected · run ${_mc_lav}pvpn${_R}${_mc_ov} for full status${_R}\n\n" "$1"
}

# ── Dashboard ────────────────────────────────────────────────────

_pvpn_dashboard() {
    local raw; raw=$(protonvpn status 2>&1)
    local level; level=$(_pvpn_get_level)
    local connected=0
    echo "$raw" | grep -qi '^status: connected' && connected=1

    local server load protocol ip4 ip6 uptime cfg ks ns cfg_ipv6 accel pf nat cdns
    if (( connected )); then
        server=$(echo   "$raw" | grep -i '^server:'  | cut -d: -f2- | xargs)
        load=$(echo     "$raw" | grep -i '^load'     | cut -d: -f2- | xargs)
        protocol=$(echo "$raw" | grep -i '^protocol' | cut -d: -f2- | xargs)
        uptime=$(_pvpn_uptime)
        local _ips; _ips=$(_pvpn_get_ips)
        ip4="${_ips%%	*}"
        ip6="${_ips##*	}"
    fi
    cfg=$(protonvpn config list 2>&1)
    ks=$(echo       "$cfg" | grep -i 'kill-switch'     | awk '{print $NF}')
    ns=$(echo       "$cfg" | grep -i 'netshield'       | awk '{print $NF}')
    cfg_ipv6=$(echo "$cfg" | grep -i '^ipv6'           | awk '{print $NF}')
    accel=$(echo    "$cfg" | grep -i 'vpn-accelerator' | awk '{print $NF}')
    pf=$(echo       "$cfg" | grep -i 'port-forwarding' | awk '{print $NF}')
    nat=$(echo      "$cfg" | grep -i 'moderate-nat'    | awk '{print $NF}')
    local _cdns_raw; _cdns_raw=$(echo "$cfg" | grep -i 'custom-dns' | awk '{$1=""; print}' | xargs)
    # Show "ProtonVPN" when custom-dns is off, otherwise show the IP(s)
    if [[ "$_cdns_raw" == "off" || -z "$_cdns_raw" ]]; then
        cdns=""
    else
        cdns="$_cdns_raw"
    fi

    # ── Header ───────────────────────────────────────────────────
    printf "\n"
    printf "  ${_mc_mauve}${_B}pvpn${_R}  ${_mc_ov}protonvpn${_R}\n"
    printf "\n"
    _pvpn_div

    # ── Connection ───────────────────────────────────────────────
    if (( connected )); then
        local cc; cc=$(echo "$server" | grep -oP '^[A-Z]{2}(?=-|#)' | head -1)
        local flag; flag=$(_pvpn_flag "$cc")
        local load_val="${load:-—}"
        local load_col; load_col=$(_pvpn_load_col "$load_val")

        _pvpn_line "status"    "$_mc_teal"              "✓ connected"
        _pvpn_line "level"     "$(_pvpn_level_col "$level")"  "$level"
        printf "\n"
        _pvpn_line "server"    "$_mc_blue"              "${flag:+$flag }${server}"
        _pvpn_line "uptime"    "$_mc_lav"               "${uptime:-—}"
        _pvpn_line "load"      "$load_col"              "$load_val"
        _pvpn_line "protocol"  "$_mc_sapp"              "${protocol:-—}"
        printf "\n"
        _pvpn_line "ipv4"      "$_mc_pink"              "${ip4:-—}"
        _pvpn_line "ipv6"      "$_mc_pink"              "${ip6:-—}"
    else
        _pvpn_line "status"    "$_mc_red"   "✗ disconnected"
        _pvpn_line "level"     "$_mc_ov"    "—"
        printf "\n"
        _pvpn_line "server"    "$_mc_ov"    "—"
        _pvpn_line "uptime"    "$_mc_ov"    "—"
        _pvpn_line "load"      "$_mc_ov"    "—"
        _pvpn_line "protocol"  "$_mc_ov"    "—"
        printf "\n"
        _pvpn_line "ipv4"      "$_mc_ov"    "—"
        _pvpn_line "ipv6"      "$_mc_ov"    "—"
    fi

    printf "\n"
    _pvpn_div

    # ── Config ───────────────────────────────────────────────────
    _pvpn_line "kill-sw"   "$(_pvpn_cval_col "$ks")"        "${ks:-—}"
    _pvpn_line "netshield" "$(_pvpn_cval_col "$ns")"        "${ns:-—}"
    _pvpn_line "ipv6"      "$(_pvpn_cval_col "$cfg_ipv6")"  "${cfg_ipv6:-—}"
    _pvpn_line "vpn-accel" "$(_pvpn_cval_col "$accel")"     "${accel:-—}"
    _pvpn_line "port-fw"   "$(_pvpn_cval_col "$pf")"        "${pf:-—}"
    _pvpn_line "nat"       "$(_pvpn_cval_col "$nat")"        "${nat:-—}"
    _pvpn_line "dns"       "$(_pvpn_cval_col "${cdns%% *}")" "${cdns:-ProtonVPN}"

    printf "\n"
    _pvpn_div

    # ── Levels bar ───────────────────────────────────────────────
    local _lbar() {
        local name="$1" col="$2"
        if [[ "$level" == "$name" ]]; then
            printf "  ${_mc_teal}▸  ${col}${_B}%s${_R}\n" "$name"
        else
            printf "     ${_mc_ov}%s${_R}\n" "$name"
        fi
    }
    _lbar tor     "$_mc_peach"
    _lbar ghost   "$_mc_mauve"
    _lbar home    "$_mc_sapp"
    _lbar fast    "$_mc_green"
    if [[ "$level" == "—" || "$level" == "" ]]; then
        printf "  ${_mc_teal}▸  ${_mc_red}off${_R}\n"
    else
        printf "     ${_mc_ov}off${_R}\n"
    fi

    printf "\n"
    _pvpn_div
    printf "  ${_mc_ov}pvpn --help  ·  pvpn config  ·  pvpn reconnect  ·  pvpn connect <CC> [-ghost|-p2p|-random]${_R}\n\n"
}

# ── Help ─────────────────────────────────────────────────────────
_pvpn_help() {
    printf "\n"
    printf "  ${_mc_mauve}${_B}pvpn${_R}  ${_mc_ov}ProtonVPN wrapper · Catppuccin Mocha · zero-drop switching${_R}\n\n"
    _pvpn_div

    printf "  ${_mc_lav}${_B}LEVELS${_R}  ${_mc_ov}most private → fastest${_R}\n\n"
    printf "  ${_mc_peach}${_B}tor${_R}      you → VPN → Tor → internet\n"
    printf "           ${_mc_ov}ks:standard · netshield:malware-ads-trackers · ipv6:off · accel:on · pfw:off · nat:off · dns:off${_R}\n"
    printf "           ${_mc_ov}slowest — use for maximum anonymity only${_R}\n\n"
    printf "  ${_mc_mauve}${_B}ghost${_R}    you → Secure Core hub → fastest exit server → internet\n"
    printf "           ${_mc_ov}ks:standard · netshield:malware-ads-trackers · ipv6:off · accel:on · pfw:off · nat:off · dns:off${_R}\n"
    printf "           ${_mc_ov}even a compromised exit server cannot reveal your real IP${_R}\n\n"
    printf "  ${_mc_sapp}${_B}home${_R}     India · Mumbai · lowest latency for IN services\n"
    printf "           ${_mc_ov}ks:standard · netshield:malware-ads-trackers · ipv6:off · accel:on · pfw:off · nat:off · dns:off${_R}\n\n"
    printf "  ${_mc_green}${_B}fast${_R}     Singapore · speed-first\n"
    printf "           ${_mc_ov}ks:standard · netshield:malware-only · ipv6:on · accel:on · pfw:off · nat:off · dns:off${_R}\n\n"
    printf "  ${_mc_red}off${_R}      Disconnect · restores full internet · kill-switch lifts\n\n"
    printf "  ${_mc_ov}  connect <CC> (no flag) — uses your existing pvpn config as-is, only enforces kill-switch standard${_R}\n"
    printf "  ${_mc_ov}  connect <CC> -ghost/-random — max-security config (same as ghost preset)${_R}\n"
    printf "  ${_mc_ov}  connect <CC> -p2p — max-security + port-forwarding:on + moderate-nat:on${_R}\n\n"

    _pvpn_div
    printf "  ${_mc_lav}${_B}COMMANDS${_R}\n\n"
    printf "  ${_mc_teal}pvpn${_R}                          Dashboard\n"
    printf "  ${_mc_teal}pvpn <level>${_R}                  Connect at level — tor ghost home fast\n"
    printf "  ${_mc_teal}pvpn off${_R}                      Disconnect\n"
    printf "  ${_mc_teal}pvpn reconnect${_R} ${_mc_ov}(${_mc_teal}r${_mc_ov})${_R}         Restore last level — after WiFi switch / sleep / drop\n"
    printf "  ${_mc_teal}pvpn connect <CC>${_R}             Fastest server in country\n"
    printf "  ${_mc_teal}pvpn connect <CC> -ghost${_R}      Secure Core into that country\n"
    printf "  ${_mc_teal}pvpn connect <CC> -p2p${_R}        P2P-optimized server in that country\n"
    printf "  ${_mc_teal}pvpn connect <CC> -random${_R}     Random server in that country\n"
    printf "  ${_mc_teal}pvpn countries${_R}                List all country codes with flags\n"
    printf "  ${_mc_teal}pvpn config${_R}                   Interactive config TUI — toggle every setting\n"
    printf "  ${_mc_teal}pvpn --help${_R}                   This page\n\n"
    printf "  ${_mc_ov}  Note: -tor is not available on connect — Tor servers are a fixed pool,\n"
    printf "        country selection is not supported. Use 'pvpn tor' instead.${_R}\n\n"

    _pvpn_div
    printf "  ${_mc_lav}${_B}KILL SWITCH${_R}\n\n"
    printf "  Blocks all internet the moment the VPN tunnel drops — before any packet leaks.\n"
    printf "  Restores automatically when you run ${_mc_teal}pvpn off${_R} (intentional disconnect).\n"
    printf "  ${_mc_ov}  Values: ${_mc_text}standard${_R}${_mc_ov} (active) · ${_mc_red}off${_R}${_mc_ov} (unprotected)${_R}\n"
    printf "  ${_mc_yellow}  ⚠  All pvpn levels use standard — switching between them is zero-drop.${_R}\n"
    printf "  ${_mc_ov}  After a drop (WiFi switch / sleep) the CLI does ${_mc_text}not${_mc_ov} auto-reconnect — it just\n"
    printf "    keeps blocking. Your real IP stays hidden. Run ${_mc_teal}pvpn reconnect${_R}${_mc_ov} to restore.${_R}\n"
    printf "  ${_mc_ov}  ${_mc_text}advanced${_mc_ov} kill switch (blocks even before first connect, survives reboot) is\n"
    printf "    GUI-only — the Linux CLI exposes ${_mc_text}standard${_mc_ov} only.${_R}\n\n"

    _pvpn_div
    printf "  ${_mc_lav}${_B}NETSHIELD${_R}  ${_mc_ov}DNS-level — blocks before traffic leaves your device${_R}\n\n"
    printf "  ${_mc_green}malware-ads-trackers${_R}  ${_mc_ov}(ghost / home / tor)${_R}\n"
    printf "    Blocks malware domains — stops ransomware, spyware, phishing at DNS level\n"
    printf "    Blocks ad networks — no ad JS, no ad images, no ad tracking pixels\n"
    printf "    Blocks tracker domains — Google Analytics, Meta Pixel, etc. blocked entirely\n\n"
    printf "  ${_mc_yellow}malware-only${_R}  ${_mc_ov}(fast)${_R}\n"
    printf "    Blocks malware domains only — ads and trackers still load\n"
    printf "    Lower DNS lookup overhead — slightly faster browsing\n\n"
    printf "  ${_mc_red}off${_R}\n"
    printf "    No DNS filtering — maximum compatibility, zero protection\n\n"
    printf "  ${_mc_ov}  NetShield uses ProtonVPN's own DNS servers. All DNS queries go through\n"
    printf "    the encrypted VPN tunnel — your ISP cannot see what you look up.${_R}\n\n"

    _pvpn_div
    printf "  ${_mc_lav}${_B}DNS${_R}\n\n"
    printf "  Default: ${_mc_text}ProtonVPN DNS${_R} — encrypted, zero-log, inside the tunnel\n"
    printf "  ${_mc_ov}  Your ISP sees zero DNS queries when VPN is active.${_R}\n\n"
    printf "  Custom DNS override (bypasses NetShield):\n"
    printf "  ${_mc_teal}protonvpn config set custom-dns on --dns 1.1.1.1${_R}        Cloudflare\n"
    printf "  ${_mc_teal}protonvpn config set custom-dns on --dns 9.9.9.9${_R}        Quad9 (malware-blocking)\n"
    printf "  ${_mc_teal}protonvpn config set custom-dns on --dns 1.1.1.1,8.8.8.8${_R} Cloudflare + Google\n"
    printf "  ${_mc_teal}protonvpn config set custom-dns off${_R}                     Restore ProtonVPN DNS\n"
    printf "  ${_mc_yellow}  ⚠  Custom DNS disables NetShield. Use only if you have a specific reason.${_R}\n\n"

    _pvpn_div
    printf "  ${_mc_lav}${_B}ALL SETTINGS${_R}  ${_mc_ov}toggle via ${_mc_lav}pvpn config${_R}${_mc_ov} or raw commands below${_R}\n\n"
    printf "  ${_mc_text}kill-switch${_R}              standard · off\n"
    printf "  ${_mc_ov}                         standard = blocks internet on VPN drop · off = unprotected\n"
    printf "                         note: 'advanced' (permanent) is disabled in this CLI version — GUI only${_R}\n\n"
    printf "  ${_mc_text}netshield${_R}                malware-ads-trackers · malware-only · off\n"
    printf "  ${_mc_ov}                         DNS-level blocking. See NETSHIELD above.${_R}\n\n"
    printf "  ${_mc_text}ipv6${_R}                     on · off\n"
    printf "  ${_mc_ov}                         off = hide real IPv6 (leak prevention). on = tunnel IPv6 through VPN.${_R}\n\n"
    printf "  ${_mc_text}vpn-accelerator${_R}          on · off\n"
    printf "  ${_mc_ov}                         ProtonVPN's speed optimization. Keep on always.${_R}\n\n"
    printf "  ${_mc_text}port-forwarding${_R}          on · off\n"
    printf "  ${_mc_ov}                         Opens inbound port for P2P/hosting. Requires lease script.${_R}\n\n"
    printf "  ${_mc_text}moderate-nat${_R}             on · off\n"
    printf "  ${_mc_ov}                         Relaxes NAT for gaming/P2P. off = strict (most secure).${_R}\n\n"
    printf "  ${_mc_text}custom-dns${_R}               on --dns <IP> · off\n"
    printf "  ${_mc_ov}                         Override ProtonVPN DNS. Disables NetShield when on.${_R}\n\n"
    printf "  ${_mc_text}anonymous-crash-reports${_R}  on · off\n"
    printf "  ${_mc_ov}                         Send anonymous crash reports to Proton.${_R}\n\n"

    _pvpn_div
    printf "  ${_mc_lav}${_B}SECURE CORE${_R}  ${_mc_ov}used by ghost + connect -ghost${_R}\n\n"
    printf "  your device → ${_mc_mauve}Secure Core hub${_R} (CH, IS, SE, or IC) → exit server → internet\n"
    printf "  ${_mc_ov}  Hub servers are in privacy-friendly jurisdictions, physically\n"
    printf "    secured, and owned+operated by Proton. Even if the exit server\n"
    printf "    is wiretapped or seized, traffic is already encrypted from the\n"
    printf "    Secure Core hop — your origin IP is unreachable.${_R}\n\n"

    _pvpn_div
    printf "  ${_mc_lav}${_B}TOR OVER VPN${_R}  ${_mc_ov}used by tor level only — no country selection possible${_R}\n\n"
    printf "  your device → ${_mc_teal}VPN tunnel (encrypted)${_R} → ${_mc_peach}Tor entry node${_R} → Tor relays → exit → internet\n"
    printf "  ${_mc_ov}  ProtonVPN encrypts your connection to Tor — your ISP cannot see\n"
    printf "    you are using Tor. Tor cannot see your real IP. The exit node\n"
    printf "    sees only the Tor circuit, not you. Very slow. For maximum anonymity.${_R}\n\n"

    _pvpn_div
    printf "  ${_mc_lav}${_B}PROTOCOLS${_R}  ${_mc_ov}set via GUI only — CLI has no protocol setter${_R}\n\n"
    printf "  ${_mc_green}WireGuard${_R}          Default. Fast, modern, UDP. Best for everyday use.\n\n"
    printf "  ${_mc_sapp}WireGuard UDP${_R}      WireGuard + Proton obfuscation layer, UDP.\n\n"
    printf "  ${_mc_sapp}WireGuard TCP${_R}      WireGuard + obfuscation, TCP. Bypasses firewalls blocking UDP.\n\n"
    printf "  ${_mc_mauve}Stealth${_R}            WireGuard wrapped in TLS — looks like HTTPS traffic.\n"
    printf "  ${_mc_ov}                   Bypasses deep packet inspection, censorship, restrictive networks.${_R}\n\n"
    printf "  ${_mc_lav}Smart${_R}              Auto-selects best protocol per network conditions.\n\n"
    printf "  ${_mc_yellow}OpenVPN TCP/UDP${_R}    Legacy. CLI warns it may be unstable. Avoid unless needed.\n\n"
    printf "  ${_mc_ov}  To change protocol: open ProtonVPN GUI → Settings → Connection → Protocol.${_R}\n\n"

    _pvpn_div
    printf "  ${_mc_lav}${_B}SPLIT TUNNELING${_R}  ${_mc_ov}GUI only — no CLI interface${_R}\n\n"
    printf "  Routes only selected apps/IPs through VPN, rest goes direct.\n"
    printf "  ${_mc_ov}  Exclude mode: everything through VPN except listed apps/IPs.${_R}\n"
    printf "  ${_mc_ov}  Include mode: only listed apps/IPs go through VPN.${_R}\n"
    printf "  ${_mc_ov}  Configure via: ProtonVPN GUI → Settings → Connection → Split Tunneling.${_R}\n\n"

    _pvpn_div
    printf "  ${_mc_lav}${_B}LAN${_R}\n\n"
    printf "  Local network (LAN) is always accessible even with kill-switch on.\n"
    printf "  ${_mc_ov}  Kill-switch blocks internet traffic, not local network.\n"
    printf "    Your printer, NAS, local devices — all reachable at all times.${_R}\n\n"
}

# ── Config TUI ───────────────────────────────────────────────────
# State arrays live at file scope so render function can access them
# without subshells (subshells can't modify parent arrays).
typeset -ga _PCFG_KEYS _PCFG_LABELS _PCFG_DESCS
typeset -gA _PCFG_VALUES _PCFG_OPTS

_pvpn_cfg_vcol() {
    # Returns color variable name — no subshell, sets _pvpn_cfg_col directly
    case "$1" in
        off|disabled)         _pvpn_cfg_col="$_mc_red"    ;;
        on|standard)          _pvpn_cfg_col="$_mc_green"  ;;
        malware-ads-trackers) _pvpn_cfg_col="$_mc_green"  ;;
        malware-only)         _pvpn_cfg_col="$_mc_yellow" ;;
        *)                    _pvpn_cfg_col="$_mc_sapp"   ;;
    esac
}

_pvpn_cfg_draw() {
    # Renders the mutable block: all rows + desc + div + hint + blank line
    # Call after moving cursor to the top of this block with \033[NA
    local j key label val dval dns_ip="$1"
    for (( j=0; j<${#_PCFG_KEYS}; j++ )); do
        key="${_PCFG_KEYS[$((j+1))]}"
        label="${_PCFG_LABELS[$((j+1))]}"
        val="${_PCFG_VALUES[$key]:-—}"
        _pvpn_cfg_vcol "$val"
        dval="$val"
        [[ "$key" == "custom-dns" && "$val" == "on" && -n "$dns_ip" ]] \
            && dval="on  ($dns_ip)"
        if (( j == _pvpn_cfg_cur )); then
            printf "\033[2K  ${_mc_teal}▸  ${_mc_lav}${_B}%-12s${_R}  ${_pvpn_cfg_col}%s${_R}\n" \
                "$label" "$dval"
        else
            printf "\033[2K     ${_mc_ov}%-12s${_R}  ${_pvpn_cfg_col}%s${_R}\n" \
                "$label" "$dval"
        fi
    done
    local desc="${_PCFG_DESCS[$((  _pvpn_cfg_cur+1))]}"
    local hkey="${_PCFG_KEYS[$((   _pvpn_cfg_cur+1))]}"
    printf "\033[2K  ${_mc_ov}%s${_R}\n"                                                 "$desc"
    printf "\033[2K  ${_mc_surf}────────────────────────────────────────────${_R}\n"
    printf "\033[2K  ${_mc_ov}values:${_R}  ${_mc_text}%s${_R}\n"                       "${_PCFG_OPTS[$hkey]}"
    printf "\033[2K\n"
}

_pvpn_cfg_next() {
    local key="$1"
    local -a opts; opts=(${=_PCFG_OPTS[$key]})
    local cur="${_PCFG_VALUES[$key]:-}" n=${#opts} i
    for (( i=0; i<n; i++ )); do
        if [[ "${opts[$((i+1))]}" == "$cur" ]]; then
            _PCFG_VALUES[$key]="${opts[$(( (i+1) % n + 1 ))]}"
            return
        fi
    done
    _PCFG_VALUES[$key]="${opts[1]}"
}

_pvpn_cfg_apply() {
    local key="$1" val="$2"
    if [[ "$key" == "kill-switch" ]]; then
        _pvpn_ensure_ks "$val"
    elif [[ "$key" == "custom-dns" && "$val" == "off" ]]; then
        protonvpn config set custom-dns off > /dev/null 2>&1
    elif [[ "$key" != "custom-dns" ]]; then
        protonvpn config set "$key" "$val" > /dev/null 2>&1
    fi
}

_pvpn_config_tui() {
    _PCFG_KEYS=(
        kill-switch
        netshield
        ipv6
        vpn-accelerator
        port-forwarding
        moderate-nat
        custom-dns
        anonymous-crash-reports
    )
    _PCFG_LABELS=(
        "kill-sw"
        "netshield"
        "ipv6"
        "vpn-accel"
        "port-fw"
        "nat"
        "custom-dns"
        "crash-rep"
    )
    _PCFG_DESCS=(
        "standard = blocks internet on VPN drop · off = unprotected"
        "DNS-level filtering: ads, trackers, malware"
        "off = leak prevention · on = tunnel IPv6 through VPN"
        "ProtonVPN speed optimization — keep on"
        "opens inbound port for P2P / hosting"
        "relaxed NAT for gaming / P2P (off = strict/secure)"
        "custom DNS override — disables NetShield when on"
        "send anonymous crash reports to Proton"
    )
    _PCFG_OPTS[kill-switch]="standard off"
    _PCFG_OPTS[netshield]="malware-ads-trackers malware-only off"
    _PCFG_OPTS[ipv6]="on off"
    _PCFG_OPTS[vpn-accelerator]="on off"
    _PCFG_OPTS[port-forwarding]="on off"
    _PCFG_OPTS[moderate-nat]="on off"
    _PCFG_OPTS[custom-dns]="on off"
    _PCFG_OPTS[anonymous-crash-reports]="on off"

    local _cfgraw; _cfgraw=$(protonvpn config list 2>&1)
    if echo "$_cfgraw" | grep -qi 'desktop app is currently running'; then
        printf "\n  ${_mc_yellow}⚠  ProtonVPN GUI is running — close it first${_R}\n\n"
        return 1
    fi

    local v
    v=$(echo "$_cfgraw" | grep -i 'kill-switch'     | awk '{print $NF}'); _PCFG_VALUES[kill-switch]="${v:-off}"
    v=$(echo "$_cfgraw" | grep -i 'netshield'       | awk '{print $NF}'); _PCFG_VALUES[netshield]="${v:-off}"
    v=$(echo "$_cfgraw" | grep -i '^ipv6'           | awk '{print $NF}'); _PCFG_VALUES[ipv6]="${v:-off}"
    v=$(echo "$_cfgraw" | grep -i 'vpn-accelerator' | awk '{print $NF}'); _PCFG_VALUES[vpn-accelerator]="${v:-off}"
    v=$(echo "$_cfgraw" | grep -i 'port-forwarding' | awk '{print $NF}'); _PCFG_VALUES[port-forwarding]="${v:-off}"
    v=$(echo "$_cfgraw" | grep -i 'moderate-nat'    | awk '{print $NF}'); _PCFG_VALUES[moderate-nat]="${v:-off}"
    v=$(echo "$_cfgraw" | grep -i 'custom-dns'      | awk '{print $NF}'); _PCFG_VALUES[custom-dns]="${v:-off}"
    v=$(echo "$_cfgraw" | grep -i 'anonymous-crash' | awk '{print $NF}'); _PCFG_VALUES[anonymous-crash-reports]="${v:-off}"
    local _dns_ip; _dns_ip=$(echo "$_cfgraw" | grep -i 'dns-server' | awk '{$1=""; print}' | xargs)

    _pvpn_cfg_cur=0
    _pvpn_cfg_col=""
    local total=${#_PCFG_KEYS}
    # block = rows + desc + div + hint + blank
    local block=$(( total + 4 ))

    printf "\n"
    printf "  ${_mc_mauve}${_B}pvpn config${_R}  ${_mc_ov}↑↓ move  ·  Enter/Space cycle  ·  q quit${_R}\n\n"
    printf "  ${_mc_surf}────────────────────────────────────────────${_R}\n"
    _pvpn_cfg_draw "$_dns_ip"

    local ch esc done_loop=0
    local old_stty; old_stty=$(stty -g 2>/dev/null)
    # Drain any buffered input (e.g. leftover \n from shell) before raw mode
    stty -echo -icanon min 0 time 0 2>/dev/null
    while IFS= read -r -k1 -t 0 ch 2>/dev/null; do :; done
    stty -echo -icanon min 1 time 0 2>/dev/null

    while (( !done_loop )); do
        ch=""
        IFS= read -r -k1 ch 2>/dev/null
        case "$ch" in
            $'\033')
                IFS= read -r -k1 esc 2>/dev/null
                if [[ "$esc" == "[" ]]; then
                    IFS= read -r -k1 esc 2>/dev/null
                    case "$esc" in
                        A)  (( _pvpn_cfg_cur > 0 )) && (( _pvpn_cfg_cur-- ))
                            printf "\033[%dA" $block
                            _pvpn_cfg_draw "$_dns_ip" ;;
                        B)  (( _pvpn_cfg_cur < total-1 )) && (( _pvpn_cfg_cur++ ))
                            printf "\033[%dA" $block
                            _pvpn_cfg_draw "$_dns_ip" ;;
                    esac
                else
                    done_loop=1
                fi
                ;;
            ' '|$'\n'|$'\r')
                local ckey="${_PCFG_KEYS[$(( _pvpn_cfg_cur+1 ))]}"
                _pvpn_cfg_next "$ckey"
                local newval="${_PCFG_VALUES[$ckey]}"

                if [[ "$ckey" == "custom-dns" && "$newval" == "on" ]]; then
                    stty "$old_stty" 2>/dev/null
                    printf "\033[%dA\033[J" $block
                    printf "  ${_mc_lav}${_B}custom-dns${_R}  ${_mc_ov}comma-separated IPs · blank = cancel${_R}\n"
                    [[ -n "$_dns_ip" ]] && printf "  ${_mc_ov}current: %s${_R}\n" "$_dns_ip"
                    printf "  ${_mc_sapp}DNS IP(s)${_R} ${_mc_ov}[${_mc_text}%s${_mc_ov}]${_R}: " "${_dns_ip:-1.1.1.1}"
                    local dns_input=""
                    IFS= read -r dns_input
                    if [[ -z "$dns_input" ]]; then
                        _PCFG_VALUES[custom-dns]="off"
                    else
                        _dns_ip="$dns_input"
                        protonvpn config set custom-dns on --dns "$dns_input" > /dev/null 2>&1
                    fi
                    stty -echo -icanon min 1 time 0 2>/dev/null
                    printf "\n"
                    printf "  ${_mc_surf}────────────────────────────────────────────${_R}\n"
                    _pvpn_cfg_draw "$_dns_ip"
                else
                    _pvpn_cfg_apply "$ckey" "$newval"
                    printf "\033[%dA" $block
                    _pvpn_cfg_draw "$_dns_ip"
                fi
                ;;
            q|Q) done_loop=1 ;;
        esac
    done

    stty "$old_stty" 2>/dev/null
    printf "\n  ${_mc_ov}saved · run ${_mc_lav}pvpn${_R}${_mc_ov} to see full status${_R}\n\n"
}

# ── Countries ────────────────────────────────────────────────────
_pvpn_countries() {
    printf "\n"
    printf "  ${_mc_mauve}${_B}countries${_R}  ${_mc_ov}pvpn connect <CODE>${_R}\n\n"
    _pvpn_div
    protonvpn countries list 2>&1 | awk '
        NR<=2 || /^[-]/ || /^$/ { next }
        {
            code = $NF
            name = $0
            sub(/[[:space:]]+[^[:space:]]+$/, "", name)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
            printf "  \033[38;2;166;173;200m%-36s\033[0m  \033[38;2;148;226;213m%s\033[0m\n", name, code
        }
    '
    printf "\n"
}

# ── Connect to country (with optional mode flag) ──────────────────
_pvpn_connect_country() {
    local cc="${1:u}" mode="$2"
    if [[ -z "$cc" ]]; then
        printf "  ${_mc_red}✗  usage: pvpn connect <CC> [-ghost|-p2p|-random]${_R}\n"
        printf "  ${_mc_ov}e.g.  pvpn connect JP  ·  pvpn connect US -ghost${_R}\n"
        return 1
    fi
    if ! protonvpn countries list 2>&1 | grep -q " $cc$"; then
        printf "  ${_mc_red}✗  unknown country code '%s'${_R}\n" "$cc"
        printf "  ${_mc_ov}run ${_mc_lav}pvpn countries${_R}${_mc_ov} to see valid codes${_R}\n"
        return 1
    fi

    local flag; flag=$(_pvpn_flag "$cc")
    local extra_args=()
    local mode_label mode_col

    case "$mode" in
        -ghost)
            extra_args=(--securecore)
            mode_label="Secure Core"
            mode_col="$_mc_mauve"
            _pvpn_apply standard malware-ads-trackers off on off off off
            ;;
        -p2p)
            extra_args=(--p2p)
            mode_label="P2P"
            mode_col="$_mc_lav"
            _pvpn_apply standard malware-ads-trackers off on on on off
            ;;
        -random)
            extra_args=(--random)
            mode_label="random server"
            mode_col="$_mc_yellow"
            _pvpn_apply standard malware-ads-trackers off on off off off
            ;;
        "")
            mode_label="fastest"
            mode_col="$_mc_sapp"
            # no _pvpn_apply — use existing config as-is
            _pvpn_ensure_ks standard
            ;;
        -tor)
            printf "  ${_mc_red}✗  -tor is not supported on connect${_R}\n"
            printf "  ${_mc_ov}Tor servers are a fixed pool — country selection is not possible.${_R}\n"
            printf "  ${_mc_ov}Use ${_mc_peach}pvpn tor${_R}${_mc_ov} instead.${_R}\n"
            return 1
            ;;
        *)
            printf "  ${_mc_red}✗  unknown flag: %s${_R}\n" "$mode"
            printf "  ${_mc_ov}valid flags: -ghost  -p2p  -random${_R}\n"
            return 1
            ;;
    esac

    # Build a clean level label like "JP" or "JP -ghost"
    local level_label="$cc${mode:+ $mode}"

    printf "\n  ${mode_col}${_B}connect${_R}  ${_mc_ov}%s %s · %s${_R}\n" "$flag" "$cc" "$mode_label"
    printf "  ${_mc_ov}connecting...${_R}\n"
    _pvpn_do_connect "$level_label" --country "$cc" "${extra_args[@]}" || return 1
    _pvpn_connect_ok "${mode_col}${_B}${level_label}${_R}"
}

# ── Reconnect ─────────────────────────────────────────────────────
# The official CLI does NOT auto-reconnect on drop (WiFi switch, sleep,
# server hiccup) — it only blocks via kill-switch and waits. This restores
# whatever level you were last on. Falls back to _PVPN_LAST so it works
# even after an intentional `pvpn off`.
_pvpn_reconnect() {
    local last; last=$(_pvpn_get_level)
    [[ "$last" == "—" || -z "$last" ]] && last=$(_pvpn_get_last)
    if [[ "$last" == "—" || -z "$last" ]]; then
        printf "\n  ${_mc_red}✗  nothing to reconnect to${_R}\n"
        printf "  ${_mc_ov}pick a level first: ${_mc_lav}pvpn ghost${_R}${_mc_ov} · ${_mc_lav}pvpn fast${_R}${_mc_ov} · ${_mc_lav}pvpn home${_R}\n\n"
        return 1
    fi
    printf "\n  ${_mc_teal}${_B}reconnect${_R}  ${_mc_ov}restoring last level: ${_mc_text}%s${_R}\n" "$last"
    case "$last" in
        tor|ghost|home|fast)
            pvpn "$last"
            ;;
        *)
            # country label: "JP" or "JP -ghost"
            local cc="${last%% *}" mode=""
            [[ "$last" == *" "* ]] && mode="${last#* }"
            pvpn connect "$cc" "$mode"
            ;;
    esac
}

# ── Main ─────────────────────────────────────────────────────────
pvpn() {
    local cmd="${1:-status}"

    case "$cmd" in

        tor)
            printf "\n  ${_mc_peach}${_B}tor${_R}  ${_mc_ov}Tor over VPN · extreme anonymity · very slow${_R}\n"
            _pvpn_apply standard malware-ads-trackers off on off off off
            printf "  ${_mc_ov}connecting via Tor...${_R}\n"
            _pvpn_do_connect tor --tor || return 1
            _pvpn_connect_ok "${_mc_peach}${_B}tor${_R}"
            ;;

        ghost)
            printf "\n  ${_mc_mauve}${_B}ghost${_R}  ${_mc_ov}Secure Core · max privacy · all shields${_R}\n"
            _pvpn_apply standard malware-ads-trackers off on off off off
            printf "  ${_mc_ov}connecting via Secure Core...${_R}\n"
            _pvpn_do_connect ghost --securecore || return 1
            _pvpn_connect_ok "${_mc_mauve}${_B}ghost${_R}"
            ;;

        home)
            printf "\n  ${_mc_sapp}${_B}home${_R}  ${_mc_ov}India · Mumbai · full shields${_R}\n"
            _pvpn_apply standard malware-ads-trackers off on off off off
            printf "  ${_mc_ov}connecting to India...${_R}\n"
            _pvpn_do_connect home --country IN || return 1
            _pvpn_connect_ok "${_mc_sapp}${_B}home${_R}"
            ;;

        fast)
            printf "\n  ${_mc_green}${_B}fast${_R}  ${_mc_ov}Singapore · kill switch · speed priority${_R}\n"
            _pvpn_apply standard malware-only on on off off off
            printf "  ${_mc_ov}connecting to Singapore...${_R}\n"
            _pvpn_do_connect fast --country SG || return 1
            _pvpn_connect_ok "${_mc_green}${_B}fast${_R}"
            ;;

        off|disconnect)
            if ! _pvpn_is_connected; then
                printf "\n  ${_mc_ov}already disconnected${_R}\n\n"
                return 0
            fi
            printf "\n  ${_mc_ov}disconnecting...${_R}\n"
            if protonvpn disconnect; then
                _pvpn_clear_state
                printf "  ${_mc_red}✗  disconnected${_R}\n\n"
            else
                printf "  ${_mc_red}✗  disconnect failed — check protonvpn status${_R}\n\n"
                return 1
            fi
            ;;

        config)
            _pvpn_config_tui
            ;;

        connect)
            _pvpn_connect_country "$2" "$3"
            ;;

        reconnect|r)
            _pvpn_reconnect
            ;;

        countries|contries|country)
            _pvpn_countries
            ;;

        --help|-h|help)
            _pvpn_help
            ;;

        status|"")
            _pvpn_dashboard
            ;;

        *)
            printf "\n  ${_mc_red}✗  unknown command: %s${_R}\n" "$cmd"
            printf "  ${_mc_ov}run ${_mc_lav}pvpn --help${_R}${_mc_ov} for reference${_R}\n\n"
            return 1
            ;;
    esac
}
