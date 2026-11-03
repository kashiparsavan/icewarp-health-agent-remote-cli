#!/bin/bash
# ============================================================
# IceWarp Health Agent - Bootstrap Script (Advanced TUI)
# ============================================================
# curl -sSL https://parsavan.com/support/iceautochecker/linux-agent/bootstrap.sh | bash
#
# Advanced Terminal User Interface with fixed layout, colors,
# and live execution area. Pure Bash, no external dependencies.
# ============================================================

set -euo pipefail

# ============================================================
# Color & Style Definitions
# ============================================================
readonly RESET='\e[0m'
readonly BOLD='\e[1m'
readonly DIM='\e[2m'

# Foreground colors
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

# Background colors
readonly BG_BLACK='\e[40m'
readonly BG_RED='\e[41m'
readonly BG_GREEN='\e[42m'
readonly BG_YELLOW='\e[43m'
readonly BG_BLUE='\e[44m'
readonly BG_MAGENTA='\e[45m'
readonly BG_CYAN='\e[46m'
readonly BG_WHITE='\e[47m'

# ============================================================
# Configuration
# ============================================================
readonly BASE_URL="https://parsavan.com/support/iceautochecker/linux-agent"
readonly AGENT_VERSION="0.8.0"

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

# Layout constants
readonly HEADER_TOP=1
readonly HEADER_BOTTOM=5
readonly MENU_TOP=7
readonly MENU_LEFT=2
readonly EXEC_TOP=7
readonly EXEC_LEFT=42
readonly PROMPT_ROW=20

# ============================================================
# Utility Functions
# ============================================================

# Get terminal dimensions
get_term_size() {
    TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
    TERM_HEIGHT=$(tput lines 2>/dev/null || echo 24)
}

# Hide cursor
hide_cursor() { printf '\e[?25l'; }

# Show cursor
show_cursor() { printf '\e[?25h'; }

# Clear screen and home cursor
clear_screen() { printf '\e[2J\e[H'; }

# Move cursor to row, col (1-indexed)
cursor_to() { printf '\e[%d;%dH' "$1" "$2"; }

# Save cursor position
save_cursor() { printf '\e7'; }

# Restore cursor position
restore_cursor() { printf '\e8'; }

# Clear from cursor to end of line
clear_eol() { printf '\e[K'; }

# Clear from cursor to end of screen
clear_eos() { printf '\e[J'; }

# Draw a horizontal line
draw_hline() {
    local row=$1 col=$2 len=$3 char=${4:-'─'}
    cursor_to "$row" "$col"
    printf '%*s' "$len" '' | tr ' ' "$char"
}

# Draw a vertical line
draw_vline() {
    local row=$1 col=$2 len=$3 char=${4:-'│'}
    for ((i=0; i<len; i++)); do
        cursor_to $((row+i)) "$col"
        printf '%s' "$char"
    done
}

# Draw a box
draw_box() {
    local top=$1 left=$2 height=$3 width=$4 color=$5 title=${6:-}
    local bottom=$((top + height - 1))
    local right=$((left + width - 1))

    # Corners
    cursor_to "$top" "$left";     printf '%s┌%s' "$color" "$RESET"
    cursor_to "$top" "$right";    printf '%s┐%s' "$color" "$RESET"
    cursor_to "$bottom" "$left";  printf '%s└%s' "$color" "$RESET"
    cursor_to "$bottom" "$right"; printf '%s┘%s' "$color" "$RESET"

    # Top/bottom borders
    draw_hline "$top" $((left+1)) $((width-2)) '─'
    draw_hline "$bottom" $((left+1)) $((width-2)) '─'

    # Side borders
    draw_vline $((top+1)) "$left" $((height-2)) '│'
    draw_vline $((top+1)) "$right" $((height-2)) '│'

    # Title if provided
    if [[ -n "$title" ]]; then
        cursor_to "$top" $((left + 2))
        printf '%s%s%s' "$color" "$title" "$RESET"
    fi
}

