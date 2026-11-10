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
AGENT_VERSION="0.8.1"
TARGET_VERSION=""
VERSION_STALE=0
BLINK_ON=0
# IceWarp package sources, also read from VERSION at runtime.
ICEWARP_OFFICIAL_REPO=""
ICEWARP_PARS_AVAN_URL=""

# Probe results for the IceWarp installer menu.
IW_OFF_OK=0; IW_OFF_VERSION=""; IW_OFF_FILE=""; IW_OFF_CODE=""; IW_OFF_OTHER=""
IW_PA_OK=0;  IW_PA_VERSION="";  IW_PA_FILE="";  IW_PA_CODE=""; IW_PA_OTHER=""
# Absolute latest published by VERSION, and the branch-aware target actually
# used for the header warning.
VERSION_FILE_TARGET=""
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
# 1 while the last output line is an unfinished (no newline yet) fragment
PARTIAL_ACTIVE=0
# 1 while a menu action is executing: only the Output pane may be repainted
ACTION_RUNNING=0

# Core IceWarp services shown in the header (only when IceWarp is installed).
# Display name is not always the binary name: the calendar/groupware service
# runs as "cal" and the antivirus daemon lives in sophos/.
IW_SERVICES=(control smtp savdid cal pop3 im)
declare -A SVC_PATH=(
    [control]="control"
    [smtp]="smtp"
    [savdid]="sophos/savdid"
    [cal]="cal"
    [pop3]="pop3"
    [im]="im"
)
# icewarpd.sh knows the calendar service under its product name.
declare -A SVC_CHECK=(
    [cal]="groupware"
)
declare -A SVC_UP=()
# -100 so the very first svc_refresh() always runs, even at SECONDS=0.
SVC_LAST=-100
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
# The arrays hold the SELECTABLE items only; the visual grouping comes from
# menu_section_for() below, so headers never affect indexing.
# Entry 0 is context-sensitive: "Install IceWarp" on a server without
# IceWarp, "Update IceWarp" once it is installed.
MENU_LABELS=(
    "Install IceWarp"
    "Manage SSL (Let's Encrypt / Self-Signed)"
    "Check Configuration"
    "Apply Configuration"
    "Check Firewall / Ports"
    "Manage Services"
    "Backup / Restore"
    "Switch Web Ports (Nginx Prep)"
    "Install ModSecurity"
    "Configure ModSecurity"
    "Install Nginx"
    "Configure Nginx"
    "Install CSF"
    "Configure CSF"
    "Resource Overview"
    "Quit"
)
MENU_ACTIONS=(
    "icewarp"
    "ssl"
    "config"
    "apply"
    "firewall"
    "services"
    "backup"
    "web_ports"
    "modsec_install"
    "modsec_config"
    "nginx_install"
    "nginx_config"
    "csf_install"
    "csf_config"
    "resources"
    "quit"
)
# Visual lines of the Navigation pane: headers, spacers and items.
NAV_LINES=()
NAV_ITEM=()

# menu_section_for <item-index> — section header to print before this item.
menu_section_for() {
    case "$1" in
        0)  printf 'Installation' ;;
        2)  printf 'Configuration' ;;
        7)  printf 'Security' ;;
        14) printf 'System' ;;
    esac
}

