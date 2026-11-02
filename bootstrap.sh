#!/bin/bash
# ============================================================
# IceWarp Health Agent - Bootstrap Script
# ============================================================
# This script is designed to be run via curl | bash:
#   curl -sSL https://parsavan.com/support/iceautochecker/linux-agent/bootstrap.sh | bash
#
# It downloads the agent package, extracts to a temp directory,
# runs the health check, copies results to the current directory,
# and cleans up all temporary files.
# ============================================================

set -euo pipefail

# Base URL where the package is hosted
BASE_URL="https://parsavan.com/support/iceautochecker/linux-agent"

# Store the user's starting directory BEFORE any cd operations
START_DIR="$(pwd)"

# Create a temporary directory for the run
TMP_DIR="$(mktemp -d -t icewarp-health-agent.XXXXXX)"

# Spinner PID (for cleanup)
SPINNER_PID=""

# Spinner function - shows animation while background work runs
spinner() {
    local spin_chars='|/-\'
    local i=0
    while true; do
        printf "\r[INFO] Preparing... %c" "${spin_chars:i++%${#spin_chars}:1}"
        sleep 0.1
    done
}

# Ensure cleanup on exit (success or failure)
cleanup() {
    # Stop spinner if running
    if [ -n "$SPINNER_PID" ]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
    fi
    # Clear spinner line
    printf "\r\033[K"
    # Remove temp directory
    if [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT INT TERM

echo "[INFO] IceWarp Health Agent Bootstrap"
echo "[INFO] Temporary directory: $TMP_DIR"

# Download the package
PACKAGE_URL="${BASE_URL}/linux-agent.tar.gz"
echo "[INFO] Downloading package from $PACKAGE_URL..."

# Start spinner before background download/extract
spinner &
SPINNER_PID=$!

# Download with progress hidden
if ! curl -sSL -f "$PACKAGE_URL" -o "$TMP_DIR/linux-agent.tar.gz"; then
    # Stop spinner on error
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    printf "\r\033[K"
    echo "[ERROR] Failed to download package from $PACKAGE_URL" >&2
    exit 1
fi

# Extract the package
if ! tar -xzf "$TMP_DIR/linux-agent.tar.gz" -C "$TMP_DIR"; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    printf "\r\033[K"
    echo "[ERROR] Failed to extract package" >&2
    exit 1
fi

# Stop spinner after successful preparation
kill "$SPINNER_PID" 2>/dev/null || true
wait "$SPINNER_PID" 2>/dev/null || true
printf "\r\033[K"
echo "[INFO] Preparation complete. Running checks..."

# Navigate into the extracted directory
cd "$TMP_DIR"

# Make agent.sh executable
chmod +x agent.sh

echo "[INFO] Running IceWarp Health Agent..."
echo "[INFO] This may take a moment..."

# Run the agent with --report flag
if ./agent.sh --report; then
    echo "[INFO] Agent completed successfully."
else
    RC=$?
    echo "[ERROR] Agent exited with code $RC" >&2
    exit $RC
fi

# Copy output directory back to the user's starting directory
if [ -d "$TMP_DIR/output" ]; then
    echo "[INFO] Copying output to $START_DIR/output..."
    cp -r "$TMP_DIR/output" "$START_DIR/output"
    echo "[INFO] Reports available in $START_DIR/output/"
else
    echo "[WARN] No output directory found" >&2
fi

echo "[INFO] Done. Temporary files will be cleaned up automatically."
exit 0