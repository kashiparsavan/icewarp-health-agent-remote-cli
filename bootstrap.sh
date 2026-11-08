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
# Dedicated working root. Everything this script downloads, extracts or logs
# lives under here - never /tmp. /root/output (the reports) is never touched.
AGENT_DIR="${HEALTH_AGENT_DIR:-/root/agent}"
LOG_FILE="${AGENT_DIR}/bootstrap.log"
# Absolute path to tar, resolved once. A restricted PATH must never turn
# extraction into "tar: command not found".
TAR_BIN=""
# Set when a fatal error (missing tar, unreadable package) must make the
# process exit non-zero instead of reporting success.
FATAL_ERROR=0
# Where agent.sh writes its final artifacts (persistent, not the temp workspace)
REPORT_DIR=""
FIFO=""
STTY_SAVE=""
IS_TTY=0
QUIT=0
RUNNING=0
WINCH_FLAG=0RENDER_NEEDED=1
SCROLL_NEEDED=0
# Right-pane scrolling is OFF by default: the pane always shows the last N
# lines. Set DSH_TUI_SCROLL=1 to re-enable in-memory scrolling.
NO_SCROLL="${DSH_TUI_SCROLL:+0}"
NO_SCROLL="${NO_SCROLL:-1}"
MENU_SEL=0
LOG_BUFFER=()
SCROLL_OFFSET=0
SCROLL_FOLLOW=1
OUT_ROWS=1
AGENT_PID=""
STATUS_MSG="Starting"
OS_NAME=""
OS_VERSION=""
IW_VERSION="Not Installed"
IW_PATH="N/A"
IW_INSTALLED=0
AGENT_VERSION=""

# Target version comes from the tarball's VERSION file at runtime.
TARGET_VERSION=""
VERSION_STALE=0
BLINK_ON=0
# IceWarp package sources, also read from VERSION at runtime.
ICEWARP_OFFICIAL_REPO=""
ICEWARP_PARS_AVAN_URL=""

# Probe results for the IceWarp installer menu.
IW_OFF_OK=0; IW_OFF_VERSION=""; IW_OFF_FILE=""; IW_OFF_CODE="000"
IW_PA_OK=0;  IW_PA_VERSION="";  IW_PA_FILE="";  IW_PA_CODE="000"
PROBE_CODE="000"; PST_COLOR=""; PST_TEXT=""

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
# 1 = child reads from the terminal; keystrokes are forwarded to its stdin
INTERACTIVE=0
# 1 while a single-line progress bar occupies the last output line
PROGRESS_ACTIVE=0
IN_FIFO=""
ECHO_ACTIVE=0

# ------------------------------------------------------------
# blog — append one timestamped line to the persistent bootstrap log.
# The log is never truncated: it accumulates history across runs.
# ------------------------------------------------------------
blog() {
    [[ -n "${LOG_FILE}" ]] || return 0
    # Never let a missing workdir turn logging into a shell error (this runs
    # before init_workdir on some paths).
    local _d="${LOG_FILE%/*}"
    [[ -n "${_d}" && -d "${_d}" ]] || return 0
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$*" \
        >>"${LOG_FILE}" 2>/dev/null || true
}

# ------------------------------------------------------------
# resolve_tar — locate the tar binary explicitly so a restricted or empty
# PATH cannot break package extraction. Sets TAR_BIN.
# ------------------------------------------------------------
resolve_tar() {
    local _t
    for _t in /bin/tar /usr/bin/tar /usr/local/bin/tar /sbin/tar; do
        if [[ -x "${_t}" ]]; then TAR_BIN="${_t}"; return 0; fi
    done
    _t="$(command -v tar 2>/dev/null)"
    if [[ -n "${_t}" && -x "${_t}" ]]; then TAR_BIN="${_t}"; return 0; fi
    TAR_BIN=""
    return 1
}

