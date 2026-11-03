#!/bin/bash
# ============================================================
# IceWarp Health Agent - Bootstrap Script (Advanced TUI)
# ============================================================
# curl -sSL https://parsavan.com/support/iceautochecker/linux-agent/bootstrap.sh | bash
#
# Advanced Terminal User Interface with fixed layout, colors,
# and live execution area. Pure Bash, no external dependencies.
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

# Layout constants
readonly HEADER_TOP=1
readonly HEADER_BOTTOM=5
readonly MENU_TOP=7
readonly MENU_LEFT=2
readonly EXEC_TOP=7
readonly EXEC_LEFT=42
readonly PROMPT_ROW=20

# ============================================================
# Color & Style Definitions
# ============================================================
readonly RESET='\e[0m'
readonly BOLD='\e[1m'
readonly DIM='\e[2m'

readonly FG_BLACK='\e[30m'
readonly FG_RED='\e[31m'
readonly FG_GREEN='\e[32m'
readonly FG_YELLOW='\e[33m'
readonly FG_BLUE='\e[34m'
readonly FG_MAGENTA='\e[35m'
readonly FG_CYAN='\e[36m'
readonly FG_WHITE='\e[37m'
readonly FG_BRIGHT_RED='\e[91m'
readonly FG_BRIGHT_GREEN='\e[92m'
readonly FG_BRIGHT_YELLOW='\e[93m'
readonly FG_BRIGHT_BLUE='\e[94m'
readonly FG_BRIGHT_MAGENTA='\e[95m'
readonly FG_BRIGHT_CYAN='\e[96m'
readonly FG_BRIGHT_WHITE='\e[97m'

readonly BG_BLACK='\e[40m'
readonly BG_RED='\e[41m'
readonly BG_GREEN='\e[42m'
readonly BG_YELLOW='\e[43m'
readonly BG_BLUE='\e[44m'
readonly BG_MAGENTA='\e[45m'
readonly BG_CYAN='\e[46m'
readonly BG_WHITE='\e[47m'

# ============================================================
# Utility Functions
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
save_cursor() { printf '\e7'; }
restore_cursor() { printf '\e8'; }
clear_eol() { printf '\e[K'; }
clear_eos() { printf '\e[J'; }

draw_hline() {
    local row=$1 col=$2 len=$3 char=${4:-'─'}
    cursor_to "$row" "$col"
    printf '%*s' "$len" '' | tr ' ' "$char"
}

draw_vline() {
    local row=$1 col=$2 len=$3 char=${4:-'│'}
    for ((i=0; i<len; i++)); do
        cursor_to $((row+i)) "$col"
        printf '%s' "$char"
    done
}

draw_box() {
    local top=$1 left=$2 height=$3 width=$4 color=$5 title=${6:-}
    local bottom=$((top + height - 1))
    local right=$((left + width - 1))

    cursor_to "$top" "$left";     printf '%s┌%s' "$color" "$RESET"
    cursor_to "$top" "$right";    printf '%s┐%s' "$color" "$RESET"
    cursor_to "$bottom" "$left";  printf '%s└%s' "$color" "$RESET"
    cursor_to "$bottom" "$right"; printf '%s┘%s' "$color" "$RESET"

    draw_hline "$top" $((left+1)) $((width-2)) '─'
    draw_hline "$bottom" $((left+1)) $((width-2)) '─'
    draw_vline $((top+1)) "$left" $((height-2)) '│'
    draw_vline $((top+1)) "$right" $((height-2)) '│'

    if [[ -n "$title" ]]; then
        cursor_to "$top" $((left + 2))
        printf '%s%s%s' "$color" "$title" "$RESET"
    fi
}

write_at() {
    local row=$1 col=$2 color=$3 text=$4
    cursor_to "$row" "$col"
    printf '%s%s%s' "$color" "$text" "$RESET"
}

# ============================================================
# Spinner (for download phase)
# ============================================================
spinner() {
    local spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while true; do
        printf "\r${FG_CYAN}[%s]${RESET} %s" "${spin_chars:i++%${#spin_chars}:1}" "$1"
        sleep 0.08
    done
}

