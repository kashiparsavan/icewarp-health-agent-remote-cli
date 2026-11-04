#!/bin/bash
# ============================================================
# IceWarp Health Agent - Bootstrap (premium TrueColor TUI)
# ============================================================
#   curl -sSL https://parsavan.com/support/iceautochecker/linux-agent/bootstrap.sh | bash
#
# Header (4 rows) + left Navigation pane (~18% width) + right Execution
# Output pane (~82%), 1-column drop shadow, rounded borders, full-row
# highlight. One renderer: SIGWINCH only sets a flag; stats refresh
# repaints the header only, so there is no flicker.
#
# All UI text is ASCII: multi-byte glyphs inside a framed region have
# terminal-dependent width (U+2699 U+FE0F rendered 1 column on some
# terminals, 2 on others) which is what broke the right border.
#
# Headless bypass: any argument (--report, --list, --only=...) or a
# non-TTY stdout runs agent.sh directly with no UI at all.
# ============================================================

# CRLF guard. Check BASH_SOURCE (the real script file) rather than $0:
# under `bash -s` / `bash -c`, $0 is the bash binary itself, and grepping it
# for \r false-positives on the ELF file. Under `curl | bash` BASH_SOURCE is
# empty, so the guard is skipped exactly as before.
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    if grep -q $'\r' "${BASH_SOURCE[0]}" 2>/dev/null; then
        printf 'ERROR: CRLF line endings in %s - convert to LF.\n' "${BASH_SOURCE[0]}" >&2
        exit 1
    fi
fi

# Our string maths needs the C locale (one byte per ${s:i:1}); agent.sh still
# gets the caller's original locale, so its behaviour is unchanged.
ORIG_LC_ALL="${LC_ALL:-}"
export LC_ALL=C

readonly BASE_URL="https://parsavan.com/support/iceautochecker/linux-agent"
readonly AUTH_USER="parsavan"
readonly AUTH_PASS='P@rsavan.com@123'

readonly MIN_COLS=70
readonly MIN_ROWS=16
readonly LOG_CAP=2000
readonly REFRESH_SECS=2

# ------------------------------------------------------------
# State
# ------------------------------------------------------------
START_DIR=""
TMP_DIR=""
# Where agent.sh writes its final artifacts (persistent, not the temp workspace)
REPORT_DIR=""
FIFO=""
STTY_SAVE=""
IS_TTY=0
QUIT=0
RUNNING=0
WINCH_FLAG=0
RENDER_NEEDED=1
SCROLL_NEEDED=0
MENU_SEL=0
LOG_BUFFER=()
SCROLL_OFFSET=0
SCROLL_FOLLOW=1
OUT_ROWS=1
AGENT_PID=""
STATUS_MSG="Starting"
OS_NAME=""
OS_VERSION=""
IW_VERSION=""
IW_PATH=""
AGENT_VERSION=""

# Target version comes from the tarball's VERSION file at runtime.
TARGET_VERSION=""
VERSION_STALE=0
BLINK_ON=0

CPU_PCT=-1
CPU_PREV_T=0
CPU_PREV_I=0
RAM_PCT=0
RAM_TOTAL_MB=0
RAM_USED_MB=0
LAST_STATS=0

T_COLS=80
T_LINES=24

# Branding block (built per-frame from the live panel width)
BRAND_LINES=()
BRAND_H=0
SHOW_BRAND=0

# Exit code of the last streamed command
STREAM_RC=0
STREAM_CMD=()

# ASCII-only labels: ${#s} == display width on every terminal.
MENU_LABELS=("Run Health Assessment" "Check Configuration" "Apply Configuration" \
             "Run Filtered Collectors" "List Collectors" "View Latest Reports" \
             "Update IceWarp" "Quit")
MENU_ACTIONS=("run" "config" "apply" "only" "list" "report" "update" "quit")
readonly M_SEL="[>]" M_OFF="[ ]"

# ------------------------------------------------------------
# Palette - Tokyo Night (TrueColor 24-bit)
# ------------------------------------------------------------
readonly C_RESET=$'\e[0m'
readonly C_BOLD=$'\e[1m'

readonly BG_HDR=$'\e[48;2;26;27;38m'      # #1a1b26
readonly BG_NAV=$'\e[48;2;22;22;30m'      # #16161e
readonly BG_EXEC=$'\e[48;2;13;14;20m'     # #0d0e14
readonly BG_SHADOW=$'\e[48;2;6;6;10m'     # #06060a
readonly BG_SEL=$'\e[48;2;125;207;255m'   # #7dcfff neon cyan

readonly FG_TXT=$'\e[38;2;192;202;245m'   # #c0caf5
readonly FG_DIM=$'\e[38;2;86;95;137m'     # #565f89
readonly FG_BORDER=$'\e[38;2;59;66;97m'   # #3b4261
readonly FG_ACC=$'\e[38;2;255;158;100m'   # #ff9e64 orange
readonly FG_TITLE=$'\e[38;2;187;154;247m' # #bb9af7 purple
readonly FG_SEL=$'\e[38;2;13;14;20m'      # #0d0e14 dark text on neon
readonly FG_SHADOW=$'\e[38;2;40;43;62m'

# Semantic log-level accents
readonly FG_OK=$'\e[38;2;158;206;106m'    # #9ece6a bright green
readonly FG_WARN=$'\e[38;2;224;175;104m'  # #e0af68 bright yellow
readonly FG_ERR=$'\e[38;2;247;118;142m'   # #f7768e bright red
readonly FG_INFO=$'\e[38;2;122;162;247m'  # #7aa2f7 blue
readonly FG_RUN=$'\e[38;2;125;207;255m'   # #7dcfff cyan
readonly FG_BRAND=$'\e[38;2;255;138;0m'   # #ff8a00 Pars Avan brand orange

readonly B_TL="╭" B_TR="╮" B_BL="╰" B_BR="╯"
readonly B_H="─"  B_V="│"
readonly SHADOW_CH="░"

# ------------------------------------------------------------
# Debug trace - proves the key handler fires. Uses the printf
# time builtin so it never forks inside the input loop.
# ------------------------------------------------------------
readonly DBG_LOG="/tmp/tui_debug.log"
dbg() {
    printf '%(%H:%M:%S)T %s\n' -1 "$*" >>"$DBG_LOG" 2>/dev/null
}

# ------------------------------------------------------------
# Version comparison - `sort -V` semantics (14.3.0.12 < 14.4.0.1)
# ------------------------------------------------------------
version_lt() {
    [[ "$1" == "$2" ]] && return 1
    local first
    first="$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)"
    [[ "$first" == "$1" ]]
}

# Target version is read from the downloaded tarball's VERSION file -
# nothing is hardcoded, so a new release updates it automatically.
# Read KEY="value" (or KEY=value) from a version file into the named variable.
# Falls back to the whole file for legacy single-value VERSION files.
version_key() {
    local _file="$1" _key="$2" _v="$3"
    local _line _val=""
    printf -v "$_v" '%s' ""
    [[ -f "$_file" ]] || return 1
    while IFS= read -r _line || [[ -n "$_line" ]]; do
        _line="${_line#"${_line%%[![:space:]]*}"}"      # strip leading spaces
        [[ "$_line" == "${_key}="* ]] || continue
        _val="${_line#*=}"
        _val="${_val%\"}"; _val="${_val#\"}"            # strip double quotes
        _val="${_val%\'}"; _val="${_val#\'}"            # strip single quotes
        _val="${_val//[[:space:]]/}"
        printf -v "$_v" '%s' "$_val"
        return 0
    done < "$_file"
    if [[ "$_key" == "AGENT_VERSION" ]]; then
        # legacy format: the file held a single bare version
        _val="$(tr -d '[:space:]' < "$_file")"
        if [[ -n "$_val" && "$_val" != *"="* ]]; then
            printf -v "$_v" '%s' "$_val"
            return 0
        fi
    fi
    return 1
}

