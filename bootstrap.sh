#!/bin/bash
# ============================================================
# IceWarp Health Agent - Bootstrap Script (headless)
# ============================================================
#   curl -sSL https://parsavan.com/support/iceautochecker/linux-agent/bootstrap.sh | bash
#
# Downloads the package, extracts it to a temp dir, runs ./agent.sh with the
# arguments you passed, copies output/ back to the current directory, and
# deletes every temporary file.
#
# No TUI, no prompts, no cursor tricks: safe under cron, `ssh -T`, CI and
# `| tee`. Progress goes to stderr only; agent.sh output stays on stdout.
# ============================================================

# CRLF guard - only meaningful when run as a file (via `curl | bash`, $0 is "bash").
case "$0" in
    */*) if grep -q $'\r' "$0" 2>/dev/null; then
             printf 'ERROR: CRLF line endings in %s - convert to LF.\n' "$0" >&2
             exit 1
         fi ;;
esac

readonly BASE_URL="https://parsavan.com/support/iceautochecker/linux-agent"
readonly AUTH_USER="parsavan"
readonly AUTH_PASS='P@rsavan.com@123'

START_DIR=""
TMP_DIR=""
STTY_SAVE=""

# All progress -> stderr, one full line per message. Never touches stdout.
say() {
    [ -t 2 ] && printf '\r\033[K'
    printf '%s\n' "$*" >&2
}

cleanup() {
    # Disarm first: nothing may redraw or re-enter while the terminal is restored.
    trap - EXIT INT TERM WINCH

    # Probe the tty by opening it: `-w /dev/tty` passes even when no controlling
    # terminal exists. stderr is silenced BEFORE the open so a failure is quiet.
    if { : </dev/tty; } 2>/dev/null; then
        [ -n "$STTY_SAVE" ] && stty "$STTY_SAVE" 2>/dev/null </dev/tty
        stty sane 2>/dev/null </dev/tty
        # Unconditional and idempotent: also repairs a tty left raw/dark by an older TUI build.
        printf '\033[?25h\033[?7h\033[0m' 2>/dev/null >/dev/tty
    fi

    # Only ever delete a directory we created via mktemp -t icewarp-health-agent.*
    case "$TMP_DIR" in
        */icewarp-health-agent.*) rm -rf -- "$TMP_DIR" ;;
    esac
    return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fetch_package() {
    local pkg="$TMP_DIR/linux-agent.tar.gz"
    say "[1/4] Downloading package..."
    curl -sSL -f -u "${AUTH_USER}:${AUTH_PASS}" \
        "${BASE_URL}/linux-agent.tar.gz" -o "$pkg" </dev/null || {
        say "[FAIL] Download failed - check credentials or network connectivity"
        return 1
    }
    say "[2/4] Extracting package..."
    tar -xzf "$pkg" -C "$TMP_DIR" || { say "[FAIL] Extraction failed"; return 1; }
    rm -f -- "$pkg"
    chmod +x "$TMP_DIR/agent.sh" 2>/dev/null || true
    say "[3/4] Package ready (agent v$(cat "$TMP_DIR/VERSION" 2>/dev/null || echo unknown))"
}

run_agent() {
    local -a args=("$@")
    (( ${#args[@]} )) || args=(--report)     # documented default mode
    say "[4/4] Running ./agent.sh ${args[*]}"
    # </dev/null is mandatory: under `curl | bash` the script itself is stdin, so a
    # child inheriting the pipe would swallow the rest of it or block forever.
    ( cd "$TMP_DIR" && ./agent.sh "${args[@]}" ) </dev/null
}

copy_output() {
    [ -d "$TMP_DIR/output" ] || return 0
    mkdir -p "$START_DIR/output" 2>/dev/null || return 0
    cp -R "$TMP_DIR/output/." "$START_DIR/output/" 2>/dev/null || true
    say "Reports saved to: $START_DIR/output/"
}

main() {
    START_DIR="$(pwd)"
    STTY_SAVE="$(stty -g 2>/dev/null </dev/tty || true)"

    TMP_DIR="$(mktemp -d -t icewarp-health-agent.XXXXXX)" || {
        say "[FAIL] Could not create a temporary directory"
        return 1
    }

    local rc=1
    if fetch_package; then
        run_agent "$@"
        rc=$?
    fi

    copy_output          # copy even on partial/failed runs
    return "$rc"
}

main "$@"