# ------------------------------------------------------------
# init_workdir — create /root/agent and its tmp/ subdirectory.
# Everything this script downloads, extracts or logs lives here; nothing goes
# to /tmp. /root/output (the reports) is never created or touched here.
# Falls back to ~/.icewarp-agent only when /root is not writable (non-root).
# ------------------------------------------------------------
init_workdir() {
    if ! mkdir -p "${AGENT_DIR}" 2>/dev/null || [[ ! -w "${AGENT_DIR}" ]]; then
        AGENT_DIR="${HOME:-/root}/.icewarp-agent"
        if ! mkdir -p "${AGENT_DIR}" 2>/dev/null || [[ ! -w "${AGENT_DIR}" ]]; then
            AGENT_DIR=""
            return 1
        fi
    fi
    # One log per session, named to the minute. Append-mode, so two runs in
    # the same minute share a file rather than truncating each other.
    LOG_FILE="${AGENT_DIR}/agent-$(date +%Y%m%d-%H%M 2>/dev/null).log"
    [[ "${LOG_FILE}" == *"agent-.log" ]] && LOG_FILE="${AGENT_DIR}/agent.log"
    TMP_DIR="${AGENT_DIR}/tmp"
    if ! mkdir -p "${TMP_DIR}" 2>/dev/null; then
        TMP_DIR=""
        return 1
    fi
    # Keep the logs across runs, start a fresh tmp/ each time.
    rm -rf "${TMP_DIR:?}"/* 2>/dev/null
    mkdir -p "${TMP_DIR}" 2>/dev/null
    resolve_tar || true
    blog "=== bootstrap start (pid $$) ==="
    blog "agent dir : ${AGENT_DIR}"
    blog "tmp dir   : ${TMP_DIR}"
    blog "log file  : ${LOG_FILE}"
    blog "tar       : ${TAR_BIN:-NOT FOUND}"
    dbg "workdir ${AGENT_DIR} tmp ${TMP_DIR} tar ${TAR_BIN:-none}"
    return 0
}

# ASCII-only labels: ${#s} == display width on every terminal.
# Fixed order. Entry 0 is context-sensitive: "Install IceWarp" on a server
# without IceWarp, "Update IceWarp" once it is installed. build_menu()
# rewrites label 0 after the system has been probed - nothing else moves.
MENU_LABELS=(
    "Install IceWarp"
    "Check Configuration"
    "Apply Configuration"
    "Install SSL (Let's Encrypt)"
    "Run Health Assessment"
    "List Collectors"
    "Run Filtered Collectors"
    "Quit"
)
MENU_ACTIONS=(
    "icewarp"
    "config"
    "apply"
    "ssl"
    "health"
    "list"
    "only"
    "quit"
)
readonly M_SEL="[>]" M_OFF="[ ]"

# Strict ANSI codes used by the IceWarp source report.
# These are plain SGR so they render identically on any colour terminal.
readonly A_GREEN=$'\e[32m'
readonly A_YELLOW=$'\e[33m'
readonly A_RED=$'\e[31m'
readonly A_OFF=$'\e[0m'

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
readonly DBG_LOG="${AGENT_DIR}/tui_debug.log"
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

# version_branch <version> <outvar> — Major.Minor.Patch only.
#   14.3.0.13 -> 14.3.0 ; 14.3.0 -> 14.3.0
# Used so a mirror shipping "14.3.0" is not treated as older than the
# official "14.3.0.13": they are the same release branch.
version_branch() {
    local _v="$1" _o="$2"
    local -a _p=()
    IFS='.' read -r -a _p <<< "${_v}"
    printf -v "${_o}" '%s.%s.%s' "${_p[0]:-0}" "${_p[1]:-0}" "${_p[2]:-0}"
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
        version_key "$vf" ICEWARP_OFFICIAL_REPO ICEWARP_OFFICIAL_REPO || true
        version_key "$vf" ICEWARP_PARS_AVAN_URL ICEWARP_PARS_AVAN_URL || true
    fi
    [[ -z "$AGENT_VERSION" ]] && AGENT_VERSION="unknown"
    if [[ -n "$TARGET_VERSION" && -n "$IW_VERSION" \
          && "$IW_VERSION" != "unknown" && "$IW_VERSION" != "Not Installed" ]]; then
        local _ib="" _tb=""
        version_branch "$IW_VERSION" _ib
        version_branch "$TARGET_VERSION" _tb
        # Compare the RELEASE BRANCH only. 14.3.0 and 14.3.0.13 are the same
        # branch, so a mirror that ships without the build suffix must not be
        # flagged as outdated.
        if [[ "${_ib}" != "${_tb}" ]] && version_lt "${_ib}" "${_tb}"; then
            VERSION_STALE=1
        fi
    fi
    dbg "version installed=${IW_VERSION} target=${TARGET_VERSION} agent=${AGENT_VERSION} stale=${VERSION_STALE}"
    blog "version: installed=${IW_VERSION} target=${TARGET_VERSION} agent=${AGENT_VERSION} stale=${VERSION_STALE}"
    blog "version: repo=${ICEWARP_OFFICIAL_REPO}"
    blog "version: pars_avan=${ICEWARP_PARS_AVAN_URL}"
}

# ------------------------------------------------------------
# load_version_info — make sure TARGET_VERSION, ICEWARP_OFFICIAL_REPO and
# ICEWARP_PARS_AVAN_URL are populated before the installer probes anything.
#
# VERSION ships INSIDE the agent package, and that package is no longer
# downloaded at startup, so on a fresh server all three values are empty
# until it is fetched. Without them the probe has no URL to test and wrongly
# reports Unreachable / Not Found.
# ------------------------------------------------------------
load_version_info() {
    local _vf

    # 1) the agent package is already extracted
    if [[ -n "${TMP_DIR}" && -f "${TMP_DIR}/VERSION" ]]; then
        read_target_version
        [[ -n "${TARGET_VERSION}" && -n "${ICEWARP_PARS_AVAN_URL}" ]] && return 0
    fi

    # 2) a VERSION file sitting next to where we were started
    _vf="${START_DIR:-$PWD}/VERSION"
    if [[ -f "${_vf}" ]]; then
        version_key "${_vf}" ICEWARP_TARGET TARGET_VERSION || true
        version_key "${_vf}" ICEWARP_OFFICIAL_REPO ICEWARP_OFFICIAL_REPO || true
        version_key "${_vf}" ICEWARP_PARS_AVAN_URL ICEWARP_PARS_AVAN_URL || true
        dbg "version loaded from ${_vf}"
        [[ -n "${TARGET_VERSION}" && -n "${ICEWARP_PARS_AVAN_URL}" ]] && return 0
    fi

    # 3) fetch the agent package so its VERSION becomes available
    ensure_agent || return 1
    [[ -f "${TMP_DIR}/VERSION" ]] && read_target_version
    [[ -n "${TARGET_VERSION}" && -n "${ICEWARP_PARS_AVAN_URL}" ]]
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

# pane_safe <line> <outvar>
# A line may carry its own SGR colours and end a segment with \e[0m. A bare
# reset would also drop the panel background, so every embedded reset is
# followed by the pane background + base foreground again.
pane_safe() {
    local _s="$1" _v="$2" _rep=""
    _rep=$'\e[0m'"${BG_EXEC}${FG_TXT}"
    printf -v "${_v}" '%s' "${_s//$'\e[0m'/${_rep}}"
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

# sgr_end <string> <index-of-ESC> — sets SGR_END to the index just past the
# escape sequence that starts at <index-of-ESC>. Handles CSI (ESC [ ... final)
# and simple 2-byte escapes. '[' is the introducer, NOT the terminator, so the
# scan starts after it; the final byte is in 0x40..0x7E.
sgr_end() {
    local _s="$1" _i="$2" _n _j _c
    _n=${#_s}
    _j=$(( _i + 1 ))
    if (( _j < _n )) && [[ "${_s:_j:1}" == '[' ]]; then
        _j=$(( _j + 1 ))
        while (( _j < _n )); do
            _c="${_s:_j:1}"
            _j=$(( _j + 1 ))
            [[ "${_c}" > $'\x3F' ]] && break
        done
    elif (( _j < _n )); then
        _j=$(( _j + 1 ))
    fi
    SGR_END=$_j
}

dw() {
    # All internals are _-prefixed so a caller can pass any variable name as
    # the output variable without it being shadowed by a local of the same name.
    local _s="$1" _v="$2"
    local _n=${#_s} _i=0 _w=0
    # Fast path only for pure printable ASCII (no escapes, no multibyte).
    if [[ "$_s" != *[!-~]* ]]; then printf -v "$_v" '%d' "$_n"; return; fi
    while (( _i < _n )); do
        # SGR sequences are zero width.
        if [[ "${_s:_i:1}" == $'\e' ]]; then
            sgr_end "$_s" "$_i"
            _i=$SGR_END
            continue
        fi
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

# progress_bar <percent> <outvar> [cells]
# Renders a bar that spans the output pane (default 100 cells), e.g.
# "[##########...----------]  50%". The cell count is reduced automatically
# when the pane is narrower than the requested width, so the bar always fits
# between the borders. The percentage is right-aligned in 3 columns, making
# the total width constant - the line is rewritten in place, so a changing
# width would visibly jitter.
progress_bar() {
    local _pct="$1" _v="$2" _cells="${3:-100}"
    local _filled _empty _fb="" _eb=""

    [[ "${_pct}" =~ ^[0-9]+$ ]] || _pct=0
    (( _pct > 100 )) && _pct=100

    # Keep room for "[" + "]" + " " + "100%" = 7 columns inside the pane.
    local _max="${L_INNER_R:-100}"
    (( _max < 12 )) && _max=12
    _max=$(( _max - 7 ))
    (( _cells > _max )) && _cells="$_max"
    (( _cells < 6 )) && _cells=6

    _filled=$(( _pct * _cells / 100 ))
    _empty=$(( _cells - _filled ))
    if (( _filled > 0 )); then
        printf -v _fb '%*s' "$_filled" ''
        _fb="${_fb// /█}"
    fi
    if (( _empty > 0 )); then
        printf -v _eb '%*s' "$_empty" ''
        _eb="${_eb// /░}"
    fi
    printf -v "${_v}" '[%s%s] %3d%%' "${_fb}" "${_eb}" "$_pct"
}

# stream_handle_line <text>
# Handles one line of child output. A child may emit "@@PROGRESS <pct>" to
# drive a SINGLE-LINE progress bar: instead of appending a new line, the same
# output line is rewritten in place. "@@PROGRESS CLEAR" removes it again.
# This keeps the pane clean - no dots, no scrolling, no thousands of lines.
stream_handle_line() {
    local _line="$1" _pct="" _bar=""

    case "${_line}" in
        "@@PROGRESS CLEAR")
            if (( PROGRESS_ACTIVE == 1 )); then
                if (( ${#LOG_BUFFER[@]} > 0 )); then
                    LOG_BUFFER=("${LOG_BUFFER[@]:0:${#LOG_BUFFER[@]}-1}")
                fi
                PROGRESS_ACTIVE=0
            fi
            return 0
            ;;
        "@@PROGRESS "*)
            _pct="${_line#@@PROGRESS }"
            _pct="${_pct%% *}"
            progress_bar "${_pct}" _bar
            if (( PROGRESS_ACTIVE == 1 )) && (( ${#LOG_BUFFER[@]} > 0 )); then
                LOG_BUFFER[-1]="${_bar}"          # update in place
            else
                LOG_BUFFER+=("${_bar}")
                PROGRESS_ACTIVE=1
            fi
            if (( SCROLL_FOLLOW == 1 )); then
                SCROLL_OFFSET=$(( ${#LOG_BUFFER[@]} - OUT_ROWS ))
                (( SCROLL_OFFSET < 0 )) && SCROLL_OFFSET=0
            fi
            return 0
            ;;
    esac

    PROGRESS_ACTIVE=0
    add_output_line "${_line}"
}

# fitf <string> <width> <fillchar> <outvar>
# Clips to <width> display columns then pads with <fillchar>. The ONLY place
# text touches a border, so a long label can never push an edge out.
fitf() {    local _s="$1" _width="$2" _fill="${3:- }" _v="$4"
    local _n=${#_s} _i=0 _w=0 _out="" _pad="" _limit _j _cc
    if (( _width <= 0 )); then printf -v "$_v" '%s' ""; return; fi
    _limit=$_width
    while (( _i < _n )); do
        # SGR colour sequences occupy no columns: copy them verbatim and keep
        # measuring the visible text.
        if [[ "${_s:_i:1}" == $'\e' ]]; then
            sgr_end "$_s" "$_i"
            _out+="${_s:_i:$(( SGR_END - _i ))}"
            _i=$SGR_END
            continue
        fi
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
                if [[ "${_s:_i:1}" == $'\e' ]]; then
                    sgr_end "$_s" "$_i"
                    _out+="${_s:_i:$(( SGR_END - _i ))}"
                    _i=$SGR_END
                    continue
                fi
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
# SGR colour sequences (\e[...m) are PRESERVED so a line can carry its own
# colours; every other control/escape sequence is stripped so a child process
# can never move the cursor or corrupt the frame.
sanitize() {
    local str="$1" __v="$2"
    local n i c out="" st=0 seq=""
    str="${str//$'\t'/    }"
    str="${str//$'\r'/}"
    if [[ "$str" == *[$'\x01'-$'\x1F']* ]]; then
        n=${#str}
        for (( i = 0; i < n; i++ )); do
            c="${str:i:1}"
            if (( st == 0 )); then
                if [[ "$c" == $'\e' ]]; then st=1; seq=$'\e'; continue; fi
                [[ "$c" < $'\x20' ]] && continue
                out+="$c"
            elif (( st == 1 )); then
                seq+="$c"
                if [[ "$c" == '[' ]]; then
                    st=2
                else
                    st=0; seq=""          # not a CSI - discard
                fi
            else
                seq+="$c"
                if [[ "$c" > $'\x3F' ]]; then
                    [[ "$c" == 'm' ]] && out+="$seq"   # keep SGR only
                    st=0; seq=""
                fi
            fi
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
    if [[ "${IS_TTY:-0}" == "1" ]]; then
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
    # Scrollback inside the pane is purely in-memory, but the user asked for it
    # to be switchable off; when off the pane simply tails the newest lines.
    [[ "${NO_SCROLL:-0}" == "1" ]] && return 0
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
    # STRICT DRAWING BOUNDARY
    #   rows : 1 .. LINES-1   (the footer is the last row we touch;
    #                          row LINES is never written at all)
    #   cols : 1 .. COLS-1    (the rightmost terminal column is never written)
    # Writing the bottom-right cell is the one thing that reliably makes a
    # terminal start a new scrollback line / paint its scrollbar, so the whole
    # canvas is inset by one column and the final row is left blank.
    L_COLS=$(( T_COLS - 1 ))
    (( L_COLS < 1 )) && L_COLS=1
    L_LINES=$T_LINES
    L_LEFT=$(( L_COLS * 18 / 100 ))
    (( L_LEFT < 14 )) && L_LEFT=14
    (( L_LEFT > L_COLS - 30 )) && L_LEFT=$(( L_COLS - 30 ))
    L_RIGHT=$(( L_COLS - L_LEFT - 1 ))     # 1 column reserved for the shadow
    L_TOP=5
    # Footer on L_LINES-1, shadow band on L_LINES-2, row L_LINES never drawn.
    L_FOOTER=$(( L_LINES - 1 ))
    L_BOTTOM=$(( L_LINES - 3 ))
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
    local msg buf r tmp w
    msg="Terminal too small: ${T_COLS}x${T_LINES} (need ${MIN_COLS}x${MIN_ROWS}) - enlarge window or press q"
    r=$(( T_LINES / 2 )); (( r < 1 )) && r=1
    # Same strict boundary: never reach the last column.
    w=$(( T_COLS - 1 )); (( w < 1 )) && w=1
    fitf "$msg" "$w" " " tmp
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
    local buf="" rt rb rc rc2 r row i loidx rtitle last

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
                pane_safe "${rc}" rc2
                buf+=$'\e['"$row"';'"$col"'H'"${BG_EXEC}${FG_BORDER}${B_V}${BG_EXEC}${LINE_FG}${rc2}${C_RESET}${FG_BORDER}${B_V}${C_RESET}"
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

    local buf="" tmp lb lt rb rt lc rc rc2 row r i loidx seg lrow rrow bidx

    build_branding

    # Full absolute clear at the start of EVERY frame: the buffer is wiped and
    # the cursor homed, so nothing is drawn "over" stale content and the
    # terminal never has to scroll to fit the frame.
    printf '\e[?2026h\e[?7l\e[2J\e[H'
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
                pane_safe "${rc}" rc2
                rrow="${FG_BORDER}${B_V}${BG_EXEC}${LINE_FG}${rc2}${C_RESET}${FG_BORDER}${B_V}${C_RESET}"
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

    # ---- shadow band under the navigation pane (row L_LINES-2)
    row=$(( L_LINES - 2 ))
    repeat_ch "$SHADOW_CH" "$L_LEFT" lb
    repeat_ch " " $(( L_COLS - L_LEFT - 1 )) rb
    buf+=$'\e['"$row"';1H'"${BG_SHADOW} ${FG_SHADOW}${lb}${BG_EXEC}${rb}${C_RESET}"

    # ---- footer on L_LINES-1; the true last row stays blank forever
    if [[ "${RUNNING:-0}" == "1" ]]; then
        local foot="Running...   [q] Abort"
    elif [[ "${NO_SCROLL:-0}" == "1" ]]; then
        local foot="[j/k] or [Up/Down] Navigate   Click/Enter Select   [q] Quit"
    else
        local foot="[j/k] or [Up/Down] Navigate   [PgUp/PgDn] Scroll   Click/Enter Select   [q] Quit"
    fi
    # L_COLS is already COLS-1, so this fills columns 1..COLS-1 and leaves
    # the rightmost terminal column untouched.
    fitf "$foot" "$L_COLS" " " tmp
    buf+=$'\e['"$L_FOOTER"';1H'"${BG_HDR}${FG_DIM}${tmp}${C_RESET}"

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

    # Interactive mode also needs a stdin pipe so keystrokes can be forwarded
    # to a child that prompts on the terminal (IceWarp's install.sh).
    IN_FIFO=""
    local in_src="/dev/null"
    if (( INTERACTIVE == 1 )); then
        IN_FIFO="$TMP_DIR/.ui.in"
        rm -f "$IN_FIFO"
        if ! mkfifo "$IN_FIFO" 2>/dev/null; then
            add_output_line "[FAIL] Cannot create input FIFO in $TMP_DIR"
            RUNNING=0
            return 1
        fi
        in_src="$IN_FIFO"

        # Mouse reporting MUST be off while an interactive child prompts.
        # Otherwise every mouse movement is delivered as an escape sequence
        # (e.g. "<65;104;39M") and lands in the installer's stdin, corrupting
        # the prompt. Drain whatever is already queued first.
        printf '\e[?1000l\e[?1006l' 2>/dev/null >/dev/tty
        local _drain=""
        while IFS= read -rsn1 -t 0.01 _drain </dev/tty 2>/dev/null; do :; done
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
    ) >"$FIFO" 2>&1 <"$in_src" &
    pid=$!
    AGENT_PID=$pid
    exec 9<>"$FIFO"        # read+write: the open can never block
    if (( INTERACTIVE == 1 )); then
        exec 8>"$IN_FIFO"  # rendezvous with the child's stdin
        ECHO_ACTIVE=0
    fi

    while :; do
        got=0
        n=0
        while (( n < 500 )); do
            IFS= read -r -t 0.1 -u 9 line
            rc=$?
            if (( rc == 0 )); then
                stream_handle_line "${partial}${line}"
                partial=""
                ECHO_ACTIVE=0        # next typed char starts a fresh line
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
                    stream_handle_line "${partial}${line}"
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

        # Repaint ONLY the output pane while a command streams. A full frame
        # clears the whole screen first, which makes streamed output and
        # interactive installer prompts flash/flicker unreadably.
        (( got == 1 )) && SCROLL_NEEDED=1
        if [[ "${WINCH_FLAG:-0}" == "1" ]]; then
            WINCH_FLAG=0
            get_size
            RENDER_NEEDED=1
        fi
        if [[ "${RENDER_NEEDED:-0}" == "1" ]]; then
            RENDER_NEEDED=0
            SCROLL_NEEDED=0
            render_frame
        elif [[ "${SCROLL_NEEDED:-0}" == "1" ]]; then
            SCROLL_NEEDED=0
            render_output_pane
        fi

        k=""
        IFS= read -rsn1 -t 0.02 k </dev/tty 2>/dev/null
        rc=$?
        if (( rc == 0 )); then
            if (( INTERACTIVE == 1 )); then
                # Forward the keystroke to install.sh, echoing it in the pane.
                if [[ -z "$k" ]]; then                       # Enter
                    printf '\n' >&8 2>/dev/null
                    ECHO_ACTIVE=0
                elif [[ "$k" == $'\x7f' || "$k" == $'\x08' ]]; then
                    printf '\x7f' >&8 2>/dev/null
                    if (( ECHO_ACTIVE == 1 )) && (( ${#LOG_BUFFER[@]} > 0 )); then
                        LOG_BUFFER[-1]="${LOG_BUFFER[-1]%?}"
                    fi
                elif [[ "$k" == $'\e' ]]; then
                    :                                        # arrows: don't forward junk
                else
                    printf '%s' "$k" >&8 2>/dev/null
                    if [[ "$k" == [[:print:]] ]]; then
                        if (( ECHO_ACTIVE == 0 )); then
                            [[ -n "$partial" ]] && { add_output_line "$partial"; partial=""; }
                            ECHO_ACTIVE=1
                        fi
                        if (( ${#LOG_BUFFER[@]} > 0 )); then
                            LOG_BUFFER[-1]+="$k"
                        else
                            LOG_BUFFER+=("$k")
                        fi
                    fi
                fi
                SCROLL_FOLLOW=1
                # Pane-only repaint: the installer's prompt must not be
                # cleared and redrawn on every keystroke.
                SCROLL_NEEDED=1
            elif [[ "$k" == "q" || "$k" == "Q" ]]; then
                dbg "abort requested"
                kill "$pid" 2>/dev/null
            fi
        fi
    done

    exec 9<&-
    exec 8>&- 2>/dev/null
    [[ -n "$IN_FIFO" && -f "$IN_FIFO" ]] && rm -f "$IN_FIFO" 2>/dev/null
    IN_FIFO=""
    rm -f "$FIFO" 2>/dev/null
    FIFO=""
    wait "$pid" 2>/dev/null
    STREAM_RC="$(cat "$rcfile" 2>/dev/null)"
    [[ -z "$STREAM_RC" ]] && STREAM_RC=130
    rm -f "$rcfile" 2>/dev/null
    AGENT_PID=""
    RUNNING=0

    # Interactive child is gone: give mouse reporting back to the TUI and
    # drop any keystrokes it left queued, so the next menu action starts clean.
    if (( INTERACTIVE == 1 )); then
        local _drain2=""
        while IFS= read -rsn1 -t 0.01 _drain2 </dev/tty 2>/dev/null; do :; done
        printf '\e[?1000h\e[?1006h' 2>/dev/null >/dev/tty
        RENDER_NEEDED=1
    fi

    dbg "stream finished rc=${STREAM_RC} lines=${#LOG_BUFFER[@]}"
    return 0
}

# ---- agent actions ------------------------------------------------
# ------------------------------------------------------------
# ensure_agent — make ./agent.sh available in TMP_DIR.
# Called LAZILY, only when an action actually needs the agent. Nothing is
# downloaded at startup or on menu render.
# ------------------------------------------------------------
ensure_agent() {
    local f

    [[ -x "${TMP_DIR}/agent.sh" ]] && return 0

    # 1) The package may already be extracted next to where we were started.
    if [[ -x "${START_DIR}/agent.sh" ]]; then
        for f in agent.sh VERSION config lib collectors; do
            [[ -e "${START_DIR}/${f}" ]] && cp -R "${START_DIR}/${f}" "${TMP_DIR}/" 2>/dev/null
        done
        if [[ -x "${TMP_DIR}/agent.sh" ]]; then
            [[ -n "${TMP_DIR}/VERSION" ]] && read_target_version
            return 0
        fi
    fi

    # 2) Fetch it now - this is a user-initiated action.
    add_output_line "[INFO] Fetching the agent package..."
    RENDER_NEEDED=1
    render_frame
    RENDER_NEEDED=0

    if ! fetch_package; then
        add_output_line "[FAIL] Could not fetch the agent package."
        add_output_line "[INFO] Log: ${LOG_FILE}"
        RENDER_NEEDED=1
        render_frame
        RENDER_NEEDED=0
        return 1
    fi

    read_target_version
    add_output_line "[OK] Agent package ready (v${AGENT_VERSION:-unknown})"
    RENDER_NEEDED=1
    render_frame
    RENDER_NEEDED=0
    return 0
}

run_and_stream() {
    local -a args=("$@")
    LOG_BUFFER=()
    SCROLL_OFFSET=0
    SCROLL_FOLLOW=1
    STATUS_MSG="Running..."
    RENDER_NEEDED=1
    render_frame
    RENDER_NEEDED=0

    if ! ensure_agent; then
        STATUS_MSG="Agent unavailable"
        return 1
    fi

    add_output_line "[INFO] Running: ./agent.sh ${args[*]}"
    RENDER_NEEDED=1
    render_frame
    RENDER_NEEDED=0

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
    local prompt="$1" __v="$2" prefill="${3:-}"
    local buf="$prefill" key="" rc=0 done=0 status=1
    printf -v "$__v" '%s' ""

    # Typing mode: switch mouse reporting off. Otherwise a stray click would
    # stream "[<0;12;5M" into the buffer as printable characters.
    printf '\e[?1000l\e[?1006l'

    LOG_BUFFER=("$prompt" "" "> ${buf}_")
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

# ------------------------------------------------------------
# split_mmp <version> <mmp-outvar> <build-outvar>
#   14.3.0.13 -> mmp=14.3.0 build=13
#   14.3.0    -> mmp=14.3.0 build=0   (no build number)
# ------------------------------------------------------------
split_mmp() {
    local _v="$1" _mo="$2" _bo="$3"
    local -a _p=()
    IFS='.' read -r -a _p <<< "${_v}"
    printf -v "${_mo}" '%s.%s.%s' "${_p[0]:-0}" "${_p[1]:-0}" "${_p[2]:-0}"
    printf -v "${_bo}" '%s' "${_p[3]:-0}"
}

# NOTE: the old multi-version picker (highest Major.Minor.Patch, then highest
# build) was removed together with directory scraping: it needs a file listing
# to choose from, and the official index is no longer read. Candidate versions
# are now constructed directly and verified one by one with probe_url().

# ------------------------------------------------------------
# probe_url <url> [auth]
#   auth=1 -> send the Basic Auth credentials
# Sets PROBE_CODE to 200 / 404 / 401 / 403 / 000 / nover / nobinary.
#
# wget ONLY. No curl and no HEAD: both servers reject HEAD, and curl fails
# on this network. This is a real GET whose body goes to /dev/null.
#
# The Range header makes wget ask for a single byte, so the reply is
# "206 Partial Content" and the 645 MB package is never transferred. -S
# prints the response headers, which is what we classify.
#
# wget's EXIT CODE IS DELIBERATELY IGNORED - a 401 retry or an early close
# changes it even when the request succeeded. Only the printed status lines
# are trusted.
# ------------------------------------------------------------
probe_url() {
    local _url="$1" _auth="${2:-0}" _out=""

    PROBE_CODE="000"

    if [[ -z "${_url}" ]]; then
        PROBE_CODE="nover"      # no URL to test - VERSION was not loaded
        return 1
    fi
    if ! command -v wget >/dev/null 2>&1; then
        PROBE_CODE="nobinary"
        return 1
    fi

    if (( _auth == 1 )); then
        _out="$(wget -S -O /dev/null --timeout=10 --tries=1 \
                    --header='Range: bytes=0-0' \
                    --user="${AUTH_USER}" --password="${AUTH_PASS}" \
                    "${_url}" 2>&1)"
    else
        _out="$(wget -S -O /dev/null --timeout=10 --tries=1 \
                    --header='Range: bytes=0-0' \
                    "${_url}" 2>&1)"
    fi

    # 200/206 is tested FIRST. The Pars Avan mirror answers 401, then retries
    # with the credentials and answers 206 - that exchange is a SUCCESS.
    if printf '%s' "${_out}" | grep -qE 'HTTP/1\.[01] (200|206)'; then
        PROBE_CODE="200"
    elif printf '%s' "${_out}" | grep -q 'HTTP/1\.[01] 404'; then
        PROBE_CODE="404"
    elif printf '%s' "${_out}" | grep -q 'HTTP/1\.[01] 401'; then
        PROBE_CODE="401"
    elif printf '%s' "${_out}" | grep -q 'HTTP/1\.[01] 403'; then
        PROBE_CODE="403"
    else
        PROBE_CODE="000"        # timeout, DNS failure, connection refused...
    fi

    dbg "probe ${_url##*/} -> ${PROBE_CODE}"
    blog "probe: ${PROBE_CODE} ${_url}"
    return 0
}