# VERSION holds both values:
#   AGENT_VERSION="0.8.0"
#   ICEWARP_TARGET="14.3.0.13"
# Target is never hardcoded - it ships with the tarball.
read_target_version() {
    local vf="${TMP_DIR}/VERSION"
    TARGET_VERSION=""
    VERSION_STALE=0
    if [[ -f "$vf" ]]; then
        version_key "$vf" ICEWARP_TARGET TARGET_VERSION || true
        version_key "$vf" AGENT_VERSION AGENT_VERSION || true
    fi
    [[ -z "$AGENT_VERSION" ]] && AGENT_VERSION="unknown"
    if [[ -n "$TARGET_VERSION" && -n "$IW_VERSION" && "$IW_VERSION" != "unknown" ]]; then
        if version_lt "$IW_VERSION" "$TARGET_VERSION"; then
            VERSION_STALE=1
        fi
    fi
    dbg "version installed=${IW_VERSION} target=${TARGET_VERSION} agent=${AGENT_VERSION} stale=${VERSION_STALE}"
}

# Colour an output line by its level tag.
line_color() {
    case "$1" in
        "[OK"*)                    LINE_FG="$FG_OK" ;;
        "[WARN"*)                  LINE_FG="$FG_WARN" ;;
        "[FAIL"*|"[ERR"*|"[ERROR"*) LINE_FG="$FG_ERR" ;;
        "[RUN"*)                   LINE_FG="$FG_RUN" ;;
        "[INFO"*)                  LINE_FG="$FG_INFO" ;;
        *)                         LINE_FG="$FG_TXT" ;;
    esac
}

# ------------------------------------------------------------
# Character width (UTF-8 aware) - used for any non-ASCII content,
# e.g. collector output. UI strings themselves are pure ASCII.
# ------------------------------------------------------------
UW_N=1
UW_W=1
uw_at() {
    local s="$1" i="$2" c1 j
    c1="${s:i:1}"
    if   [[ "$c1" < $'\x80' ]]; then UW_N=1; UW_W=1
    elif [[ "$c1" < $'\xC0' ]]; then UW_N=1; UW_W=0
    elif [[ "$c1" < $'\xE0' ]]; then UW_N=2; UW_W=1
    elif [[ "$c1" < $'\xF0' ]]; then
        UW_N=3; UW_W=1
        j=$(( i + 3 ))
        [[ "${s:j:3}" == $'\xEF\xB8\x8F' ]] && { UW_N=6; UW_W=2; }
    else
        UW_N=4; UW_W=2
    fi
}

dw() {
    # All internals are _-prefixed so a caller can pass any variable name as
    # the output variable without it being shadowed by a local of the same name.
    local _s="$1" _v="$2"
    local _n=${#_s} _i=0 _w=0
    if [[ "$_s" != *[!-~]* ]]; then printf -v "$_v" '%d' "$_n"; return; fi
    while (( _i < _n )); do
        uw_at "$_s" "$_i"
        _w=$(( _w + UW_W )); _i=$(( _i + UW_N ))
    done
    printf -v "$_v" '%d' "$_w"
}

repeat_ch() {
    local ch="$1" n="$2" __v="$3" sp=""
    if (( n <= 0 )); then printf -v "$__v" '%s' ""; return; fi
    printf -v sp '%*s' "$n" ''
    printf -v "$__v" '%s' "${sp// /$ch}"
}

# fitf <string> <width> <fillchar> <outvar>
# Clips to <width> display columns then pads with <fillchar>. The ONLY place
# text touches a border, so a long label can never push an edge out.
fitf() {
    local _s="$1" _width="$2" _fill="${3:- }" _v="$4"
    local _n=${#_s} _i=0 _w=0 _out="" _pad="" _limit
    if (( _width <= 0 )); then printf -v "$_v" '%s' ""; return; fi
    _limit=$_width
    while (( _i < _n )); do
        uw_at "$_s" "$_i"
        (( _w + UW_W > _limit )) && break
        _out+="${_s:_i:UW_N}"
        _w=$(( _w + UW_W )); _i=$(( _i + UW_N ))
    done
    if (( _i < _n )); then
        # Truncated: reserve 3 columns for an ASCII marker so no non-ASCII
        # glyph is ever needed inside a framed cell.
        if (( _width >= 4 )); then
            _limit=$(( _width - 3 ))
            _out=""; _w=0; _i=0
            while (( _i < _n )); do
                uw_at "$_s" "$_i"
                (( _w + UW_W > _limit )) && break
                _out+="${_s:_i:UW_N}"
                _w=$(( _w + UW_W )); _i=$(( _i + UW_N ))
            done
            _out+="..."; _w=$(( _w + 3 ))
        fi
    fi
    (( _w < _width )) && repeat_ch "$_fill" $(( _width - _w )) _pad && _out+="$_pad"
    printf -v "$_v" '%s' "$_out"
}

# NOTE: the value parameter must NOT be named "s" - callers pass "s" as the
# output variable name and a local of that name would shadow it.
sanitize() {
    local str="$1" __v="$2"
    local n i c out="" skip=0
    str="${str//$'\t'/    }"
    str="${str//$'\r'/}"
    if [[ "$str" == *[$'\x01'-$'\x1F']* ]]; then
        n=${#str}
        for (( i = 0; i < n; i++ )); do
            c="${str:i:1}"
            if (( skip )); then
                [[ "$c" > $'\x3F' ]] && skip=0
                continue
            fi
            [[ "$c" == $'\e' ]] && { skip=1; continue; }
            [[ "$c" < $'\x20' ]] && continue
            out+="$c"
        done
        str="$out"
    fi
    printf -v "$__v" '%s' "$str"
}

# ------------------------------------------------------------
# Terminal
# ------------------------------------------------------------
get_size() {
    local sz="" t=""
    T_COLS=0
    T_LINES=0
    if (( IS_TTY == 1 )); then
        sz="$(stty size 2>/dev/null </dev/tty)"
        if [[ "$sz" =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]]; then
            T_LINES="${BASH_REMATCH[1]}"
            T_COLS="${BASH_REMATCH[2]}"
        fi
    fi
    if (( T_COLS <= 0 || T_LINES <= 0 )) && command -v tput >/dev/null 2>&1; then
        t="$(tput cols 2>/dev/null)"
        [[ "$t" =~ ^[0-9]+$ ]] && T_COLS="$t"
        t="$(tput lines 2>/dev/null)"
        [[ "$t" =~ ^[0-9]+$ ]] && T_LINES="$t"
    fi
    (( T_COLS <= 0 )) && T_COLS=${COLUMNS:-80}
    (( T_LINES <= 0 )) && T_LINES=${LINES:-24}
    [[ "$T_COLS" =~ ^[0-9]+$ ]] || T_COLS=80
    [[ "$T_LINES" =~ ^[0-9]+$ ]] || T_LINES=24
    (( T_COLS < 1 )) && T_COLS=80
    (( T_LINES < 1 )) && T_LINES=24
}

# ------------------------------------------------------------
# Live stats - pure /proc reads, zero forks, no `top` stall
# ------------------------------------------------------------
read_stats() {
    local -a f
    local i t=0 idle=0
    local k v _rest total=0 avail=0 mfree=0 mbuf=0 mcached=0

    if read -r -a f < /proc/stat 2>/dev/null; then
        for (( i = 1; i <= 8; i++ )); do
            t=$(( t + ${f[i]:-0} ))
        done
        idle=$(( ${f[4]:-0} + ${f[5]:-0} ))
        if (( CPU_PREV_T > 0 && t > CPU_PREV_T )); then
            local dt=$(( t - CPU_PREV_T ))
            local di=$(( idle - CPU_PREV_I ))
            CPU_PCT=$(( (dt - di) * 100 / dt ))
            (( CPU_PCT < 0 )) && CPU_PCT=0
            (( CPU_PCT > 100 )) && CPU_PCT=100
        fi
        CPU_PREV_T=$t
        CPU_PREV_I=$idle
    fi

    while read -r k v _rest 2>/dev/null; do
        case "$k" in
            MemTotal:)     total=$v ;;
            MemAvailable:) avail=$v ;;
            MemFree:)      mfree=$v ;;
            Buffers:)      mbuf=$v ;;
            Cached:)       mcached=$v ;;
        esac
        (( total > 0 && avail > 0 )) && break
    done < /proc/meminfo

    # Older kernels have no MemAvailable; approximate it.
    if (( total > 0 && avail <= 0 )); then
        avail=$(( mfree + mbuf + mcached ))
    fi

    if (( total > 0 )); then
        RAM_TOTAL_MB=$(( total / 1024 ))
        RAM_USED_MB=$(( (total - avail) / 1024 ))
        RAM_PCT=$(( (total - avail) * 100 / total ))
    fi
}