start_spinner() {
    log "Starting spinner: $1"
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
# Cleanup Handler - NO screen clear on normal exit
# ============================================================
cleanup() {
    log "Cleanup triggered (SCRIPT_EXITING=$SCRIPT_EXITING)"
    stop_spinner
    show_cursor
    if [[ -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
        log "Removed temp dir: $TMP_DIR"
    fi
    # Only reset terminal on crash/interrupt (SCRIPT_EXITING=0)
    # On normal exit (SCRIPT_EXITING=1), leave final message visible
    if (( SCRIPT_EXITING == 0 )); then
        log "Non-clean exit: resetting terminal"
        printf '\e[0m'
    else
        log "Clean exit: preserving terminal state"
    fi
    # IMPORTANT: Never touch $START_DIR/output/ - logs and reports persist there
}
trap cleanup EXIT INT TERM

# ============================================================
# IceWarp Path Detection
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
# TUI Rendering Functions
# ============================================================

render_header() {
    log "Rendering header..."
    local box_color="${FG_CYAN}"
    local title_color="${BOLD}${FG_MAGENTA}"
    local info_color="${FG_BRIGHT_CYAN}"

    draw_box "$HEADER_TOP" 2 5 $((TERM_WIDTH - 3)) "$box_color"
    write_at 2 $(( (TERM_WIDTH - 28) / 2 )) "$title_color" "IceWarp Health Agent v$AGENT_VERSION"
    write_at 3 4 "$info_color" "OS: ${FG_BRIGHT_WHITE}${OS_NAME} ${OS_VERSION}${RESET}${info_color}  |  IceWarp: ${FG_BRIGHT_WHITE}${IW_VERSION}${RESET}${info_color}"
    write_at 4 4 "$info_color" "Path: ${FG_BRIGHT_YELLOW}${IW_ROOT}${RESET}"
}

render_menu() {
    log "Rendering menu..."
    local box_color="${FG_BLUE}"
    local menu_items=(
        "Run Full Assessment"
        "Check Configuration (Dry-Run)"
        "Apply Configuration"
        "Exit"
    )
    local menu_height=$(( ${#menu_items[@]} + 4 ))
    local menu_width=38

    draw_box "$MENU_TOP" "$MENU_LEFT" "$menu_height" "$menu_width" "$box_color" " MENU "

    local row=$((MENU_TOP + 2))
    for i in "${!menu_items[@]}"; do
        local num=$((i + 1))
        local prefix="${FG_BRIGHT_YELLOW}[$num]${RESET} "
        local text="${FG_BRIGHT_WHITE}${menu_items[i]}${RESET}"
        write_at "$row" $((MENU_LEFT + 2)) "" "$prefix$text"
        ((row++))
    done
}

render_execution_area() {
    log "Rendering execution area..."
    local box_color="${FG_CYAN}"
    local exec_width=$((TERM_WIDTH - EXEC_LEFT - 1))
    local exec_height=$((TERM_HEIGHT - EXEC_TOP - 2))

    draw_box "$EXEC_TOP" "$EXEC_LEFT" "$exec_height" "$exec_width" "$box_color" " OUTPUT / STATUS "
    write_at $((EXEC_TOP + 2)) $((EXEC_LEFT + 2)) "${FG_BRIGHT_GREEN}" "Ready. Select an option from the menu."
    write_at $((EXEC_TOP + 4)) $((EXEC_LEFT + 2)) "${DIM}${FG_WHITE}" "Output will appear here when a command runs."
}

render_prompt() {
    cursor_to "$PROMPT_ROW" 2
    clear_eol
    printf '${FG_BRIGHT_YELLOW}Select an option [1-4]: ${RESET}'
}

clear_execution_area() {
    local exec_width=$((TERM_WIDTH - EXEC_LEFT - 1))
    local exec_height=$((TERM_HEIGHT - EXEC_TOP - 2))
    for ((row = EXEC_TOP + 1; row < EXEC_TOP + exec_height; row++)); do
        cursor_to "$row" $((EXEC_LEFT + 1))
        printf '%*s' $((exec_width - 1)) ''
    done
}

# ============================================================
# Command Execution - Safe wrapper
# ============================================================
execute_in_area() {
    local cmd=$1
    log "Executing command: $cmd"
    local exec_top=$((EXEC_TOP + 1))
    local exec_left=$((EXEC_LEFT + 1))
    local exec_width=$((TERM_WIDTH - EXEC_LEFT - 2))
    local exec_height=$((TERM_HEIGHT - EXEC_TOP - 3))

    clear_execution_area

    cursor_to "$exec_top" "$exec_left"
    printf '${FG_BRIGHT_CYAN}Executing: %s${RESET}\n' "$cmd"
    printf '${DIM}───────────────────────────────────────${RESET}\n'

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
        printf '%s\n' "$line"
        ((line_count++))
    done

    local exit_code=0
    if [[ -f "$exit_code_file" ]]; then
        exit_code=$(cat "$exit_code_file" 2>/dev/null || echo 0)
        rm -f "$exit_code_file"
    fi

    log "Command exited with code: $exit_code"

    cursor_to $((exec_top + 2 + line_count)) "$exec_left"
    if (( exit_code == 0 )); then
        printf '${FG_BRIGHT_GREEN}✓ Command completed successfully (exit 0)${RESET}'
    else
        printf '${FG_BRIGHT_RED}✗ Command failed (exit %d)${RESET}' "$exit_code"
    fi

    cursor_to $((exec_top + 3 + line_count)) "$exec_left"
    printf '${FG_BRIGHT_YELLOW}[ENTER] to return to dashboard...${RESET}'
    read -r </dev/tty || true
}

# ============================================================
# Main TUI Loop
# ============================================================
run_tui() {
    log "Starting TUI loop..."
    hide_cursor
    clear_screen
    get_term_size

    render_header
    render_menu
    render_execution_area

    while true; do
        render_prompt
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
                printf '${FG_BRIGHT_GREEN}Thank you for using IceWarp Health Agent. Goodbye!${RESET}\n'
                sleep 1
                SCRIPT_EXITING=1
                log "User chose Exit - clean shutdown"
                break
                ;;
            *)
                cursor_to "$PROMPT_ROW" 2
                printf '${FG_BRIGHT_RED}Invalid option. Please enter 1-4.${RESET}'
                sleep 1
                render_prompt
                ;;
        esac

        render_header
        render_menu
        render_execution_area
    done

    show_cursor
}

# ============================================================
# Logging Setup - Called from main() after START_DIR is known
# ============================================================
setup_logging() {
    local log_file="$START_DIR/output/bootstrap_debug.log"
    mkdir -p "$START_DIR/output"

    # Close any existing fd 3
    exec 3>&- 2>/dev/null || true

    # Open log file on fd 3
    exec 3>"$log_file"

    # Redirect stderr to both log file and console
    exec 2> >(tee -a "$log_file" >&2)

    log "=== Bootstrap script started ==="
    log "BASH_VERSION=$BASH_VERSION"
    log "TERM=$TERM"
    log "PWD=$(pwd)"
    log "UID=$UID"
    log "Log file: $log_file"
}

log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $*" | tee -a "$START_DIR/output/bootstrap_debug.log"
}

# ============================================================
# Main Entry Point
# ============================================================
main() {
    START_DIR="$(pwd)"

    # Set up logging FIRST - after START_DIR is known
    setup_logging

    log "Start directory: $START_DIR"

    get_os_info
    detect_icewarp_path
    get_icewarp_version

    TMP_DIR="$(mktemp -d -t icewarp-health-agent.XXXXXX)"
    log "Temp directory: $TMP_DIR"

    clear_screen
    printf '\n'
    printf '${FG_CYAN}╔══════════════════════════════════════════════════════════╗${RESET}\n'
    printf '${FG_CYAN}║${RESET}  ${BOLD}${FG_MAGENTA}IceWarp Health Agent Bootstrap${RESET}  ${FG_CYAN}║${RESET}\n'
    printf '${FG_CYAN}╚══════════════════════════════════════════════════════════╝${RESET}\n'
    printf '\n'

    start_spinner "Downloading package from ${BASE_URL}..."

    local package_url="${BASE_URL}/linux-agent.tar.gz"
    log "Downloading from: $package_url"
    if ! curl -sSL -f -u "${AUTH_USER}:${AUTH_PASS}" "$package_url" -o "$TMP_DIR/linux-agent.tar.gz"; then
        stop_spinner
        log "ERROR: Failed to download package"
        printf '${FG_BRIGHT_RED}✗ Failed to download package from %s${RESET}\n' "$package_url"
        printf '${FG_YELLOW}  (Check credentials or network connectivity)${RESET}\n'
        exit 1
    fi

    stop_spinner
    log "Download complete"

    start_spinner "Extracting package..."
    if ! tar -xzf "$TMP_DIR/linux-agent.tar.gz" -C "$TMP_DIR"; then
        stop_spinner
        log "ERROR: Failed to extract package"
        printf '${FG_BRIGHT_RED}✗ Failed to extract package${RESET}\n'
        exit 1
    fi

    stop_spinner
    log "Extraction complete"

    chmod +x "$TMP_DIR/agent.sh"
    log "agent.sh made executable"

    copy_output() {
        if [[ -d "$TMP_DIR/output" ]]; then
            mkdir -p "$START_DIR/output"
            cp -r "$TMP_DIR/output/." "$START_DIR/output/"
            printf '\n${FG_BRIGHT_GREEN}Reports saved to: %s/output/${RESET}\n' "$START_DIR"
            log "Output copied to $START_DIR/output/"
        fi
    }

    run_tui

    copy_output

    SCRIPT_EXITING=1
    log "=== MAIN FUNCTION COMPLETED ==="
}

main "$@"