# ------------------------------------------------------------
# probe_status <code> <ok>
# Maps a probe result to the colour + text used by the report.
#   green  : 200
#   yellow : 404 (host answered, file missing)
#   red    : 401 / 403 / timeout
# Sets PST_COLOR and PST_TEXT.
# ------------------------------------------------------------
probe_status() {
    local _code="$1" _ok="$2"
    if (( _ok == 1 )); then
        PST_COLOR="${A_GREEN}"; PST_TEXT="Reachable - OK"
        return 0
    fi
    case "${_code}" in
        404)      PST_COLOR="${A_YELLOW}"; PST_TEXT="Reachable - Not Found" ;;
        401)      PST_COLOR="${A_RED}";    PST_TEXT="Auth Failed" ;;
        403)      PST_COLOR="${A_RED}";    PST_TEXT="Forbidden" ;;
        nover)    PST_COLOR="${A_RED}";    PST_TEXT="VERSION not loaded - no URL" ;;
        nobinary) PST_COLOR="${A_RED}";    PST_TEXT="wget not installed" ;;
        *)        PST_COLOR="${A_RED}";    PST_TEXT="UnReachable" ;;
    esac
}

# ------------------------------------------------------------
# get_exact_remote_version <url> [with_auth] — report the REAL version carried
# inside the package without downloading all 650 MB.
#
# Only the first 2 MB are fetched with an HTTP Range request. That is always
# enough to reach the first tar header, whose entry is the versioned root
# folder (e.g. "IceWarpServer-<version>_RHEL9_x64/"). The version is parsed
# from that folder name, so whatever build the archive really contains is
# what gets reported - nothing is assumed or hardcoded.
#
# with_auth=1 sends the Basic Auth credentials (required by the Pars Avan
# mirror, which answers 401 and would otherwise leave an error page behind).
#
# --http0.9 is required: the IceWarp server answers with HTTP/0.9, which curl
# refuses by default.
#
# Echoes the version. Falls back to the version embedded in the URL filename
# when the probe cannot be read.
# ------------------------------------------------------------
get_exact_remote_version() {
    local url="$1"
    local with_auth="${2:-0}"
    local tmp_file="" version="" first_entry="" folder=""
    local block_size=2097151
    local probe_dir url_ver=""

    # Version embedded in the filename - always available as a fallback.
    url_ver="${url%%\?*}"
    url_ver="${url_ver##*/}"
    url_ver="$(printf '%s' "${url_ver}" \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1)"

    if [[ -z "${url}" ]]; then
        printf '%s' "${url_ver}"
        return 1
    fi

    # Probe file lives in the agent workspace; /tmp only as a last resort.
    probe_dir="${AGENT_DIR:-/root/agent}"
    [[ -d "${probe_dir}" && -w "${probe_dir}" ]] || probe_dir="${TMPDIR:-/tmp}"
    tmp_file="$(mktemp "${probe_dir}/icewarp_probe_XXXXXX.tar.gz" 2>/dev/null)" || tmp_file=""
    if [[ -z "${tmp_file}" ]]; then
        tmp_file="$(mktemp 2>/dev/null)" || tmp_file=""
    fi
    if [[ -z "${tmp_file}" ]]; then
        printf '%s' "${url_ver}"
        return 1
    fi

    # Fetch just the head of the archive. A protected mirror answers
    # 401 without credentials, which would leave an HTML error page in the
    # probe file - so the credentials must be sent whenever auth is asked for.
    if command -v curl >/dev/null 2>&1; then
        if (( with_auth == 1 )); then
            curl -sL --http0.9 --range "0-${block_size}" \
                 -u "${AUTH_USER}:${AUTH_PASS}" \
                 -o "${tmp_file}" "${url}" 2>/dev/null
        else
            curl -sL --http0.9 --range "0-${block_size}" \
                 -o "${tmp_file}" "${url}" 2>/dev/null
        fi
    fi
    if [[ ! -s "${tmp_file}" ]] && command -v wget >/dev/null 2>&1; then
        if (( with_auth == 1 )); then
            wget -q --no-check-certificate \
                 --header="Range: bytes=0-${block_size}" \
                 --user="${AUTH_USER}" --password="${AUTH_PASS}" \
                 -O "${tmp_file}" "${url}" 2>/dev/null
        else
            wget -q --no-check-certificate \
                 --header="Range: bytes=0-${block_size}" \
                 -O "${tmp_file}" "${url}" 2>/dev/null
        fi
    fi

    first_entry="$("${TAR_BIN:-tar}" -tzf "${tmp_file}" 2>/dev/null | head -n 1)"
    rm -f "${tmp_file}" 2>/dev/null

    if [[ -n "${first_entry}" ]]; then
        folder="$(printf '%s' "${first_entry}" | sed 's:/*$::')"
        version="$(printf '%s' "${folder}" \
            | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1)"
        dbg "exact version probe: ${folder} -> ${version}"
        blog "exact version: ${version:-none} (folder=${folder}) url=${url}"
    fi

    [[ -n "${version}" ]] || version="${url_ver}"
    printf '%s' "${version}"
    [[ -n "${version}" ]]
}

