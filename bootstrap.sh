#!/bin/bash
# ============================================================
# IceWarp Health Agent - Bootstrap Script (Pure Bash Gruvbox TUI)
# ============================================================
# curl -sSL https://parsavan.com/support/iceautochecker/linux-agent/bootstrap.sh | bash
#
# Zero-dependency, double-buffered, responsive Gruvbox Dark TUI.
# Pure Bash 4.0+ builtins only. No Python, no external tools in UI loop.
# ============================================================

# ============================================================
# Configuration
# ============================================================
readonly BASE_URL="https://parsavan.com/support/iceautochecker/linux-agent"
readonly AGENT_VERSION="0.8.0"
readonly AUTH_USER="parsavan"
readonly AUTH_PASS='P@rsavan.com@123'

# Runtime variables
START_DIR=""
TMP_DIR=""
SPINNER_PID=""
IW_ROOT=""
IW_VERSION=""
OS_NAME=""
OS_VERSION=""
TERM_WIDTH=0
TERM_HEIGHT=0
SCRIPT_EXITING=0
QUEUE_MONITOR_PID=""
QUEUE_STATUS="Idle"
QUEUE_COUNT=0

# UI State
MENU_SELECTED=0
MENU_ITEMS=("Run Health Assessment" "Check Configuration" "Apply Configuration" "Quit")
MENU_KEYS=("a" "b" "c" "q")
FOCUS_PANE=0  # 0 = menu, 1 = output
OUTPUT_LINES=()
OUTPUT_SCROLL=0

# ============================================================
# Gruvbox Dark 24-Bit TrueColor Palette
# ============================================================
readonly C_RESET=$'\e[0m'
readonly C_BOLD=$'\e[1m'
readonly C_DIM=$'\e[2m'
readonly C_REV=$'\e[7m'

# Backgrounds
readonly BG_HARD=$'\e[48;2;29;32;33m'    # #1d2021
readonly BG_MAIN=$'\e[48;2;40;40;40m'    # #282828
readonly BG_PANEL=$'\e[48;2;60;56;54m'   # #3c3836
readonly BG_SELECT=$'\e[48;2;80;73;69m'  # #504945
readonly BG_MUTED=$'\e[48;2;102;92;84m'  # #665c54

# Foregrounds
readonly FG_LIGHT0=$'\e[38;2;251;241;199m' # #fbf1c7
readonly FG_LIGHT1=$'\e[38;2;235;219;178m' # #ebdbb2
readonly FG_GRAY=$'\e[38;2;146;131;116m'   # #928374
readonly FG_BORDER=$'\e[38;2;102;92;84m'   # #665c54

# Accents
readonly FG_RED=$'\e[38;2;251;73;52m'      # #fb4934
readonly FG_GREEN=$'\e[38;2;184;187;38m'   # #b8bb26
readonly FG_YELLOW=$'\e[38;2;250;189;47m'  # #fabd2f
readonly FG_BLUE=$'\e[38;2;131;165;152m'   # #83a598
readonly FG_PURPLE=$'\e[38;2;211;134;155m' # #d3869b
readonly FG_AQUA=$'\e[38;2;142;192;124m'   # #8ec07c
readonly FG_ORANGE=$'\e[38;2;254;128;25m'  # #fe8019

# Unicode box drawing
readonly BOX_TL="╭"
readonly BOX_TR="╮"
readonly BOX_BL="╰"
readonly BOX_BR="╯"
readonly BOX_H="─"
readonly BOX_V="│"
readonly BOX_T="┬"
readonly BOX_B="┴"
readonly BOX_L="├"
readonly BOX_R="┤"
readonly BOX_X="┼"

# Spinner frames
SPINNER_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
SPINNER_IDX=0

# Frame buffer for double-buffered rendering
FRAME_BUFFER=""

# ============================================================
# Logging Setup
# ============================================================
setup_logging() {
    local log_file="$START_DIR/output/bootstrap_debug.log"
    mkdir -p "$START_DIR/output"
    exec 3>&- 2>/dev/null || true
    exec 3>"$log_file"
    exec 2> >(tee -a "$log_file" >&2)
}

