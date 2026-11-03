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

# CRLF guard (skipped under `curl | bash`, where $0 is "bash").
case "$0" in
    */*) if grep -q $'\r' "$0" 2>/dev/null; then
             printf 'ERROR: CRLF line endings in %s - convert to LF.\n' "$0" >&2
             exit 1
         fi ;;
esac

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
FIFO=""
STTY_SAVE=""
IS_TTY=0
QUIT=0
RUNNING=0
WINCH_FLAG=0
RENDER_NEEDED=1
MENU_SEL=0
OUTPUT_LINES=()
OUTPUT_SCROLL=0
OUTPUT_FOLLOW=1
OUT_ROWS=1
AGENT_PID=""
STATUS_MSG="Starting"
OS_NAME=""
OS_VERSION=""
IW_VERSION=""
IW_PATH=""
AGENT_VERSION=""

CPU_PCT=-1
CPU_PREV_T=0
CPU_PREV_I=0
RAM_PCT=0
RAM_TOTAL_MB=0
RAM_USED_MB=0
LAST_STATS=0

T_COLS=80
T_LINES=24

# ASCII-only labels: ${#s} == display width on every terminal.
MENU_LABELS=("Run Health Assessment" "Check Configuration" "Apply Configuration" \
             "View Last Report" "Quit")
MENU_ACTIONS=("run" "config" "apply" "report" "quit")
readonly M_SEL="[>]" M_OFF="[ ]"

# ------------------------------------------------------------
# Palette (TrueColor)
# ------------------------------------------------------------
readonly C_RESET=$'\e[0m'
readonly C_BOLD=$'\e[1m'

readonly BG_HDR=$'\e[48;2;30;30;40m'
readonly BG_NAV=$'\e[48;2;20;20;30m'
readonly BG_EXEC=$'\e[48;2;10;10;15m'
readonly BG_SHADOW=$'\e[48;2;6;6;10m'
readonly BG_SEL=$'\e[48;2;0;229;201m'

readonly FG_TXT=$'\e[38;2;224;224;232m'
readonly FG_DIM=$'\e[38;2;122;124;145m'
readonly FG_BORDER=$'\e[38;2;92;96;132m'
readonly FG_ACC=$'\e[38;2;255;175;80m'
readonly FG_TITLE=$'\e[38;2;190;150;255m'
readonly FG_ERR=$'\e[38;2;255;95;95m'
readonly FG_SEL=$'\e[38;2;0;0;0m'
readonly FG_SHADOW=$'\e[38;2;40;43;62m'

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
    local s="$1" __v="$2"
    local n=${#s} i=0 w=0
    if [[ "$s" != *[!-~]* ]]; then printf -v "$__v" '%d' "$n"; return; fi
    while (( i < n )); do
        uw_at "$s" "$i"
        w=$(( w + UW_W )); i=$(( i + UW_N ))
    done
    printf -v "$__v" '%d' "$w"
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
    local s="$1" width="$2" fill="${3:- }" __v="$4"
    local n=${#s} i=0 w=0 out="" pad="" limit
    if (( width <= 0 )); then printf -v "$__v" '%s' ""; return; fi
    limit=$width
    while (( i < n )); do
        uw_at "$s" "$i"
        (( w + UW_W > limit )) && break
        out+="${s:i:UW_N}"
        w=$(( w + UW_W )); i=$(( i + UW_N ))
    done
    if (( i < n )); then
        # Truncated: reserve 3 columns for an ASCII marker so no non-ASCII
        # glyph is ever needed inside a framed cell.
        if (( width >= 4 )); then
            limit=$(( width - 3 ))
            out=""; w=0; i=0
            while (( i < n )); do
                uw_at "$s" "$i"
                (( w + UW_W > limit )) && break
                out+="${s:i:UW_N}"
                w=$(( w + UW_W )); i=$(( i + UW_N ))
            done
            out+="..."; w=$(( w + 3 ))
        fi
    fi
    (( w < width )) && repeat_ch "$fill" $(( width - w )) pad && out+="$pad"
    printf -v "$__v" '%s' "$out"
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
    OUTPUT_LINES+=("$s")
    if (( ${#OUTPUT_LINES[@]} > LOG_CAP )); then
        OUTPUT_LINES=("${OUTPUT_LINES[@]:1000}")
    fi
    if (( OUTPUT_FOLLOW == 1 )); then
        OUTPUT_SCROLL=$(( ${#OUTPUT_LINES[@]} - OUT_ROWS ))
        (( OUTPUT_SCROLL < 0 )) && OUTPUT_SCROLL=0
    fi
}

scroll() {
    local d="$1" max
    OUTPUT_FOLLOW=0
    OUTPUT_SCROLL=$(( OUTPUT_SCROLL + d ))
    max=$(( ${#OUTPUT_LINES[@]} - OUT_ROWS ))
    (( max < 0 )) && max=0
    (( OUTPUT_SCROLL > max )) && OUTPUT_SCROLL=$max
    (( OUTPUT_SCROLL < 0 )) && OUTPUT_SCROLL=0
    (( OUTPUT_SCROLL >= max )) && OUTPUT_FOLLOW=1
    RENDER_NEEDED=1
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
# Renderer
# ------------------------------------------------------------
render_too_small() {
    local msg buf r tmp
    msg="Terminal too small: ${T_COLS}x${T_LINES} (need ${MIN_COLS}x${MIN_ROWS}) - enlarge window or press q"
    r=$(( T_LINES / 2 )); (( r < 1 )) && r=1
    fitf "$msg" "$T_COLS" " " tmp
    buf=$'\e[H\e['"$r"';1H'"${FG_ERR}${C_BOLD}${tmp}${C_RESET}"
    printf '\e[?2026h%s\e[?2026l' "$buf"
}

# Header rows 1..4 only - used for the cheap stats refresh.
render_header() {
    local cols="$L_COLS" buf="" tmp cpu ram info stat

    fitf " IceWarp Health Agent " $(( cols - 2 )) "$B_H" tmp
    buf+=$'\e[1;1H'"${BG_HDR}${FG_TITLE}${B_TL}${FG_BORDER}${tmp}${FG_TITLE}${B_TR}${C_RESET}"

    info="OS: ${OS_NAME} ${OS_VERSION}  |  IceWarp: ${IW_VERSION}  |  Path: ${IW_PATH}"
    fitf "$info" $(( cols - 2 )) " " tmp
    buf+=$'\e[2;1H'"${BG_HDR}${FG_BORDER}${B_V}${FG_TXT}${tmp}${FG_BORDER}${B_V}${C_RESET}"

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
    printf '\e[?2026h'
    render_header
    printf '\e[?2026l'
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

    local buf="" tmp lb lt rb rt lc rc row r i loidx seg lrow rrow

    printf '\e[?2026h'
    render_header

    # ---- panel body
    for (( r = 0; r < L_PANEL_H; r++ )); do
        row=$(( L_TOP + r ))

        if (( r == 0 )); then
            fitf " Navigation " "$L_INNER_L" "$B_H" lt
            fitf " Execution Output " "$L_INNER_R" "$B_H" rt
            lrow="${FG_BORDER}${B_TL}${lt}${B_TR}${C_RESET}"
            rrow="${FG_BORDER}${B_TL}${rt}${B_TR}${C_RESET}"
        elif (( r == L_PANEL_H - 1 )); then
            repeat_ch "$B_H" "$L_INNER_L" lb
            repeat_ch "$B_H" "$L_INNER_R" rb
            lrow="${FG_BORDER}${B_BL}${lb}${B_BR}${C_RESET}"
            rrow="${FG_BORDER}${B_BL}${rb}${B_BR}${C_RESET}"
        else
            i=$(( r - 1 ))

            # ---- left: menu
            if (( i < ${#MENU_LABELS[@]} )); then
                if (( i == MENU_SEL )); then
                    fitf "${M_SEL} ${MENU_LABELS[i]}" "$L_INNER_L" " " lc
                    lrow="${FG_BORDER}${B_V}${BG_SEL}${FG_SEL}${C_BOLD}${lc}${BG_NAV}${FG_BORDER}${B_V}${C_RESET}"
                else
                    fitf "${M_OFF} ${MENU_LABELS[i]}" "$L_INNER_L" " " lc
                    lrow="${FG_BORDER}${B_V}${FG_TXT}${lc}${FG_BORDER}${B_V}${C_RESET}"
                fi
            else
                fitf "" "$L_INNER_L" " " lc
                lrow="${FG_BORDER}${B_V}${lc}${FG_BORDER}${B_V}${C_RESET}"
            fi

            # ---- right: output
            loidx=$(( OUTPUT_SCROLL + i ))
            if (( loidx < ${#OUTPUT_LINES[@]} )); then
                fitf "${OUTPUT_LINES[loidx]}" "$L_INNER_R" " " rc
                rrow="${FG_BORDER}${B_V}${FG_TXT}${rc}${FG_BORDER}${B_V}${C_RESET}"
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
        local foot="[j/k] or [Up/Down] Navigate   [PgUp/PgDn] Scroll   [Enter] Select   [q] Quit"
    fi
    fitf "$foot" "$L_COLS" " " tmp
    buf+=$'\e['"$L_LINES"';1H'"${BG_HDR}${FG_DIM}${tmp}${C_RESET}"

    printf '%s\e[?2026l' "$buf"
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

handle_key() {
    local key="$1" k2="" k3=""
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
            IFS= read -rsn2 -t 0.05 k2 </dev/tty 2>/dev/null || k2=""
            dbg "escape seq [${k2}]"
            case "$k2" in
                '[A') menu_move -1 ;;
                '[B') menu_move 1 ;;
                '[5')
                    IFS= read -rsn1 -t 0.05 k3 </dev/tty 2>/dev/null || k3=""
                    scroll $(( -OUT_ROWS ))
                    ;;
                '[6')
                    IFS= read -rsn1 -t 0.05 k3 </dev/tty 2>/dev/null || k3=""
                    scroll "$OUT_ROWS"
                    ;;
            esac
            ;;
    esac
}

# ------------------------------------------------------------
# Command execution (FIFO stream, read in THIS shell)
# ------------------------------------------------------------
run_and_stream() {
    local -a args=("$@")
    local -a cmd=(./agent.sh "${args[@]}")
    local line="" rc=0 partial="" got=0 k="" pid=0 arc=0 n=0
    local rcfile=""

    OUTPUT_LINES=()
    OUTPUT_SCROLL=0
    OUTPUT_FOLLOW=1
    RUNNING=1
    STATUS_MSG="Running..."
    add_output_line "[INFO] Running: ./agent.sh ${args[*]}"
    RENDER_NEEDED=1
    render_frame
    RENDER_NEEDED=0

    if [[ ! -x "$TMP_DIR/agent.sh" ]]; then
        add_output_line "[FAIL] agent.sh is not available - re-run to re-download"
        STATUS_MSG="Not ready"
        RUNNING=0
        RENDER_NEEDED=1
        render_frame
        RENDER_NEEDED=0
        return 1
    fi

    FIFO="$TMP_DIR/.ui.fifo"
    rm -f "$FIFO"
    if ! mkfifo "$FIFO" 2>/dev/null; then
        add_output_line "[FAIL] Cannot create FIFO in $TMP_DIR"
        STATUS_MSG="Failed"
        RUNNING=0
        RENDER_NEEDED=1
        render_frame
        RENDER_NEEDED=0
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
    arc="$(cat "$rcfile" 2>/dev/null)"
    [[ -z "$arc" ]] && arc=130
    rm -f "$rcfile" 2>/dev/null
    AGENT_PID=""
    RUNNING=0
    dbg "agent finished rc=${arc} lines=${#OUTPUT_LINES[@]}"

    copy_output
    if [[ "$arc" == "0" ]]; then
        add_output_line "[OK] agent.sh completed (exit 0)"
        STATUS_MSG="Ready"
    else
        add_output_line "[FAIL] agent.sh exited ${arc}"
        STATUS_MSG="Command failed (${arc})"
    fi
    add_output_line "[INFO] Reports: ${START_DIR}/output/"
    RENDER_NEEDED=1
    render_frame
    RENDER_NEEDED=0
    return 0
}

show_last_report() {
    local f found=0 sz
    OUTPUT_LINES=()
    OUTPUT_SCROLL=0
    OUTPUT_FOLLOW=1
    STATUS_MSG="Viewing last report"
    add_output_line "[INFO] Scanning for reports..."
    for f in "$START_DIR/output"/report_*.pdf "$TMP_DIR/output"/report_*.pdf; do
        [[ -f "$f" ]] || continue
        found=1
        sz="$(stat -c '%s' "$f" 2>/dev/null || echo '?')"
        add_output_line "[FOUND] ${f}  (${sz} bytes)"
    done
    if (( found == 0 )); then
        add_output_line "[WARN] No report_*.pdf found yet."
        add_output_line "[INFO] Choose 'Run Health Assessment' first."
    else
        add_output_line "[INFO] PDFs are in ${START_DIR}/output/"
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
        report) show_last_report ;;
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
            printf '\e[?7h\e[?25h\e[0m\e[?1049l' 2>/dev/null >/dev/tty
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

    printf '\e[?1049h\e[?7l\e[?25l'
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

    AGENT_VERSION="$(tr -d '[:space:]' < "$TMP_DIR/VERSION" 2>/dev/null)"
    STATUS_MSG="Ready"
    add_output_line "[OK] Package ready (agent v${AGENT_VERSION:-unknown})"
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
            render_frame
        fi

        IFS= read -rsn1 -t 1 key </dev/tty
        rc=$?
        if (( rc == 0 )); then
            handle_key "$key"
        elif (( rc > 128 )); then
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
    printf '[bootstrap] reports in %s/output\n' "$START_DIR" >&2
    return "$rc"
}

# ------------------------------------------------------------
# Entry point
# ------------------------------------------------------------
main() {
    START_DIR="$(pwd)"

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