# ------------------------------------------------------------
# probe_official_repo — verify the OFFICIAL package URL.
# The directory index is NOT scraped (listing is disabled upstream); the
# candidate URL is constructed first and then verified with probe_url().
# Sets IW_OFF_OK / IW_OFF_VERSION / IW_OFF_FILE / IW_OFF_CODE.
# ------------------------------------------------------------
probe_official_repo() {
    IW_OFF_OK=0
    IW_OFF_VERSION=""
    IW_OFF_FILE=""
    IW_OFF_CODE="000"

    local _base="${ICEWARP_OFFICIAL_REPO%/}"
    if [[ -z "${_base}" ]]; then
        IW_OFF_CODE="nover"
        return 1
    fi

    # Candidates, most specific first: the exact target build from VERSION,
    # then the same branch without a build number.
    local -a _cands=()
    local _mmp="" _build=""
    if [[ -n "${TARGET_VERSION}" ]]; then
        _cands+=("IceWarpServer-${TARGET_VERSION}_RHEL9_x64.tar.gz")
        split_mmp "${TARGET_VERSION}" _mmp _build
        if [[ -n "${_mmp}" && "${_mmp}" != "${TARGET_VERSION}" ]]; then
            _cands+=("IceWarpServer-${_mmp}_RHEL9_x64.tar.gz")
        fi
    fi
    if (( ${#_cands[@]} == 0 )); then
        IW_OFF_CODE="nover"      # TARGET_VERSION unknown - cannot build a URL
        return 1
    fi

    local _f _ver _exact
    for _f in "${_cands[@]}"; do
        probe_url "${_base}/${_f}" 0
        if [[ "${PROBE_CODE}" == "200" ]]; then
            IW_OFF_OK=1
            IW_OFF_CODE="200"
            IW_OFF_FILE="${_f}"
            _ver="${_f#IceWarpServer-}"
            IW_OFF_VERSION="${_ver%_RHEL9_x64.tar.gz}"
            # Read the REAL build from inside the archive (2 MB range fetch)
            # and prefer it over the filename, which may omit the build.
            _exact="$(get_exact_remote_version "${_base}/${_f}")"
            [[ -n "${_exact}" ]] && IW_OFF_VERSION="${_exact}"
            return 0
        fi
        # Keep the most informative failure (a real HTTP answer beats a timeout)
        case "${PROBE_CODE}" in
            401|403|404)             IW_OFF_CODE="${PROBE_CODE}" ;;
            nover|nobinary)          [[ "${IW_OFF_CODE}" == "000" ]] && IW_OFF_CODE="${PROBE_CODE}" ;;
        esac
    done
    return 1
}

# ------------------------------------------------------------
# probe_pars_avan — verify the Pars Avan mirror URL.
# The mirror needs Basic Auth, so the credentials are passed.
# Sets IW_PA_OK / IW_PA_VERSION / IW_PA_FILE / IW_PA_CODE.
# ------------------------------------------------------------
probe_pars_avan() {
    IW_PA_OK=0
    IW_PA_VERSION=""
    IW_PA_FILE=""
    IW_PA_CODE="000"

    if [[ -z "${ICEWARP_PARS_AVAN_URL}" ]]; then
        IW_PA_CODE="nover"
        return 1
    fi

    probe_url "${ICEWARP_PARS_AVAN_URL}" 1
    IW_PA_CODE="${PROBE_CODE}"
    [[ "${PROBE_CODE}" == "200" ]] || return 1

    IW_PA_OK=1
    IW_PA_FILE="${ICEWARP_PARS_AVAN_URL##*/}"

    # The mirror's filename may omit the build suffix, so read the real
    # version from the folder name inside the archive.
    # with_auth=1: the mirror answers 401 without the credentials.
    local _ver=""
    _ver="$(get_exact_remote_version "${ICEWARP_PARS_AVAN_URL}" 1)"

    if [[ -z "${_ver}" ]]; then
        # Fall back to the filename when the probe could not be read.
        _ver="${IW_PA_FILE#IceWarpServer-}"
        if [[ "${_ver}" != "${IW_PA_FILE}" ]]; then
            _ver="${_ver%_RHEL9_x64.tar.gz}"
        else
            _ver="unknown"
        fi
    fi
    IW_PA_VERSION="${_ver}"
    blog "pars avan: file=${IW_PA_FILE} exact_version=${IW_PA_VERSION}"
    return 0
}

# ------------------------------------------------------------
# prompt_key <prompt> <allowed-chars> <outvar> [keep]
# Read ONE keypress from an allowed set, drawn in the output pane.
#   keep=0 (default) : the prompt replaces the pane contents
#   keep=1           : the prompt is appended below what is already there,
#                      so a list of options stays visible while choosing
# ------------------------------------------------------------
prompt_key() {
    local _q="$1" _allow="$2" _v="$3" _keep="${4:-0}"
    local _key="" _rc=0 _done=0
    printf -v "${_v}" '%s' ""
    printf '\e[?1000l\e[?1006l'
    if (( _keep == 1 )); then
        add_output_line ""
        add_output_line "${_q}"
    else
        LOG_BUFFER=("${_q}" "" "  > _")
        SCROLL_OFFSET=0
        SCROLL_FOLLOW=1
    fi
    RENDER_NEEDED=1
    render_frame
    RENDER_NEEDED=0

    while (( _done == 0 )); do
        _key=""
        IFS= read -rsn1 -t 120 _key </dev/tty
        _rc=$?
        (( _rc != 0 )) && { printf '\e[?1000h\e[?1006h'; return 1; }
        [[ -z "${_key}" ]] && continue
        case "${_allow}" in
            *"${_key}"*)
                printf -v "${_v}" '%s' "${_key}"
                if (( _keep == 1 )); then
                    LOG_BUFFER[-1]="${_q}${_key}"
                else
                    LOG_BUFFER=("${_q}" "" "  > ${_key}")
                fi
                RENDER_NEEDED=1
                render_frame
                RENDER_NEEDED=0
                _done=1
                ;;
        esac
    done
    printf '\e[?1000h\e[?1006h'
    return 0
}

