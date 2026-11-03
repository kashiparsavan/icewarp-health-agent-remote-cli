#!/bin/bash
# ============================================================
# IceWarp Health Agent - Bootstrap Script (Gruvbox TUI)
# ============================================================
# curl -sSL https://parsavan.com/support/iceautochecker/linux-agent/bootstrap.sh | bash
#
# Responsive, Gruvbox-themed Terminal User Interface.
# Pure Bash, no external dependencies. ASCII only.
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

# ============================================================
# Gruvbox Color Palette (256-color ANSI)
# ============================================================
readonly RESET='\e[0m'
readonly BOLD='\e[1m'
readonly DIM='\e[2m'

# Gruvbox colors
readonly BORDER='\e[38;5;245m'   # Gray (borders)
readonly TITLE='\e[1;38;5;214m'  # Yellow/Orange bold (titles)
readonly TEXT='\e[38;5;223m'     # Light foreground (body text)
readonly SUCCESS='\e[38;5;142m'  # Green (success)
readonly ALERT='\e[38;5;167m'    # Red (errors/alerts)
readonly MENU_NUM='\e[38;5;109m' # Blue (menu numbers)
readonly MENU_TEXT='\e[38;5;223m'# Light foreground (menu items)
readonly CYAN='\e[38;5;108m'     # Cyan (info)
readonly YELLOW='\e[38;5;214m'   # Yellow (warnings)

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
# Terminal & Cursor Utilities
# ============================================================
get_term_size() {
    TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
    TERM_HEIGHT=$(tput lines 2>/dev/null || echo 24)
    log "Terminal size: ${TERM_WIDTH}x${TERM_HEIGHT}"
}

hide_cursor() { printf '\e[?25l'; }
show_cursor() { printf '\e[?25h'; }
clear_screen() { printf '\e[2J\e[H'; }
cursor_to() { printf '\e[%d;%dH' "$1" "$2"; }
clear_eol() { printf '\e[K'; }
clear_line() { cursor_to "$1" 1; clear_eol; }