# ------------------------------------------------------------
# Output buffer
# ------------------------------------------------------------
add_output_line() {
    local s
    sanitize "$1" s
    LOG_BUFFER+=("$s")
    if (( ${#LOG_BUFFER[@]} > LOG_CAP )); then
        LOG_BUFFER=("${LOG_BUFFER[@]:1000}")
    fi
    if (( SCROLL_FOLLOW == 1 )); then
        SCROLL_OFFSET=$(( ${#LOG_BUFFER[@]} - OUT_ROWS ))
        (( SCROLL_OFFSET < 0 )) && SCROLL_OFFSET=0
    fi
}

scroll() {
    local d="$1" max
    SCROLL_FOLLOW=0
    SCROLL_OFFSET=$(( SCROLL_OFFSET + d ))
    max=$(( ${#LOG_BUFFER[@]} - OUT_ROWS ))
    (( max < 0 )) && max=0
    (( SCROLL_OFFSET > max )) && SCROLL_OFFSET=$max
    (( SCROLL_OFFSET < 0 )) && SCROLL_OFFSET=0
    (( SCROLL_OFFSET >= max )) && SCROLL_FOLLOW=1
    # Only the output pane changes on a scroll, so request a pane repaint
    # rather than a full frame. Critical for mouse-wheel bursts over SSH.
    SCROLL_NEEDED=1
}

# ------------------------------------------------------------
# Geometry helper - single source of truth
# ------------------------------------------------------------
layout() {
    L_COLS=$T_COLS
    L_LINES=$T_LINES
    L_LEFT=$(( L_COLS * 18 / 100 ))
    (( L_LEFT < 14 )) && L_LEFT=14
    (( L_LEFT > L_COLS - 30 )) && L_LEFT=$(( L_COLS - 30 ))
    L_RIGHT=$(( L_COLS - L_LEFT - 1 ))     # 1 column reserved for the shadow
    L_TOP=5
    L_BOTTOM=$(( L_LINES - 2 ))            # last row is the shadow band
    L_PANEL_H=$(( L_BOTTOM - L_TOP + 1 ))
    L_CONTENT_H=$(( L_PANEL_H - 2 ))
    (( L_CONTENT_H < 1 )) && L_CONTENT_H=1
    L_INNER_L=$(( L_LEFT - 2 ))
    L_INNER_R=$(( L_RIGHT - 2 ))
    (( L_INNER_L < 1 )) && L_INNER_L=1
    (( L_INNER_R < 1 )) && L_INNER_R=1
    OUT_ROWS=$L_CONTENT_H
}

# ------------------------------------------------------------
# Pars Avan branding block for the bottom of the Navigation pane.
# Pure Bash: the .webp cannot be drawn, so this is block-character art.
# Wrapped to the live pane width and hidden when there is not enough room.
# ------------------------------------------------------------
wrap_add() {
    local text="$1" w="$2"
    local line="" word
    for word in $text; do
        if (( ${#line} == 0 )); then
            line="$word"
        elif (( ${#line} + 1 + ${#word} <= w )); then
            line+=" $word"
        else
            BRAND_LINES+=("$line")
            line="$word"
        fi
    done
    [[ -n "$line" ]] && BRAND_LINES+=("$line")
}

build_branding() {
    local w="$L_INNER_L"
    BRAND_LINES=()
    BRAND_H=0
    SHOW_BRAND=0
    (( w < 8 )) && return 0

    if (( w >= 14 )); then
        BRAND_LINES+=("██████████████")
        BRAND_LINES+=("█ PARS AVAN  █")
    else
        BRAND_LINES+=("PARS AVAN")
    fi
    BRAND_LINES+=("")
    wrap_add "Contact Us:" "$w"
    wrap_add "2nd Floor, No. 333, Shahid Dastgardi (Zafar) St., Jordan, Tehran" "$w"
    wrap_add "Tel: 02191005418" "$w"
    wrap_add "Sales (24/7): 09389094141" "$w"

    BRAND_H=${#BRAND_LINES[@]}
    # only if the menu plus a 1-row gap still fits above it
    if (( L_CONTENT_H >= ${#MENU_LABELS[@]} + 1 + BRAND_H )); then
        SHOW_BRAND=1
    fi
}

# ------------------------------------------------------------
# Renderer
# ------------------------------------------------------------
render_too_small() {
    local msg buf r tmp
    msg="Terminal too small: ${T_COLS}x${T_LINES} (need ${MIN_COLS}x${MIN_ROWS}) - enlarge window or press q"
    r=$(( T_LINES / 2 )); (( r < 1 )) && r=1
    fitf "$msg" "$T_COLS" " " tmp
    buf=$'\e[H\e['"$r"';1H'"${FG_ERR}${C_BOLD}${tmp}${C_RESET}"
    printf '\e[?2026h%s\e[1;1H\e[?2026l' "$buf"
}

# Header rows 1..4 only - used for the cheap stats refresh.
render_header() {
    local cols="$L_COLS" buf="" tmp cpu ram info stat
    local prefix suffix p1w=0 vw=0 icol inner

    fitf " IceWarp Health Agent " $(( cols - 2 )) "$B_H" tmp
    buf+=$'\e[1;1H'"${BG_HDR}${FG_TITLE}${B_TL}${FG_BORDER}${tmp}${FG_TITLE}${B_TR}${C_RESET}"

    prefix="OS: ${OS_NAME} ${OS_VERSION}  |  IceWarp: "
    suffix="  |  Path: ${IW_PATH}"
    info="${prefix}${IW_VERSION}${suffix}"
    fitf "$info" $(( cols - 2 )) " " tmp
    buf+=$'\e[2;1H'"${BG_HDR}${FG_BORDER}${B_V}${FG_TXT}${tmp}${FG_BORDER}${B_V}${C_RESET}"

    # Installed IceWarp older than the tarball's VERSION -> blink the value.
    if (( VERSION_STALE == 1 )); then
        dw "$prefix" p1w
        dw "$IW_VERSION" vw
        inner=$(( cols - 2 ))
        if (( p1w + vw <= inner )); then
            icol=$(( 2 + p1w ))
            if (( BLINK_ON == 1 )); then
                buf+=$'\e[2;'"${icol}"'H'"${BG_HDR}${FG_WARN}${C_BOLD}${IW_VERSION}${C_RESET}"
            else
                buf+=$'\e[2;'"${icol}"'H'"${BG_HDR}${FG_ERR}${C_BOLD}${IW_VERSION}${C_RESET}"
            fi
        fi
    fi

    if (( CPU_PCT < 0 )); then cpu="CPU: --"; else cpu="CPU: ${CPU_PCT}%"; fi
    if (( RAM_TOTAL_MB > 0 )); then
        ram="RAM: ${RAM_PCT}% ${RAM_USED_MB}M/${RAM_TOTAL_MB}M"
    else
        ram="RAM: --"
    fi
    stat="${cpu}  |  ${ram}  |  Agent: v${AGENT_VERSION:-0.8.0}  |  Status: ${STATUS_MSG}"
    fitf "$stat" $(( cols - 2 )) " " tmp
    buf+=$'\e[3;1H'"${BG_HDR}${FG_BORDER}${B_V}${FG_ACC}${tmp}${FG_BORDER}${B_V}${C_RESET}"

    repeat_ch "$B_H" $(( cols - 2 )) tmp
    buf+=$'\e[4;1H'"${BG_HDR}${FG_BORDER}${B_BL}${tmp}${B_BR}${C_RESET}"

    printf '%s' "$buf"
}

render_stats_only() {
    layout
    if (( L_COLS < MIN_COLS || L_LINES < MIN_ROWS )); then render_too_small; return; fi
    printf '\e[?2026h\e[?7l'
    render_header
    printf '\e[1;1H\e[?2026l'
}

# Repaints ONLY the right-hand output pane. Used for scrolling so that a burst
# of mouse-wheel events costs one cheap update instead of N full frames.
render_output_pane() {
    if (( T_COLS < MIN_COLS || T_LINES < MIN_ROWS )); then return 0; fi
    layout
    local col=$(( L_LEFT + 2 ))
    local buf="" rt rb rc r row i loidx rtitle last

    printf '\e[?2026h\e[?7l'
    for (( r = 0; r < L_PANEL_H; r++ )); do
        row=$(( L_TOP + r ))
        if (( r == 0 )); then
            rtitle=" Execution Output "
            if (( ${#LOG_BUFFER[@]} > OUT_ROWS )); then
                last=$(( SCROLL_OFFSET + OUT_ROWS ))
                (( last > ${#LOG_BUFFER[@]} )) && last=${#LOG_BUFFER[@]}
                rtitle=" Output ${SCROLL_OFFSET}-${last}/${#LOG_BUFFER[@]} "
            fi
            fitf "$rtitle" "$L_INNER_R" "$B_H" rt
            buf+=$'\e['"$row"';'"$col"'H'"${BG_EXEC}${FG_BORDER}${B_TL}${rt}${B_TR}${C_RESET}"
        elif (( r == L_PANEL_H - 1 )); then
            repeat_ch "$B_H" "$L_INNER_R" rb
            buf+=$'\e['"$row"';'"$col"'H'"${BG_EXEC}${FG_BORDER}${B_BL}${rb}${B_BR}${C_RESET}"
        else
            i=$(( r - 1 ))
            loidx=$(( SCROLL_OFFSET + i ))
            if (( loidx < ${#LOG_BUFFER[@]} )); then
                fitf "${LOG_BUFFER[loidx]}" "$L_INNER_R" " " rc
                line_color "${LOG_BUFFER[loidx]}"
                buf+=$'\e['"$row"';'"$col"'H'"${BG_EXEC}${FG_BORDER}${B_V}${LINE_FG}${rc}${FG_BORDER}${B_V}${C_RESET}"
            else
                fitf "" "$L_INNER_R" " " rc
                buf+=$'\e['"$row"';'"$col"'H'"${BG_EXEC}${FG_BORDER}${B_V}${rc}${FG_BORDER}${B_V}${C_RESET}"
            fi
        fi
    done
    printf '%s\e[1;1H\e[?2026l' "$buf"
}

render_frame() {
    if (( T_COLS < MIN_COLS || T_LINES < MIN_ROWS )); then
        render_frame_small
        return
    fi
    layout
    if (( L_COLS < MIN_COLS || L_LINES < MIN_ROWS )); then
        render_frame_small
        return
    fi

    local buf="" tmp lb lt rb rt lc rc row r i loidx seg lrow rrow bidx

    build_branding

    # ?7l with every frame: if anything ever re-enables autowrap, a write to
    # the last column would scroll the whole buffer and hide the header.
    printf '\e[?2026h\e[?7l'
    render_header

    # ---- panel body
    for (( r = 0; r < L_PANEL_H; r++ )); do
        row=$(( L_TOP + r ))

        if (( r == 0 )); then
            fitf " Navigation " "$L_INNER_L" "$B_H" lt
            local rtitle=" Execution Output "
            if (( ${#LOG_BUFFER[@]} > OUT_ROWS )); then
                local last=$(( SCROLL_OFFSET + OUT_ROWS ))
                (( last > ${#LOG_BUFFER[@]} )) && last=${#LOG_BUFFER[@]}
                rtitle=" Output ${SCROLL_OFFSET}-${last}/${#LOG_BUFFER[@]} "
            fi
            fitf "$rtitle" "$L_INNER_R" "$B_H" rt
            lrow="${FG_BORDER}${B_TL}${lt}${B_TR}${C_RESET}"
            rrow="${FG_BORDER}${B_TL}${rt}${B_TR}${C_RESET}"
        elif (( r == L_PANEL_H - 1 )); then
            repeat_ch "$B_H" "$L_INNER_L" lb
            repeat_ch "$B_H" "$L_INNER_R" rb
            lrow="${FG_BORDER}${B_BL}${lb}${B_BR}${C_RESET}"
            rrow="${FG_BORDER}${B_BL}${rb}${B_BR}${C_RESET}"
        else
            i=$(( r - 1 ))

            # ---- left: menu, then the branding block pinned to the bottom
            if (( i < ${#MENU_LABELS[@]} )); then
                if (( i == MENU_SEL )); then
                    fitf "${M_SEL} ${MENU_LABELS[i]}" "$L_INNER_L" " " lc
                    lrow="${FG_BORDER}${B_V}${BG_SEL}${FG_SEL}${C_BOLD}${lc}${BG_NAV}${FG_BORDER}${B_V}${C_RESET}"
                else
                    fitf "${M_OFF} ${MENU_LABELS[i]}" "$L_INNER_L" " " lc
                    lrow="${FG_BORDER}${B_V}${FG_TXT}${lc}${FG_BORDER}${B_V}${C_RESET}"
                fi
            elif (( SHOW_BRAND == 1 && i >= L_CONTENT_H - BRAND_H )); then
                bidx=$(( i - (L_CONTENT_H - BRAND_H) ))
                fitf "${BRAND_LINES[bidx]}" "$L_INNER_L" " " lc
                if (( bidx < 2 )); then
                    lrow="${FG_BORDER}${B_V}${FG_BRAND}${C_BOLD}${lc}${FG_BORDER}${B_V}${C_RESET}"
                else
                    lrow="${FG_BORDER}${B_V}${FG_DIM}${lc}${FG_BORDER}${B_V}${C_RESET}"
                fi
            else
                fitf "" "$L_INNER_L" " " lc
                lrow="${FG_BORDER}${B_V}${lc}${FG_BORDER}${B_V}${C_RESET}"
            fi

            # ---- right: output (windowed by SCROLL_OFFSET)
            loidx=$(( SCROLL_OFFSET + i ))
            if (( loidx < ${#LOG_BUFFER[@]} )); then
                fitf "${LOG_BUFFER[loidx]}" "$L_INNER_R" " " rc
                line_color "${LOG_BUFFER[loidx]}"
                rrow="${FG_BORDER}${B_V}${LINE_FG}${rc}${FG_BORDER}${B_V}${C_RESET}"
            else
                fitf "" "$L_INNER_R" " " rc
                rrow="${FG_BORDER}${B_V}${rc}${FG_BORDER}${B_V}${C_RESET}"
            fi
        fi

        # drop shadow occupies the 1 column between the panes, offset one row down
        seg=$'\e['"$row"';1H'"${BG_NAV}${lrow}"
        if (( r > 0 )); then
            seg+="${BG_SHADOW}${FG_SHADOW}${SHADOW_CH}${C_RESET}"
        else
            seg+="${BG_SHADOW} ${C_RESET}"
        fi
        seg+="${BG_EXEC}${rrow}"
        buf+="$seg"
    done

    # ---- shadow band under the navigation pane
    row=$(( L_LINES - 1 ))
    repeat_ch "$SHADOW_CH" "$L_LEFT" lb
    repeat_ch " " $(( L_COLS - L_LEFT - 1 )) rb
    buf+=$'\e['"$row"';1H'"${BG_SHADOW} ${FG_SHADOW}${lb}${BG_EXEC}${rb}${C_RESET}"

    # ---- footer (only keys that actually work)
    if (( RUNNING == 1 )); then
        local foot="Running...   [q] Abort"
    else
        local foot="[j/k] or [Up/Down] Navigate   [PgUp/PgDn] Scroll   Click/Enter Select   [q] Quit"
    fi
    # One column short of full width: writing the final cell of the final row
    # is what makes a terminal scroll the whole screen up (pushing the header
    # out of view). Never touch it.
    fitf "$foot" $(( L_COLS - 1 )) " " tmp
    buf+=$'\e['"$L_LINES"';1H'"${BG_HDR}${FG_DIM}${tmp}${C_RESET}"

    printf '%s\e[1;1H\e[?2026l' "$buf"
}

render_frame_small() {
    render_too_small
}

# ------------------------------------------------------------
# Input
# ------------------------------------------------------------
menu_move() {
    local d="$1"
    MENU_SEL=$(( MENU_SEL + d ))
    (( MENU_SEL < 0 )) && MENU_SEL=0
    (( MENU_SEL >= ${#MENU_LABELS[@]} )) && MENU_SEL=$(( ${#MENU_LABELS[@]} - 1 ))
    RENDER_NEEDED=1
}

# Left-click on a Navigation row: first click SELECTS, a second click on the
# already-selected row RUNS it. (Avoids accidental execution on a stray click.)
handle_click() {
    local mx="$1" my="$2" idx
    layout
    (( mx < 1 || mx > L_LEFT )) && return 0        # not in the nav pane
    (( my < L_TOP + 1 )) && return 0               # header area
    idx=$(( my - L_TOP - 1 ))
    (( idx < 0 || idx >= ${#MENU_LABELS[@]} )) && return 0

    if (( idx == MENU_SEL )); then
        dbg "click x=${mx} y=${my} -> already selected ${idx}:${MENU_ACTIONS[idx]} -> run"
        RENDER_NEEDED=1
        activate
    else
        dbg "click x=${mx} y=${my} -> select ${idx} (not running)"
        MENU_SEL=$idx
        RENDER_NEEDED=1
    fi
}

# Dispatch an already-read escape sequence body (the part after ESC):
#   A / B        arrows
#   5~ / 6~      PgUp / PgDn
#   <b;x;yM      SGR mouse (b=0 left press, b=64 wheel up, b=65 wheel down)
#   <b;x;ym      SGR release - ignored
# Kept separate from handle_key so it can be exercised without a tty.
handle_escape_seq() {
    local seq="$1"
    case "$seq" in
        '[A') menu_move -1 ;;
        '[B') menu_move 1 ;;
        '[5~') scroll $(( -OUT_ROWS )) ;;
        '[6~') scroll "$OUT_ROWS" ;;
        '[<'*[Mm])
            local sfx="${seq: -1}"
            local body="${seq#\[<}"
            body="${body:0:${#body}-1}"
            local mbtn="${body%%;*}"
            local mrest="${body#*;}"
            local mx="${mrest%%;*}"
            local my="${mrest#*;}"
            case "$mbtn" in
                64) scroll -3 ;;                 # wheel up
                65) scroll 3 ;;                  # wheel down
                0)  [[ "$sfx" == "M" ]] && handle_click "$mx" "$my" ;;   # left press
            esac
            ;;
    esac
}

# Consume keys that are already queued, without rendering between them.
# This is what stops a mouse-wheel burst from doing one full repaint per event.
drain_pending_keys() {
    local k="" n=0
    while (( n < 64 )); do
        IFS= read -rsn1 -t 0.005 k </dev/tty 2>/dev/null || break
        handle_key "$k"
        n=$(( n + 1 ))
    done
}

handle_key() {
    local key="$1"
    dbg "key rc=0 len=${#key} hex=$(printf '%s' "$key" | od -An -tx1 | tr -d ' \n')"
    case "$key" in
        q|Q) QUIT=1 ;;
        j)   menu_move 1 ;;
        k)   menu_move -1 ;;
        # Enter arrives as an EMPTY string: `read -n1` strips the newline it
        # just read. It can also arrive as CR or LF on other terminals.
        ''|$'\r'|$'\n')
            dbg "ENTER -> action=${MENU_ACTIONS[MENU_SEL]} sel=${MENU_SEL}"
            activate
            ;;
        $'\e')
            # Consume the complete sequence, then dispatch.
            local seq="" ch=""
            while IFS= read -rsn1 -t 0.05 ch </dev/tty 2>/dev/null; do
                seq+="$ch"
                case "$ch" in
                    [A-Za-z~]) break ;;
                esac
                (( ${#seq} >= 24 )) && break
            done
            dbg "escape seq [${seq}]"
            handle_escape_seq "$seq"
            ;;
    esac
}

# ------------------------------------------------------------
# Command execution (FIFO stream, read in THIS shell)
# ------------------------------------------------------------
# Generic streaming runner: executes STREAM_CMD inside TMP_DIR and appends its
# stdout/stderr to LOG_BUFFER. Sets STREAM_RC. The caller prepares the buffer.
stream_run() {
    local -a cmd=("${STREAM_CMD[@]}")
    local line="" rc=0 partial="" got=0 k="" pid=0 n=0
    local rcfile=""
    STREAM_RC=0
    RUNNING=1

    if [[ -z "${TMP_DIR:-}" || ! -d "$TMP_DIR" ]]; then
        add_output_line "[FAIL] workspace directory is missing"
        RUNNING=0
        return 1
    fi

    FIFO="$TMP_DIR/.ui.fifo"
    rm -f "$FIFO"
    if ! mkfifo "$FIFO" 2>/dev/null; then
        add_output_line "[FAIL] Cannot create FIFO in $TMP_DIR"
        RUNNING=0
        return 1
    fi

    # Child writes its exit status to a file when it finishes. Completion is
    # detected by that file, NOT by EOF (we hold the write end) and NOT by
    # `kill -0` (which still succeeds for an unreaped zombie).
    rcfile="$TMP_DIR/.ui.rc"
    rm -f "$rcfile"
    (
        sub_rc=1
        if cd "$TMP_DIR"; then
            LC_ALL="$ORIG_LC_ALL" "${cmd[@]}"
            sub_rc=$?
        fi
        printf '%s' "$sub_rc" > "$rcfile"
    ) >"$FIFO" 2>&1 </dev/null &
    pid=$!
    AGENT_PID=$pid
    exec 9<>"$FIFO"        # read+write: the open can never block

    while :; do
        got=0
        n=0
        while (( n < 500 )); do
            IFS= read -r -t 0.1 -u 9 line
            rc=$?
            if (( rc == 0 )); then
                add_output_line "${partial}${line}"
                partial=""
                got=1
            else
                [[ -n "$line" ]] && partial+="$line"
                break
            fi
            n=$(( n + 1 ))
        done

        if [[ -s "$rcfile" ]]; then
            # child finished: drain whatever is still buffered, flush partial
            n=0
            while (( n < 1000 )); do
                IFS= read -r -t 0.05 -u 9 line
                rc=$?
                if (( rc == 0 )); then
                    add_output_line "${partial}${line}"
                    partial=""
                    got=1
                else
                    [[ -n "$line" ]] && partial+="$line"
                    break
                fi
                n=$(( n + 1 ))
            done
            [[ -n "$partial" ]] && { add_output_line "$partial"; partial=""; got=1; }
            break
        fi

        (( got == 1 )) && RENDER_NEEDED=1
        if (( WINCH_FLAG == 1 )); then
            WINCH_FLAG=0
            get_size
            RENDER_NEEDED=1
        fi
        if (( RENDER_NEEDED == 1 )); then
            RENDER_NEEDED=0
            render_frame
        fi

        k=""
        IFS= read -rsn1 -t 0.02 k </dev/tty 2>/dev/null || k=""
        if [[ "$k" == "q" || "$k" == "Q" ]]; then
            dbg "abort requested"
            kill "$pid" 2>/dev/null
        fi
    done

    exec 9<&-
    rm -f "$FIFO" 2>/dev/null
    FIFO=""
    wait "$pid" 2>/dev/null
    STREAM_RC="$(cat "$rcfile" 2>/dev/null)"
    [[ -z "$STREAM_RC" ]] && STREAM_RC=130
    rm -f "$rcfile" 2>/dev/null
    AGENT_PID=""
    RUNNING=0
    dbg "stream finished rc=${STREAM_RC} lines=${#LOG_BUFFER[@]}"
    return 0
}

# ---- agent actions ------------------------------------------------
run_and_stream() {
    local -a args=("$@")
    LOG_BUFFER=()
    SCROLL_OFFSET=0
    SCROLL_FOLLOW=1
    STATUS_MSG="Running..."
    add_output_line "[INFO] Running: ./agent.sh ${args[*]}"
    RENDER_NEEDED=1
    render_frame
    RENDER_NEEDED=0

    if [[ ! -x "$TMP_DIR/agent.sh" ]]; then
        add_output_line "[FAIL] agent.sh is not available - re-run to re-download"
        STATUS_MSG="Not ready"
        RENDER_NEEDED=1
        render_frame
        RENDER_NEEDED=0
        return 1
    fi

    STREAM_CMD=(./agent.sh "${args[@]}")
    stream_run
    copy_output
    if [[ "$STREAM_RC" == "0" ]]; then
        add_output_line "[OK] agent.sh completed (exit 0)"
        STATUS_MSG="Ready"
    else
        add_output_line "[FAIL] agent.sh exited ${STREAM_RC}"
        STATUS_MSG="Command failed (${STREAM_RC})"
    fi
    add_output_line "[INFO] Reports: ${REPORT_DIR}/"
    RENDER_NEEDED=1
    render_frame
    RENDER_NEEDED=0
    return 0
}

# ------------------------------------------------------------
# Line input for the Execution Output pane.
# The terminal is in -icanon -echo, so characters are echoed manually.
# Enter submits (read -n1 strips the newline -> empty string), ESC cancels.
# ------------------------------------------------------------
prompt_input() {
    local prompt="$1" __v="$2"
    local buf="" key="" rc=0 done=0 status=1
    printf -v "$__v" '%s' ""

    # Typing mode: switch mouse reporting off. Otherwise a stray click would
    # stream "[<0;12;5M" into the buffer as printable characters.
    printf '\e[?1000l\e[?1006l'

    LOG_BUFFER=("$prompt" "" "> _")
    SCROLL_OFFSET=0
    SCROLL_FOLLOW=1
    RENDER_NEEDED=1
    render_frame
    RENDER_NEEDED=0

    while (( done == 0 )); do
        key=""
        IFS= read -rsn1 -t 120 key </dev/tty
        rc=$?
        if (( rc > 128 )); then
            done=1; status=1                 # idle timeout -> cancel
            continue
        fi
        if (( rc != 0 )); then
            done=1; status=1                 # tty gone
            continue
        fi
        case "$key" in
            "")                              # Enter
                printf -v "$__v" '%s' "$buf"
                done=1; status=0
                continue
                ;;
            $'\e')                           # ESC
                done=1; status=1
                continue
                ;;
            $'\x7f'|$'\x08')                 # Backspace
                buf="${buf%?}"
                ;;
            *)
                [[ "$key" == [[:print:]] ]] && buf+="$key"
                ;;
        esac
        LOG_BUFFER=("$prompt" "" "> ${buf}_")
        RENDER_NEEDED=1
        render_frame
        RENDER_NEEDED=0
    done

    printf '\e[?1000h\e[?1006h'              # back to click/wheel mode
    return $status
}

# "Run Filtered Collectors" -> agent.sh --report --only=<filter>
run_only_prompt() {
    local f=""
    if ! prompt_input "Collector filter (e.g. dns,backup) then Enter, Esc cancels:" f; then
        LOG_BUFFER=("[INFO] Cancelled.")
        STATUS_MSG="Ready"
        RENDER_NEEDED=1
        render_frame
        RENDER_NEEDED=0
        return 1
    fi
    [[ -z "$f" ]] && f="all"
    run_and_stream --report "--only=${f}"
}

# "Update Agent / IceWarp" -> re-download the agent package from a user URL.
# NOTE: this updates the AGENT package in the current session workspace only.
# The agent is stateless by design, so nothing is written outside TMP_DIR.
update_agent() {
    local url=""
    if ! prompt_input "Update package URL (Enter = default, Esc cancels):" url; then
        LOG_BUFFER=("[INFO] Update cancelled.")
        STATUS_MSG="Ready"
        RENDER_NEEDED=1
        render_frame
        RENDER_NEEDED=0
        return 1
    fi
    [[ -z "$url" ]] && url="${BASE_URL}/linux-agent.tar.gz"

    cat > "$TMP_DIR/.ui_update.sh" <<'UPD'
#!/bin/bash
url="$1"; au="$2"; ap="$3"
echo "[INFO] Source: $url"
rm -f .update.tar.gz
if ! curl -fsSL -u "$au:$ap" "$url" -o .update.tar.gz; then
    echo "[FAIL] Download failed - check URL, credentials and network"
    exit 1
fi
echo "[OK] Downloaded $(wc -c < .update.tar.gz) bytes"
if ! tar -tzf .update.tar.gz >/dev/null 2>&1; then
    echo "[FAIL] Not a valid .tar.gz archive"
    exit 1
fi
rm -rf .update_stage
mkdir -p .update_stage
if ! tar -xzf .update.tar.gz -C .update_stage; then
    echo "[FAIL] Extraction failed"
    exit 1
fi
if [ ! -f .update_stage/agent.sh ]; then
    echo "[FAIL] Archive contains no agent.sh - refusing to install"
    exit 1
fi
echo "[INFO] Installing runtime files..."
for f in agent.sh VERSION config lib collectors; do
    [ -e ".update_stage/$f" ] || continue
    rm -rf "$f"
    cp -R ".update_stage/$f" .
    echo "[OK] installed $f"
done
chmod +x agent.sh 2>/dev/null || true
rm -rf .update_stage .update.tar.gz
echo "[OK] Update complete."
exit 0
UPD

    LOG_BUFFER=()
    SCROLL_OFFSET=0
    SCROLL_FOLLOW=1
    STATUS_MSG="Updating..."
    add_output_line "[INFO] Updating agent package from: $url"
    add_output_line "[WARN] IceWarp itself is NOT upgraded by this action -"
    add_output_line "       no IceWarp upgrade command is defined in this package."
    add_output_line "[INFO] This refreshes the agent (collectors/lib/PDF code)."
    RENDER_NEEDED=1
    render_frame
    RENDER_NEEDED=0

    STREAM_CMD=(bash .ui_update.sh "$url" "$AUTH_USER" "$AUTH_PASS")
    stream_run

    if [[ "$STREAM_RC" == "0" ]]; then
        read_target_version
        add_output_line "[OK] Now running agent v${AGENT_VERSION:-unknown} (IceWarp target ${TARGET_VERSION:-unset})"
        STATUS_MSG="Ready"
    else
        add_output_line "[FAIL] Update failed (exit ${STREAM_RC})"
        STATUS_MSG="Update failed"
    fi
    RENDER_NEEDED=1
    render_frame
    RENDER_NEEDED=0
    return 0
}

show_last_report() {
    local newest="" found=0 sz="" mt="" host="" spec="" label="" glob=""
    LOG_BUFFER=()
    SCROLL_OFFSET=0
    SCROLL_FOLLOW=1
    STATUS_MSG="Latest reports"

    add_output_line "[INFO] Newest artifacts in ${REPORT_DIR}"
    add_output_line ""

    if [[ -d "$REPORT_DIR" ]]; then
        for spec in "technical PDF|report_*.pdf" \
                    "management PDF|management_report_*.pdf" \
                    "health JSON|health_*.json"; do
            label="${spec%%|*}"
            glob="${spec#*|}"
            newest="$(ls -1t "$REPORT_DIR"/$glob 2>/dev/null | head -n1)"
            if [[ -n "$newest" && -f "$newest" ]]; then
                found=$(( found + 1 ))
                sz="$(stat -c '%s' "$newest" 2>/dev/null || echo '?')"
                mt="$(date -r "$newest" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')"
                add_output_line "[OK ] ${label}: $(basename "$newest")"
                add_output_line "        ${sz} bytes, modified ${mt}"
            else
                add_output_line "[----] ${label}: none yet"
            fi
        done
    else
        add_output_line "[WARN] ${REPORT_DIR} does not exist yet."
    fi

    add_output_line ""
    if (( found == 0 )); then
        add_output_line "[WARN] No reports have been generated yet."
        add_output_line "[INFO] Choose 'Run Health Assessment' to create them."
    else
        host="$(hostname 2>/dev/null || echo this-server)"
        add_output_line "[INFO] Copy to your workstation with:"
        add_output_line "        scp root@${host}:${REPORT_DIR}/report_*.pdf ."
        add_output_line "[INFO] PDFs cannot be rendered inside this TUI."
    fi
    RENDER_NEEDED=1
    render_frame
    RENDER_NEEDED=0
}

activate() {
    case "${MENU_ACTIONS[MENU_SEL]}" in
        quit)   QUIT=1 ;;
        run)    run_and_stream --report ;;
        config) run_and_stream --config ;;
        apply)  run_and_stream --config --apply ;;
        only)   run_only_prompt ;;
        list)   run_and_stream --list ;;
        report) show_last_report ;;
        update) update_agent ;;
    esac
    RENDER_NEEDED=1
}

# ------------------------------------------------------------
# Environment detection (once)
# ------------------------------------------------------------
detect_system() {
    local k v p t=""
    if [[ -f /etc/os-release ]]; then
        while IFS='=' read -r k v; do
            case "$k" in
                NAME)       OS_NAME="${v//\"/}" ;;
                VERSION_ID) OS_VERSION="${v//\"/}" ;;
            esac
        done < /etc/os-release
    fi
    [[ -z "$OS_NAME" ]] && OS_NAME="Linux"

    for p in /opt/icewarp /usr/local/icewarp /var/icewarp /home/icewarp; do
        [[ -x "$p/tool.sh" ]] && { IW_PATH="$p"; break; }
    done
    [[ -z "$IW_PATH" ]] && IW_PATH="not found"

    IW_VERSION="unknown"
    if [[ -x "$IW_PATH/tool.sh" ]]; then
        if command -v timeout >/dev/null 2>&1; then
            t="$(timeout 5 "$IW_PATH/tool.sh" get system C_Version 2>/dev/null | head -n1 | tr -d '[:space:]')"
        else
            t="$("$IW_PATH/tool.sh" get system C_Version 2>/dev/null | head -n1 | tr -d '[:space:]')"
        fi
        t="${t#C_Version:}"          # tool.sh prefixes the key name
        t="${t#C_Version=}"
        [[ -n "$t" ]] && IW_VERSION="$t"
    fi
}

# ------------------------------------------------------------
# Package fetch (output to a hidden log, never to the TUI)
# ------------------------------------------------------------
fetch_package() {
    local pkg="$TMP_DIR/linux-agent.tar.gz"
    local log="$TMP_DIR/.bootstrap.log"
    rm -f "$pkg"
    {
        curl -sSL -f -u "${AUTH_USER}:${AUTH_PASS}" \
            "${BASE_URL}/linux-agent.tar.gz" -o "$pkg" </dev/null &&
        tar -xzf "$pkg" -C "$TMP_DIR" &&
        rm -f "$pkg" &&
        chmod +x "$TMP_DIR/agent.sh"
    } >>"$log" 2>&1
    [[ -x "$TMP_DIR/agent.sh" ]]
}

copy_output() {
    [[ -d "$TMP_DIR/output" ]] || return 0
    mkdir -p "$START_DIR/output" 2>/dev/null || return 0
    cp -R "$TMP_DIR/output/." "$START_DIR/output/" 2>/dev/null || true
}

# ------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------
cleanup() {
    trap - EXIT INT TERM WINCH

    [[ -n "$AGENT_PID" ]] && kill "$AGENT_PID" 2>/dev/null
    exec 9<&- 2>/dev/null
    [[ -n "$FIFO" && -f "$FIFO" ]] && rm -f "$FIFO" 2>/dev/null

    if (( IS_TTY == 1 )); then
        { : </dev/tty; } 2>/dev/null && {
            # Restore mouse reporting FIRST, then cursor/wrap/alt-screen.
            # Without ?1000l/?1006l the shell would keep receiving mouse
            # escape sequences after we exit.
            printf '\e[?1000l\e[?1006l\e[?7h\e[?25h\e[0m\e[?1049l' 2>/dev/null >/dev/tty
            [[ -n "$STTY_SAVE" ]] && stty "$STTY_SAVE" 2>/dev/null </dev/tty
            stty sane 2>/dev/null </dev/tty
        }
    fi

    case "$TMP_DIR" in
        */icewarp-health-agent.*) rm -rf -- "$TMP_DIR" ;;
    esac
    return 0
}

# ------------------------------------------------------------
# TUI
# ------------------------------------------------------------
tui_init() {
    : >"$DBG_LOG" 2>/dev/null
    dbg "=== TUI start (bash ${BASH_VERSION}) ==="

    # Wipe scrollback BEFORE switching buffers. The render path emits zero
    # newline bytes (verified), so the terminal scrollbar can only be leftover
    # scrollback from the shell/curl output. ED3 (\e[3J) drops that history and
    # the bar collapses; ED2 clears the visible screen.
    printf '\e[3J\e[2J\e[H'
    printf '\e[?1049h\e[?7l\e[?25l'
    # Mouse: ?1000 = button events, ?1006 = SGR extended coordinates, which
    # is what lets us parse wheel up (?64) / down (?65) reliably.
    printf '\e[?1000h\e[?1006h'
    # Explicit non-canonical mode: one byte per read, no echo, no line
    # buffering. This is what makes j/k/Enter work without a newline.
    stty -icanon -echo min 1 time 0 2>/dev/null </dev/tty

    get_size
    dbg "terminal ${T_COLS}x${T_LINES}"
    read_stats
    LAST_STATS=$SECONDS
    STATUS_MSG="Detecting system"
    render_frame
    RENDER_NEEDED=0

    detect_system

    STATUS_MSG="Preparing workspace"
    add_output_line "[INFO] ${OS_NAME} ${OS_VERSION} | IceWarp ${IW_VERSION} | ${IW_PATH}"
    render_frame
    RENDER_NEEDED=0

    TMP_DIR="$(mktemp -d -t icewarp-health-agent.XXXXXX)" || {
        STATUS_MSG="Failed"
        add_output_line "[FAIL] Cannot create temporary directory"
        RENDER_NEEDED=1
        render_frame
        RENDER_NEEDED=0
        return 1
    }

    add_output_line "[INFO] Downloading package..."
    STATUS_MSG="Downloading package"
    render_frame
    RENDER_NEEDED=0

    if ! fetch_package; then
        STATUS_MSG="Download failed"
        add_output_line "[FAIL] Download/extract failed - check credentials or network"
        add_output_line "[INFO] Log: ${TMP_DIR}/.bootstrap.log"
        RENDER_NEEDED=1
        render_frame
        RENDER_NEEDED=0
        return 1
    fi

    read_target_version          # parses AGENT_VERSION + ICEWARP_TARGET from VERSION
    STATUS_MSG="Ready"
    add_output_line "[OK] Package ready (agent v${AGENT_VERSION:-unknown})"
    if (( VERSION_STALE == 1 )); then
        add_output_line "[WARN] IceWarp ${IW_VERSION} is older than target ${TARGET_VERSION}"
    fi
    add_output_line "[INFO] j/k or arrows to move, Enter to run, q to quit."
    RENDER_NEEDED=1
    render_frame
    RENDER_NEEDED=0
    return 0
}

tui_loop() {
    local key="" rc=0
    while (( QUIT == 0 )); do
        if (( WINCH_FLAG == 1 )); then
            WINCH_FLAG=0
            get_size
            RENDER_NEEDED=1
        fi

        if (( SECONDS - LAST_STATS >= REFRESH_SECS )); then
            LAST_STATS=$SECONDS
            read_stats
            if (( RENDER_NEEDED == 0 )); then
                render_stats_only     # repaint the header only: no flicker
            fi
        fi

        if (( RENDER_NEEDED == 1 )); then
            RENDER_NEEDED=0
            SCROLL_NEEDED=0
            render_frame
        elif (( SCROLL_NEEDED == 1 )); then
            SCROLL_NEEDED=0
            render_output_pane      # cheap: only the right pane
        fi

        IFS= read -rsn1 -t 1 key </dev/tty
        rc=$?
        if (( rc == 0 )); then
            handle_key "$key"
            drain_pending_keys      # coalesce queued wheel/click events
        elif (( rc > 128 )); then
            # 1s tick (no key pressed): blink the stale-version warning.
            # Only the header is repainted, so the panes never flicker.
            if (( VERSION_STALE == 1 )); then
                BLINK_ON=$(( 1 - BLINK_ON ))
                if (( RENDER_NEEDED == 0 )); then
                    render_stats_only
                fi
            fi
            continue
        else
            break
        fi
    done
}

# ------------------------------------------------------------
# Headless path
# ------------------------------------------------------------
headless() {
    local -a args=("$@")
    local rc=0
    (( ${#args[@]} )) || args=(--report)

    TMP_DIR="$(mktemp -d -t icewarp-health-agent.XXXXXX)" || {
        printf 'ERROR: cannot create temporary directory\n' >&2
        return 1
    }

    printf '[bootstrap] downloading package...\n' >&2
    if ! fetch_package; then
        printf '[bootstrap] download/extract failed\n' >&2
        printf '[bootstrap] see %s/.bootstrap.log\n' "$TMP_DIR" >&2
        return 1
    fi

    printf '[bootstrap] running ./agent.sh %s\n' "${args[*]}" >&2
    ( cd "$TMP_DIR" && LC_ALL="$ORIG_LC_ALL" ./agent.sh "${args[@]}" ) </dev/null
    rc=$?

    copy_output
    printf '[bootstrap] reports in %s\n' "$REPORT_DIR" >&2
    return "$rc"
}

# ------------------------------------------------------------
# Entry point
# ------------------------------------------------------------
main() {
    START_DIR="$(pwd)"
    # agent.sh writes its final artifacts here (persistent, survives cleanup)
    REPORT_DIR="${HEALTH_AGENT_OUTPUT_DIR:-${HOME:-/root}/output}"

    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    if (( $# > 0 )) || [[ ! -t 1 ]] || [[ ! -r /dev/tty ]]; then
        local hrc=0
        headless "$@" || hrc=$?
        return "$hrc"
    fi

    IS_TTY=1
    STTY_SAVE="$(stty -g 2>/dev/null </dev/tty || true)"
    trap 'WINCH_FLAG=1' WINCH        # flag only - never render from the trap

    tui_init
    tui_loop
    copy_output
    return 0
}

[[ "${HEALTH_AGENT_NO_MAIN:-0}" == "1" ]] || main "$@"