# ------------------------------------------------------------
# update_agent — "Install / Update IceWarp".
# Probes both sources, applies the SAFE version selection, lets the operator
# choose, then downloads to /root, extracts there, cd's in and runs
# ./install.sh interactively through the dual-FIFO engine.
# ------------------------------------------------------------
update_agent() {
    local dest="${AGENT_DIR:-/root/agent}" choice="" url="" src=""

    if [[ ! -w "${dest}" ]]; then
        LOG_BUFFER=("[FAIL] ${dest} is not writable - the IceWarp update needs root.")
        STATUS_MSG="Ready"
        RENDER_NEEDED=1
        render_frame
        RENDER_NEEDED=0
        return 1
    fi

    # ---- probe both sources -------------------------------------------
    LOG_BUFFER=()
    SCROLL_OFFSET=0
    SCROLL_FOLLOW=1
    STATUS_MSG="Checking sources..."
    add_output_line "[INFO] Checking IceWarp package sources..."
    RENDER_NEEDED=1
    render_frame
    RENDER_NEEDED=0

    # The source URLs live in VERSION, which ships inside the agent package.
    # Make sure it is loaded before probing, otherwise there is no URL to test.
    if [[ -z "${TARGET_VERSION}" || -z "${ICEWARP_PARS_AVAN_URL}" ]]; then
        STATUS_MSG="Loading VERSION..."
        add_output_line "[INFO] Loading VERSION (package source URLs)..."
        RENDER_NEEDED=1
        render_frame
        RENDER_NEEDED=0
        if ! load_version_info; then
            add_output_line "[FAIL] VERSION is unavailable - cannot determine package URLs."
            STATUS_MSG="Ready"
            RENDER_NEEDED=1
            render_frame
            RENDER_NEEDED=0
            return 1
        fi
    fi

    # Warm the DNS cache before probing. On networks with slow resolvers
    # (e.g. inside Iran) the first lookup alone can exceed a few seconds.
    getent hosts parsavan.com >/dev/null 2>&1

    probe_official_repo
    probe_pars_avan

    # ---- render the source report --------------------------------------
    # Colour rules (from the probe result):
    #   green  : 200 -> show the extracted version
    #   yellow : 404 -> no version
    #   red    : 401 / 403 / timeout -> no version
    probe_status "${IW_OFF_CODE}" "${IW_OFF_OK}"
    local off_color="${PST_COLOR}" off_status="${PST_TEXT}"
    probe_status "${IW_PA_CODE}" "${IW_PA_OK}"
    local pa_color="${PST_COLOR}" pa_status="${PST_TEXT}"

    LOG_BUFFER=()
    add_output_line "[INFO] IceWarp package sources:"
    add_output_line ""

    if (( IW_OFF_OK == 1 )); then
        add_output_line "[${A_GREEN}OK${A_OFF}] 1) Official Server"
        add_output_line "        Status: ${A_GREEN}Reachable - OK${A_OFF}"
        add_output_line "        Version: ${A_GREEN}${IW_OFF_VERSION}${A_OFF} Found"
    else
        add_output_line "[${off_color}FAIL${A_OFF}] 1) Official Server"
        add_output_line "        Status: ${off_color}${off_status}${A_OFF}"
    fi
    add_output_line ""

    if (( IW_PA_OK == 1 )); then
        add_output_line "[${A_GREEN}OK${A_OFF}] 2) Pars Avan Mirror"
        add_output_line "        Status: ${A_GREEN}Reachable - OK${A_OFF}"
        add_output_line "        Version: ${A_GREEN}${IW_PA_VERSION}${A_OFF} Found"
    else
        add_output_line "[${pa_color}FAIL${A_OFF}] 2) Pars Avan Mirror"
        add_output_line "        Status: ${pa_color}${pa_status}${A_OFF}"
    fi
    add_output_line ""

    add_output_line "3) Enter Custom URL"
    add_output_line "4) Cancel"
    RENDER_NEEDED=1
    render_frame
    RENDER_NEEDED=0

    # ---- let the operator choose (the report stays visible above) -------
    if ! prompt_key "Select source [1-4]:" "1234" choice 1; then
        choice="4"
    fi

    local custom=""
    case "${choice}" in
        1)
            if (( IW_OFF_OK == 0 )); then
                add_output_line "[FAIL] Official source is unreachable."
                STATUS_MSG="Ready"
                RENDER_NEEDED=1
                render_frame
                RENDER_NEEDED=0
                return 1
            fi
            url="${ICEWARP_OFFICIAL_REPO}${IW_OFF_FILE}"
            src="official (${IW_OFF_VERSION})"
            ;;
        2)
            if (( IW_PA_OK == 0 )); then
                add_output_line "[FAIL] Pars Avan source is unreachable (${pa_status})."
                STATUS_MSG="Ready"
                RENDER_NEEDED=1
                render_frame
                RENDER_NEEDED=0
                return 1
            fi
            url="${ICEWARP_PARS_AVAN_URL}"
            src="Pars Avan (${IW_PA_VERSION})"
            ;;
        3)
            if ! prompt_input "Enter the full .tar.gz URL then press Enter:" custom ""; then
                custom=""
            fi
            case "${custom}" in
                http://*|https://*)
                    url="${custom}"
                    src="custom URL"
                    ;;
                "")
                    add_output_line "[INFO] Cancelled - nothing was installed."
                    STATUS_MSG="Ready"
                    RENDER_NEEDED=1
                    render_frame
                    RENDER_NEEDED=0
                    return 0
                    ;;
                *)
                    add_output_line "[FAIL] Not a valid http(s) URL: ${custom}"
                    STATUS_MSG="Ready"
                    RENDER_NEEDED=1
                    render_frame
                    RENDER_NEEDED=0
                    return 1
                    ;;
            esac
            ;;
        *)
            add_output_line "[INFO] Cancelled - nothing was installed."
            STATUS_MSG="Ready"
            RENDER_NEEDED=1
            render_frame
            RENDER_NEEDED=0
            return 0
            ;;
    esac

    cat > "$TMP_DIR/.ui_icewarp_update.sh" <<'UPD'