log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $*" | tee -a "$START_DIR/output/bootstrap_debug.log"
}

# ============================================================
# Pure Bash String Utilities (No External Tools)
# ============================================================
# Pads or truncates string $1 to exact width $2, result in $3
fit_text() {
    local text="$1" width="$2" __outvar="$3"
    if (( width <= 0 )); then
        printf -v "$__outvar" ""
        return
    fi
    if (( ${#text} > width )); then
        if (( width > 1 )); then
            printf -v "$__outvar" "%s…" "${text:0:width-1}"
        else
            printf -v "$__outvar" "%s" "${text:0:1}"
        fi
    else
        printf -v "$__outvar" "%-*s" "$width" "$text"
    fi
}

# Repeats character $1 for $2 times into variable $3
repeat_str() {
    local char="$1" count="$2" __outvar="$3"
    if (( count <= 0 )); then
        printf -v "$__outvar" ""
        return
    fi
    local spaces
    printf -v spaces "%*s" "$count" ""
    printf -v "$__outvar" "%s" "${spaces// /$char}"
}

# ============================================================
# Terminal & Cursor Control
# ============================================================
get_term_size() {
    # Trigger checkwinsize to update COLUMNS/LINES
    (:;:) 2>/dev/null
    TERM_WIDTH=${COLUMNS:-80}
    TERM_HEIGHT=${LINES:-24}
    log "Terminal size: ${TERM_WIDTH}x${TERM_HEIGHT}"
}

hide_cursor() { printf '\e[?25l'; }
show_cursor() { printf '\e[?25h'; }
enter_alt_screen() { printf '\e[?1049h'; }
exit_alt_screen() { printf '\e[?1049l'; }
cursor_to() { printf '\e[%d;%dH' "$1" "$2"; }
clear_eol() { printf '\e[K'; }

# ============================================================
# Cleanup Handler
# ============================================================
cleanup() {
    log "Cleanup triggered (SCRIPT_EXITING=$SCRIPT_EXITING)"
    # Stop background processes
    if [[ -n "$SPINNER_PID" ]]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
    fi
    if [[ -n "$QUEUE_MONITOR_PID" ]]; then
        kill "$QUEUE_MONITOR_PID" 2>/dev/null || true
        wait "$QUEUE_MONITOR_PID" 2>/dev/null || true
    fi
    # Restore terminal
    show_cursor
    exit_alt_screen
    printf '%s' "$C_RESET"
    # Clean temp dir only
    if [[ -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
        log "Removed temp dir: $TMP_DIR"
    fi
    # NEVER touch $START_DIR/output/
}
trap cleanup EXIT INT TERM

# Handle window resize
handle_winch() {
    get_term_size
    render_frame
}
trap handle_winch WINCH

# ============================================================
# IceWarp Detection
# ============================================================
detect_icewarp_path() {
    log "Detecting IceWarp path..."
    local candidates=(
        "/opt/icewarp"
        "/usr/local/icewarp"
        "/home/icewarp"
        "/var/icewarp"
    )
    for path in "${candidates[@]}"; do
        if [[ -f "$path/tool.sh" && -x "$path/tool.sh" ]]; then
            IW_ROOT="$path"
            log "Found IceWarp at: $IW_ROOT"
            return 0
        fi
    done
    local found
    found=$(find / -maxdepth 4 -name "tool.sh" -type f -executable 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then
        IW_ROOT=$(dirname "$found")
        log "Found IceWarp via find: $IW_ROOT"
        return 0
    fi
    log "IceWarp NOT found"
    return 1
}

get_icewarp_version() {
    log "Getting IceWarp version..."
    if [[ -n "$IW_ROOT" && -f "$IW_ROOT/tool.sh" ]]; then
        IW_VERSION=$("$IW_ROOT/tool.sh" get system C_Version 2>/dev/null | head -1 | tr -d '[:space:]')
        [[ -z "$IW_VERSION" ]] && IW_VERSION="Unknown"
    else
        IW_VERSION="Not detected"
    fi
    log "IceWarp version: $IW_VERSION"
}

get_os_info() {
    log "Getting OS info..."
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_NAME="$NAME"
        OS_VERSION="$VERSION_ID"
    elif command -v lsb_release &>/dev/null; then
        OS_NAME=$(lsb_release -si)
        OS_VERSION=$(lsb_release -sr)
    else
        OS_NAME="Linux"
        OS_VERSION="Unknown"
    fi
    log "OS: $OS_NAME $OS_VERSION"
}

# ============================================================
# Background Queue Monitor
# ============================================================
start_queue_monitor() {
    (
        while true; do
            sleep 2
            QUEUE_STATUS="Idle"
            QUEUE_COUNT=0
            if [[ -n "$IW_ROOT" && -f "$IW_ROOT/tool.sh" && -x "$IW_ROOT/tool.sh" ]]; then
                QUEUE_COUNT=$("$IW_ROOT/tool.sh" get queue C_QueueCount 2>/dev/null | head -1 | tr -d '[:space:]' || echo 0)
                if [[ "$QUEUE_COUNT" =~ ^[0-9]+$ ]] && (( QUEUE_COUNT > 0 )); then
                    QUEUE_STATUS="Active ($QUEUE_COUNT messages)"
                fi
            fi
            # Trigger redraw by sending WINCH to self
            kill -WINCH $$ 2>/dev/null || true
        done
    ) &
    QUEUE_MONITOR_PID=$!
    log "Queue monitor started (PID: $QUEUE_MONITOR_PID)"
}

# ============================================================
# Output Panel Management
# ============================================================
add_output_line() {
    local line="$1"
    OUTPUT_LINES+=("$line")
    # Auto-scroll to bottom if we were at bottom
    local max_scroll=$(( ${#OUTPUT_LINES[@]} - OUTPUT_PANEL_H + 2 ))
    if (( OUTPUT_SCROLL >= max_scroll - 1 )) || (( OUTPUT_SCROLL < 0 )); then
        OUTPUT_SCROLL=$(( ${#OUTPUT_LINES[@]} - OUTPUT_PANEL_H + 2 ))
        if (( OUTPUT_SCROLL < 0 )); then OUTPUT_SCROLL=0; fi
    fi
}

clear_output() {
    OUTPUT_LINES=()
    OUTPUT_SCROLL=0
}

# ============================================================
# Double-Buffered Frame Renderer
# ============================================================
render_frame() {
    get_term_size
    FRAME_BUFFER=""

    # Minimum size check
    if (( TERM_WIDTH < 70 || TERM_HEIGHT < 20 )); then
        render_minimum_size_warning
        printf '%s' "$FRAME_BUFFER"
        return
    end

    # Layout calculations
    local header_h=3
    local footer_h=2
    local menu_w=36
    local menu_top=$((header_h + 1))
    local menu_h=$((TERM_HEIGHT - header_h - footer_h))
    local output_left=$((menu_w + 1))
    local output_w=$((TERM_WIDTH - menu_w))
    OUTPUT_PANEL_H=$((menu_h - 2))

    # ===== BACKGROUND FILL =====
    local bg_line
    repeat_str " " "$TERM_WIDTH" bg_line
    local row=1
    while (( row <= TERM_HEIGHT )); do
        FRAME_BUFFER+="${BG_MAIN}${bg_line}${C_RESET}"
        ((row++))
    done

    # ===== HEADER BAR =====
    local header_title=" IceWarp Health Agent v${AGENT_VERSION} "
    local header_mode="[ Interactive ]"
    local header_info="OS: ${OS_NAME} ${OS_VERSION} | IceWarp: ${IW_VERSION} | Path: ${IW_ROOT}"
    local queue_info="Queue: ${QUEUE_STATUS}"

    # Header background
    repeat_str "${BOX_H}" "$TERM_WIDTH" header_bg
    FRAME_BUFFER+="${BG_PANEL}${FG_BORDER}${header_bg}${C_RESET}"

    # Title (left)
    cursor_to 1 2
    FRAME_BUFFER+="${BG_PANEL}${FG_ORANGE}${C_BOLD}${header_title}${C_RESET}"

    # Mode badge (right)
    local mode_len=${#header_mode}
    cursor_to 1 $((TERM_WIDTH - mode_len - 1))
    FRAME_BUFFER+="${BG_PANEL}${FG_PURPLE}${C_BOLD}${header_mode}${C_RESET}"

    # Info line
    cursor_to 2 2
    local info_truncated
    fit_text "$header_info" $((TERM_WIDTH - 4)) info_truncated
    FRAME_BUFFER+="${BG_PANEL}${FG_LIGHT1}${info_truncated}${C_RESET}"

    # Queue status line
    cursor_to 3 2
    local queue_truncated
    fit_text "$queue_info" $((TERM_WIDTH - 4)) queue_truncated
    FRAME_BUFFER+="${BG_PANEL}${FG_AQUA}${queue_truncated}${C_RESET}"

    # ===== MENU PANE (Left) =====
    local menu_border_color="${FG_YELLOW}"
    local menu_title=" Navigation "
    if (( FOCUS_PANE != 0 )); then
        menu_border_color="${FG_BORDER}"
    fi

    # Top border
    local top_border
    repeat_str "${BOX_H}" $((menu_w - 2)) top_border
    cursor_to "$menu_top" 1
    FRAME_BUFFER+="${BG_MAIN}${menu_border_color}${BOX_TL}${top_border}${BOX_TR}${C_RESET}"

    # Title in top border
    cursor_to "$menu_top" 3
    FRAME_BUFFER+="${BG_MAIN}${menu_border_color}${BOX_L}${C_RESET}${menu_border_color}${C_BOLD}${menu_title}${C_RESET}${BG_MAIN}${menu_border_color}${BOX_R}${C_RESET}"

    # Menu items
    local item_count=${#MENU_ITEMS[@]}
    local view_h=$((menu_h - 2))
    local offset=0
    if (( MENU_SELECTED >= offset + view_h )); then
        offset=$((MENU_SELECTED - view_h + 1))
    fi

    local i idx
    for (( i = 0; i < view_h; i++ )); do
        idx=$((offset + i))
        local row_num=$((menu_top + 1 + i))
        cursor_to "$row_num" 1

        # Left border
        FRAME_BUFFER+="${BG_MAIN}${menu_border_color}${BOX_V}${C_RESET}"

        # Content
        if (( idx < item_count )); then
            local item_text="[${MENU_KEYS[idx]}] ${MENU_ITEMS[idx]}"
            local content_w=$((menu_w - 4))
            local formatted
            fit_text "$item_text" "$content_w" formatted

            if (( idx == MENU_SELECTED )); then
                FRAME_BUFFER+="${BG_SELECT}${FG_ORANGE}${C_BOLD}▶ ${FG_LIGHT0}${formatted}${C_RESET}"
            else
                FRAME_BUFFER+="${BG_MAIN}${FG_LIGHT1}  ${formatted}${C_RESET}"
            fi
        else
            local empty_str
            repeat_str " " $((menu_w - 4)) empty_str
            FRAME_BUFFER+="${BG_MAIN}  ${empty_str}${C_RESET}"
        fi

        # Right border
        cursor_to "$row_num" "$menu_w"
        FRAME_BUFFER+="${BG_MAIN}${menu_border_color}${BOX_V}${C_RESET}"
    done

    # Bottom border
    local bottom_border
    repeat_str "${BOX_H}" $((menu_w - 2)) bottom_border
    cursor_to $((menu_top + menu_h - 1)) 1
    FRAME_BUFFER+="${BG_MAIN}${menu_border_color}${BOX_BL}${bottom_border}${BOX_BR}${C_RESET}"

    # ===== OUTPUT PANE (Right) =====
    local output_border_color="${FG_BORDER}"
    local output_title=" Output "
    if (( FOCUS_PANE == 1 )); then
        output_border_color="${FG_YELLOW}"
    fi

    # Top border
    local out_top_border
    repeat_str "${BOX_H}" $((output_w - 2)) out_top_border
    cursor_to "$menu_top" "$output_left"
    FRAME_BUFFER+="${BG_MAIN}${output_border_color}${BOX_TL}${out_top_border}${BOX_TR}${C_RESET}"

    # Title in top border
    cursor_to "$menu_top" $((output_left + 2))
    FRAME_BUFFER+="${BG_MAIN}${output_border_color}${BOX_L}${C_RESET}${output_border_color}${C_BOLD}${output_title}${C_RESET}${BG_MAIN}${output_border_color}${BOX_R}${C_RESET}"

    # Output content
    local out_content_top=$((menu_top + 1))
    local out_content_h=$((menu_h - 2))
    local out_content_left=$((output_left + 1))
    local out_content_w=$((output_w - 2))

    local line_idx=0
    for (( i = 0; i < out_content_h; i++ )); do
        idx=$((OUTPUT_SCROLL + i))
        row_num=$((out_content_top + i))
        cursor_to "$row_num" "$out_content_left"

        if (( idx < ${#OUTPUT_LINES[@]} )); then
            local formatted
            fit_text "${OUTPUT_LINES[idx]}" "$out_content_w" formatted
            FRAME_BUFFER+="${BG_MAIN}${FG_LIGHT1}${formatted}${C_RESET}"
        else
            local empty_str
            repeat_str " " "$out_content_w" empty_str
            FRAME_BUFFER+="${BG_MAIN}${empty_str}${C_RESET}"
        fi
    done

    # Bottom border
    local out_bottom_border
    repeat_str "${BOX_H}" $((output_w - 2)) out_bottom_border
    cursor_to $((menu_top + menu_h - 1)) "$output_left"
    FRAME_BUFFER+="${BG_MAIN}${output_border_color}${BOX_BL}${out_bottom_border}${BOX_BR}${C_RESET}"

    # ===== FOOTER BAR =====
    local footer_y=$((TERM_HEIGHT - 1))
    cursor_to "$footer_y" 1

    # Status message (left)
    local status_msg="Ready"
    if (( FOCUS_PANE == 0 )); then
        status_msg="Navigate with [j/k] or [↑/↓] | [Tab] Focus Output | [Enter] Select | [q] Quit"
    else
        status_msg="[↑/↓] Scroll Output | [Tab] Focus Menu | [q] Quit"
    fi
    local status_truncated
    fit_text "$status_msg" $((TERM_WIDTH - 40)) status_truncated
    FRAME_BUFFER+="${BG_PANEL}${FG_GRAY}${status_truncated}${C_RESET}"

    # Keybind pills (right)
    local pills=""
    if (( FOCUS_PANE == 0 )); then
        pills="[j/k] Nav  [Tab] Focus  [Enter] Run  [q] Quit"
    else
        pills="[↑/↓] Scroll  [Tab] Focus  [q] Quit"
    fi
    local pills_len=${#pills}
    cursor_to "$footer_y" $((TERM_WIDTH - pills_len))
    FRAME_BUFFER+="${BG_PANEL}${FG_ORANGE}${C_BOLD}${pills}${C_RESET}"

    # ===== FLUSH FRAME =====
    printf '%s' "$FRAME_BUFFER"
}

render_minimum_size_warning() {
    cursor_to $((TERM_HEIGHT / 2)) 2
    local msg="Terminal too small: ${TERM_WIDTH}x${TERM_HEIGHT} (minimum 70x20)"
    FRAME_BUFFER+="${BG_HARD}${FG_RED}${C_BOLD} ${msg} ${C_RESET}"
}

# ============================================================
# Spinner
# ============================================================
start_spinner() {
    log "Spinner: $1"
    add_output_line "${FG_BLUE}${SPINNER_FRAMES[0]}${C_RESET} $1"
    (
        while true; do
            SPINNER_IDX=$(( (SPINNER_IDX + 1) % 10 ))
            sleep 0.1
            # Update last line with spinner
            kill -WINCH $$ 2>/dev/null || true
        done
    ) &
    SPINNER_PID=$!
}

stop_spinner() {
    if [[ -n "$SPINNER_PID" ]]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
    fi
    # Clear spinner from last output line
    if (( ${#OUTPUT_LINES[@]} > 0 )); then
        OUTPUT_LINES[-1]="${OUTPUT_LINES[-1]//${FG_BLUE}${SPINNER_FRAMES[*]}${C_RESET} /}"
    fi
}

# ============================================================
# Command Execution
# ============================================================
execute_in_area() {
    local cmd=$1
    log "Executing: $cmd"
    FOCUS_PANE=1
    clear_output
    add_output_line "${CYAN}Executing: ${cmd}${C_RESET}"
    add_output_line "$(repeat_str "─" 50)"

    local exit_code_file
    exit_code_file=$(mktemp)
    local line_count=0

    (
        cd "$TMP_DIR"
        set +e
        eval "$cmd" 2>&1
        echo $? > "$exit_code_file"
    ) | while IFS= read -r line; do
        # Truncate to output panel width
        local max_w=$((TERM_WIDTH - 40))
        if (( ${#line} > max_w )); then
            line="${line:0:$((max_w - 3))}..."
        fi
        add_output_line "$line"
        kill -WINCH $$ 2>/dev/null || true
    done

    local exit_code=0
    if [[ -f "$exit_code_file" ]]; then
        exit_code=$(cat "$exit_code_file" 2>/dev/null || echo 0)
        rm -f "$exit_code_file"
    fi

    log "Command exited: $exit_code"

    add_output_line ""
    if (( exit_code == 0 )); then
        add_output_line "${FG_GREEN}[OK] Command completed successfully (exit 0)${C_RESET}"
    else
        add_output_line "${FG_RED}[FAIL] Command failed (exit ${exit_code})${C_RESET}"
    fi
    add_output_line "${FG_ORANGE}[Press Enter to return to menu]${C_RESET}"

    # Wait for Enter
    read -r </dev/tty || true
    FOCUS_PANE=0
}

# ============================================================
# Main TUI Loop
# ============================================================
run_tui() {
    log "Starting TUI loop..."
    hide_cursor
    enter_alt_screen
    get_term_size
    render_frame
    start_queue_monitor

    while true; do
        # Read single key non-blocking with timeout for animations
        local key
        IFS= read -rsn1 -t 0.1 key </dev/tty || key=""

        if [[ -n "$key" ]]; then
            # Handle escape sequences (arrow keys)
            if [[ "$key" == $'\e' ]]; then
                read -rsn2 -t 0.01 key </dev/tty || key=""
                key="\e${key}"
            fi

            case "$key" in
                q|Q)
                    SCRIPT_EXITING=1
                    log "User chose Quit"
                    break
                    ;;
                a|A)
                    if (( FOCUS_PANE == 0 )); then
                        MENU_SELECTED=0
                        execute_in_area "./agent.sh --report"
                    fi
                    ;;
                b|B)
                    if (( FOCUS_PANE == 0 )); then
                        MENU_SELECTED=1
                        execute_in_area "./agent.sh --config"
                    fi
                    ;;
                c|C)
                    if (( FOCUS_PANE == 0 )); then
                        MENU_SELECTED=2
                        execute_in_area "./agent.sh --config --apply"
                    fi
                    ;;
                $'\t')  # Tab
                    FOCUS_PANE=$((1 - FOCUS_PANE))
                    OUTPUT_SCROLL=0
                    ;;
                j|$'\e[B')  # Down / j
                    if (( FOCUS_PANE == 0 )); then
                        (( MENU_SELECTED < ${#MENU_ITEMS[@]} - 1 )) && ((MENU_SELECTED++))
                    else
                        local max_scroll=$(( ${#OUTPUT_LINES[@]} - OUTPUT_PANEL_H + 2 ))
                        (( OUTPUT_SCROLL < max_scroll )) && ((OUTPUT_SCROLL++))
                        (( OUTPUT_SCROLL < 0 )) && OUTPUT_SCROLL=0
                    fi
                    ;;
                k|$'\e[A')  # Up / k
                    if (( FOCUS_PANE == 0 )); then
                        (( MENU_SELECTED > 0 )) && ((MENU_SELECTED--))
                    else
                        (( OUTPUT_SCROLL > 0 )) && ((OUTPUT_SCROLL--))
                    fi
                    ;;
                "")  # Timeout - just redraw for spinner animation
                    ;;
            esac
        fi

        render_frame
    done

    show_cursor
    exit_alt_screen
    printf '%s' "$C_RESET"
}

# ============================================================
# Download Phase (Before TUI)
# ============================================================
download_and_extract() {
    clear_screen
    printf "\n"
    printf "${FG_BORDER}╔══════════════════════════════════════════════════════════╗${C_RESET}\n"
    printf "${FG_BORDER}║${C_RESET}  ${FG_ORANGE}${C_BOLD}IceWarp Health Agent Bootstrap${C_RESET}  ${FG_BORDER}║${C_RESET}\n"
    printf "${FG_BORDER}╚══════════════════════════════════════════════════════════╝${C_RESET}\n"
    printf "\n"

    start_spinner "Downloading package from ${BASE_URL}..."

    local package_url="${BASE_URL}/linux-agent.tar.gz"
    log "Downloading: $package_url"
    if ! curl -sSL -f -u "${AUTH_USER}:${AUTH_PASS}" "$package_url" -o "$TMP_DIR/linux-agent.tar.gz"; then
        stop_spinner
        log "ERROR: Download failed"
        printf "${FG_RED}Failed to download package from %s${C_RESET}\n" "$package_url"
        printf "${FG_YELLOW}(Check credentials or network connectivity)${C_RESET}\n"
        exit 1
    fi

    stop_spinner
    log "Download complete"
    add_output_line "${FG_GREEN}✓ Download complete${C_RESET}"

    start_spinner "Extracting package..."
    if ! tar -xzf "$TMP_DIR/linux-agent.tar.gz" -C "$TMP_DIR"; then
        stop_spinner
        log "ERROR: Extraction failed"
        printf "${FG_RED}Failed to extract package${C_RESET}\n"
        exit 1
    fi

    stop_spinner
    log "Extraction complete"
    add_output_line "${FG_GREEN}✓ Extraction complete${C_RESET}"

    chmod +x "$TMP_DIR/agent.sh"
    log "agent.sh executable"
    add_output_line "${FG_GREEN}✓ Agent ready${C_RESET}"
    add_output_line ""
}

# ============================================================
# Main Entry Point
# ============================================================
main() {
    START_DIR="$(pwd)"
    setup_logging

    log "=== MAIN STARTED ==="
    log "Start dir: $START_DIR"

    get_os_info
    detect_icewarp_path
    get_icewarp_version

    TMP_DIR="$(mktemp -d -t icewarp-health-agent.XXXXXX)"
    log "Temp dir: $TMP_DIR"

    download_and_extract

    copy_output() {
        if [[ -d "$TMP_DIR/output" ]]; then
            mkdir -p "$START_DIR/output"
            cp -r "$TMP_DIR/output/." "$START_DIR/output/"
            printf "\n${FG_GREEN}Reports saved to: %s/output/${C_RESET}\n" "$START_DIR"
            log "Output copied to $START_DIR/output/"
        fi
    }

    run_tui

    copy_output

    SCRIPT_EXITING=1
    log "=== MAIN COMPLETED ==="
}

main "$@"