# _build_menu_impl <mode>
#   mode 0: section headers + blank spacers (the normal look)
#   mode 1: section headers, no blank spacers
#   mode 2: no headers, no spacers (last resort so no item becomes unreachable)
_build_menu_impl() {
    local mode="$1"
    local i n hdr num marker label
    NAV_LINES=()
    NAV_ITEM=()
    n=${#MENU_LABELS[@]}

    for (( i = 0; i < n; i++ )); do
        if (( mode < 2 )); then
            hdr="$(menu_section_for "$i")"
            if [[ -n "$hdr" ]]; then
                if (( mode == 0 )) && (( ${#NAV_LINES[@]} > 0 )); then
                    NAV_LINES+=(""); NAV_ITEM+=(-1)
                fi
                NAV_LINES+=("-- ${hdr} --")
                NAV_ITEM+=(-1)
            fi
        fi

        # Quit is option 0 and sits directly under the last item.
        if (( i == n - 1 )); then
            num="0"
        else
            num="$(( i + 1 ))"
        fi

        marker="${M_OFF}"
        (( i == MENU_SEL )) && marker="${M_SEL}"
        printf -v label '%s %2s) %s' "$marker" "$num" "${MENU_LABELS[i]}"
        NAV_LINES+=("$label")
        NAV_ITEM+=("$i")
    done
}

# build_menu_lines — rebuild NAV_LINES/NAV_ITEM from MENU_LABELS.
# NAV_ITEM[i] is the selectable index of that row, or -1 for a header/spacer.
# The selection marker is baked in, so this runs on every frame.
build_menu_lines() {
    _build_menu_impl 0
    # Short terminal: shed spacers first, then headers, so every item (Quit
    # included) stays reachable no matter how many sections the menu has.
    if (( L_CONTENT_H > 0 )) && (( ${#NAV_LINES[@]} > L_CONTENT_H )); then
        _build_menu_impl 1
    fi
    if (( L_CONTENT_H > 0 )) && (( ${#NAV_LINES[@]} > L_CONTENT_H )); then
        _build_menu_impl 2
    fi
}
readonly M_SEL="[>]" M_OFF="[ ]"

# Strict ANSI codes used by the IceWarp source report.
# These are plain SGR so they render identically on any colour terminal.
readonly A_GREEN=$'\e[32m'
readonly A_YELLOW=$'\e[33m'
readonly A_RED=$'\e[31m'
readonly A_OFF=$'\e[0m'

# Shown on the last content row while the view is scrolled away from the tail.
readonly OVH_TEXT="[↓ New output available]"

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

# ------------------------------------------------------------
# branch_of <version> <outvar> — Major.Minor, e.g. 14.2.0.16 -> "14.2".
# This is the unit IceWarp upgrades within: a server may only move to a newer
# build of its OWN branch, never across branches (14.2 -> 14.3 is forbidden).
# ------------------------------------------------------------
branch_of() {
    local _v="$1" _o="$2"
    local _a="" _b="" _rest=""
    IFS='.' read -r _a _b _rest <<< "${_v}"
    printf -v "${_o}" '%s.%s' "${_a:-0}" "${_b:-0}"
}

# ------------------------------------------------------------
# highest_in_branch <branch> — reads versions on stdin and prints the highest
# one that belongs to <branch>. An empty branch accepts every version (used
# when IceWarp is not installed and the absolute latest is wanted).
# ------------------------------------------------------------
highest_in_branch() {
    local _br="$1" _v="" _best="" _vb=""
    while IFS= read -r _v; do
        [[ -z "${_v}" ]] && continue
        if [[ -n "${_br}" ]]; then
            branch_of "${_v}" _vb
            [[ "${_vb}" != "${_br}" ]] && continue
        fi
        if [[ -z "${_best}" ]] || version_lt "${_best}" "${_v}"; then
            _best="${_v}"
        fi
    done
    printf '%s' "${_best}"
}

# ------------------------------------------------------------
# enumerate_official_versions — list every published
# IceWarpServer-*_RHEL9_x64.tar.gz version, one per line.
# The IceWarp server answers HTTP/0.9, which curl only accepts with
# --http0.9; wget is the fallback.
# ------------------------------------------------------------
enumerate_official_versions() {
    local _base="${ICEWARP_OFFICIAL_REPO%/}"
    local _page=""
    [[ -n "${_base}" ]] || return 1

    if command -v curl >/dev/null 2>&1; then
        _page="$(curl -sL --http0.9 --max-time 10 "${_base}/" 2>/dev/null)"
    fi
    if [[ -z "${_page}" ]] && command -v wget >/dev/null 2>&1; then
        _page="$(wget -q -O - --no-check-certificate --timeout=10 "${_base}/" 2>/dev/null)"
    fi
    [[ -n "${_page}" ]] || return 1

    printf '%s\n' "${_page}" \
        | grep -oE 'IceWarpServer-[0-9]+(\.[0-9]+)+_RHEL9_x64\.tar\.gz' \
        | sed 's/^IceWarpServer-//; s/_RHEL9_x64\.tar\.gz$//' \
        | sort -u
}

# ------------------------------------------------------------
# recompute_stale — the header warning only fires when the INSTALLED build is
# older than the newest build of the SAME branch.
# ------------------------------------------------------------
recompute_stale() {
    VERSION_STALE=0
    (( IW_INSTALLED == 1 )) || return 0
    [[ -n "${TARGET_VERSION}" && -n "${IW_VERSION}" ]] || return 0
    case "${IW_VERSION}" in
        "Not Installed"|"Installed"|"unknown"|"") return 0 ;;
    esac
    if version_lt "${IW_VERSION}" "${TARGET_VERSION}"; then
        VERSION_STALE=1
    fi
    return 0
}

# ------------------------------------------------------------
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
#   AGENT_VERSION="0.8.1"
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

    # VERSION carries the ABSOLUTE latest build. On an installed server that is
    # only a valid target when it belongs to the SAME branch - IceWarp cannot
    # be upgraded across major branches (14.2 -> 14.3 is forbidden).
    VERSION_FILE_TARGET="$TARGET_VERSION"
    if (( IW_INSTALLED == 1 )) && [[ -n "$IW_VERSION" ]]; then
        local _ib="" _vb=""
        branch_of "$IW_VERSION" _ib
        branch_of "$VERSION_FILE_TARGET" _vb
        if [[ -n "$_vb" && "$_vb" != "$_ib" ]]; then
            # Different branch: the real target is the newest build of the
            # installed branch, which is only known once the repo is probed.
            TARGET_VERSION=""
            blog "version: VERSION points at ${VERSION_FILE_TARGET} (branch $_vb); installed branch is $_ib - target unknown until probed"
        fi
    fi

    recompute_stale

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
    # Space is part of the range, otherwise ordinary log lines would take the
    # slow per-character path. The class is applied through a parameter
    # expansion because a literal space is not allowed inside [[ ]] globs.
    local _pv="${_s//[^ -~]/}"
    if (( ${#_pv} == ${#_s} )); then printf -v "$_v" '%d' "$_n"; return; fi
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
    local _line="$1" _pct="" _bar="" _cr=$'\r' _tail="" _head=""
    local _replace=0

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

    # The fragment line (if any) already contains the start of this text, so
    # the finished line REPLACES it instead of being appended twice.
    if (( PARTIAL_ACTIVE == 1 )) && (( ${#LOG_BUFFER[@]} > 0 )); then
        PARTIAL_ACTIVE=0
        _replace=1
    fi

    # ---- carriage returns ------------------------------------------------
    # dnf/yum redraw a progress bar with "\r" instead of "\n":
    #     25%\r50%\r100%\n
    # Appending that as separate lines is what filled the pane with hundreds
    # of useless bar fragments and pushed the installer's prompts off screen.
    if [[ "$_line" == *"$_cr"* ]]; then
        _tail="${_line##*"$_cr"}"          # text after the LAST CR
        _head="${_line%"$_cr"}"            # line minus a trailing CR
        if [[ -z "$_tail" ]]; then
            # Ends with CR: the pty turns every "\n" into "\r\n", so this is
            # an ordinary line - drop the CR (and any earlier redraws) and
            # append it normally.
            _head="${_head##*"$_cr"}"
            [[ -z "$_head" ]] && return 0
            PROGRESS_ACTIVE=0
            if (( _replace == 1 )); then LOG_BUFFER[-1]="${_head}"
            else add_output_line "${_head}"; fi
            return 0
        fi
        # Several updates in one read: keep only the final state and OVERWRITE
        # the current line instead of adding a new one.
        if (( _replace == 1 )); then PROGRESS_ACTIVE=1; fi
        if (( PROGRESS_ACTIVE == 1 )) && (( ${#LOG_BUFFER[@]} > 0 )); then
            LOG_BUFFER[-1]="${_tail}"
        else
            LOG_BUFFER+=("${_tail}")
            PROGRESS_ACTIVE=1
        fi
        if (( SCROLL_FOLLOW == 1 )); then
            SCROLL_OFFSET=$(( ${#LOG_BUFFER[@]} - OUT_ROWS ))
            (( SCROLL_OFFSET < 0 )) && SCROLL_OFFSET=0
        fi
        return 0
    fi

    PROGRESS_ACTIVE=0
    if (( _replace == 1 )); then
        LOG_BUFFER[-1]="${_line}"
        if (( SCROLL_FOLLOW == 1 )); then
            SCROLL_OFFSET=$(( ${#LOG_BUFFER[@]} - OUT_ROWS ))
            (( SCROLL_OFFSET < 0 )) && SCROLL_OFFSET=0
        fi
    else
        add_output_line "${_line}"
    fi
}

# stream_handle_partial <text>
# Shows a fragment that has NOT been newline-terminated yet, such as an
# installer prompt ("Press ENTER to accept ..."). Without this it would sit in
# the reader's buffer and stay invisible until the next full line arrives -
# which never happens when the child is waiting for an answer.
stream_handle_partial() {
    local _t="$1"
    [[ -z "$_t" ]] && return 0

    if (( PARTIAL_ACTIVE == 1 )) && (( ${#LOG_BUFFER[@]} > 0 )); then
        LOG_BUFFER[-1]="${_t}"            # grow the live line in place
    else
        LOG_BUFFER+=("${_t}")
        PARTIAL_ACTIVE=1
    fi
    if (( SCROLL_FOLLOW == 1 )); then
        SCROLL_OFFSET=$(( ${#LOG_BUFFER[@]} - OUT_ROWS ))
        (( SCROLL_OFFSET < 0 )) && SCROLL_OFFSET=0
    fi
    SCROLL_NEEDED=1
}

# fitf <string> <width> <fillchar> <outvar>
# Clips to <width> display columns then pads with <fillchar>. The ONLY place
# text touches a border, so a long label can never push an edge out.
fitf() {    local _s="$1" _width="$2" _fill="${3:- }" _v="$4"
    local _n=${#_s} _i=0 _w=0 _out="" _pad="" _limit _j _cc
    if (( _width <= 0 )); then printf -v "$_v" '%s' ""; return; fi

    # Fast path: pure printable ASCII (space..tilde, no SGR, no multibyte).
    # One column per byte, so this is a substring plus padding. Installer
    # output is almost entirely ASCII and this keeps a full pane repaint in the
    # low milliseconds instead of hundreds - which is what makes typing
    # responsive. The class is applied through a parameter expansion because a
    # literal space is not allowed inside [[ ]] globs.
    local _pv="${_s//[^ -~]/}"
    if (( ${#_pv} == ${#_s} )); then
        if (( _n > _width )); then
            if (( _width >= 4 )); then
                printf -v "$_v" '%s...' "${_s:0:$(( _width - 3 ))}"
            else
                printf -v "$_v" '%s' "${_s:0:_width}"
            fi
            return
        fi
        if (( _n < _width )); then
            repeat_ch "$_fill" $(( _width - _n )) _pad
            printf -v "$_v" '%s%s' "$_s" "$_pad"
        else
            printf -v "$_v" '%s' "$_s"
        fi
        return
    fi

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

# snap_output_bottom — resume tail-following and jump to the newest line.
# Used whenever the user answers a prompt: they must see the latest output.
snap_output_bottom() {
    SCROLL_FOLLOW=1
    SCROLL_OFFSET=$(( ${#LOG_BUFFER[@]} - OUT_ROWS ))
    (( SCROLL_OFFSET < 0 )) && SCROLL_OFFSET=0
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
    L_LEFT=$(( L_COLS * 30 / 100 ))     # wide enough for " 2) Install SSL (..."
    (( L_LEFT < 26 )) && L_LEFT=26
    (( L_LEFT > 40 )) && L_LEFT=40
    (( L_LEFT > L_COLS - 30 )) && L_LEFT=$(( L_COLS - 30 ))
    L_RIGHT=$(( L_COLS - L_LEFT - 1 ))     # 1 column reserved for the shadow
    L_TOP=5
    # Footer on L_LINES-1, bottom border on L_LINES-2, so the LAST text row is
    # L_LINES-3 and the active prompt is never hidden behind the border.
    # Row L_LINES itself is never drawn.
    L_FOOTER=$(( L_LINES - 1 ))
    L_BOTTOM=$(( L_LINES - 2 ))
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
    # only if the menu (headers included) plus a 1-row gap still fits above it
    if (( L_CONTENT_H >= ${#NAV_LINES[@]} + 1 + BRAND_H )); then
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

# ------------------------------------------------------------
# svc_refresh — cache the state of the five core IceWarp services so the header
# can show them at a glance. Refreshed at most every 3 s, because the header is
# repainted once a second and pgrep/icewarpd must not run on every frame.
# ------------------------------------------------------------
svc_refresh() {
    (( IW_INSTALLED == 1 )) || return 0
    local _now=$SECONDS
    (( _now - SVC_LAST < 3 )) && return 0
    SVC_LAST=$_now

    local _root="${IW_ROOT:-/opt/icewarp}"
    local _d="${_root}/icewarpd.sh"
    local _s="" _p="" _c=""

    for _s in "${IW_SERVICES[@]}"; do
        _p="${SVC_PATH[${_s}]:-${_s}}"        # real binary path, e.g. sophos/savdid
        _c="${SVC_CHECK[${_s}]:-${_s}}"       # name icewarpd.sh knows, e.g. groupware

        # Primary: the service process itself.
        if command -v pgrep >/dev/null 2>&1 && pgrep -f "${_root}/${_p}" >/dev/null 2>&1; then
            SVC_UP["${_s}"]=1
            continue
        fi
        # Fallback: IceWarp's own init script.
        if [[ -x "${_d}" ]] \
           && timeout 3 "${_d}" --check "${_c}" >/dev/null 2>&1; then
            SVC_UP["${_s}"]=1
        else
            SVC_UP["${_s}"]=0
        fi
    done
    return 0
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

    if (( IW_INSTALLED == 1 )); then
        # At-a-glance health of the six core IceWarp services. RAM is shown as a
        # percentage only here, so all six fit on a narrow terminal.
        svc_refresh
        local _svc="" _s="" _ram_s=""
        if (( RAM_TOTAL_MB > 0 )); then
            _ram_s="RAM: ${RAM_PCT}%"
        else
            _ram_s="RAM: --"
        fi
        for _s in "${IW_SERVICES[@]}"; do
            if [[ "${SVC_UP[${_s}]:-0}" == "1" ]]; then
                _svc+="${FG_OK}[${_s}:OK]${C_RESET} "
            else
                _svc+="${FG_ERR}[${_s}:DOWN]${C_RESET} "
            fi
        done
        stat="${cpu}  |  ${_ram_s}  |  Services: ${_svc}|  Status: ${STATUS_MSG}"
    else
        stat="${cpu}  |  ${ram}  |  Agent: v${AGENT_VERSION:-0.8.1}  |  Status: ${STATUS_MSG}"
    fi
    fitf "$stat" $(( cols - 2 )) " " tmp
    buf+=$'\e[3;1H'"${BG_HDR}${FG_BORDER}${B_V}${FG_ACC}${tmp}${FG_BORDER}${B_V}${C_RESET}"

    repeat_ch "$B_H" $(( cols - 2 )) tmp
    buf+=$'\e[4;1H'"${BG_HDR}${FG_BORDER}${B_BL}${tmp}${B_BR}${C_RESET}"

    # Build only: the caller appends this to the frame buffer so the WHOLE
    # screen goes out in one write (double buffering - no tearing).
    RH_BUF="$buf"
}

render_stats_only() {
    layout
    if (( L_COLS < MIN_COLS || L_LINES < MIN_ROWS )); then render_too_small; return; fi
    render_header
    # One write for the whole header block.
    printf '\e[?2026h\e[?7l%s\e[1;1H\e[?2026l' "$RH_BUF"
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

    # Overflow hint on the last content row while scrolled away from the tail.
    if [[ "${SCROLL_FOLLOW:-1}" == "0" ]] \
       && (( SCROLL_OFFSET + OUT_ROWS < ${#LOG_BUFFER[@]} )) \
       && (( L_PANEL_H > 2 )); then
        fitf "${OVH_TEXT}" "$L_INNER_R" " " rt
        buf+=$'\e['"$(( L_TOP + L_PANEL_H - 2 ))"';'"$(( col + 1 ))"'H'"${BG_EXEC}${FG_WARN}${rt}${FG_BORDER}${B_V}${C_RESET}"
    fi
    printf '%s\e[1;1H\e[?2026l' "$buf"
}

# Cached, fully rendered Navigation pane rows. The pane only changes when the
# selection, the geometry or the menu labels change, so it is built once and
# reused by every repaint during a stream (this is what keeps the per-refresh
# cost low enough that typing stays responsive).
NAV_CACHE_KEY=""
NAV_CACHE_ROWS=()

nav_cache_refresh() {
    local _key="${MENU_SEL}|${IW_INSTALLED}|${L_LEFT}|${L_INNER_L}|${L_CONTENT_H}|${L_PANEL_H}|${SHOW_BRAND}|${BRAND_H}|${#NAV_LINES[@]}"
    if [[ "${_key}" == "${NAV_CACHE_KEY}" && ${#NAV_CACHE_ROWS[@]} -gt 0 ]]; then
        return 0
    fi
    NAV_CACHE_KEY="${_key}"
    NAV_CACHE_ROWS=()

    local r i lc
    for (( r = 0; r < L_PANEL_H; r++ )); do
        if (( r == 0 )); then
            fitf " Navigation " "$L_INNER_L" "$B_H" lc
            NAV_CACHE_ROWS+=("${FG_BORDER}${B_TL}${lc}${B_TR}${C_RESET}")
        elif (( r == L_PANEL_H - 1 )); then
            repeat_ch "$B_H" "$L_INNER_L" lc
            NAV_CACHE_ROWS+=("${FG_BORDER}${B_BL}${lc}${B_BR}${C_RESET}")
        else
            i=$(( r - 1 ))
            if (( i < ${#NAV_LINES[@]} )); then
                fitf "${NAV_LINES[i]}" "$L_INNER_L" " " lc
                if (( i < ${#NAV_ITEM[@]} )) && (( NAV_ITEM[i] >= 0 )) \
                   && (( NAV_ITEM[i] == MENU_SEL )); then
                    NAV_CACHE_ROWS+=("${BG_SEL}${FG_SEL}${C_BOLD}${lc}${BG_NAV}${C_RESET}")
                elif (( i < ${#NAV_ITEM[@]} )) && (( NAV_ITEM[i] < 0 )); then
                    if [[ -n "${NAV_LINES[i]}" ]]; then
                        NAV_CACHE_ROWS+=("${FG_ACC}${C_BOLD}${lc}${C_RESET}")
                    else
                        NAV_CACHE_ROWS+=("${lc}")
                    fi
                else
                    NAV_CACHE_ROWS+=("${FG_TXT}${lc}${C_RESET}")
                fi
            elif (( SHOW_BRAND == 1 && i >= L_CONTENT_H - BRAND_H )); then
                fitf "${BRAND_LINES[i - (L_CONTENT_H - BRAND_H)]}" "$L_INNER_L" " " lc
                NAV_CACHE_ROWS+=("${FG_DIM}${lc}${C_RESET}")
            else
                fitf "" "$L_INNER_L" " " lc
                NAV_CACHE_ROWS+=("${lc}")
            fi
        fi
    done
    return 0
}

# Builds the menu lines and the branding only when something that affects them
# actually changed, then (re)builds the cached Navigation rows. Rebuilding the
# menu on every repaint cost ~265 ms per frame, which starved the input loop
# and made typing crawl.
MENU_BUILD_KEY=""

nav_refresh_all() {
    local _k="${MENU_SEL}|${IW_INSTALLED}|${AGENT_VERSION}|${L_LEFT}|${L_INNER_L}|${L_CONTENT_H}|${L_PANEL_H}|${T_COLS}|${T_LINES}"
    if [[ "${_k}" != "${MENU_BUILD_KEY}" ]]; then
        build_menu_lines
        build_branding
        MENU_BUILD_KEY="${_k}"
        NAV_CACHE_KEY=""        # force the row cache to rebuild
    fi
    nav_cache_refresh
}

# Repaints ONLY the text lines inside the Output pane. No header, no
# navigation menu, no borders, no title - just the ~60x20 text box.
# This is what runs while a module streams: a small region repaint is smooth
# even on Windows Terminal, whereas a full-screen redraw tears and flickers.
render_output_pane_only() {
    if (( T_COLS < MIN_COLS || T_LINES < MIN_ROWS )); then return 0; fi
    layout

    local col=$(( L_LEFT + 2 ))
    local buf="" rc rc2 lc row r i loidx mx navline pad

    # Keep the newest line flush against the bottom border (row L_BOTTOM-1).
    if (( SCROLL_FOLLOW == 1 )); then
        SCROLL_OFFSET=$(( ${#LOG_BUFFER[@]} - OUT_ROWS ))
        (( SCROLL_OFFSET < 0 )) && SCROLL_OFFSET=0
    else
        mx=$(( ${#LOG_BUFFER[@]} - OUT_ROWS ))
        (( mx < 0 )) && mx=0
        (( SCROLL_OFFSET > mx )) && SCROLL_OFFSET=$mx
    fi

    nav_refresh_all        # menu + branding + nav rows, all cached

    buf+=$'\e[?2026h\e[?7l'
    for (( r = 0; r <= L_PANEL_H - 1; r++ )); do
        row=$(( L_TOP + r ))
        navline="${NAV_CACHE_ROWS[r]}"

        # ---- right column: the streamed text
        if (( r == 0 )); then
            fitf " Execution Output " "$L_INNER_R" "$B_H" rc
            buf+=$'\e['"$row"';1H'"${BG_NAV}${FG_BORDER}${B_V}${navline}${FG_BORDER}${B_V}${C_RESET}${BG_SHADOW}${FG_SHADOW}${SHADOW_CH}${C_RESET}${BG_EXEC}${FG_BORDER}${B_TL}${rc}${B_TR}${C_RESET}"
            continue
        elif (( r == L_PANEL_H - 1 )); then
            repeat_ch "$B_H" "$L_INNER_R" rc
            buf+=$'\e['"$row"';1H'"${BG_NAV}${FG_BORDER}${B_V}${navline}${FG_BORDER}${B_V}${C_RESET}${BG_SHADOW}${FG_SHADOW}${SHADOW_CH}${C_RESET}${BG_EXEC}${FG_BORDER}${B_BL}${rc}${B_BR}${C_RESET}"
            continue
        fi

        i=$(( r - 1 ))
        loidx=$(( SCROLL_OFFSET + i ))
        if (( loidx < ${#LOG_BUFFER[@]} )); then
            fitf "${LOG_BUFFER[loidx]}" "$L_INNER_R" " " rc
            line_color "${LOG_BUFFER[loidx]}"
            pane_safe "${rc}" rc2
        else
            fitf "" "$L_INNER_R" " " rc
            rc2="${rc}"
        fi
        # Split the padding off the text and reset in between: a colour that the
        # child opened and never closed is terminated BEFORE the padding, so it
        # can neither tint the empty part of the pane nor bleed into the border.
        pad="${rc2##*[! ]}"
        rc2="${rc2%"${pad}"}"
        buf+=$'\e['"$row"';1H'"${BG_NAV}${FG_BORDER}${B_V}${navline}${FG_BORDER}${B_V}${C_RESET}${BG_SHADOW}${FG_SHADOW}${SHADOW_CH}${C_RESET}${BG_EXEC}${C_RESET}${FG_BORDER}${B_V}${C_RESET}${BG_EXEC}${LINE_FG}${rc2}${C_RESET}${BG_EXEC}${pad}${C_RESET}${FG_BORDER}${B_V}${C_RESET}"
    done
    printf '%s\e[1;1H\e[?2026l' "$buf"
}

render_frame() {
    local _force="${1:-}"
    if (( T_COLS < MIN_COLS || T_LINES < MIN_ROWS )); then
        render_frame_small
        return
    fi
    layout
    if (( L_COLS < MIN_COLS || L_LINES < MIN_ROWS )); then
        render_frame_small
        return
    fi

    # While an action is executing, the header and the Navigation pane are
    # FROZEN. A full repaint here is what made both panes flash on every output
    # chunk, so any request is downgraded to a pane-only repaint. The caller
    # asks for a full frame with `render_frame force` when the action is over.
    if (( ACTION_RUNNING == 1 )) && [[ "$_force" != "force" ]]; then
        render_output_pane_only
        return 0
    fi

    local buf="" tmp lb lt rb rt lc rc rc2 row r i loidx seg lrow rrow bidx pad

    # Keep the window inside the buffer and, when following, flush against the
    # bottom border (newest line on row L_BOTTOM-1, no blank line below it).
    if (( SCROLL_FOLLOW == 1 )); then
        SCROLL_OFFSET=$(( ${#LOG_BUFFER[@]} - OUT_ROWS ))
        (( SCROLL_OFFSET < 0 )) && SCROLL_OFFSET=0
    else
        local _mx=$(( ${#LOG_BUFFER[@]} - OUT_ROWS ))
        (( _mx < 0 )) && _mx=0
        (( SCROLL_OFFSET > _mx )) && SCROLL_OFFSET=$_mx
    fi

    nav_refresh_all       # menu + branding, rebuilt only when they change

    # DOUBLE BUFFERING: the entire frame - prologue, header, both panes,
    # overflow hint and footer - is assembled here in memory and written with
    # ONE printf at the end. Nothing touches the terminal until it is complete,
    # so there is no tearing and no partial repaint.
    #
    # There is deliberately NO \e[2J (would flicker) and NO \e[?1049h either:
    # re-entering the alternate screen buffer CLEARS it on most terminals,
    # which is what produced the black flash every second.
    buf+=$'\e[?2026h\e[?7l\e[1;1H'
    render_header
    buf+="${RH_BUF}"

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

            # ---- left: menu (section headers + numbered items), then branding
            if (( i < ${#NAV_LINES[@]} )); then
                if (( i < ${#NAV_ITEM[@]} )) && (( NAV_ITEM[i] >= 0 )) \
                   && (( NAV_ITEM[i] == MENU_SEL )); then
                    fitf "${NAV_LINES[i]}" "$L_INNER_L" " " lc
                    lrow="${FG_BORDER}${B_V}${BG_SEL}${FG_SEL}${C_BOLD}${lc}${BG_NAV}${FG_BORDER}${B_V}${C_RESET}"
                elif (( i < ${#NAV_ITEM[@]} )) && (( NAV_ITEM[i] < 0 )); then
                    # section header / spacer
                    fitf "${NAV_LINES[i]}" "$L_INNER_L" " " lc
                    if [[ -n "${NAV_LINES[i]}" ]]; then
                        lrow="${FG_BORDER}${B_V}${FG_ACC}${C_BOLD}${lc}${FG_BORDER}${B_V}${C_RESET}"
                    else
                        lrow="${FG_BORDER}${B_V}${lc}${FG_BORDER}${B_V}${C_RESET}"
                    fi
                else
                    fitf "${NAV_LINES[i]}" "$L_INNER_L" " " lc
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
                # Hard reset at the START and END of every line, between the
                # text and its padding: a colour that the child opened and
                # never closed cannot bleed into the border or the next row.
                pad="${rc2##*[! ]}"
                rc2="${rc2%"${pad}"}"
                rrow="${C_RESET}${FG_BORDER}${B_V}${C_RESET}${BG_EXEC}${LINE_FG}${rc2}${C_RESET}${BG_EXEC}${pad}${C_RESET}${FG_BORDER}${B_V}${C_RESET}"
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

    # ---- overflow hint on the last content row (scrolled away from the tail)
    if [[ "${SCROLL_FOLLOW:-1}" == "0" ]] \
       && (( SCROLL_OFFSET + OUT_ROWS < ${#LOG_BUFFER[@]} )) \
       && (( L_PANEL_H > 2 )); then
        fitf "${OVH_TEXT}" "$L_INNER_R" " " tmp
        buf+=$'\e['"$(( L_TOP + L_PANEL_H - 2 ))"';'"$(( L_LEFT + 3 ))"'H'"${BG_EXEC}${FG_WARN}${tmp}${FG_BORDER}${B_V}${C_RESET}"
    fi

    # ---- footer on L_LINES-1; the true last row stays blank forever
    if [[ "${RUNNING:-0}" == "1" ]]; then
        local foot="Running...   [PgUp/PgDn] Scroll   [Esc/Ctrl-C] Abort"
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
# ------------------------------------------------------------
# read_escape_rest <outvar> [source]
# Called after an ESC byte has been read. Collects the remainder of the escape
# sequence and stores it WITHOUT the leading ESC ("[B", "[5~", "OA" ...).
#   - a CSI sequence is consumed up to and including its final byte (0x40..0x7E),
#     so the "~" of ESC [ 5 ~ never leaks out as a typed character
#   - sets the outvar to "" when nothing follows (a genuine, bare ESC press)
# The 50 ms window is what distinguishes an arrow key from a lone ESC.
# ------------------------------------------------------------
read_escape_rest() {
    local _v="$1" _src="${2:-/dev/tty}"
    local _seq="" _c="" _i=0
    printf -v "$_v" '%s' ""

    # Both reads must consume the SAME stream. A per-command redirect would
    # re-open a regular file from the start on every read.
    exec 7<"$_src" 2>/dev/null || return 0

    IFS= read -rsn1 -t 0.05 _c <&7 2>/dev/null || _c=""

    if [[ "$_c" == "[" || "$_c" == "O" ]]; then
        _seq="$_c"
        # Consume parameters until the final byte of the sequence.
        while (( _i < 4 )); do
            IFS= read -rsn1 -t 0.05 _c <&7 2>/dev/null || { _c=""; break; }
            [[ -z "$_c" ]] && break
            _seq+="$_c"
            [[ "$_c" > $'\x3F' ]] && break      # 0x40..0x7E = final byte
            _i=$(( _i + 1 ))
        done
    fi

    exec 7<&- 2>/dev/null
    printf -v "$_v" '%s' "$_seq"
    return 0
}

# menu_move — move the selection by d, clamped to the selectable items.
menu_move() {
    local d="$1"
    MENU_SEL=$(( MENU_SEL + d ))
    (( MENU_SEL < 0 )) && MENU_SEL=0
    (( MENU_SEL >= ${#MENU_LABELS[@]} )) && MENU_SEL=$(( ${#MENU_LABELS[@]} - 1 ))
    RENDER_NEEDED=1
}

# Left-click on a Navigation row: first click SELECTS, a second click on the
# already-selected row RUNS it. (Avoids accidental execution on a stray click.)
# Section headers and spacers are not selectable.
handle_click() {
    local mx="$1" my="$2" row idx
    layout
    (( mx < 1 || mx > L_LEFT )) && return 0        # not in the nav pane
    (( my < L_TOP + 1 )) && return 0               # header area
    build_menu_lines
    row=$(( my - L_TOP - 1 ))
    (( row < 0 || row >= ${#NAV_ITEM[@]} )) && return 0
    idx="${NAV_ITEM[row]}"
    (( idx < 0 )) && return 0                      # header / spacer row

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
        # ISIG is deliberately LEFT ON. Ctrl+C must raise SIGINT in OUR shell
        # (trapped below), not arrive as a raw 0x03 that we would forward into
        # the pty - there the line discipline would turn it into SIGINT for
        # install.sh, which is exactly how it ended up dying with code 130.
    fi

    # A signal during the stream aborts the child; it must not tear down the
    # TUI. The original handler is restored when the stream finishes.
    local STREAM_ABORT=0
    local _last_scrub=$SECONDS
    local _last_render_us=0 _now_us=0
    trap 'STREAM_ABORT=1' INT

    # Child writes its exit status to a file when it finishes. Completion is
    # detected by that file, NOT by EOF (we hold the write end) and NOT by
    # `kill -0` (which still succeeds for an unreaped zombie).
    rcfile="$TMP_DIR/.ui.rc"
    rm -f "$rcfile"
    # Interactive child: build a single shell-quoted command string so it can
    # be executed on a PTY. install.sh and its children (dnf/yum/rpm) draw to
    # /dev/tty unless they are attached to a pty; on a pty their output is
    # captured into the FIFO and lands in the Output pane instead of painting
    # over the Navigation pane.
    local pty_cmd="" a
    if (( INTERACTIVE == 1 )); then
        for a in "${cmd[@]}"; do
            pty_cmd+="$(printf '%q' "$a") "
        done
    fi

    (
        sub_rc=1
        if cd "$TMP_DIR"; then
            if (( INTERACTIVE == 1 )) && [[ -n "$pty_cmd" ]] && command -v script >/dev/null 2>&1; then
                # script(1) gives the child its own pty; setsid additionally
                # detaches it from OUR controlling terminal, so a tool like dnf
                # that opens /dev/tty cannot paint over the navigation pane -
                # it only ever reaches its pty, which we capture into the FIFO.
                if command -v setsid >/dev/null 2>&1; then
                    LC_ALL="$ORIG_LC_ALL" setsid script -q -c "$pty_cmd" /dev/null
                else
                    LC_ALL="$ORIG_LC_ALL" script -q -c "$pty_cmd" /dev/null
                fi
                sub_rc=$?
            elif (( INTERACTIVE == 1 )) && [[ -n "$pty_cmd" ]] && command -v setsid >/dev/null 2>&1; then
                # No pty available: at least detach the controlling terminal so
                # /dev/tty opens fail and the child falls back to stdout/stdin.
                LC_ALL="$ORIG_LC_ALL" setsid sh -c "$pty_cmd"
                sub_rc=$?
            else
                LC_ALL="$ORIG_LC_ALL" "${cmd[@]}"
                sub_rc=$?
            fi
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
        # ESC / Ctrl+C / SIGINT asked for an abort: stop the child, fall out.
        if (( STREAM_ABORT == 1 )); then
            kill "$pid" 2>/dev/null
            break
        fi
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

        # Repaint ONLY the output pane while a command streams, and never
        # faster than ~10 fps: dnf/yum emit thousands of lines and repainting
        # on every chunk is what made the screen flicker.
        (( got == 1 )) && SCROLL_NEEDED=1
        if [[ "${WINCH_FLAG:-0}" == "1" ]]; then
            WINCH_FLAG=0
            get_size
            RENDER_NEEDED=1
        fi

        _now_us="${EPOCHREALTIME//[!0-9]/}"
        [[ -z "$_now_us" ]] && _now_us=0
        if (( _now_us == 0 )) || (( _now_us - _last_render_us >= 100000 )); then
            if [[ "${RENDER_NEEDED:-0}" == "1" ]]; then
                RENDER_NEEDED=0
                SCROLL_NEEDED=0
                render_frame
                _last_render_us=$_now_us
            elif [[ "${SCROLL_NEEDED:-0}" == "1" ]]; then
                SCROLL_NEEDED=0
                # Pane text only: the header, menu and borders stay untouched.
                render_output_pane_only
                _last_render_us=$_now_us
            fi
        fi

        # Belt and braces: a child that still manages to write straight to the
        # terminal (dnf ignoring the pty) can smudge the navigation pane. Every
        # 5 s the whole frame is repainted with `force` so any stray output is
        # scrubbed and the menu is restored.
        if (( SECONDS - _last_scrub >= 5 )); then
            _last_scrub=$SECONDS
            RENDER_NEEDED=0
            SCROLL_NEEDED=0
            render_frame force
            _last_render_us=0
        fi

        # A prompt written WITHOUT a trailing newline ("Press ENTER to ...")
        # never reaches the line reader, so it would stay invisible. Show the
        # pending fragment live as the last line of the pane.
        if [[ -n "$partial" ]]; then
            stream_handle_partial "$partial"
        fi

        k=""
        IFS= read -rsn1 -t 0.02 k </dev/tty 2>/dev/null
        rc=$?
        if (( rc == 0 )); then
            case "$k" in
                $'\e')
                    # ESC starts a sequence. PageUp/PageDown belong to the TUI
                    # pane; everything else (arrows) goes to the installer.
                    local _seq="" _maxoff=0
                    read_escape_rest _seq /dev/tty
                    case "$_seq" in
                        '[5~')
                            # PageUp: stop following the tail, scroll back.
                            SCROLL_FOLLOW=0
                            SCROLL_OFFSET=$(( SCROLL_OFFSET - OUT_ROWS ))
                            (( SCROLL_OFFSET < 0 )) && SCROLL_OFFSET=0
                            dbg "pageup -> offset ${SCROLL_OFFSET}"
                            SCROLL_NEEDED=1
                            ;;
                        '[6~')
                            # PageDown: scroll forward, resume tail at the end.
                            SCROLL_OFFSET=$(( SCROLL_OFFSET + OUT_ROWS ))
                            _maxoff=$(( ${#LOG_BUFFER[@]} - OUT_ROWS ))
                            (( _maxoff < 0 )) && _maxoff=0
                            if (( SCROLL_OFFSET >= _maxoff )); then
                                SCROLL_OFFSET=$_maxoff
                                SCROLL_FOLLOW=1
                            fi
                            dbg "pagedown -> offset ${SCROLL_OFFSET} follow ${SCROLL_FOLLOW}"
                            SCROLL_NEEDED=1
                            ;;
                        '')
                            # Bare ESC cancels the running task (any mode).
                            dbg "ESC -> abort requested"
                            printf '\e[?1000h\e[?1006h' 2>/dev/null >/dev/tty
                            STREAM_ABORT=1
                            ;;
                        *)
                            if (( INTERACTIVE == 1 )); then
                                printf '%s%s' $'\e' "$_seq" >&8 2>/dev/null
                                dbg "forwarded escape sequence ESC${_seq}"
                            fi
                            ;;
                    esac
                    ;;
                $'\x03')
                    # Ctrl+C: abort the child and stay in the TUI.
                    dbg "CTRL-C -> abort requested"
                    printf '\e[?1000h\e[?1006h' 2>/dev/null >/dev/tty
                    STREAM_ABORT=1
                    ;;
                ''|$'\r'|$'\n')
                    # Enter. `read -n1` strips the newline, so Enter normally
                    # arrives as an EMPTY string; some terminals deliver CR/LF.
                    # The child lives on a pty, where a prompt is submitted with
                    # CR (0x0d) - sending LF would make install.sh ignore it.
                    if (( INTERACTIVE == 1 )); then
                        printf '\r' >&8 2>/dev/null
                        ECHO_ACTIVE=0
                        # No repaint here either: the pty echoes the newline
                        # and that output drives the next refresh.
                    fi
                    ;;
                *)
                    if (( INTERACTIVE == 1 )); then
                        if [[ "$k" == $'\x7f' || "$k" == $'\x08' ]]; then
                            printf '\x7f' >&8 2>/dev/null
                        elif [[ "$k" == [[:print:]] ]]; then
                            printf '%s' "$k" >&8 2>/dev/null
                        fi
                        # Deliberately NO local echo. The pty echoes the
                        # character back and stream_handle_partial draws it on
                        # the SAME line as the prompt; echoing it here as well
                        # is what produced the duplicated / next-line copy.
                        #
                        # Also NO repaint here: rendering on a keystroke blocks
                        # the input loop and makes typing crawl. The screen is
                        # refreshed only when the child actually writes output.
                    elif [[ "$k" == "q" || "$k" == "Q" ]]; then
                        dbg "abort requested"
                        kill "$pid" 2>/dev/null
                    fi
                    ;;
            esac
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
        # The installer may have left the screen in any state. Re-enter the
        # alternate buffer ONCE here (not on every frame - re-entering clears
        # it, which is what caused the black flash), then repaint fully.
        printf '\e[?1049h\e[2J\e[H' 2>/dev/null >/dev/tty
        RENDER_NEEDED=0
        SCROLL_NEEDED=0
        render_frame
        RENDER_NEEDED=1
    fi
    # Restore the application-level SIGINT handler for the menu.
    trap 'exit 130' INT

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
        branch)   PST_COLOR="${A_YELLOW}"; PST_TEXT="Different major branch - not installable" ;;
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
    IW_OFF_OTHER=""

    local _base="${ICEWARP_OFFICIAL_REPO%/}"
    if [[ -z "${_base}" ]]; then
        IW_OFF_CODE="nover"
        return 1
    fi

    # Which branch may we install? The installed one, or none (= newest
    # overall) on a fresh server.
    local _br=""
    (( IW_INSTALLED == 1 )) && branch_of "$IW_VERSION" _br

    # Collect every published version, then pick the highest of the branch.
    local _list=""
    _list="$(enumerate_official_versions 2>/dev/null)" || _list=""
    if [[ -z "${_list}" && -n "${VERSION_FILE_TARGET}" ]]; then
        _list="${VERSION_FILE_TARGET}"      # offline fallback
    fi
    if [[ -z "${_list}" ]]; then
        IW_OFF_CODE="nover"
        return 1
    fi

    local _pick=""
    _pick="$(printf '%s\n' "${_list}" | highest_in_branch "${_br}")"
    if [[ -z "${_pick}" ]]; then
        # Nothing in this branch: report what the newest overall is so the UI
        # can explain why it is not offered.
        IW_OFF_OTHER="$(printf '%s\n' "${_list}" | highest_in_branch "")"
        IW_OFF_CODE="branch"
        blog "official: no package in branch ${_br}; newest overall ${IW_OFF_OTHER}"
        return 1
    fi

    local _f="IceWarpServer-${_pick}_RHEL9_x64.tar.gz"
    probe_url "${_base}/${_f}" 0
    IW_OFF_CODE="${PROBE_CODE}"
    if [[ "${PROBE_CODE}" != "200" ]]; then
        blog "official: ${_f} -> ${PROBE_CODE}"
        return 1
    fi

    IW_OFF_OK=1
    IW_OFF_FILE="${_f}"
    IW_OFF_VERSION="${_pick}"

    # Read the REAL build from inside the archive (2 MB range fetch) and prefer
    # it over the filename, which may omit the build.
    local _exact=""
    _exact="$(get_exact_remote_version "${_base}/${_f}")"
    [[ -n "${_exact}" ]] && IW_OFF_VERSION="${_exact}"
    blog "official: branch=${_br:-any} file=${_f} version=${IW_OFF_VERSION}"
    return 0
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

    # Branch gate: never offer a package from a different major branch.
    if (( IW_INSTALLED == 1 )); then
        local _ib="" _pb=""
        branch_of "${IW_VERSION}" _ib
        branch_of "${IW_PA_VERSION}" _pb
        if [[ -n "${_pb}" && "${_pb}" != "${_ib}" ]]; then
            IW_PA_OK=0
            IW_PA_CODE="branch"
            IW_PA_OTHER="${IW_PA_VERSION}"
            blog "pars avan: ${IW_PA_VERSION} is outside branch ${_ib} - not offered"
            return 1
        fi
    fi
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

    # The newest build of the INSTALLED branch is now known: that - not the
    # absolute latest - is what the header warning compares against.
    if (( IW_OFF_OK == 1 )) && [[ -n "${IW_OFF_VERSION}" ]]; then
        TARGET_VERSION="${IW_OFF_VERSION}"
        recompute_stale
    fi

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
    if (( IW_INSTALLED == 1 )); then
        local _eb=""
        branch_of "${IW_VERSION}" _eb
        add_output_line "[INFO] Installed: ${IW_VERSION} - updates must stay in branch ${_eb}"
    else
        add_output_line "[INFO] IceWarp not installed - newest available build is offered"
    fi
    add_output_line ""

    if (( IW_OFF_OK == 1 )); then
        add_output_line "[${A_GREEN}OK${A_OFF}] 1) Official Server"
        add_output_line "        Status: ${A_GREEN}Reachable - OK${A_OFF}"
        add_output_line "        Version: ${A_GREEN}${IW_OFF_VERSION}${A_OFF} Found"
    else
        add_output_line "[${off_color}FAIL${A_OFF}] 1) Official Server"
        add_output_line "        Status: ${off_color}${off_status}${A_OFF}"
        if [[ "${IW_OFF_CODE}" == "branch" && -n "${IW_OFF_OTHER}" ]]; then
            add_output_line "        Newest: ${A_YELLOW}${IW_OFF_OTHER}${A_OFF} (other branch)"
        fi
    fi
    add_output_line ""

    if (( IW_PA_OK == 1 )); then
        add_output_line "[${A_GREEN}OK${A_OFF}] 2) Pars Avan Mirror"
        add_output_line "        Status: ${A_GREEN}Reachable - OK${A_OFF}"
        add_output_line "        Version: ${A_GREEN}${IW_PA_VERSION}${A_OFF} Found"
    else
        add_output_line "[${pa_color}FAIL${A_OFF}] 2) Pars Avan Mirror"
        add_output_line "        Status: ${pa_color}${pa_status}${A_OFF}"
        if [[ "${IW_PA_CODE}" == "branch" && -n "${IW_PA_OTHER}" ]]; then
            add_output_line "        Newest: ${A_YELLOW}${IW_PA_OTHER}${A_OFF} (other branch)"
        fi
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
                    # A custom URL must respect the same branch rule: a
                    # cross-branch package cannot be installed directly.
                    if (( IW_INSTALLED == 1 )); then
                        local _cur_ver="" _cur_b="" _wb=""
                        _cur_ver="$(get_exact_remote_version "${custom}" 1)"
                        [[ -z "${_cur_ver}" ]] && \
                            _cur_ver="$(get_exact_remote_version "${custom}" 0)"
                        if [[ -n "${_cur_ver}" ]]; then
                            branch_of "${IW_VERSION}" _cur_b
                            branch_of "${_cur_ver}" _wb
                            if [[ -n "${_wb}" && "${_wb}" != "${_cur_b}" ]]; then
                                add_output_line "[WARN] Major version jumps are not supported directly. You must update within the ${_cur_b} branch first."
                                add_output_line "[WARN] That URL contains ${_cur_ver} (branch ${_wb})."
                                STATUS_MSG="Ready"
                                RENDER_NEEDED=1
                                render_frame
                                RENDER_NEEDED=0
                                return 1
                            fi
                        fi
                    fi
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
        # verifiable from the target server.
        # Run inside a subshell with ALL THREE descriptors redirected: the
        # downloader must have no way at all to reach the terminal, so its
        # native progress bar can never overwrite the TUI. Only our
        # @@PROGRESS line is shown.
        (
            exec </dev/null >>"$log" 2>&1
            wget -q --no-check-certificate \
                 --user="$au" --password="$ap" \
                 --timeout=15 --tries=1 \
                 -O "$tmp_file" "$url"
        ) &
        dl_pid=$!
    fi
    if [ -z "$dl_pid" ] && command -v curl >/dev/null 2>&1; then
        (
            exec </dev/null >>"$log" 2>&1
            curl -fsSL --http0.9 --connect-timeout 15 -k -u "$au:$ap" \
                 -o "$tmp_file" "$url"
        ) &
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
# action_placeholder <message> — shared body for the not-yet-implemented
# modules. Keeps the menu wiring testable before the real logic lands.
# ------------------------------------------------------------
action_placeholder() {
    local _msg="$1"
    LOG_BUFFER=()
    SCROLL_OFFSET=0
    SCROLL_FOLLOW=1
    add_output_line "[INFO] ${_msg}"
    STATUS_MSG="Ready"
    RENDER_NEEDED=1
    render_frame
    RENDER_NEEDED=0
    return 0
}

# ---------------------------------------------------------------------------
# Security stack: CSF firewall, Nginx reverse proxy, ModSecurity + OWASP CRS.
# All sources are bundled in a single password-protected ZIP to avoid AV
# false positives on shared hosting. Override the URL by exporting the
# variable before running the agent.
# ---------------------------------------------------------------------------
SEC_BUNDLE_URL="https://parsavan.com/support/iceautochecker/linux-agent/source/icewarp-sec-sources.zip"
SEC_BUNDLE_PASS="parsavan"

# DO NOT assign SEC_BUNDLE_DIR here. TMP_DIR is empty at load time (it is set
# later by init_env), so a top-level assignment would freeze as "/sec-sources"
# at the root of the filesystem. Resolve the path lazily instead.
sec_bundle_dir() {
    printf '%s' "${TMP_DIR}/sec-sources"
}

# Exact archive names inside the bundle. The ZIP is FLAT (no top-level dir).
SEC_CSF_NAME="csf-firewall-v15.10.tgz"
SEC_NGINX_NAME="nginx-1.30.6.tar.gz"
SEC_MODSEC_NAME="modsecurity-v3.0.17.tar.gz"
SEC_MODSEC_NGINX_NAME="ModSecurity-nginx-v1.0.4.tar.gz"
SEC_CRS_NAME="coreruleset-4.25.2-minimal.tar.gz"

# Minimal build toolchain for Nginx + ModSecurity. Deliberately an explicit
# list - NEVER a dnf group ("Development Tools") and NEVER doxygen: those pull
# in documentation and desktop stacks (flatpak, pipewire, xdg-desktop-portal,
# tracker, X fonts) that are useless on a mail server and time out from slow
# mirrors. Keep this list tight; it is used by both build steps.
SEC_BUILD_PKGS=(
    gcc gcc-c++
    make cmake
    flex bison
    pcre2-devel libxml2-devel yajl-devel
    curl-devel openssl-devel zlib-devel
    libtool automake
)

# Individual source paths inside the extracted bundle (populated by
# fetch_and_extract_security_sources).
CSF_SRC_FILE=""
NGINX_SRC_FILE=""
MODSEC_SRC_FILE=""
MODSEC_NGINX_FILE=""
CRS_SRC_FILE=""

# Paths (overridable so the modules can be exercised off-server).
CSF_CONF="${CSF_CONF:-/etc/csf/csf.conf}"
NGINX_PREFIX="${NGINX_PREFIX:-/etc/nginx}"
NGINX_CONF_DIR="${NGINX_CONF_DIR:-/etc/nginx/conf.d}"
NGINX_CONF="${NGINX_CONF:-/etc/nginx/nginx.conf}"
MODSEC_DIR="${MODSEC_DIR:-/etc/nginx/modsec}"
NGINX_SRC_DIR="${NGINX_SRC_DIR:-/usr/src}"

# Ports CSF must leave open: 22 SSH, 80/443 the proxy, the mail ports,
# 32000/32001 IceWarp control, 5060/5061 SIP and 1080 Socks.
CSF_PORTS="22,80,443,25,110,143,465,587,993,995,32000,32001,5060,5061,1080"
CSF_UDP_PORTS="5060,32002"

# ---------------------------------------------------------------------------
# sec_fetch <url> <dest> — download one archive (wget, curl fallback).
# ---------------------------------------------------------------------------
sec_fetch() {
    local _u="$1" _d="$2"
    [[ -n "${_u}" && -n "${_d}" ]] || return 1
    rm -f "${_d}"
    if command -v wget >/dev/null 2>&1; then
        wget -q --no-check-certificate --timeout=30 --tries=2 \
             --user="${AUTH_USER:-}" --password="${AUTH_PASS:-}" \
             -O "${_d}" "${_u}" >/dev/null 2>&1 || true
    fi
    if [[ ! -s "${_d}" ]] && command -v curl >/dev/null 2>&1; then
        curl -fsSL -u "${AUTH_USER:-}:${AUTH_PASS:-}" -o "${_d}" "${_u}" 2>/dev/null || true
    fi
    [[ -s "${_d}" ]]
}

# ---------------------------------------------------------------------------
# sec_extract <archive> <destdir> — unpack .tar.gz/.tgz/.tar.xz/.zip.
# ---------------------------------------------------------------------------
sec_extract() {
    local _a="$1" _d="$2"
    [[ -f "${_a}" ]] || return 1
    mkdir -p "${_d}" || return 1
    case "${_a}" in
        *.tar.gz|*.tgz) tar -xzf "${_a}" -C "${_d}" 2>/dev/null ;;
        *.tar.xz)       tar -xJf "${_a}" -C "${_d}" 2>/dev/null ;;
        *.zip)          unzip -q "${_a}" -d "${_d}" 2>/dev/null || return 1 ;;
        *)              return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# sec_find_srcdir <extract_dir> <marker_file> — print the source root inside an
# extracted tarball. The folder name is NEVER assumed: releases ship as
# ModSecurity-3.0.17/, modsecurity-3.0.17/ or even flat (files at the archive
# root), so the location is derived from where <marker_file> actually lives.
# Returns 1 when the marker is nowhere to be found.
# ---------------------------------------------------------------------------
sec_find_srcdir() {
    local _base="$1" _marker="$2" _hit=""

    [[ -d "${_base}" ]] || return 1

    # 1. Flat archive: the marker sits at the extraction root.
    if [[ -e "${_base}/${_marker}" ]]; then
        printf '%s' "${_base}"
        return 0
    fi

    # 2. Single top-level directory that contains the marker.
    _hit="$(find "${_base}" -mindepth 2 -maxdepth 2 -iname "${_marker}" 2>/dev/null | head -1)"
    if [[ -n "${_hit}" ]]; then
        printf '%s' "$(dirname "${_hit}")"
        return 0
    fi

    # 3. Marker deeper down (e.g. a repackaged archive with an extra level).
    _hit="$(find "${_base}" -mindepth 2 -maxdepth 4 -iname "${_marker}" 2>/dev/null | head -1)"
    if [[ -n "${_hit}" ]]; then
        printf '%s' "$(dirname "${_hit}")"
        return 0
    fi

    return 1
}

# ---------------------------------------------------------------------------
# sec_install_connector — place the ModSecurity-nginx connector so that
# ${NGINX_SRC_DIR}/ModSecurity-nginx/config exists. nginx's
# --add-dynamic-module requires exactly that file, and the tarball ships it one
# level down (ModSecurity-nginx-<version>/config), so the CONTENTS of the
# detected root are copied - never the directory itself.
# Idempotent and self-healing. Returns 0 only when <target>/config is present.
# ---------------------------------------------------------------------------
sec_install_connector() {
    local _target="${NGINX_SRC_DIR}/ModSecurity-nginx"
    local _cbuild="${TMP_DIR}/modsec-nginx-build"
    local _src=""

    # Already in place.
    [[ -f "${_target}/config" ]] && return 0

    [[ -n "${MODSEC_NGINX_FILE:-}" && -f "${MODSEC_NGINX_FILE}" ]] || return 1

    rm -rf "${_cbuild}" "${_target}"
    if ! mkdir -p "${_cbuild}" "${NGINX_SRC_DIR}" 2>/dev/null; then
        rm -rf "${_cbuild}"
        return 1
    fi

    if ! tar -xzf "${MODSEC_NGINX_FILE}" -C "${_cbuild}" 2>/dev/null; then
        rm -rf "${_cbuild}"
        return 1
    fi

    # Locate the root by the file nginx needs, not by the folder name.
    if ! _src="$(sec_find_srcdir "${_cbuild}" config)"; then
        rm -rf "${_cbuild}"
        return 1
    fi

    mkdir -p "${_target}" 2>/dev/null
    # Copy the CONTENTS so <target>/config is exactly where nginx looks.
    if ! cp -a "${_src}/." "${_target}/" 2>/dev/null; then
        rm -rf "${_cbuild}" "${_target}"
        return 1
    fi
    rm -rf "${_cbuild}"

    [[ -f "${_target}/config" ]]
}

# ---------------------------------------------------------------------------
# sec_libmodsec_installed — true when libmodsecurity v3 headers/libs are present.
# Prevents adding --add-dynamic-module when the library is missing: that would
# fail the whole Nginx build instead of simply skipping the module.
# ---------------------------------------------------------------------------
sec_libmodsec_installed() {
    [[ -f /usr/local/include/modsecurity/modsecurity.h ]] && return 0
    [[ -f /usr/include/modsecurity/modsecurity.h ]] && return 0
    if command -v ldconfig >/dev/null 2>&1; then
        ldconfig -p 2>/dev/null | grep -q 'libmodsecurity' && return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# fetch_and_extract_security_sources — download the single password-protected
# ZIP bundle and extract ALL 5 source archives into ${TMP_DIR}/sec-sources/.
#
# Call once before any security-module install; repeat calls are cheap no-ops.
# The ZIP is FLAT: 5 files at the root, no top-level directory.
# The destination is resolved at CALL time via sec_bundle_dir(); never use a
# load-time variable here (TMP_DIR is still empty when this file is sourced,
# which previously produced the bogus "/sec-sources" path at the fs root).
# ---------------------------------------------------------------------------
fetch_and_extract_security_sources() {
    if [[ -z "${TMP_DIR:-}" ]]; then
        add_output_line "[FAIL] TMP_DIR is not initialised - cannot unpack the bundle."
        show_pane "Failed"
        return 1
    fi

    local _dir=""
    _dir="$(sec_bundle_dir)"

    # Contract: the five exact paths inside the bundle directory.
    CSF_SRC_FILE="${_dir}/${SEC_CSF_NAME}"
    NGINX_SRC_FILE="${_dir}/${SEC_NGINX_NAME}"
    MODSEC_SRC_FILE="${_dir}/${SEC_MODSEC_NAME}"
    MODSEC_NGINX_FILE="${_dir}/${SEC_MODSEC_NGINX_NAME}"
    CRS_SRC_FILE="${_dir}/${SEC_CRS_NAME}"

    # Already extracted and complete? Nothing to do.
    if [[ -f "${CSF_SRC_FILE}" && -f "${NGINX_SRC_FILE}" \
          && -f "${MODSEC_SRC_FILE}" && -f "${MODSEC_NGINX_FILE}" \
          && -f "${CRS_SRC_FILE}" ]]; then
        add_output_line "[OK] Security sources already present at ${_dir}"
        return 0
    fi

    # A directory that exists but is incomplete is stale (an earlier failure
    # left it behind). Remove it so unzip starts from a clean target.
    if [[ -d "${_dir}" ]]; then
        add_output_line "[INFO] Stale bundle found at ${_dir} - forcing fresh download..."
        rm -rf "${_dir}"
    fi
    if ! mkdir -p "${_dir}" 2>/dev/null; then
        add_output_line "[FAIL] Cannot create ${_dir}"
        show_pane "Failed"
        return 1
    fi

    # unzip is required for the password-protected bundle.
    if ! command -v unzip >/dev/null 2>&1; then
        add_output_line "[INFO] unzip is missing - installing it..."
        show_pane "Installing unzip..."
        stream_cmd --keep 0 dnf install -y unzip
        if ! command -v unzip >/dev/null 2>&1; then
            add_output_line "[FAIL] unzip is still unavailable - cannot extract the bundle."
            show_pane "Failed"
            return 1
        fi
    fi

    local _zip="${TMP_DIR}/icewarp-sec-sources.zip"
    add_output_line "[INFO] Downloading security sources bundle..."
    show_pane "Downloading security bundle..."
    if ! sec_fetch "${SEC_BUNDLE_URL}" "${_zip}"; then
        add_output_line "[FAIL] Could not download ${SEC_BUNDLE_URL}"
        show_pane "Failed"
        return 1
    fi

    add_output_line "[INFO] Extracting bundle into ${_dir}"
    show_pane "Extracting bundle..."

    local _out="" _rc=0
    _out="$(unzip -q -o -P "${SEC_BUNDLE_PASS}" "${_zip}" -d "${_dir}" 2>&1)"
    _rc=$?
    if (( _rc != 0 )); then
        add_output_line "[FAIL] unzip failed (exit ${_rc})."
        [[ -n "${_out}" ]] && add_output_line "[INFO] ${_out}"
        add_output_line "[INFO] Wrong password or corrupt download: ${_zip}"
        show_pane "Failed"
        return 1
    fi

    # Verify all five archives landed in the bundle directory.
    local _missing=""
    [[ -f "${CSF_SRC_FILE}" ]]         || _missing+="${SEC_CSF_NAME} "
    [[ -f "${NGINX_SRC_FILE}" ]]       || _missing+="${SEC_NGINX_NAME} "
    [[ -f "${MODSEC_SRC_FILE}" ]]      || _missing+="${SEC_MODSEC_NAME} "
    [[ -f "${MODSEC_NGINX_FILE}" ]]    || _missing+="${SEC_MODSEC_NGINX_NAME} "
    [[ -f "${CRS_SRC_FILE}" ]]         || _missing+="${SEC_CRS_NAME} "

    if [[ -n "${_missing}" ]]; then
        add_output_line "[FAIL] Security bundle incomplete - missing: ${_missing}"
        add_output_line "[INFO] Contents of ${_dir}:"
        ls -la "${_dir}" 2>/dev/null | while IFS= read -r _line; do
            add_output_line "       ${_line}"
        done
        show_pane "Failed"
        return 1
    fi

    add_output_line "[OK] All 5 security sources extracted to ${_dir}"
    return 0
}

# ---------------------------------------------------------------------------
# csf_set <KEY> <VALUE> <file> — replace "KEY = ..." or append it.
# ---------------------------------------------------------------------------
csf_set() {
    local _k="$1" _v="$2" _f="$3"
    [[ -f "${_f}" ]] || return 1
    if grep -qE "^[[:space:]]*${_k}[[:space:]]*=" "${_f}"; then
        sed -i -E "s|^[[:space:]]*${_k}[[:space:]]*=.*|${_k} = \"${_v}\"|" "${_f}"
    else
        printf '%s = "%s"\n' "${_k}" "${_v}" >> "${_f}"
    fi
}

# ---------------------------------------------------------------------------
# IceWarp web-port switching.
#
# The config property names for the HTTP/HTTPS listener differ between IceWarp
# builds: 14.3.0.13 has no c_server_http_port, and writing an unknown key makes
# tool.sh answer "Property ... not found" / "Settings save problem". The names
# are therefore DISCOVERED at runtime - the documented convention is
# c_config_services_<service>_port / _sslport - and every write is verified by
# reading the value back.
#
# SAFETY RULE: IceWarp is stopped only AFTER both new ports are written and
# confirmed, and it is always started again before this function returns.
# A failed switch must never leave the mail server down.
# ---------------------------------------------------------------------------

# port_snapshot — "ss -tulpn" output, netstat as fallback, empty when neither.
port_snapshot() {
    local _out=""
    if command -v ss >/dev/null 2>&1; then
        _out="$(ss -tulpn 2>/dev/null)"
    fi
    if [[ -z "${_out}" ]] && command -v netstat >/dev/null 2>&1; then
        _out="$(netstat -tulpn 2>/dev/null)"
    fi
    printf '%s' "${_out}"
}

# icewarp_tool — absolute path to tool.sh, empty (rc 1) when not installed.
icewarp_tool() {
    local _root="${IW_ROOT:-/opt/icewarp}"
    if [[ -x "${_root}/tool.sh" ]]; then
        printf '%s' "${_root}/tool.sh"
        return 0
    fi
    if command -v tool.sh >/dev/null 2>&1; then
        command -v tool.sh
        return 0
    fi
    return 1
}

# iw_run_tool <tool> <args...> — run tool.sh with a timeout, stdout+stderr.
iw_run_tool() {
    local _tool="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout 15 "${_tool}" "$@" 2>&1
    else
        "${_tool}" "$@" 2>&1
    fi
}

# iw_tool_get <tool> <property> — current value, rc 1 when this build does not
# know the property (tool.sh prints "Property <name> not found").
iw_tool_get() {
    local _tool="$1" _key="$2" _out=""

    _out="$(iw_run_tool "${_tool}" get system "${_key}")"
    [[ -n "${_out}" ]] || return 1
    printf '%s' "${_out}" | grep -qi 'not found' && return 1

    _out="${_out%%$'\n'*}"            # first line only
    _out="${_out#*${_key}:}"          # tool.sh prefixes "<key>: "
    _out="${_out#*${_key}=}"
    _out="${_out//[[:space:]]/}"
    [[ "${_out}" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "${_out}"
}

# iw_tool_set_verified <tool> <property> <value> — write a property and confirm
# it by reading it back. Deletion-proof: a silent "save problem" is a failure.
iw_tool_set_verified() {
    local _tool="$1" _key="$2" _want="$3" _out="" _now=""

    _out="$(iw_run_tool "${_tool}" set system "${_key}" "${_want}")"
    printf '%s\n' "${_out}" | grep -qiE 'not found|save problem|failed|error' && return 1

    _now="$(iw_tool_get "${_tool}" "${_key}")" || return 1
    (( 10#${_now} == 10#${_want} ))
}

# iw_pick_prop <tool> <http|https> — print the property name this build really
# has, preferring the one whose current value is a known listener port (80/8080
# for HTTP, 443/8443 for HTTPS). That value check is what stops us from grabbing
# a look-alike key such as the second port (32000/32001).
iw_pick_prop() {
    local _tool="$1" _kind="$2" _name="" _val="" _lname="" _fallback=""
    local _sane_a="80" _sane_b="8080"
    local -a _list=()

    if [[ "${_kind}" == "https" ]]; then
        _sane_a="443"
        _sane_b="8443"
        _list=(c_config_services_control_sslport c_system_services_control_sslport
               c_config_services_control_https_port c_config_services_http_sslport
               c_config_services_https_port c_system_services_https_port
               c_server_https_port C_Server_HTTPS_Port c_server_port_https)
    else
        _list=(c_config_services_control_port c_system_services_control_port
               c_config_services_http_port c_system_services_http_port
               c_config_services_web_port c_server_http_port
               C_Server_HTTP_Port c_server_port_http)
    fi

    for _name in "${IW_HARVESTED[@]}" "${_list[@]}"; do
        [[ -n "${_name}" ]] || continue
        _lname="${_name,,}"
        case "${_lname}" in
            *altport*|*port2*|*second*) continue ;;
        esac
        if [[ "${_kind}" == "https" ]]; then
            [[ "${_lname}" == *https* || "${_lname}" == *ssl* ]] || continue
        else
            [[ "${_lname}" == *https* || "${_lname}" == *ssl* ]] && continue
        fi

        _val="$(iw_tool_get "${_tool}" "${_name}")" || continue
        if [[ "${_val}" == "${_sane_a}" || "${_val}" == "${_sane_b}" ]]; then
            printf '%s' "${_name}"
            return 0
        fi
        [[ -z "${_fallback}" ]] && _fallback="${_name}"
    done

    [[ -n "${_fallback}" ]] || return 1
    printf '%s' "${_fallback}"
}

# iw_find_port_props <tool> — sets IW_HTTP_PROP / IW_HTTPS_PROP.
# Harvests candidate names from the full "display system" dump first (this is
# the "find the correct name dynamically" step), then falls back to the
# documented and legacy naming schemes.
iw_find_port_props() {
    local _tool="$1" _dump="" _line="" _name=""

    IW_HTTP_PROP=""
    IW_HTTPS_PROP=""
    IW_HARVESTED=()

    _dump="$(iw_run_tool "${_tool}" display system)"
    if [[ -n "${_dump}" ]]; then
        while IFS= read -r _line; do
            _name="${_line%%[:=]*}"
            _name="${_name//[[:space:]]/}"
            [[ -n "${_name}" ]] && IW_HARVESTED+=("${_name}")
        done < <(printf '%s\n' "${_dump}" | grep -i 'port' | grep -iE 'http|control|web' | grep -E '[:=]')
    fi

    IW_HTTP_PROP="$(iw_pick_prop "${_tool}" http)"
    IW_HTTPS_PROP="$(iw_pick_prop "${_tool}" https)"
}

# icewarp_ensure_running <init> — last-resort guard: if no IceWarp listener is
# visible, start the server so the TUI never returns with the mail server down.
icewarp_ensure_running() {
    local _init="$1" _dump="" _p=""

    _dump="$(port_snapshot)"
    for _p in 25 143 993 110 995 32000 32001 8080 8443; do
        if port_is_listening "${_p}" "${_dump}"; then
            return 0
        fi
    done
    add_output_line "[WARN] No IceWarp listener detected - starting IceWarp again."
    stream_cmd --keep 0 "${_init}" --start
    return 0
}

# ---------------------------------------------------------------------------
# icewarp_set_web_ports <http-port> — move IceWarp's own HTTP/HTTPS listener.
#   8080 -> https 8443 (frees 80/443 for the Nginx proxy)
#     80 -> https  443 (restore the default, e.g. to remove the proxy)
# ---------------------------------------------------------------------------
icewarp_set_web_ports() {
    local _http="$1" _https=""
    case "${_http}" in
        8080) _https="8443" ;;
        80)   _https="443"  ;;
        *)
            add_output_line "[FAIL] Unsupported web port ${_http}."
            return 1
            ;;
    esac

    local _root="${IW_ROOT:-/opt/icewarp}"
    local _init="${_root}/icewarpd.sh"
    local _tool="" _old_http="" _old_https="" _dump="" _waited=""

    if ! _tool="$(icewarp_tool)"; then
        add_output_line "[FAIL] tool.sh not found (${_root}/tool.sh and not on PATH)."
        add_output_line "[INFO] Nothing was changed - IceWarp keeps running unchanged."
        return 1
    fi

    # ---- 1. Discover the property names for THIS build ------------------
    add_output_line "[INFO] Looking up the IceWarp HTTP/HTTPS port properties..."
    iw_find_port_props "${_tool}"
    if [[ -z "${IW_HTTP_PROP}" || -z "${IW_HTTPS_PROP}" ]]; then
        add_output_line "[FAIL] This IceWarp build exposes no HTTP/HTTPS port property."
        add_output_line "[INFO] Tried the c_config_services_* / c_server_* names plus the"
        add_output_line "[INFO] names listed by 'tool.sh display system'."
        add_output_line "[INFO] Nothing was changed."
        add_output_line "[FAIL] IceWarp was NOT stopped - the mail server is still running."
        return 1
    fi
    add_output_line "[OK] HTTP port property:  ${IW_HTTP_PROP}"
    add_output_line "[OK] HTTPS port property: ${IW_HTTPS_PROP}"

    _old_http="$(iw_tool_get "${_tool}" "${IW_HTTP_PROP}")"
    _old_https="$(iw_tool_get "${_tool}" "${IW_HTTPS_PROP}")"
    add_output_line "[INFO] Current ports: ${_old_http}/${_old_https} -> ${_http}/${_https}"

    # Already there: do not restart a healthy server for nothing.
    if [[ "${_old_http}" == "${_http}" && "${_old_https}" == "${_https}" ]]; then
        add_output_line "[OK] IceWarp already uses ${_http}/${_https} - no restart needed."
        return 0
    fi

    # ---- 2. Write the ports; abort BEFORE touching the services ---------
    add_output_line "[INFO] Writing ${IW_HTTP_PROP} = ${_http}"
    if ! iw_tool_set_verified "${_tool}" "${IW_HTTP_PROP}" "${_http}"; then
        add_output_line "[FAIL] IceWarp rejected ${IW_HTTP_PROP}=${_http} - ports not changed."
        add_output_line "[FAIL] IceWarp was NOT stopped - the mail server is still running."
        return 1
    fi
    add_output_line "[INFO] Writing ${IW_HTTPS_PROP} = ${_https}"
    if ! iw_tool_set_verified "${_tool}" "${IW_HTTPS_PROP}" "${_https}"; then
        add_output_line "[FAIL] IceWarp rejected ${IW_HTTPS_PROP}=${_https} - ports not changed."
        add_output_line "[INFO] Rolling ${IW_HTTP_PROP} back to ${_old_http}..."
        if iw_tool_set_verified "${_tool}" "${IW_HTTP_PROP}" "${_old_http}"; then
            add_output_line "[OK] ${IW_HTTP_PROP} restored to ${_old_http}."
        else
            add_output_line "[WARN] Could not roll ${IW_HTTP_PROP} back - check it in the console."
        fi
        add_output_line "[FAIL] IceWarp was NOT stopped - the mail server is still running."
        return 1
    fi
    add_output_line "[OK] Both ports accepted and verified by read-back."

    # ---- 3. Restart cycle (only now are the services touched) -----------
    if [[ ! -x "${_init}" ]]; then
        add_output_line "[FAIL] ${_init} not found - cannot restart IceWarp safely."
        add_output_line "[INFO] Ports were written but stay inactive until the next restart."
        return 1
    fi

    add_output_line "[INFO] Stopping IceWarp to release the old ports..."
    stream_cmd --keep 0 "${_init}" --stop
    sleep 3

    if [[ "${_http}" == "8080" ]]; then
        _dump="$(port_snapshot)"
        if port_is_listening 80 "${_dump}" || port_is_listening 443 "${_dump}"; then
            add_output_line "[WARN] Ports 80/443 are still in use after the stop."
        else
            add_output_line "[OK] Ports 80/443 are free."
        fi
    fi

    add_output_line "[INFO] Starting IceWarp on ${_http}/${_https}..."
    stream_cmd --keep 0 "${_init}" --start
    if (( $? != 0 )); then
        add_output_line "[WARN] icewarpd.sh --start returned non-zero - retrying once."
        stream_cmd --keep 0 "${_init}" --start
    fi

    # Wait for the listener to appear (up to 10s) before declaring success.
    local _i=0
    _waited=0
    for _i in 1 2 3 4 5 6 7 8 9 10; do
        sleep 1
        _dump="$(port_snapshot)"
        if port_is_listening "${_http}" "${_dump}"; then
            _waited=1
            break
        fi
    done

    if (( _waited == 0 )); then
        icewarp_ensure_running "${_init}"
        add_output_line "[FAIL] IceWarp did not start listening on ${_http}."
        add_output_line "[INFO] Check System > Services in the IceWarp console."
        return 1
    fi

    add_output_line "[OK] IceWarp is back online on ports ${_http}/${_https}."
    if [[ "${_http}" == "8080" ]]; then
        _dump="$(port_snapshot)"
        if port_is_listening 80 "${_dump}" || port_is_listening 443 "${_dump}"; then
            add_output_line "[WARN] Something else still listens on 80/443."
        else
            add_output_line "[OK] Ports 80/443 are free for Nginx."
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# action_web_ports — manual switch between 8080/8443 and 80/443.
# ---------------------------------------------------------------------------
action_web_ports() {
    local k=""

    LOG_BUFFER=()
    add_output_line "[INFO] IceWarp web port switching"
    add_output_line ""
    add_output_line "1) Move IceWarp Web to Custom Ports (8080 / 8443)"
    add_output_line "2) Restore IceWarp Web to Default Ports (80 / 443)"
    add_output_line "3) Cancel"
    add_output_line ""
    add_output_line "Press 1-3 (Esc cancels)."
    show_pane "Choose 1-3"

    printf '\e[?1000l\e[?1006l' 2>/dev/null >/dev/tty
    if [[ -r /dev/tty ]]; then
        IFS= read -rsn1 -t 60 k </dev/tty || k=""
    else
        IFS= read -rsn1 -t 60 k || k=""
    fi
    printf '\e[?1000h\e[?1006h' 2>/dev/null >/dev/tty

    case "${k}" in
        1)
            add_output_line ""
            if icewarp_set_web_ports 8080; then
                add_output_line ""
                add_output_line "[OK] IceWarp web ports changed to 8080/8443. You can now install Nginx."
                SVC_LAST=-100
                show_pane "Ports switched"
                return 0
            fi
            add_output_line "[FAIL] Could not switch the ports - IceWarp was left running."
            SVC_LAST=-100
            show_pane "Failed"
            return 1
            ;;
        2)
            add_output_line ""
            if icewarp_set_web_ports 80; then
                add_output_line ""
                add_output_line "[OK] IceWarp web ports restored to 80/443."
                SVC_LAST=-100
                show_pane "Ports restored"
                return 0
            fi
            add_output_line "[FAIL] Could not restore the ports - IceWarp was left running."
            SVC_LAST=-100
            show_pane "Failed"
            return 1
            ;;
        *)
            add_output_line ""
            add_output_line "[INFO] Cancelled - no port change."
            show_pane
            return 0
            ;;
    esac
}

# ---------------------------------------------------------------------------
# install_csf — replace firewalld with CSF.
# ---------------------------------------------------------------------------
install_csf() {
    LOG_BUFFER=()
    add_output_line "[INFO] CSF - ConfigServer Security & Firewall"
    show_pane "Disabling firewalld..."

    if command -v firewall-cmd >/dev/null 2>&1; then
        stream_cmd --keep 0 systemctl disable --now firewalld
        add_output_line "[OK] firewalld disabled - CSF takes over."
        show_pane
    else
        add_output_line "[INFO] firewalld is not installed - nothing to disable."
        show_pane
    fi

    if ! fetch_and_extract_security_sources; then
        return 1
    fi
    add_output_line "[INFO] Using CSF archive: ${CSF_SRC_FILE}"
    show_pane "Extracting CSF..."

    local _work="${TMP_DIR}/csf-build"
    rm -rf "${_work}"
    if ! sec_extract "${CSF_SRC_FILE}" "${_work}"; then
        add_output_line "[FAIL] Could not extract ${CSF_SRC_NAME}"
        show_pane "Failed"
        return 1
    fi

    local _sh=""
    _sh="$(find "${_work}" -maxdepth 3 -type f -name install.sh 2>/dev/null | head -1)"
    if [[ -z "${_sh}" ]]; then
        add_output_line "[FAIL] install.sh not found inside ${CSF_SRC_NAME}"
        show_pane "Failed"
        return 1
    fi

    add_output_line "[INFO] Running ${_sh} (answer its prompts below)"
    show_pane "Installing CSF..."
    stream_cmd --keep 1 sh -c "cd '$(dirname "${_sh}")' && sh ./install.sh"

    add_output_line ""
    if command -v csf >/dev/null 2>&1; then
        add_output_line "[OK] CSF installed. Next: menu item 'Configure CSF'."
        show_pane "CSF installed"
        return 0
    fi
    add_output_line "[FAIL] csf command not found after the installer finished."
    show_pane "Failed"
    return 1
}

# ---------------------------------------------------------------------------
# configure_csf — open exactly the IceWarp ports and switch TESTING off.
# ---------------------------------------------------------------------------
configure_csf() {
    LOG_BUFFER=()
    add_output_line "[INFO] Configuring CSF: ${CSF_CONF}"
    if [[ ! -f "${CSF_CONF}" ]]; then
        add_output_line "[FAIL] ${CSF_CONF} not found - install CSF first."
        show_pane "Failed"
        return 1
    fi

    local _bak="${CSF_CONF}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "${CSF_CONF}" "${_bak}" 2>/dev/null \
        && add_output_line "[OK] Backup: ${_bak}" \
        || add_output_line "[WARN] Could not create a backup."

    csf_set TESTING    "0"              "${CSF_CONF}"
    csf_set TCP_IN     "${CSF_PORTS}"   "${CSF_CONF}"
    csf_set TCP_OUT    "${CSF_PORTS}"   "${CSF_CONF}"
    csf_set UDP_IN     "${CSF_UDP_PORTS}" "${CSF_CONF}"

    add_output_line ""
    add_output_line "[OK] TESTING = \"0\"  (live firewall)"
    add_output_line "[OK] TCP_IN  = \"${CSF_PORTS}\""
    add_output_line "[OK] TCP_OUT = \"${CSF_PORTS}\""
    add_output_line "[OK] UDP_IN  = \"${CSF_UDP_PORTS}\""
    add_output_line ""
    add_output_line "[INFO] Reloading CSF rules (csf -r)..."
    show_pane "Applying CSF rules..."

    if ! command -v csf >/dev/null 2>&1; then
        add_output_line "[WARN] csf command not found - rules written but not loaded."
        add_output_line "[INFO] Start it once CSF is installed: csf -r"
        show_pane "CSF not installed"
        return 1
    fi

    stream_cmd --keep 0 csf -r
    local _rc=$?
    add_output_line ""
    if (( _rc == 0 )); then
        add_output_line "[OK] CSF rules reloaded."
        show_pane "CSF configured"
        return 0
    fi
    add_output_line "[FAIL] csf -r exited ${_rc}."
    show_pane "CSF reload failed"
    return 1
}

# ---------------------------------------------------------------------------
# install_nginx — build Nginx from source, with the ModSecurity connector as a
# dynamic module when it has already been downloaded.
# ---------------------------------------------------------------------------
install_nginx() {
    LOG_BUFFER=()
    add_output_line "[INFO] Nginx will become the reverse proxy on 80/443."
    show_pane "Checking ports..."

    # 80/443 must already be free. The port switch is a separate, explicit
    # step ("Switch Web Ports"), so nothing is changed behind the operator's
    # back here - only a warning and a confirmation.
    local _dump=""
    if command -v ss >/dev/null 2>&1; then
        _dump="$(ss -tulpn 2>/dev/null)"
    elif command -v netstat >/dev/null 2>&1; then
        _dump="$(netstat -tulpn 2>/dev/null)"
    fi

    if port_is_listening 80 "${_dump}" || port_is_listening 443 "${_dump}"; then
        add_output_line "[WARN] Ports 80/443 are still in use by IceWarp."
        add_output_line "[WARN] Please run \"Switch Web Ports\" (Item 8) first!"
        add_output_line ""
        add_output_line "Do you want to continue anyway? (y/N)"
        show_pane "Ports in use"

        local _ans=""
        printf '\e[?1000l\e[?1006l' 2>/dev/null >/dev/tty
        if [[ -r /dev/tty ]]; then
            IFS= read -rsn1 -t 60 _ans </dev/tty || _ans=""
        else
            IFS= read -rsn1 -t 60 _ans || _ans=""
        fi
        printf '\e[?1000h\e[?1006h' 2>/dev/null >/dev/tty

        case "${_ans}" in
            y|Y)
                add_output_line "[INFO] Continuing at operator request."
                show_pane
                ;;
            *)
                add_output_line ""
                add_output_line "[INFO] Aborted - free ports 80/443 first."
                show_pane "Aborted"
                return 1
                ;;
        esac
    else
        add_output_line "[OK] Ports 80/443 are free."
    fi
    add_output_line ""

    add_output_line ""
    add_output_line "[INFO] Installing build prerequisites..."
    add_output_line "[INFO] Packages: ${SEC_BUILD_PKGS[*]}"
    show_pane "Installing prerequisites..."
    # Explicit package list + weak deps off: no documentation or desktop stack.
    stream_cmd --keep 0 dnf install -y --setopt=install_weak_deps=False \
        "${SEC_BUILD_PKGS[@]}"

    if ! fetch_and_extract_security_sources; then
        return 1
    fi
    add_output_line "[INFO] Using Nginx archive: ${NGINX_SRC_FILE}"
    show_pane "Extracting Nginx..."

    # Unpack into a scratch dir; the tarball holds a single nginx-<version>/.
    local _build="${TMP_DIR}/nginx-build"
    rm -rf "${_build}"
    if ! mkdir -p "${_build}" 2>/dev/null; then
        add_output_line "[FAIL] Cannot create ${_build}"
        rm -rf "${_build}"
        show_pane "Failed"
        return 1
    fi
    if ! tar -xzf "${NGINX_SRC_FILE}" -C "${_build}" 2>/dev/null; then
        add_output_line "[FAIL] Could not extract ${SEC_NGINX_NAME}"
        rm -rf "${_build}"
        show_pane "Failed"
        return 1
    fi

    local _dir=""
    if ! _dir="$(sec_find_srcdir "${_build}" configure)"; then
        add_output_line "[FAIL] ./configure not found - unexpected ${SEC_NGINX_NAME} layout."
        add_output_line "[INFO] Extracted into ${_build}:"
        find "${_build}" -maxdepth 2 2>/dev/null | while IFS= read -r _line; do
            add_output_line "       ${_line}"
        done
        rm -rf "${_build}"
        show_pane "Failed"
        return 1
    fi
    add_output_line "[OK] Nginx source ready: ${_dir}"

    local _cfg="--prefix=${NGINX_PREFIX} --sbin-path=/usr/sbin/nginx"
    _cfg+=" --conf-path=${NGINX_CONF} --pid-path=/run/nginx.pid"
    _cfg+=" --with-http_ssl_module --with-http_realip_module --with-http_v2_module"
    local _conn="${NGINX_SRC_DIR}/ModSecurity-nginx"

    # Only add the dynamic module when the connector's <dir>/config exists AND
    # libmodsecurity is installed. Otherwise nginx's configure aborts with
    # "no <dir>/config was found" or the module fails to compile, and the whole
    # build is lost - worse than building without the module.
    if ! sec_libmodsec_installed; then
        add_output_line "[WARN] You should install ModSecurity BEFORE Nginx for the module to compile."
        add_output_line "[INFO] libmodsecurity is not installed - building Nginx WITHOUT it."
    elif sec_install_connector; then
        _cfg+=" --add-dynamic-module=${_conn}"
        add_output_line "[OK] Connector at ${_conn}/config - building the module."
    else
        add_output_line "[WARN] You should install ModSecurity BEFORE Nginx for the module to compile."
        add_output_line "[INFO] Connector missing at ${_conn}/config - building WITHOUT it."
    fi

    add_output_line "[INFO] ./configure ${_cfg}"
    show_pane "Compiling Nginx..."
    stream_cmd --keep 1 sh -c "cd '${_dir}' && ./configure ${_cfg} && make && make install"

    local _rc=$?
    add_output_line ""
    # Remove the build tree on both outcomes so the next run starts clean.
    rm -rf "${_build}"
    if (( _rc == 0 )) && command -v nginx >/dev/null 2>&1; then
        add_output_line "[OK] Nginx installed. Next: 'Configure Nginx'."
        show_pane "Nginx installed"
        return 0
    fi
    add_output_line "[FAIL] Nginx build failed (exit ${_rc})."
    add_output_line "[INFO] Full log is in the pane above."
    show_pane "Failed"
    return 1
}

# ---------------------------------------------------------------------------
# configure_nginx — IceWarp virtual host as a reverse proxy + module load.
# SSL certificate path is resolved dynamically:
#  1) Use an existing self-signed cert from ${AGENT_DIR}/ssl/self-signed-*/
#  2) Otherwise generate a temporary self-signed cert in /etc/nginx/ssl/
# ---------------------------------------------------------------------------
configure_nginx() {
    LOG_BUFFER=()
    add_output_line "[INFO] Writing ${NGINX_CONF_DIR}/icewarp.conf"
    if ! mkdir -p "${NGINX_CONF_DIR}" 2>/dev/null; then
        add_output_line "[FAIL] Cannot create ${NGINX_CONF_DIR}"
        show_pane "Failed"
        return 1
    fi

    # -----------------------------------------------------------------------
    # Determine SSL certificate paths
    # -----------------------------------------------------------------------
    local _ssl_cert="" _ssl_key="" _ssl_store=""
    _ssl_store="$(ssl_store)"   # ${AGENT_DIR}/ssl

    # Look for any self-signed certificate in the agent store (IP or custom domain)
    local _found=""
    for _dir in "${_ssl_store}"/self-signed-*/; do
        [[ -d "${_dir}" ]] || continue
        if [[ -f "${_dir}fullchain.pem" && -f "${_dir}privkey.pem" ]]; then
            _ssl_cert="${_dir}fullchain.pem"
            _ssl_key="${_dir}privkey.pem"
            _found="${_dir}"
            break
        fi
    done

    if [[ -z "${_ssl_cert}" ]]; then
        # No self-signed cert found: generate a temporary one in /etc/nginx/ssl/
        local _nginx_ssl_dir="/etc/nginx/ssl"
        mkdir -p "${_nginx_ssl_dir}" 2>/dev/null
        _ssl_cert="${_nginx_ssl_dir}/default-fullchain.pem"
        _ssl_key="${_nginx_ssl_dir}/default-privkey.pem"

        if [[ ! -f "${_ssl_cert}" || ! -f "${_ssl_key}" ]]; then
            add_output_line "[WARN] No self-signed certificate found in ${_ssl_store}/self-signed-*/"
            add_output_line "[WARN] Generating a temporary default certificate in ${_nginx_ssl_dir}/"
            show_pane "Generating temporary SSL certificate..."

            local _ip="" _subj=""
            _ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
            [[ -z "${_ip}" ]] && _ip="127.0.0.1"
            _subj="/C=IR/ST=Tehran/L=Tehran/O=Pars Avan/CN=${_ip}"

            stream_cmd --keep 0 openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
                -keyout "${_ssl_key}" -out "${_ssl_cert}" -subj "${_subj}" 2>/dev/null
            local _rc=$?
            if (( _rc != 0 )) || [[ ! -f "${_ssl_cert}" || ! -f "${_ssl_key}" ]]; then
                add_output_line "[FAIL] Could not generate temporary SSL certificate."
                show_pane "Failed"
                return 1
            fi
            add_output_line "[OK] Temporary certificate generated: ${_ssl_cert}"
        fi
        add_output_line "[INFO] Using temporary default certificate (replace with real one)."
    else
        add_output_line "[OK] Using self-signed certificate from: ${_found}"
    fi

    # -----------------------------------------------------------------------
    # Write the vhost configuration with the resolved certificate paths
    # -----------------------------------------------------------------------
    local _vhost="${NGINX_CONF_DIR}/icewarp.conf"
    cat > "${_vhost}" <<NGINXCONF
# IceWarp behind Nginx - managed by the IceWarp Health Agent.
# IceWarp itself listens on 8443 (https) / 8080 (http); Nginx owns 80/443.

proxy_cache_path /var/cache/nginx/icewarp levels=1:2 keys_zone=icewarp_cache:10m
                 max_size=500m inactive=60m use_temp_path=off;

upstream icewarp_backend {
    server 127.0.0.1:8443;
    keepalive 32;
}

server {
    listen 80 default_server;
    server_name _;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl default_server;
    server_name _;

    ssl_certificate     ${_ssl_cert};
    ssl_certificate_key ${_ssl_key};

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5:!RC4:!3DES;
    ssl_prefer_server_ciphers on;

    modsecurity on;
    modsecurity_rules_file /etc/nginx/modsec/modsec.conf;

    client_max_body_size 100m;
    proxy_http_version 1.1;
    proxy_set_header Host              \$host;
    proxy_set_header X-Real-IP         \$remote_addr;
    proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Upgrade           \$http_upgrade;
    proxy_set_header Connection        "upgrade";

    location / {
        proxy_pass https://icewarp_backend;
        proxy_ssl_verify off;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
NGINXCONF

    add_output_line "[OK] ${_vhost}"
    add_output_line "[INFO] HTTPS backend 127.0.0.1:8443 (IceWarp internal)"

    # Load the dynamic ModSecurity module once, if Nginx was built with it.
    local _mod="${NGINX_PREFIX}/modules/ngx_http_modsecurity_module.so"
    if [[ -f "${_mod}" && -f "${NGINX_CONF}" ]] \
       && ! grep -q 'ngx_http_modsecurity_module' "${NGINX_CONF}"; then
        sed -i "1i load_module modules/ngx_http_modsecurity_module.so;" "${NGINX_CONF}"
        add_output_line "[OK] load_module added to ${NGINX_CONF}"
    fi

    add_output_line ""
    add_output_line "[INFO] SSL certificate: ${_ssl_cert}"
    add_output_line "[INFO] SSL key:         ${_ssl_key}"
    show_pane "Testing Nginx config..."

    if ! command -v nginx >/dev/null 2>&1; then
        add_output_line "[FAIL] nginx binary not found - install it first."
        show_pane "Failed"
        return 1
    fi

    stream_cmd --keep 0 nginx -t
    local _rc=$?
    add_output_line ""
    if (( _rc != 0 )); then
        add_output_line "[FAIL] nginx -t failed - not reloading."
        show_pane "Config invalid"
        return 1
    fi
    add_output_line "[OK] Configuration is valid."
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^nginx'; then
        stream_cmd --keep 0 systemctl restart nginx
    else
        stream_cmd --keep 0 nginx -s reload
    fi
    add_output_line "[OK] Nginx is serving 80/443 and proxying to IceWarp:8443."
    show_pane "Nginx configured"
    return 0
}

# ---------------------------------------------------------------------------
# install_modsecurity — libmodsecurity v3 + the Nginx connector.
# Must run BEFORE install_nginx: the connector is needed at Nginx configure time.
# ---------------------------------------------------------------------------
install_modsecurity() {
    LOG_BUFFER=()
    add_output_line "[INFO] ModSecurity v3 (libmodsecurity) + Nginx connector"
    add_output_line "[INFO] Packages: ${SEC_BUILD_PKGS[*]}"
    show_pane "Installing prerequisites..."

    # Explicit package list + weak deps off: no doxygen, no graphviz, no desktop.
    stream_cmd --keep 0 dnf install -y --setopt=install_weak_deps=False \
        "${SEC_BUILD_PKGS[@]}"

    if ! fetch_and_extract_security_sources; then
        return 1
    fi

    # ---- 1. libmodsecurity ------------------------------------------------
    add_output_line "[INFO] Using ModSecurity archive: ${MODSEC_SRC_FILE}"
    show_pane "Extracting ModSecurity..."

    local _build="${TMP_DIR}/modsecurity-build"
    rm -rf "${_build}"
    if ! mkdir -p "${_build}" 2>/dev/null; then
        add_output_line "[FAIL] Cannot create ${_build}"
        rm -rf "${_build}"
        show_pane "Failed"
        return 1
    fi
    if ! tar -xzf "${MODSEC_SRC_FILE}" -C "${_build}" 2>/dev/null; then
        add_output_line "[FAIL] Could not extract ${SEC_MODSEC_NAME}"
        rm -rf "${_build}"
        show_pane "Failed"
        return 1
    fi

    local _dir=""
    if ! _dir="$(sec_find_srcdir "${_build}" build.sh)"; then
        add_output_line "[FAIL] Could not locate the ModSecurity source root in ${_build}"
        add_output_line "[INFO] Looking for build.sh (any folder name, any depth)."
        add_output_line "[INFO] Archive contents:"
        find "${_build}" -maxdepth 2 2>/dev/null | while IFS= read -r _line; do
            add_output_line "       ${_line}"
        done
        rm -rf "${_build}"
        show_pane "Failed"
        return 1
    fi
    add_output_line "[OK] ModSecurity source ready: ${_dir}"

    # ModSecurity's autotools step calls `git describe` to learn its version.
    # git is NOT a build dependency (configure falls back to a default) and it
    # must never be installed on a production mail server. A tiny PATH shim
    # answers the version query with the real version: no package, no
    # "git: command not found" noise, and a correct version string. The shim
    # lives inside the build tree, so it disappears with the usual cleanup.
    local _shim="${_build}/.gitshim"
    rm -rf "${_shim}"
    if mkdir -p "${_shim}" 2>/dev/null; then
        cat > "${_shim}/git" <<'GITSHIM'
#!/bin/sh
# Minimal git stand-in for ModSecurity's version probe.
case "$1" in
    describe)  echo "v3.0.17" ;;
    rev-parse) echo "0000000" ;;
    rev-list)  echo "1" ;;
esac
exit 0
GITSHIM
        chmod +x "${_shim}/git" 2>/dev/null
        add_output_line "[INFO] git is not installed (by design) - using a version shim."
    fi

    add_output_line "[INFO] ./configure --with-yajl  (this takes a few minutes)"
    show_pane "Compiling ModSecurity..."
    stream_cmd --keep 1 sh -c "export PATH='${_shim}:'\"\$PATH\"; cd '${_dir}' && ./build.sh && ./configure --with-yajl && make && make install && ldconfig"
    local _rc=$?

    add_output_line ""
    if (( _rc != 0 )); then
        add_output_line "[FAIL] ModSecurity build failed (exit ${_rc})."
        add_output_line "[INFO] Full log is in the pane above."
        rm -rf "${_build}"
        show_pane "Failed"
        return 1
    fi
    add_output_line "[OK] libmodsecurity installed."

    # ---- 2. Nginx connector (needed before Nginx is built) ----------------
    add_output_line "[INFO] Using connector archive: ${MODSEC_NGINX_FILE}"
    show_pane "Extracting connector..."

    if ! sec_install_connector; then
        add_output_line "[FAIL] Could not install the connector into ${NGINX_SRC_DIR}/ModSecurity-nginx"
        add_output_line "[INFO] nginx --add-dynamic-module needs <dir>/config to exist."
        add_output_line "[INFO] Archive: ${MODSEC_NGINX_FILE}"
        rm -rf "${_build}"
        show_pane "Failed"
        return 1
    fi
    add_output_line "[OK] Connector ready: ${NGINX_SRC_DIR}/ModSecurity-nginx/config"
    add_output_line "[INFO] Now run 'Install Nginx' so the module is compiled in."

    # Build tree no longer needed.
    rm -rf "${_build}"
    show_pane "ModSecurity installed"
    return 0
}

# ---------------------------------------------------------------------------
# configure_modsecurity — OWASP CRS + IceWarp exclusions (no conflict with the
# built-in Sophos AV: uploads are left to IceWarp, ModSecurity blocks the rest).
# ---------------------------------------------------------------------------
configure_modsecurity() {
    LOG_BUFFER=()
    add_output_line "[INFO] OWASP CRS -> ${MODSEC_DIR}"
    show_pane "Downloading OWASP CRS..."

    if ! fetch_and_extract_security_sources; then
        return 1
    fi
    add_output_line "[INFO] Using CRS archive: ${CRS_SRC_FILE}"

    if ! mkdir -p "${MODSEC_DIR}" 2>/dev/null; then
        add_output_line "[FAIL] Cannot create ${MODSEC_DIR}"
        show_pane "Failed"
        return 1
    fi

    rm -rf "${MODSEC_DIR}/crs"
    if ! sec_extract "${CRS_SRC_FILE}" "${MODSEC_DIR}"; then
        add_output_line "[FAIL] Could not extract ${SEC_CRS_NAME}"
        show_pane "Failed"
        return 1
    fi
    if [[ ! -f "${MODSEC_DIR}/crs/crs-setup.conf.example" ]]; then
        local _cd=""
        _cd="$(find "${MODSEC_DIR}" -maxdepth 2 -type f -name 'crs-setup.conf.example' 2>/dev/null | head -1)"
        if [[ -n "${_cd}" ]]; then
            mv "$(dirname "${_cd}")" "${MODSEC_DIR}/crs" 2>/dev/null
        fi
    fi
    if [[ -f "${MODSEC_DIR}/crs/crs-setup.conf.example" \
          && ! -f "${MODSEC_DIR}/crs/crs-setup.conf" ]]; then
        cp "${MODSEC_DIR}/crs/crs-setup.conf.example" "${MODSEC_DIR}/crs/crs-setup.conf"
    fi

    # The CRS exclusion hooks must exist before they are included. Minimal
    # bundles sometimes ship only the .example file.
    local _rules="${MODSEC_DIR}/crs/rules"
    local _hook _base
    for _hook in "REQUEST-900-EXCLUSION-RULES-BEFORE-CRS" \
                 "RESPONSE-999-EXCLUSION-RULES-AFTER-CRS"; do
        _base="${_rules}/${_hook}"
        if [[ ! -f "${_base}.conf" ]]; then
            if [[ -f "${_base}.conf.example" ]]; then
                cp "${_base}.conf.example" "${_base}.conf"
            else
                printf '# %s - created by the IceWarp Health Agent\n' "${_hook}" > "${_base}.conf"
            fi
        fi
    done
    add_output_line "[OK] CRS extracted to ${MODSEC_DIR}/crs"

    # Build the rule include list explicitly, so REQUEST-900 is loaded first and
    # RESPONSE-999 last WITHOUT listing them twice (duplicate rule IDs make
    # ModSecurity refuse to load).
    local _incs="" _f="" _b=""
    if [[ -d "${_rules}" ]]; then
        for _f in "${_rules}"/*.conf; do
            [[ -f "${_f}" ]] || continue
            _b="$(basename "${_f}")"
            case "${_b}" in
                REQUEST-900-*|RESPONSE-999-*) continue ;;
            esac
            _incs+="Include ${_f}"$'\n'
        done
    fi

    {
        cat <<'MODSECCONF'
# ModSecurity - managed by the IceWarp Health Agent.
# Start in DetectionOnly, review /var/log/nginx/modsecurity_audit.log, then
# switch SecRuleEngine to On.
SecRuleEngine DetectionOnly
SecRequestBodyAccess On
SecResponseBodyAccess Off
SecRequestBodyLimit 13107200
SecRequestBodyInMemoryLimit 131072
SecRequestBodyNoFilesLimit 131072
SecTmpDir /tmp/
SecDataDir /tmp/
SecAuditEngine RelevantOnly
SecAuditLogRelevantStatus "^(?:5|4(?!04))"
SecAuditLogParts ABIJDEFHZ
SecAuditLogType Serial
SecAuditLog /var/log/nginx/modsecurity_audit.log

MODSECCONF
        printf 'Include %s/crs/crs-setup.conf\n' "${MODSEC_DIR}"
        printf 'Include %s/crs/rules/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf\n' "${MODSEC_DIR}"
        printf '%s' "${_incs}"
        printf 'Include %s/crs/rules/RESPONSE-999-EXCLUSION-RULES-AFTER-CRS.conf\n' "${MODSEC_DIR}"
        printf 'Include %s/icewarp-exclusions.conf\n' "${MODSEC_DIR}"
    } > "${MODSEC_DIR}/modsec.conf"

    cat > "${MODSEC_DIR}/icewarp-exclusions.conf" <<'EXCLUSIONSCONF'
# ---------------------------------------------------------------------------
# IceWarp tuning for the OWASP CRS.
#
# Scope: ModSecurity guards the WEBMAIL / ADMIN web surface only. Mail protocol
# traffic (SMTP/IMAP/POP3) never passes through Nginx, so nothing here affects
# it.
#
# 1) FILE UPLOADS are NOT scanned here. IceWarp's built-in Sophos engine scans
#    every attachment; letting CRS inspect the same multipart bodies doubles the
#    CPU cost and rejects legitimate business files. For multipart requests the
#    engine is switched to DetectionOnly, so XSS / SQLi / RCE in ordinary
#    requests are still inspected and blocked by modsec.conf's SecRuleEngine.
# ---------------------------------------------------------------------------
SecRule REQUEST_HEADERS:Content-Type "@rx ^multipart/form-data" "id:1000001,phase:1,pass,nolog,ctl:ruleEngine=DetectionOnly"

# 2) CRS protocol checks that fight the webmail file picker.
#    920440 - URL file-extension restriction
#    920450 - HTTP header injection via file name
#    921110 - HTTP request smuggling (breaks some reverse-proxy POSTs)
# Uncomment the ones your audit log flags; they are not disabled by default so
# the generic protections stay intact.
#SecRuleRemoveById 920440
#SecRuleRemoveById 920450
#SecRuleRemoveById 921110

# 3) RCE rules. Keep them ON in general: they are the ones that stop a
#    compromised webmail. Only the specific IDs that fire on legitimate admin
#    commands should be relaxed, and only after reviewing the audit log:
#    932xxx - remote command execution
#    933xxx - PHP injection
#SecRuleRemoveById 932230
#SecRuleRemoveById 932235

# 4) Admin console endpoints can be excluded per location instead of globally.
#    Prefer a location block in icewarp.conf:
#      location /admin/ { modsecurity off; ... }
#    A blanket rule removal for the whole site is deliberately NOT applied.

# 5) Nuclear option - DISABLES EVERY CRS RULE. Only for triage; never leave it
#    enabled, it removes XSS/SQLi/RCE protection entirely:
#SecRuleRemoveById 900000-999999
EXCLUSIONSCONF

    add_output_line "[OK] ${MODSEC_DIR}/modsec.conf (SecRuleEngine DetectionOnly)"
    add_output_line "[OK] CRS hooks: REQUEST-900 (before) + RESPONSE-999 (after)"
    add_output_line "[OK] ${MODSEC_DIR}/icewarp-exclusions.conf (uploads -> Sophos)"

    if [[ -f "${NGINX_CONF_DIR}/icewarp.conf" ]] \
       && ! grep -q 'modsecurity_rules_file' "${NGINX_CONF_DIR}/icewarp.conf"; then
        add_output_line "[WARN] icewarp.conf does not load ModSecurity - run 'Configure Nginx'."
    fi

    add_output_line ""
    add_output_line "[INFO] Testing and reloading Nginx..."
    show_pane "Reloading Nginx..."
    if ! command -v nginx >/dev/null 2>&1; then
        add_output_line "[WARN] nginx not installed - configuration written only."
        show_pane "ModSecurity configured"
        return 0
    fi
    stream_cmd --keep 0 nginx -t
    if (( STREAM_RC != 0 )); then
        add_output_line "[FAIL] nginx -t failed - not reloading."
        show_pane "Config invalid"
        return 1
    fi
    stream_cmd --keep 0 nginx -s reload
    add_output_line "[OK] ModSecurity active (DetectionOnly). Switch to On after review."
    show_pane "ModSecurity configured"
    return 0
}

# ---------------------------------------------------------------------------
# action_resources — CPU / RAM / disk / block devices / uptime at a glance.
# Every probe is guarded so a minimal host still produces a readable report.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Table helpers for the Resource Overview. Columns are fixed at 20 + 48 visible
# characters so every border lines up; fitf() truncates with "..." when a value
# is too long and pads when it is too short.
# ---------------------------------------------------------------------------
TBL_W1=20
TBL_W2=48

tbl_border() {
    local _s1="" _s2=""
    repeat_ch "-" $(( TBL_W1 + 2 )) _s1
    repeat_ch "-" $(( TBL_W2 + 2 )) _s2
    add_output_line "+${_s1}+${_s2}+"
}

tbl_row() {
    local _a="" _b=""
    fitf "$1" "${TBL_W1}" " " _a
    fitf "$2" "${TBL_W2}" " " _b
    add_output_line "| ${_a} | ${_b} |"
}

# ---------------------------------------------------------------------------
# action_resources — CPU / memory / disk / network / uptime as an ASCII table.
# Every probe is guarded so a minimal host still produces a readable report.
# ---------------------------------------------------------------------------
action_resources() {
    local _os="" _kern="" _cores="" _model="" _load="" _line=""
    local _mt="" _mu="" _mf="" _ma="" _swp=""
    local _devs="" _nets="" _up="" _u="" _t="" _p="" _m="" _item=""

    LOG_BUFFER=()
    add_output_line "[INFO] === System Resources ==="
    add_output_line ""
    tbl_border
    tbl_row "System Information" "Value"
    tbl_border

    # ---- OS / kernel
    if [[ -r /etc/os-release ]]; then
        _os="$(awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null)"
    fi
    tbl_row "OS" "${_os:-n/a}"

    _kern="$(uname -r 2>/dev/null)"
    tbl_row "Kernel" "${_kern:-n/a}"

    # ---- CPU
    _cores="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
    tbl_row "CPU Cores" "${_cores:-n/a}"

    if command -v lscpu >/dev/null 2>&1; then
        _model="$(lscpu 2>/dev/null | sed -n 's/^Model name: *//p' | head -1)"
    fi
    if [[ -z "${_model}" && -r /proc/cpuinfo ]]; then
        _model="$(awk -F: '/model name/{sub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)"
    fi
    tbl_row "CPU Model" "${_model:-n/a}"

    if [[ -r /proc/loadavg ]]; then
        _load="$(awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null)"
    fi
    tbl_row "Load Average" "${_load:-n/a}"

    # ---- Memory
    if command -v free >/dev/null 2>&1; then
        read -r _mt _mu _mf _ma <<< "$(free -h 2>/dev/null | awk '/^Mem:/{print $2, $3, $4, $7; exit}')"
        _swp="$(free -h 2>/dev/null | awk '/^Swap:/{print $3" / "$2; exit}')"
    fi
    tbl_row "Memory (Total)"     "${_mt:-n/a}"
    tbl_row "Memory (Used)"      "${_mu:-n/a}"
    tbl_row "Memory (Free)"      "${_mf:-n/a}"
    tbl_row "Memory (Available)" "${_ma:-n/a}"
    tbl_row "Swap (Used/Total)"  "${_swp:-n/a}"

    # ---- Disk (only distinct mount points; /opt often lives on /)
    if command -v df >/dev/null 2>&1; then
        local _lastmnt=""
        while IFS= read -r _line; do
            [[ -z "${_line}" ]] && continue
            read -r _u _t _p _m <<< "${_line}"
            [[ "${_m}" == "${_lastmnt}" ]] && continue
            _lastmnt="${_m}"
            tbl_row "Disk (${_m})" "${_u} used / ${_t} total (${_p})"
        done < <(df -hP / /opt 2>/dev/null | awk 'NR>1{print $3, $2, $5, $6}')
    fi

    # ---- Block devices, joined into one row
    if command -v lsblk >/dev/null 2>&1; then
        while IFS= read -r _line; do
            [[ -z "${_line}" ]] && continue
            read -r _n _sz _ty <<< "${_line}"
            [[ -z "${_n}" ]] && continue
            [[ -n "${_devs}" ]] && _devs+=", "
            _devs+="${_n} (${_sz} ${_ty})"
        done < <(lsblk -d -o NAME,SIZE,TYPE --noheadings 2>/dev/null)
    fi
    tbl_row "Block Devices" "${_devs:-n/a}"

    # ---- Network interfaces with their first address
    if command -v ip >/dev/null 2>&1; then
        while IFS= read -r _line; do
            [[ -z "${_line}" ]] && continue
            read -r _n _st _a _rest <<< "${_line}"
            [[ -z "${_n}" || -z "${_a}" ]] && continue
            [[ -n "${_nets}" ]] && _nets+=", "
            _nets+="${_n} (${_a})"
        done < <(ip -br a 2>/dev/null)
    fi
    tbl_row "Network" "${_nets:-n/a}"

    # ---- Uptime
    if command -v uptime >/dev/null 2>&1; then
        _up="$(uptime -p 2>/dev/null)"
    fi
    tbl_row "Uptime" "${_up:-n/a}"

    tbl_border
    show_pane "Ready"
    return 0
}

# show_pane [status] — repaint after LOG_BUFFER has been filled by hand.
show_pane() {
    STATUS_MSG="${1:-Ready}"
    RENDER_NEEDED=1
    render_frame
    RENDER_NEEDED=0
    return 0
}

# stream_cmd [--keep] <interactive:0|1> <command...>
# Runs an ordinary system command through the same pty/FIFO engine the agent
# uses, so its output lands in the Output pane instead of on the raw terminal.
# --keep preserves the lines already in the pane (prompts printed just before
# the command, e.g. the DNS instructions shown before certbot runs).
stream_cmd() {
    local _keep=0
    if [[ "${1:-}" == "--keep" ]]; then
        _keep=1
        shift
    fi
    local _inter="$1"
    shift
    if (( _keep == 0 )); then
        LOG_BUFFER=()
    fi
    SCROLL_OFFSET=0
    SCROLL_FOLLOW=1
    STATUS_MSG="Running..."
    RENDER_NEEDED=1
    render_frame
    RENDER_NEEDED=0
    INTERACTIVE="${_inter}"
    STREAM_CMD=("$@")
    stream_run
    INTERACTIVE=0
    return "${STREAM_RC:-0}"
}

# valid_domain <name> — hostname check for the SSL module. Every label must
# start and end with an alphanumeric, and the TLD is alphabetic.
valid_domain() {
    local _d="$1"
    [[ -n "${_d}" && ${#_d} -le 253 ]] || return 1
    [[ "${_d}" == *.* ]] || return 1
    [[ "${_d}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || return 1
    return 0
}

# port_is_listening <port> <ss|netstat output>
# A port matches only as a whole token (":25 " / ".25 "), so 80 does not match
# 8080 and 25 does not match 1025.
port_is_listening() {
    local _p="$1" _dump="$2"
    [[ -n "${_dump}" ]] || return 1
    printf '%s\n' "${_dump}" | grep -qE "[.:]${_p}[[:space:]]"
}

# icewarp_svc <verb> — start/stop/restart through IceWarp's own init script
# (/opt/icewarp/icewarpd.sh). systemctl/service are NOT used: IceWarp ships its
# own service manager.
icewarp_svc() {
    local _verb="$1"
    local _root="${IW_ROOT:-/opt/icewarp}"
    local _init="${_root}/icewarpd.sh"

    LOG_BUFFER=()
    if [[ ! -x "${_init}" ]]; then
        add_output_line "[FAIL] ${_init} not found or not executable."
        add_output_line "[INFO] IceWarp uses its own init script, not systemctl."
        show_pane "Failed"
        return 1
    fi

    add_output_line "[INFO] ${_verb} IceWarp: ${_init} --${_verb}"
    stream_cmd --keep 0 "${_init}" "--${_verb}"
    local _rc=$?

    add_output_line ""
    if (( _rc == 0 )); then
        add_output_line "[OK] ${_init} --${_verb} finished (exit 0)"
    else
        add_output_line "[FAIL] --${_verb} failed (exit ${_rc})"
    fi

    # --check with no argument reports the overall state (0 = running).
    if timeout 5 "${_init}" --check >/dev/null 2>&1; then
        add_output_line "[INFO] Current state: running"
    else
        add_output_line "[INFO] Current state: stopped"
    fi
    SVC_LAST=-100             # force the header to re-read the service states
    show_pane "Ready"
    return "${_rc}"
}

# ---------------------------------------------------------------------------
# SSL certificates. Everything is written to the agent's own store and is NOT
# installed into IceWarp: the operator copies the .pem files manually.
# ---------------------------------------------------------------------------

# ssl_store — directory that holds every generated certificate.
# Directory that holds every generated certificate. Nothing is installed into
# IceWarp: the files are left here for manual installation.
# ALWAYS under ${AGENT_DIR}/ssl so cleanup() preserves it (see cleanup()).
ssl_store() {
    printf '%s' "${SSL_STORE:-${AGENT_DIR:-/root/agent}/ssl}"
}

# read_one_key [timeout] — read a single key, preferring the terminal.
read_one_key() {
    local _t="${1:-60}" _k=""
    printf '\e[?1000l\e[?1006l' 2>/dev/null >/dev/tty
    if [[ -r /dev/tty ]]; then
        IFS= read -rsn1 -t "${_t}" _k </dev/tty || _k=""
    else
        IFS= read -rsn1 -t "${_t}" _k || _k=""
    fi
    printf '\e[?1000h\e[?1006h' 2>/dev/null >/dev/tty
    printf '%s' "${_k}"
}

# ---------------------------------------------------------------------------
# ssl_letsencrypt — Let's Encrypt via DNS-01, then copy the issued .pem files
# into the agent store.
# ---------------------------------------------------------------------------
ssl_letsencrypt() {
    local domain="" _store="" _rc=0 _live=""

    if ! prompt_input "Domain for the certificate (e.g. mail.example.com), Esc cancels:" domain; then
        LOG_BUFFER=()
        add_output_line "[INFO] Cancelled."
        show_pane
        return 1
    fi
    domain="${domain// /}"
    if [[ -z "${domain}" ]]; then
        LOG_BUFFER=()
        add_output_line "[WARN] No domain entered - nothing to do."
        show_pane
        return 1
    fi
    if ! valid_domain "${domain}"; then
        LOG_BUFFER=()
        add_output_line "[FAIL] '${domain}' is not a valid domain name."
        show_pane "Failed"
        return 1
    fi

    LOG_BUFFER=()
    add_output_line "[INFO] Requesting a Let's Encrypt certificate for ${domain}"
    add_output_line "[INFO] Challenge type: DNS-01 (IceWarp serves its own HTTP)"
    show_pane "Checking certbot..."

    if ! command -v certbot >/dev/null 2>&1; then
        add_output_line "[INFO] certbot is not installed - installing it now..."
        stream_cmd --keep 0 dnf install -y certbot
        if ! command -v certbot >/dev/null 2>&1; then
            add_output_line "[FAIL] certbot is still unavailable - cannot continue."
            show_pane "Failed"
            return 1
        fi
        add_output_line "[OK] certbot installed."
        show_pane
    else
        add_output_line "[OK] certbot is already installed."
        show_pane
    fi

    add_output_line ""
    add_output_line "[WAIT] certbot will print a TXT record below."
    add_output_line "[WAIT] Please add the TXT record to your DNS, then press Enter to continue validation..."
    show_pane "Waiting for DNS..."

    # certbot prompts on the terminal, so this stream is interactive.
    stream_cmd --keep 1 certbot certonly --manual --preferred-challenges dns -d "${domain}" \
        --agree-tos --register-unsafely-without-email
    _rc=$?

    _live="/etc/letsencrypt/live/${domain}"
    _store="$(ssl_store)/${domain}"
    add_output_line ""
    if (( _rc == 0 )); then
        add_output_line "[OK] Certificate issued for ${domain}"
        if mkdir -p "${_store}" 2>/dev/null \
           && cp -a "${_live}/"*.pem "${_store}/" 2>/dev/null; then
            add_output_line "[OK] Certificates copied to ${_store}/"
        else
            add_output_line "[WARN] Could not copy the .pem files to ${_store}/"
            add_output_line "[INFO] They remain in ${_live}/"
        fi
    else
        add_output_line "[FAIL] certbot exited ${_rc} - no certificate was issued."
    fi

    add_output_line ""
    add_output_line "[INFO] Certificate files:"
    add_output_line "        ${_store}/fullchain.pem"
    add_output_line "        ${_store}/privkey.pem"
    add_output_line "        ${_store}/chain.pem"
    add_output_line "        ${_store}/cert.pem"
    add_output_line ""
    add_output_line "[INFO] Not installed into IceWarp - install them manually."
    if (( _rc == 0 )); then
        show_pane "Certificate issued"
    else
        show_pane "SSL failed"
    fi
    return "${_rc}"
}

# ---------------------------------------------------------------------------
# ssl_self_signed — 10-year self-signed certificate for the server IP.
# ---------------------------------------------------------------------------
ssl_self_signed() {
    local ip="" _dir="" _rc=0

    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    if [[ -z "${ip}" ]] && command -v ip >/dev/null 2>&1; then
        ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
    fi
    [[ -z "${ip}" ]] && ip="127.0.0.1"

    _dir="$(ssl_store)/self-signed-${ip}"
    LOG_BUFFER=()
    add_output_line "[INFO] Self-signed certificate for ${ip}"
    add_output_line "[INFO] Target: ${_dir}"

    if ! mkdir -p "${_dir}" 2>/dev/null; then
        add_output_line "[FAIL] Cannot create ${_dir}"
        show_pane "Failed"
        return 1
    fi
    show_pane "Generating certificate..."

    stream_cmd --keep 0 openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "${_dir}/privkey.pem" -out "${_dir}/fullchain.pem" \
        -subj "/C=IR/ST=Tehran/L=Tehran/O=Pars Avan/CN=${ip}"
    _rc=$?

    add_output_line ""
    if (( _rc == 0 )) && [[ -f "${_dir}/fullchain.pem" && -f "${_dir}/privkey.pem" ]]; then
        add_output_line "[OK] Self-signed certificate created."
        add_output_line "[INFO] Certificate files:"
        add_output_line "        ${_dir}/fullchain.pem"
        add_output_line "        ${_dir}/privkey.pem"
        add_output_line ""
        add_output_line "[INFO] CN=${ip}, valid 3650 days, RSA 2048."
        add_output_line "[INFO] Not installed into IceWarp - install them manually."
        show_pane "Certificate created"
        return 0
    fi
    add_output_line "[FAIL] openssl failed (exit ${_rc})."
    show_pane "Failed"
    return 1
}

# ---------------------------------------------------------------------------
# ssl_self_signed_domain — 10-year self-signed certificate for a CUSTOM DOMAIN.
# Needed when the domain cannot be validated for Let's Encrypt (no DNS control,
# no spare host to point at the server). Written to
# ${AGENT_DIR}/ssl/self-signed-<domain>/ and never installed into IceWarp.
# ---------------------------------------------------------------------------
ssl_self_signed_domain() {
    local domain="" _store="" _dir="" _rc=0
    local -a _san=()

    if ! prompt_input "Domain for the certificate (e.g. mail.example.com), Esc cancels:" domain; then
        LOG_BUFFER=()
        add_output_line "[INFO] Cancelled."
        show_pane
        return 1
    fi
    # Trim only leading/trailing whitespace: removing every space would silently
    # turn a typo like "mail.exa mple.com" into a different, valid domain.
    domain="${domain#"${domain%%[![:space:]]*}"}"
    domain="${domain%"${domain##*[![:space:]]}"}"
    domain="${domain%.}"          # tolerate a trailing root dot

    if [[ -z "${domain}" ]]; then
        LOG_BUFFER=()
        add_output_line "[WARN] No domain entered - nothing to do."
        show_pane
        return 1
    fi
    if [[ "${domain}" != *.* ]]; then
        LOG_BUFFER=()
        add_output_line "[FAIL] '${domain}' must be a full domain name (e.g. mail.example.com)."
        show_pane "Failed"
        return 1
    fi
    if ! valid_domain "${domain}"; then
        LOG_BUFFER=()
        add_output_line "[FAIL] '${domain}' is not a valid domain name."
        show_pane "Failed"
        return 1
    fi
    if ! command -v openssl >/dev/null 2>&1; then
        LOG_BUFFER=()
        add_output_line "[FAIL] openssl is not installed - cannot generate a certificate."
        show_pane "Failed"
        return 1
    fi

    _store="$(ssl_store)"                     # ${AGENT_DIR}/ssl
    _dir="${_store}/self-signed-${domain}"

    LOG_BUFFER=()
    add_output_line "[INFO] Self-signed certificate for ${domain}"
    add_output_line "[INFO] Target: ${_dir}"

    if ! mkdir -p "${_dir}" 2>/dev/null; then
        add_output_line "[FAIL] Cannot create ${_dir}"
        show_pane "Failed"
        return 1
    fi
    show_pane "Generating certificate..."

    # Modern clients ignore CN and validate subjectAltName only, so add a DNS
    # SAN when the local OpenSSL supports it (1.1.1+; older builds reject the
    # option outright and would make the whole command fail).
    if openssl req -help 2>&1 | grep -q -- '-addext'; then
        _san=(-addext "subjectAltName=DNS:${domain}")
    fi

    stream_cmd --keep 0 openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "${_dir}/privkey.pem" -out "${_dir}/fullchain.pem" \
        -subj "/C=IR/ST=Tehran/L=Tehran/O=Pars Avan/CN=${domain}" "${_san[@]}"
    _rc=$?

    add_output_line ""
    if (( _rc == 0 )) && [[ -f "${_dir}/fullchain.pem" && -f "${_dir}/privkey.pem" ]]; then
        add_output_line "[OK] Self-signed certificate created."
        add_output_line "[INFO] Certificate files:"
        add_output_line "        ${_dir}/fullchain.pem"
        add_output_line "        ${_dir}/privkey.pem"
        add_output_line ""
        add_output_line "[INFO] CN=${domain}, valid 3650 days, RSA 2048."
        add_output_line "[INFO] Not installed into IceWarp - install them manually."
        show_pane "Certificate created"
        return 0
    fi
    add_output_line "[FAIL] openssl failed (exit ${_rc})."
    show_pane "Failed"
    return 1
}

# ---------------------------------------------------------------------------
# action_ssl — choose the certificate type.
# ---------------------------------------------------------------------------
action_ssl() {
    local k=""

    LOG_BUFFER=()
    add_output_line "[INFO] === SSL Management ==="
    add_output_line "1) Let's Encrypt (Domain)"
    add_output_line "2) Self-Signed Certificate (Server IP)"
    add_output_line "3) Self-Signed Certificate (Custom Domain)"
    add_output_line "4) Cancel"
    add_output_line "Select [1-4]:"
    show_pane "Select 1-4"

    k="$(read_one_key 60)"

    case "${k}" in
        1) ssl_letsencrypt; return $? ;;
        2) ssl_self_signed; return $? ;;
        3) ssl_self_signed_domain; return $? ;;
        *)
            # Keep the menu on screen and just note the cancellation.
            add_output_line ""
            add_output_line "[INFO] Cancelled - no certificate was generated."
            show_pane
            return 0
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Check Firewall / Ports (report only - nothing is modified)
# ---------------------------------------------------------------------------
action_firewall() {
    # Ports IceWarp must be listening on.
    local -a required=("25:SMTP" "110:POP3" "143:IMAP" "465:SMTPS" "587:Submission" \
                       "993:IMAPS" "995:POP3S" "80:HTTP" "443:HTTPS")
    local entry port label probe="" open=0 closed=0 bad=0

    if command -v ss >/dev/null 2>&1; then
        probe="$(ss -tulpn 2>/dev/null)"
    fi
    if [[ -z "${probe}" ]] && command -v netstat >/dev/null 2>&1; then
        probe="$(netstat -tulpn 2>/dev/null)"
    fi

    LOG_BUFFER=()
    add_output_line "[INFO] IceWarp port checks:"
    add_output_line ""

    if [[ -z "${probe}" ]]; then
        add_output_line "[WARN] Could not read the listening ports (ss/netstat unavailable)."
        show_pane "Unknown"
        return 1
    fi

    for entry in "${required[@]}"; do
        port="${entry%%:*}"
        label="${entry#*:}"
        if port_is_listening "${port}" "${probe}"; then
            add_output_line "${A_GREEN}[OK] Port ${port} (${label}) is open${A_OFF}"
            open=$(( open + 1 ))
        else
            add_output_line "${A_RED}[FAIL] Port ${port} (${label}) is closed or blocked${A_OFF}"
            closed=$(( closed + 1 ))
            bad=$(( bad + 1 ))
        fi
    done

    add_output_line ""
    # 9001 is the legacy direct-control port: it must NOT be reachable.
    if port_is_listening 9001 "${probe}"; then
        add_output_line "${A_RED}[FAIL] Port 9001 is OPEN (Security Risk)${A_OFF}"
        bad=$(( bad + 1 ))
    else
        add_output_line "${A_GREEN}[OK] Port 9001 is correctly closed${A_OFF}"
    fi

    add_output_line ""
    add_output_line "[INFO] Open: ${open}   Closed: ${closed}   (report only, nothing changed)"
    if command -v firewall-cmd >/dev/null 2>&1; then
        local _fws=""
        _fws="$(firewall-cmd --state 2>/dev/null || true)"
        add_output_line "[INFO] firewalld: ${_fws:-not running}"
    fi
    if (( bad == 0 )); then
        show_pane "All ports correct"
        return 0
    fi
    show_pane "${bad} port issue(s)"
    return 1
}

# ---------------------------------------------------------------------------
# Manage IceWarp Services
# ---------------------------------------------------------------------------
action_services() {
    local k=""

    LOG_BUFFER=()
    add_output_line "[INFO] Manage IceWarp services:"
    add_output_line ""
    add_output_line "1) Restart IceWarp"
    add_output_line "2) Stop IceWarp"
    add_output_line "3) Start IceWarp"
    add_output_line "4) Cancel"
    add_output_line ""
    add_output_line "Press 1-4 (Esc cancels)."
    show_pane "Choose 1-4"

    printf '\e[?1000l\e[?1006l' 2>/dev/null >/dev/tty
    if [[ -r /dev/tty ]]; then
        IFS= read -rsn1 -t 60 k </dev/tty || k=""
    else
        IFS= read -rsn1 -t 60 k || k=""
    fi
    printf '\e[?1000h\e[?1006h' 2>/dev/null >/dev/tty

    case "${k}" in
        1) icewarp_svc restart ;;
        2) icewarp_svc stop ;;
        3) icewarp_svc start ;;
        *)
            # Keep the menu on screen and just note the cancellation.
            add_output_line ""
            add_output_line "[INFO] Cancelled - no service action taken."
            show_pane
            return 0
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Backup / Restore (backup only for now)
# ---------------------------------------------------------------------------
action_backup() {
    local _root="${IW_ROOT:-/opt/icewarp}"
    local _dir="${AGENT_DIR}/backups"
    local _stamp="" _out=""

    LOG_BUFFER=()
    if [[ ! -d "${_root}" ]]; then
        add_output_line "[FAIL] ${_root} does not exist - is IceWarp installed?"
        show_pane "Failed"
        return 1
    fi

    if ! mkdir -p "${_dir}" 2>/dev/null; then
        add_output_line "[FAIL] Cannot create ${_dir}"
        show_pane "Failed"
        return 1
    fi

    _stamp="$(date +%Y%m%d-%H%M)"
    _out="${_dir}/icewarp_backup_${_stamp}.tar.gz"

    add_output_line "[INFO] Backing up ${_root}"
    add_output_line "[INFO] Target: ${_out}"
    add_output_line "[INFO] Excluding ${_root}/logs and ${_root}/tmp"
    show_pane "Backing up..."

    stream_cmd --keep 0 tar -czf "${_out}" --exclude="${_root}/logs" --exclude="${_root}/tmp" "${_root}"
    local _rc=$?

    add_output_line ""
    if (( _rc == 0 )) && [[ -f "${_out}" ]]; then
        local _size=""
        _size="$(du -h "${_out}" 2>/dev/null | awk '{print $1}')"
        add_output_line "[OK] Backup created: ${_out} (${_size:-size unknown})"
        add_output_line "[INFO] Backup module complete. To restore, contact support."
        show_pane "Backup complete"
        return 0
    fi
    add_output_line "[FAIL] Backup failed (tar exit ${_rc})."
    show_pane "Failed"
    return 1
}

# ------------------------------------------------------------
# run_with_mouse_off — wrap EVERY action execution.
# Mouse reporting is disabled for the whole action so no escape sequence can
# leak into a child process's stdin or the pane, then restored and the TUI is
# repainted. Works for any action, interactive or not.
# ------------------------------------------------------------
run_with_mouse_off() {
    local _rc=0
    printf '\e[?1000l\e[?1006l' 2>/dev/null >/dev/tty
    # From here until the action returns, the header and the Navigation pane
    # are frozen: render_frame() is redirected to a pane-only repaint (see the
    # guard at the top of render_frame). Only the Output pane updates, which is
    # what keeps the rest of the screen from flickering.
    ACTION_RUNNING=1
    "$@" || _rc=$?
    ACTION_RUNNING=0
    printf '\e[?1000h\e[?1006h' 2>/dev/null >/dev/tty
    # One full repaint now that the action is over: menu, header and borders
    # are restored in a single write.
    RENDER_NEEDED=0
    SCROLL_NEEDED=0
    render_frame force
    return "$_rc"
}

activate() {
    case "${MENU_ACTIONS[MENU_SEL]}" in
        quit)     QUIT=1 ;;
        icewarp)  run_with_mouse_off update_agent ;;
        config)   run_with_mouse_off run_and_stream --config ;;
        apply)    run_with_mouse_off run_and_stream --config --apply ;;
        ssl)      run_with_mouse_off action_ssl ;;
        firewall) run_with_mouse_off action_firewall ;;
        services) run_with_mouse_off action_services ;;
        backup)   run_with_mouse_off action_backup ;;
        csf_install)    run_with_mouse_off install_csf ;;
        csf_config)     run_with_mouse_off configure_csf ;;
        web_ports)      run_with_mouse_off action_web_ports ;;
        nginx_install)  run_with_mouse_off install_nginx ;;
        nginx_config)   run_with_mouse_off configure_nginx ;;
        modsec_install) run_with_mouse_off install_modsecurity ;;
        modsec_config)  run_with_mouse_off configure_modsecurity ;;
        resources)      run_with_mouse_off action_resources ;;
        health)   run_with_mouse_off run_and_stream --report ;;
        list)     run_with_mouse_off run_and_stream --list ;;
        only)     run_with_mouse_off run_only_prompt ;;
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
# load_target_only — populate TARGET_VERSION at startup WITHOUT downloading the
# agent package. Tries a VERSION file next to the starting directory, then the
# tiny VERSION file from BASE_URL (never the 650 MB tarball).
# Without this the header has no target to compare against and the
# "installed version is old" warning can never fire on a fresh start.
# ------------------------------------------------------------
load_target_only() {
    [[ -n "${TMP_DIR}" ]] || return 1
    local _dst="${TMP_DIR}/VERSION"
    local _src="${START_DIR:-$PWD}/VERSION"

    if [[ -f "${_src}" ]]; then
        cp -f "${_src}" "${_dst}" 2>/dev/null || return 1
    else
        rm -f "${_dst}"
        # No local VERSION - the normal case for `curl | bash`. Pull the tiny
        # VERSION file straight from the web server; the version itself is
        # never hardcoded anywhere.
        if command -v curl >/dev/null 2>&1; then
            curl -sL --http0.9 -u "${AUTH_USER}:${AUTH_PASS}" \
                 "${BASE_URL}/VERSION" -o "${_dst}" 2>/dev/null || true
        fi
        if [[ ! -s "${_dst}" ]] && command -v wget >/dev/null 2>&1; then
            wget -q --no-check-certificate --timeout=5 \
                 --user="${AUTH_USER}" --password="${AUTH_PASS}" \
                 -O "${_dst}" "${BASE_URL}/VERSION" >/dev/null 2>&1 || true
        fi
        # Server offline or 404: no target, therefore no warning. Never guess.
        if [[ ! -s "${_dst}" ]]; then
            rm -f "${_dst}"
            blog "target version: ${BASE_URL}/VERSION unavailable - no stale check"
            return 1
        fi
    fi

    read_target_version
    blog "target version loaded from VERSION: ${TARGET_VERSION:-none} (stale=${VERSION_STALE})"
    [[ -n "${TARGET_VERSION}" ]]
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
    build_menu_lines
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
        # Restore the terminal only when /dev/tty is actually usable.
        if { : </dev/tty; } 2>/dev/null; then
            # Restore mouse reporting FIRST, then cursor/wrap/alt-screen.
            # Without ?1000l/?1006l the shell would keep receiving mouse
            # escape sequences after we exit.
            if command -v tput >/dev/null 2>&1; then
                tput rmcup 2>/dev/null >/dev/tty || true
            fi
            printf '\e[?1000l\e[?1006l\e[r\e[?7h\e[?25h\e[0m\e[?1049l' 2>/dev/null >/dev/tty
            [[ -n "$STTY_SAVE" ]] && stty "$STTY_SAVE" 2>/dev/null </dev/tty
            stty sane 2>/dev/null </dev/tty
        fi
    fi

    # Wipe the working tree, but NEVER the operator's data.
    #
    # PERSISTENT (must survive every run):
    #   ${AGENT_DIR}/ssl/       generated certificates
    #   ${AGENT_DIR}/backups/   IceWarp backups
    #   ${AGENT_DIR}/*.tar.gz   cached installers
    #   ${AGENT_DIR}/*.log      agent logs
    # DISPOSABLE (safe to delete): tmp/ and every extracted installer tree.
    if [[ -n "${AGENT_DIR}" && -d "${AGENT_DIR}" ]]; then
        blog "=== bootstrap end (rc=${_rc}) ==="
        find "${AGENT_DIR}" -mindepth 1 -maxdepth 1 -type d ! -name 'ssl' ! -name 'backups' -exec rm -rf {} + 2>/dev/null
        find "${AGENT_DIR}" -mindepth 1 -maxdepth 1 -type f -name '*.tmp' -delete 2>/dev/null
        find "${AGENT_DIR}" -mindepth 1 -maxdepth 1 -type f ! -name '*.log' ! -name '*.tar.gz' -delete 2>/dev/null
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

    # Enter the alternate screen buffer, written straight to /dev/tty so it
    # cannot be swallowed by a redirected stdout. tput smcup first (portable),
    # then the raw escape as an unconditional fallback: the shell prompt and
    # the window title must never be visible behind the TUI.
    { command -v tput >/dev/null 2>&1 && tput smcup; } 2>/dev/null >/dev/tty || true
    printf '\e[?1049h' >/dev/tty
    # Wipe the alternate buffer and home the cursor.
    printf '\e[2J\e[H' >/dev/tty
    printf '\e[3J' >/dev/tty
    # \e[r resets any DECSTBM scroll region a previous program may have left
    # set; a stale region makes writes scroll instead of overwrite in place.
    printf '\e[r' >/dev/tty
    printf '\e[?1049h\e[?7l\e[?25l' >/dev/tty
    # Mouse: ?1000 = button events, ?1006 = SGR extended coordinates, which
    # is what lets us parse wheel up (?64) / down (?65) reliably.
    printf '\e[?1000h\e[?1006h' >/dev/tty
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

    # With IceWarp installed we need the target version at startup, otherwise
    # the header has nothing to compare against and the stale-version warning
    # can never fire. This loads only the small VERSION file (no tarball).
    if (( IW_INSTALLED == 1 )) && [[ -z "${TARGET_VERSION}" ]]; then
        STATUS_MSG="Loading VERSION..."
        render_stats_only
        load_target_only || true
        build_menu
    fi

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