#!/bin/bash
url="$1"; dest="$2"; au="$3"; ap="$4"; log="${5:-/dev/null}"
cd "$dest" || { echo "[FAIL] cannot cd to $dest"; exit 1; }

pkg="${url%%\?*}"
pkg="${pkg##*/}"
[ -n "$pkg" ] || pkg="icewarp-update.tar.gz"

# Resolve tar FIRST: it is needed both to validate a cached package and to
# extract it, and a restricted PATH must not turn that into "command not found".
TAR=""
for t in /bin/tar /usr/bin/tar /usr/local/bin/tar /sbin/tar; do
    [ -x "$t" ] && { TAR="$t"; break; }
done
if [ -z "$TAR" ]; then
    t="$(command -v tar 2>/dev/null)"
    [ -n "$t" ] && [ -x "$t" ] && TAR="$t"
fi
if [ -z "$TAR" ]; then
    echo "[FAIL] tar is missing - cannot extract the package"
    exit 1
fi

dest_file="$dest/$pkg"
tmp_file="${dest_file}.tmp"

# --- cached package: never download 650 MB twice --------------------------
cached=0
if [ -s "$dest_file" ]; then
    if "$TAR" -tzf "$dest_file" 2>/dev/null | head -n 1 | grep -q .; then
        cached=1
        echo "[INFO] Using cached package: $(basename "$dest_file")"
        echo "[INFO] $(wc -c < "$dest_file") bytes already present in $dest"
    else
        echo "[WARN] Cached package is unreadable - downloading it again."
        rm -f "$dest_file"
    fi
fi