# Write text at position with color
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
# Cleanup Handler
# ============================================================
cleanup() {
    stop_spinner
    show_cursor
    if [[ -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
    # Reset terminal
    printf '\e[0m\e[2J\e[H'
}
trap cleanup EXIT INT TERM

# ============================================================
# IceWarp Path Detection
# ============================================================
detect_icewarp_path() {
    local candidates=(
        "/opt/icewarp"
        "/usr/local/icewarp"
        "/home/icewarp"
        "/var/icewarp"
    )

    for path in "${candidates[@]}"; do
        if [[ -f "$path/tool.sh" && -x "$path/tool.sh" ]]; then
            IW_ROOT="$path"
            return 0
        fi
    done

    # Fallback: search for tool.sh
    local found
    found=$(find / -maxdepth 4 -name "tool.sh" -type f -executable 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then
        IW_ROOT=$(dirname "$found")
        return 0
    fi

    return 1
}

get_icewarp_version() {
    if [[ -n "$IW_ROOT" && -f "$IW_ROOT/tool.sh" ]]; then
        IW_VERSION=$("$IW_ROOT/tool.sh" get system C_Version 2>/dev/null | head -1 | tr -d '[:space:]')
        [[ -z "$IW_VERSION" ]] && IW_VERSION="Unknown"
    else
        IW_VERSION="Not detected"
    fi
}

get_os_info() {
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
}

# ============================================================
# TUI Rendering Functions
# ============================================================

render_header() {
    local box_color="${FG_CYAN}"
    local title_color="${BOLD}${FG_MAGENTA}"
    local info_color="${FG_BRIGHT_CYAN}"

    # Draw header box
    draw_box "$HEADER_TOP" 2 5 $((TERM_WIDTH - 3)) "$box_color"

    # Title
    write_at 2 $(( (TERM_WIDTH - 28) / 2 )) "$title_color" "IceWarp Health Agent v$AGENT_VERSION"

    # System info
    write_at 3 4 "$info_color" "OS: ${FG_BRIGHT_WHITE}${OS_NAME} ${OS_VERSION}${RESET}${info_color}  |  IceWarp: ${FG_BRIGHT_WHITE}${IW_VERSION}${RESET}${info_color}"
    write_at 4 4 "$info_color" "Path: ${FG_BRIGHT_YELLOW}${IW_ROOT}${RESET}"
}

render_menu() {
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
    local box_color="${FG_CYAN}"
    local exec_width=$((TERM_WIDTH - EXEC_LEFT - 1))
    local exec_height=$((TERM_HEIGHT - EXEC_TOP - 2))

    draw_box "$EXEC_TOP" "$EXEC_LEFT" "$exec_height" "$exec_width" "$box_color" " OUTPUT / STATUS "

    # Initial message
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
# Command Execution
# ============================================================
execute_in_area() {
    local cmd=$1
    local exec_top=$((EXEC_TOP + 1))
    local exec_left=$((EXEC_LEFT + 1))
    local exec_width=$((TERM_WIDTH - EXEC_LEFT - 2))
    local exec_height=$((TERM_HEIGHT - EXEC_TOP - 3))

    clear_execution_area

    # Move to execution area and run command
    cursor_to "$exec_top" "$exec_left"
    printf '${FG_BRIGHT_CYAN}Executing: %s${RESET}\n' "$cmd"
    printf '${DIM}─────────────────────────��──────────────${RESET}\n'

    # Run the command, capturing output line by line
    local line_count=0
    while IFS= read -r line; do
        if (( line_count >= exec_height - 2 )); then
            # Scroll up if needed
            cursor_to "$exec_top" "$exec_left"
            printf '\e[1S'  # Scroll up one line
            cursor_to $((exec_top + exec_height - 3)) "$exec_left"
        else
            cursor_to $((exec_top + 2 + line_count)) "$exec_left"
        fi
        printf '%s\n' "$line"
        ((line_count++))
    done < <(cd "$TMP_DIR" && eval "$cmd" 2>&1)

    local exit_code=$?
    cursor_to $((exec_top + 2 + line_count)) "$exec_left"
    if (( exit_code == 0 )); then
        printf '${FG_BRIGHT_GREEN}✓ Command completed successfully (exit 0)${RESET}'
    else
        printf '${FG_BRIGHT_RED}✗ Command failed (exit %d)${RESET}' "$exit_code"
    fi

    # Wait for keypress
    cursor_to $((exec_top + 3 + line_count)) "$exec_left"
    printf '${FG_BRIGHT_YELLOW}[ENTER] to return to dashboard...${RESET}'
    read -r </dev/tty
}

# ============================================================
# Main TUI Loop
# ============================================================
run_tui() {
    hide_cursor
    clear_screen
    get_term_size

    # Initial render
    render_header
    render_menu
    render_execution_area

    while true; do
        render_prompt
        local choice
        read -r choice </dev/tty

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
                # Clean exit
                cursor_to "$((TERM_HEIGHT))" 1
                clear_eol
                printf '${FG_BRIGHT_GREEN}Thank you for using IceWarp Health Agent. Goodbye!${RESET}\n'
                sleep 1
                break
                ;;
            *)
                # Invalid input - flash prompt
                cursor_to "$PROMPT_ROW" 2
                printf '${FG_BRIGHT_RED}Invalid option. Please enter 1-4.${RESET}'
                sleep 1
                render_prompt
                ;;
        esac

        # Redraw static parts after command returns
        render_header
        render_menu
        render_execution_area
    done

    show_cursor
}

# ============================================================
# Main Entry Point
# ============================================================
main() {
    # Capture starting directory BEFORE any cd
    START_DIR="$(pwd)"

    # Detect system info early
    get_os_info
    detect_icewarp_path
    get_icewarp_version

    # Create temp directory
    TMP_DIR="$(mktemp -d -t icewarp-health-agent.XXXXXX)"

    # Download phase with spinner
    clear_screen
    printf '\n'
    printf '${FG_CYAN}╔══════════════════════════════════════════════════════════╗${RESET}\n'
    printf '${FG_CYAN}║${RESET}  ${BOLD}${FG_MAGENTA}IceWarp Health Agent Bootstrap${RESET}  ${FG_CYAN}║${RESET}\n'
    printf '${FG_CYAN}╚══════════════════════════════════════════════════════════╝${RESET}\n'
    printf '\n'

    start_spinner "Downloading package from ${BASE_URL}..."

    local package_url="${BASE_URL}/linux-agent.tar.gz"
    if ! curl -sSL -f "$package_url" -o "$TMP_DIR/linux-agent.tar.gz"; then
        stop_spinner
        printf '${FG_BRIGHT_RED}✗ Failed to download package from %s${RESET}\n' "$package_url"
        exit 1
    fi

    stop_spinner
    start_spinner "Extracting package..."

    if ! tar -xzf "$TMP_DIR/linux-agent.tar.gz" -C "$TMP_DIR"; then
        stop_spinner
        printf '${FG_BRIGHT_RED}✗ Failed to extract package${RESET}\n'
        exit 1
    fi

    stop_spinner

    # Make agent executable
    chmod +x "$TMP_DIR/agent.sh"

    # Copy output back function
    copy_output() {
        if [[ -d "$TMP_DIR/output" ]]; then
            mkdir -p "$START_DIR/output"
            cp -r "$TMP_DIR/output/." "$START_DIR/output/"
            printf '\n${FG_BRIGHT_GREEN}Reports saved to: %s/output/${RESET}\n' "$START_DIR"
        fi
    }

    # Run the TUI
    run_tui

    # Copy results on exit
    copy_output
}

main "$@"