# ============================================================
# Dynamic Box Drawing
# ============================================================
draw_box() {
    # Usage: draw_box <top> <left> <height> <width> <title>
    local top=$1 left=$2 height=$3 width=$4 title=${5:-}
    local bottom=$((top + height - 1))
    local right=$((left + width - 1))
    local inner_width=$((width - 2))

    # Top border
    cursor_to "$top" "$left"
    printf "${BORDER}┌"
    printf "%${inner_width}s" '' | tr ' ' '─'
    printf "┐${RESET}"

    # Side borders
    local row=$((top + 1))
    while (( row < bottom )); do
        cursor_to "$row" "$left"
        printf "${BORDER}│${RESET}"
        cursor_to "$row" "$right"
        printf "${BORDER}│${RESET}"
        ((row++))
    done

    # Bottom border
    cursor_to "$bottom" "$left"
    printf "${BORDER}└"
    printf "%${inner_width}s" '' | tr ' ' '─'
    printf "┘${RESET}"

    # Title
    if [[ -n "$title" ]]; then
        local title_len=${#title}
        local title_start=$((left + 2))
        cursor_to "$top" "$title_start"
        printf "${BORDER}┤${RESET}${TITLE}%s${RESET}${BORDER}├${RESET}" "$title"
    fi
}

write_at() {
    # Usage: write_at <row> <col> <color> <text>
    local row=$1 col=$2 color=$3 text=$4
    cursor_to "$row" "$col"
    printf "${color}%s${RESET}" "$text"
}

# ============================================================
# Spinner
# ============================================================
spinner() {
    local spin_chars='-\|/'
    local i=0
    while true; do
        printf "\r${CYAN}[%s]${RESET} %s" "${spin_chars:i++%${#spin_chars}:1}" "$1"
        sleep 0.1
    done
}

start_spinner() {
    log "Spinner: $1"
    spinner "$1" &
    SPINNER_PID=$!
}

stop_spinner() {
    if [[ -n "$SPINNER_PID" ]]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
    fi
    printf '\r\033[K'
}

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
# Live Queue Monitor (Background)
# ============================================================
start_queue_monitor() {
    local monitor_row=6
    local monitor_col=4
    local max_width=$((TERM_WIDTH - 6))

    (
        while true; do
            sleep 2
            # Try to get queue status from tool.sh if available
            local queue_status="Idle"
            local queue_count=0
            if [[ -n "$IW_ROOT" && -f "$IW_ROOT/tool.sh" && -x "$IW_ROOT/tool.sh" ]]; then
                # Quick check - don't block long
                queue_count=$("$IW_ROOT/tool.sh" get queue C_QueueCount 2>/dev/null | head -1 | tr -d '[:space:]' || echo 0)
                if [[ "$queue_count" =~ ^[0-9]+$ ]] && (( queue_count > 0 )); then
                    queue_status="Active ($queue_count messages)"
                fi
            fi
            cursor_to "$monitor_row" "$monitor_col"
            clear_eol
            printf "${TEXT}Replication Queue: ${CYAN}%s${RESET}" "$queue_status"
        done
    ) &
    QUEUE_MONITOR_PID=$!
    log "Queue monitor started (PID: $QUEUE_MONITOR_PID)"
}

stop_queue_monitor() {
    if [[ -n "$QUEUE_MONITOR_PID" ]]; then
        kill "$QUEUE_MONITOR_PID" 2>/dev/null || true
        wait "$QUEUE_MONITOR_PID" 2>/dev/null || true
        QUEUE_MONITOR_PID=""
        log "Queue monitor stopped"
    fi
}

# ============================================================
# Cleanup Handler
# ============================================================
cleanup() {
    log "Cleanup triggered (SCRIPT_EXITING=$SCRIPT_EXITING)"
    stop_spinner
    stop_queue_monitor
    show_cursor
    if [[ -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
        log "Removed temp dir: $TMP_DIR"
    fi
    # Never clear screen - preserve final message
    if (( SCRIPT_EXITING == 0 )); then
        log "Non-clean exit: resetting colors only"
        printf '\e[0m'
    else
        log "Clean exit: preserving terminal"
    fi
    # IMPORTANT: Never touch $START_DIR/output/
}
trap cleanup EXIT INT TERM

# ============================================================
# UI Rendering
# ============================================================
render_header() {
    log "Rendering header..."
    local box_top=1
    local box_left=2
    local box_height=5
    local box_width=$((TERM_WIDTH - 3))

    draw_box "$box_top" "$box_left" "$box_height" "$box_width" " ICEWARP HEALTH AGENT v${AGENT_VERSION} "

    # System info inside header
    write_at 3 4 "${TEXT}" "OS: ${CYAN}${OS_NAME} ${OS_VERSION}${RESET}${TEXT}  |  IceWarp: ${CYAN}${IW_VERSION}${RESET}${TEXT}  |  Path: ${YELLOW}${IW_ROOT}${RESET}"
}

render_menu() {
    log "Rendering menu..."
    local menu_top=8
    local menu_left=2
    local menu_items=(
        "Run Full Assessment"
        "Check Configuration"
        "Apply Configuration"
        "Exit"
    )
    local menu_height=$(( ${#menu_items[@]} + 4 ))
    local menu_width=38

    draw_box "$menu_top" "$menu_left" "$menu_height" "$menu_width" " MAIN MENU "

    local row=$((menu_top + 2))
    for i in "${!menu_items[@]}"; do
        local num=$((i + 1))
        write_at "$row" $((menu_left + 2)) "${MENU_NUM}" "[$num] "
        write_at "$row" $((menu_left + 6)) "${MENU_TEXT}" "${menu_items[i]}"
        ((row++))
    done
}

render_output_box() {
    log "Rendering output box..."
    local exec_top=8
    local exec_left=42
    local exec_width=$((TERM_WIDTH - exec_left - 1))
    local exec_height=$((TERM_HEIGHT - exec_top - 3))

    if (( exec_width < 20 )); then
        exec_left=2
        exec_width=$((TERM_WIDTH - 3))
    fi
    if (( exec_height < 5 )); then
        exec_height=5
    fi

    draw_box "$exec_top" "$exec_left" "$exec_height" "$exec_width" " OUTPUT / STATUS "

    # Initial message
    write_at $((exec_top + 2)) $((exec_left + 2)) "${SUCCESS}" "Ready. Select an option from the menu."
    write_at $((exec_top + 4)) $((exec_left + 2)) "${DIM}${TEXT}" "Output will appear here when a command runs."

    # Store globals for execute_in_area
    EXEC_TOP=$exec_top
    EXEC_LEFT=$exec_left
    EXEC_WIDTH=$exec_width
    EXEC_HEIGHT=$exec_height
}

render_initial_ui() {
    clear_screen
    get_term_size
    render_header
    render_menu
    render_output_box
    # Queue monitor line
    write_at 6 4 "${TEXT}" "Replication Queue: ${CYAN}Checking...${RESET}"
}

# ============================================================
# Command Execution
# ============================================================
execute_in_area() {
    local cmd=$1
    log "Executing: $cmd"

    local exec_top=$((EXEC_TOP + 1))
    local exec_left=$((EXEC_LEFT + 1))
    local exec_width=$((EXEC_WIDTH - 2))
    local exec_height=$((EXEC_HEIGHT - 3))

    if (( exec_width < 10 )); then exec_width=10; fi
    if (( exec_height < 3 )); then exec_height=3; fi

    # Clear output area
    local row=$((exec_top))
    while (( row < exec_top + exec_height )); do
        cursor_to "$row" "$exec_left"
        printf "%${exec_width}s" ''
        ((row++))
    done

    cursor_to "$exec_top" "$exec_left"
    printf "${CYAN}Executing: %s${RESET}\n" "$cmd"
    printf "${DIM}%s${RESET}\n" "$(printf '%*s' "$exec_width" '' | tr ' ' '─')"

    local exit_code_file
    exit_code_file=$(mktemp)
    local line_count=0

    (
        cd "$TMP_DIR"
        set +e
        eval "$cmd" 2>&1
        echo $? > "$exit_code_file"
    ) | while IFS= read -r line; do
        if (( line_count >= exec_height - 2 )); then
            cursor_to "$exec_top" "$exec_left"
            printf '\e[1S'
            cursor_to $((exec_top + exec_height - 3)) "$exec_left"
        else
            cursor_to $((exec_top + 2 + line_count)) "$exec_left"
        fi
        # Truncate long lines
        if (( ${#line} > exec_width )); then
            line="${line:0:$((exec_width - 3))}..."
        fi
        printf '%s\n' "$line"
        ((line_count++))
    done

    local exit_code=0
    if [[ -f "$exit_code_file" ]]; then
        exit_code=$(cat "$exit_code_file" 2>/dev/null || echo 0)
        rm -f "$exit_code_file"
    fi

    log "Command exited: $exit_code"

    cursor_to $((exec_top + 2 + line_count)) "$exec_left"
    if (( exit_code == 0 )); then
        printf "${SUCCESS}[OK] Command completed successfully (exit 0)${RESET}"
    else
        printf "${ALERT}[FAIL] Command failed (exit %d)${RESET}" "$exit_code"
    fi

    cursor_to $((exec_top + 3 + line_count)) "$exec_left"
    printf "${YELLOW}[Press ENTER to return]${RESET}"
    read -r </dev/tty || true
}

# ============================================================
# Main TUI Loop
# ============================================================
run_tui() {
    log "Starting TUI loop..."
    hide_cursor
    render_initial_ui
    start_queue_monitor

    while true; do
        # Prompt at bottom of menu area
        local prompt_row=$((TERM_HEIGHT - 2))
        cursor_to "$prompt_row" 2
        clear_eol
        printf "${MENU_NUM}Select option [1-4]: ${RESET}"

        local choice
        read -r choice </dev/tty || choice=""
        log "User selected: '$choice'"

        case "$choice" in
            1)
                execute_in_area "./agent.sh --report"
                ;;
            2)
                execute_in_area "./agent.sh --config"
                ;;
            3)
                execute_in_area "./agent.sh --config --apply"
                ;;
            4)
                cursor_to "$((TERM_HEIGHT))" 1
                clear_eol
                printf "${SUCCESS}Thank you for using IceWarp Health Agent. Goodbye!${RESET}\n"
                sleep 1
                SCRIPT_EXITING=1
                log "User chose Exit - clean shutdown"
                break
                ;;
            *)
                cursor_to "$prompt_row" 2
                clear_eol
                printf "${ALERT}Invalid option. Enter 1-4.${RESET}"
                sleep 1
                ;;
        esac

        # Redraw static UI
        render_header
        render_menu
        render_output_box
    done

    show_cursor
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

    # Download phase
    clear_screen
    printf "\n"
    printf "${BORDER}╔══════════════════════════════════════════════════════════╗${RESET}\n"
    printf "${BORDER}║${RESET}  ${TITLE}IceWarp Health Agent Bootstrap${RESET}  ${BORDER}║${RESET}\n"
    printf "${BORDER}╚══════════════════════════════════════════════════════════╝${RESET}\n"
    printf "\n"

    start_spinner "Downloading package from ${BASE_URL}..."

    local package_url="${BASE_URL}/linux-agent.tar.gz"
    log "Downloading: $package_url"
    if ! curl -sSL -f -u "${AUTH_USER}:${AUTH_PASS}" "$package_url" -o "$TMP_DIR/linux-agent.tar.gz"; then
        stop_spinner
        log "ERROR: Download failed"
        printf "${ALERT}Failed to download package from %s${RESET}\n" "$package_url"
        printf "${YELLOW}(Check credentials or network connectivity)${RESET}\n"
        exit 1
    fi

    stop_spinner
    log "Download complete"

    start_spinner "Extracting package..."
    if ! tar -xzf "$TMP_DIR/linux-agent.tar.gz" -C "$TMP_DIR"; then
        stop_spinner
        log "ERROR: Extraction failed"
        printf "${ALERT}Failed to extract package${RESET}\n"
        exit 1
    fi

    stop_spinner
    log "Extraction complete"

    chmod +x "$TMP_DIR/agent.sh"
    log "agent.sh executable"

    copy_output() {
        if [[ -d "$TMP_DIR/output" ]]; then
            mkdir -p "$START_DIR/output"
            cp -r "$TMP_DIR/output/." "$START_DIR/output/"
            printf "\n${SUCCESS}Reports saved to: %s/output/${RESET}\n" "$START_DIR"
            log "Output copied to $START_DIR/output/"
        fi
    }

    run_tui

    copy_output

    SCRIPT_EXITING=1
    log "=== MAIN COMPLETED ==="
}

main "$@"