if [ "$cached" -eq 0 ]; then
    # The downloader is ALWAYS silenced and its output redirected to the log.
    # wget's progress bar writes hundreds of lines; letting it reach the pane
    # floods the TUI and makes the screen unreadable.
    echo "[INFO] Downloading IceWarp package (approx. 650MB). Please wait..."
    echo "[INFO] Source: $url"

    # ATOMIC DOWNLOAD: write to <file>.tmp and only publish it once the
    # transfer completed and produced a non-empty file. An interrupted run can
    # never leave a truncated .tar.gz behind that breaks the next attempt.
    rm -f "$tmp_file" "$dest_file"

    # --- total size for the progress bar (Content-Length), 650 MB fallback --
    total=""
    if command -v curl >/dev/null 2>&1; then
        total="$(curl -sIL --http0.9 -u "$au:$ap" "$url" 2>/dev/null \
                 | grep -i '^content-length:' | awk '{print $2}' | tr -d '\r' | head -n 1)"
    fi
    case "$total" in
        ''|*[!0-9]*) total=$((650 * 1024 * 1024)) ;;
    esac
    [ "$total" -lt 1 ] && total=$((650 * 1024 * 1024))

    # --- start the transfer in the background so progress can be sampled ---
    dl_pid=""
    if command -v wget >/dev/null 2>&1; then
        # --no-check-certificate: the mirror's certificate chain is not always
        # verifiable from the target server. stdin is detached so a
        # backgrounded wget can never eat the installer's keystrokes.
        wget -q --no-check-certificate \
             --user="$au" --password="$ap" \
             --timeout=15 --tries=1 \
             -O "$tmp_file" "$url" </dev/null >>"$log" 2>&1 &
        dl_pid=$!
    fi
    if [ -z "$dl_pid" ] && command -v curl >/dev/null 2>&1; then
        curl -fsSL --http0.9 --connect-timeout 15 -k -u "$au:$ap" \
             -o "$tmp_file" "$url" </dev/null >>"$log" 2>&1 &
        dl_pid=$!
    fi

    dl_status=1
    if [ -n "$dl_pid" ]; then
        # One line per second; the TUI rewrites the SAME output line in place,
        # producing a single-line bar instead of thousands of progress lines.
        while kill -0 "$dl_pid" 2>/dev/null; do
            cur="$(stat -c %s "$tmp_file" 2>/dev/null || echo 0)"
            case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
            pct=$(( cur * 100 / total ))
            [ "$pct" -gt 100 ] && pct=100
            printf '@@PROGRESS %d\n' "$pct"
            sleep 1
        done
        wait "$dl_pid"
        dl_status=$?
    fi

    if [ "$dl_status" -ne 0 ] || [ ! -s "$tmp_file" ]; then
        printf '@@PROGRESS CLEAR\n'
        rm -f "$tmp_file"
        echo "[FAIL] Download failed or interrupted. Temporary file removed."
        exit 1
    fi

    # Final 100% frame, then remove the bar line and report success.
    printf '@@PROGRESS 100\n'
    printf '@@PROGRESS CLEAR\n'
    mv -f "$tmp_file" "$dest_file"
    echo "[OK] Download complete."
    echo "[INFO] $(wc -c < "$dest_file") bytes -> $dest_file"
fi

# NOTE: from here on use "$dest_file" (absolute). "pkg" is only the basename.
top="$("$TAR" -tzf "$dest_file" 2>/dev/null | head -n1 | cut -d/ -f1)"
if [ -z "$top" ]; then
    echo "[FAIL] Not a readable .tar.gz archive"
    exit 1
fi

echo "[INFO] Extracting into $dest"
if ! "$TAR" -xzf "$dest_file" -C "$dest"; then
    echo "[FAIL] Extraction failed"
    exit 1
fi

dir="$dest/$top"
[ -d "$dir" ] || dir="$dest"
if [ ! -f "$dir/install.sh" ]; then
    echo "[FAIL] No install.sh found in $dir"
    echo "[INFO] Directory listing of $dir:"
    ls -1 "$dir" 2>/dev/null | head -20
    exit 1
fi

chmod +x "$dir/install.sh" 2>/dev/null || true
echo "[INFO] Extracted to $dir"
echo "[INFO] Starting install.sh - answer the prompts right here."
echo ""
cd "$dir" || exit 1

if head -n1 ./install.sh 2>/dev/null | grep -q '^#!'; then
    ./install.sh
    rc=$?
else
    sh ./install.sh
    rc=$?
fi
exit "$rc"
UPD

    LOG_BUFFER=()
    SCROLL_OFFSET=0
    SCROLL_FOLLOW=1
    STATUS_MSG="Installing IceWarp..."
    blog "install: source=${src}"
    blog "install: url=${url}"
    blog "install: dest=${dest}"
    add_output_line "[INFO] Source : ${src}"
    add_output_line "[INFO] Package: ${url}"
    add_output_line "[INFO] Target : ${dest}"
    add_output_line "[INFO] install.sh is interactive - answer its prompts here."
    RENDER_NEEDED=1
    render_frame
    RENDER_NEEDED=0

    STREAM_CMD=(bash "$TMP_DIR/.ui_icewarp_update.sh" "$url" "$dest" "${AUTH_USER}" "${AUTH_PASS}" "${LOG_FILE}")
    INTERACTIVE=1
    stream_run
    INTERACTIVE=0

    if [[ "$STREAM_RC" == "0" ]]; then
        add_output_line "[OK] install.sh finished (exit 0)"
        STATUS_MSG="Ready"
        detect_system
        read_target_version
    else
        add_output_line "[FAIL] install.sh exited ${STREAM_RC}"
        STATUS_MSG="Ready"     # the agent itself is fine; only this action failed
    fi
    RENDER_NEEDED=1
    render_frame
    RENDER_NEEDED=0
    return 0
}

# ------------------------------------------------------------
# action_ssl — menu handler for "Install SSL (Let's Encrypt)".
# Placeholder for the SSL module; the menu structure and indexing are final.
# ------------------------------------------------------------
action_ssl() {
    LOG_BUFFER=()
    SCROLL_OFFSET=0
    SCROLL_FOLLOW=1
    add_output_line "[INFO] SSL module coming soon..."
    STATUS_MSG="Ready"
    RENDER_NEEDED=1
    render_frame
    RENDER_NEEDED=0
    return 0
}

activate() {
    case "${MENU_ACTIONS[MENU_SEL]}" in
        quit)    QUIT=1 ;;
        icewarp) update_agent ;;
        config)  run_and_stream --config ;;
        apply)   run_and_stream --config --apply ;;
        ssl)     action_ssl ;;
        health)  run_and_stream --report ;;
        list)    run_and_stream --list ;;
        only)    run_only_prompt ;;
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

    # ---- IceWarp presence -------------------------------------------
    # A fresh server has no IceWarp at all. Say "Not Installed" / "N/A" -
    # never "unknown" or "not found".
    IW_INSTALLED=0
    IW_PATH=""
    for p in /opt/icewarp /usr/local/icewarp /var/icewarp /home/icewarp; do
        if [[ -d "$p" ]]; then IW_PATH="$p"; break; fi
    done

    IW_VERSION="Not Installed"
    if [[ -n "$IW_PATH" && -x "$IW_PATH/tool.sh" ]]; then
        IW_INSTALLED=1
        if command -v timeout >/dev/null 2>&1; then
            t="$(timeout 5 "$IW_PATH/tool.sh" get system C_Version 2>/dev/null | head -n1 | tr -d '[:space:]')"
        else
            t="$("$IW_PATH/tool.sh" get system C_Version 2>/dev/null | head -n1 | tr -d '[:space:]')"
        fi
        t="${t#C_Version:}"          # tool.sh prefixes the key name
        t="${t#C_Version=}"
        if [[ -n "$t" ]]; then IW_VERSION="$t"; else IW_VERSION="Installed"; fi
    elif command -v icewarp >/dev/null 2>&1; then
        # Binary present but no known install directory.
        IW_INSTALLED=1
        [[ -z "$IW_PATH" ]] && IW_PATH="$(command -v icewarp 2>/dev/null)"
        IW_VERSION="Installed"
    fi

    if (( IW_INSTALLED == 0 )); then
        IW_PATH="N/A"
        IW_VERSION="Not Installed"
    fi

    blog "system: ${OS_NAME} ${OS_VERSION} | IceWarp ${IW_VERSION} | ${IW_PATH}"

    build_menu
}

# ------------------------------------------------------------
# build_menu - set the label of entry 0 from the installation state.
# Called by detect_system (and after a successful install).
# ------------------------------------------------------------
build_menu() {
    local iw_label
    if (( IW_INSTALLED == 1 )); then
        iw_label="Update IceWarp"
    else
        iw_label="Install IceWarp"
    fi
    MENU_LABELS[0]="${iw_label}"
    (( MENU_SEL >= ${#MENU_LABELS[@]} )) && MENU_SEL=$((${#MENU_LABELS[@]} - 1))
    (( MENU_SEL < 0 )) && MENU_SEL=0
}

# ------------------------------------------------------------
# Package fetch (output to a hidden log, never to the TUI)
# ------------------------------------------------------------
fetch_package() {
    local pkg="$TMP_DIR/linux-agent.tar.gz"
    local tmp="${pkg}.tmp"
    local log="${LOG_FILE:-$TMP_DIR/bootstrap.log}"
    local url="${BASE_URL}/linux-agent.tar.gz"
    local dl_ok=0
    rm -f "$tmp" "$pkg"

    # tar must be resolvable BEFORE we download, so a missing tar fails fast
    # with a clear message instead of after a 30 MB transfer.
    if [[ -z "${TAR_BIN}" ]] && ! resolve_tar; then
        echo "[FAIL] tar is missing - cannot extract the agent package" >>"$log"
        blog "fetch_package: FAILED - tar not found (PATH=${PATH})"
        FATAL_ERROR=1
        return 1
    fi

    blog "fetch_package: url=${url}"
    blog "fetch_package: dest=${pkg}"
    blog "fetch_package: tar=${TAR_BIN}"
    {
        # ATOMIC DOWNLOAD: the .tmp file is only renamed into place after the
        # transfer succeeded and produced a non-empty file, so an interrupted
        # run never leaves a truncated tarball that breaks the next attempt.
        # --no-check-certificate: the Iranian mirror frequently presents a
        # certificate chain the server's CA store cannot verify.
        if command -v wget >/dev/null 2>&1; then
            # Completely silent: the whole block is redirected to the log, and
            # --show-progress is deliberately NOT used (its progress bar would
            # flood the log and, if the redirect ever broke, the TUI pane).
            wget -q --no-check-certificate \
                 --user="${AUTH_USER}" --password="${AUTH_PASS}" \
                 --timeout=15 --tries=1 \
                 -O "$tmp" "${url}" </dev/null && dl_ok=1
        fi
        if [[ "$dl_ok" -eq 0 ]] && command -v curl >/dev/null 2>&1; then
            echo "[INFO] wget unavailable or failed - falling back to curl"
            curl -fsSL --connect-timeout 15 -k \
                 -u "${AUTH_USER}:${AUTH_PASS}" \
                 -o "$tmp" "${url}" </dev/null && dl_ok=1
        fi

        if [[ "$dl_ok" -eq 1 && -s "$tmp" ]]; then
            mv -f "$tmp" "$pkg" &&
            "${TAR_BIN}" -xzf "$pkg" -C "$TMP_DIR" &&
            rm -f "$pkg" &&
            chmod +x "$TMP_DIR/agent.sh"
        else
            rm -f "$tmp"
            echo "[FAIL] Download failed or interrupted. Temporary file removed."
            false
        fi
    } >>"$log" 2>&1

    if [[ -x "$TMP_DIR/agent.sh" ]]; then
        blog "fetch_package: OK (agent.sh extracted into ${TMP_DIR})"
        return 0
    fi
    # Distinguish a failed download from a failed extraction for the log.
    if [[ -s "$TMP_DIR/linux-agent.tar.gz" ]]; then
        blog "fetch_package: FAILED - archive present but extraction produced no agent.sh"
    else
        blog "fetch_package: FAILED - download unsuccessful"
    fi
    FATAL_ERROR=1
    return 1
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
    # Capture the REAL exit status first - any command below would clobber $?.
    local _rc=$?
    trap - EXIT INT TERM WINCH

    [[ -n "$AGENT_PID" ]] && kill "$AGENT_PID" 2>/dev/null
    exec 9<&- 2>/dev/null
    exec 8>&- 2>/dev/null
    [[ -n "$IN_FIFO" && -f "$IN_FIFO" ]] && rm -f "$IN_FIFO" 2>/dev/null
    [[ -n "$FIFO" && -f "$FIFO" ]] && rm -f "$FIFO" 2>/dev/null

    # Interrupted atomic downloads leave <name>.tmp behind - never the real
    # package - so sweep them before the workspace is wiped.
    if [[ -n "${AGENT_DIR}" && -d "${AGENT_DIR}" ]]; then
        rm -f "${AGENT_DIR}"/*.tmp 2>/dev/null
    fi

    if [[ "${IS_TTY:-0}" == "1" ]]; then
        { : </dev/tty; } 2>/dev/null && {
            # Restore mouse reporting FIRST, then cursor/wrap/alt-screen.
            # Without ?1000l/?1006l the shell would keep receiving mouse
            # escape sequences after we exit.
            { command -v tput >/dev/null 2>&1 && tput rmcup; } 2>/dev/null >/dev/tty || true
            printf '\e[?1000l\e[?1006l\e[r\e[?7h\e[?25h\e[0m\e[?1049l' 2>/dev/null >/dev/tty
            [[ -n "$STTY_SAVE" ]] && stty "$STTY_SAVE" 2>/dev/null </dev/tty
            stty sane 2>/dev/null </dev/tty
        }
    fi

    # Wipe the whole working tree EXCEPT the persistent logs.
    # /root/output is deliberately left alone - the reports live there.
    if [[ -n "${AGENT_DIR}" && -d "${AGENT_DIR}" ]]; then
        blog "=== bootstrap end (rc=${_rc}) ==="
        # Delete every extracted directory (including tmp/) and any leftover
        # .tmp transfer. The DOWNLOADED packages (*.tar.gz) and the logs are
        # kept, so a repeat run can install from the cached tarball without
        # pulling 650 MB again.
        find "${AGENT_DIR}" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} + 2>/dev/null
        find "${AGENT_DIR}" -mindepth 1 -maxdepth 1 -type f -name '*.tmp' -delete 2>/dev/null
        find "${AGENT_DIR}" -mindepth 1 -maxdepth 1 -type f \
             ! -name 'agent-*.log' ! -name '*.tar.gz' -delete 2>/dev/null
    fi
    TMP_DIR=""
    return 0
}

# ------------------------------------------------------------
# TUI
# ------------------------------------------------------------
tui_init() {
    # Create /root/agent + tmp/ BEFORE anything else, so the log and every
    # later download/extraction has a home.
    if ! init_workdir; then
        printf 'ERROR: cannot create the working directory %s\n' "${AGENT_DIR}" >&2
        return 1
    fi
    : >"$DBG_LOG" 2>/dev/null
    dbg "=== TUI start (bash ${BASH_VERSION}) ==="

    # Enter the alternate screen buffer BOTH ways: tput smcup (the portable
    # request) and the raw ?1049h escape (fallback when tput/terminfo is
    # missing). Redundant but harmless - the second is a no-op if the first
    # already switched buffers.
    { command -v tput >/dev/null 2>&1 && tput smcup; } 2>/dev/null >/dev/tty || true
    printf '\e[3J\e[2J\e[H'
    # \e[r resets any DECSTBM scroll region a previous program may have left
    # set; a stale region makes writes scroll instead of overwrite in place.
    printf '\e[r'
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
    build_menu

    # NO download happens at startup. The agent package is fetched lazily by
    # ensure_agent() the first time an action actually needs it.
    STATUS_MSG="Ready"
    add_output_line "[INFO] ${OS_NAME} ${OS_VERSION} | IceWarp: ${IW_VERSION} | Path: ${IW_PATH}"
    if (( IW_INSTALLED == 0 )); then
        add_output_line "[INFO] IceWarp is not installed - choose 'Install IceWarp'."
    fi
    add_output_line "[INFO] j/k or arrows to move, Enter to run, q to quit."
    RENDER_NEEDED=1
    render_frame
    RENDER_NEEDED=0
    return 0
}

tui_loop() {
    local key="" rc=0
        while [[ "${QUIT:-0}" == "0" ]]; do
        if [[ "${WINCH_FLAG:-0}" == "1" ]]; then
            WINCH_FLAG=0
            get_size
            RENDER_NEEDED=1
        fi

        if (( SECONDS - LAST_STATS >= REFRESH_SECS )); then
            LAST_STATS=$SECONDS
            read_stats
            if [[ "${RENDER_NEEDED:-0}" == "0" ]]; then
                render_stats_only     # repaint the header only: no flicker
            fi
        fi

        if [[ "${RENDER_NEEDED:-0}" == "1" ]]; then
            RENDER_NEEDED=0
            SCROLL_NEEDED=0
            render_frame
        elif [[ "${SCROLL_NEEDED:-0}" == "1" ]]; then
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
                if [[ "${RENDER_NEEDED:-0}" == "0" ]]; then
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

    if ! init_workdir; then
        printf 'ERROR: cannot create the working directory %s\n' "${AGENT_DIR}" >&2
        return 1
    fi

    printf '[bootstrap] downloading package...\n' >&2
    if ! fetch_package; then
        printf '[bootstrap] download/extract failed\n' >&2
        printf '[bootstrap] see %s\n' "${LOG_FILE}" >&2
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

    if ! tui_init; then
        return 1
    fi
    tui_loop
    copy_output

    # A fatal error during the session (package could not be fetched or
    # extracted) must be reflected in the exit status, not hidden behind rc=0.
    if [[ "${FATAL_ERROR:-0}" == "1" ]]; then
        return 1
    fi
    return 0
}

[[ "${HEALTH_AGENT_NO_MAIN:-0}" == "1" ]] || main "$@"
