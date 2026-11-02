#!/bin/bash
# ============================================================
# IceWarp Health Agent - Entry Point
# ============================================================
# Stateless, self-contained health checker for IceWarp mail servers.
# Runs collectors, generates outputs in output/, exits cleanly.
# No git, no auto-update, no persistent state.
# ============================================================

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_ROOT

CONFIG_DIR="${PROJECT_ROOT}/config"
LIB_DIR="${PROJECT_ROOT}/lib"
COLLECTOR_DIR="${PROJECT_ROOT}/collectors"
OUTPUT_DIR="${PROJECT_ROOT}/output"
LOG_DIR="${PROJECT_ROOT}/logs"

mkdir -p "$OUTPUT_DIR"
mkdir -p "$LOG_DIR"

# ---------- Source config files ----------
for CFG in "$CONFIG_DIR"/*.conf; do
    [ -f "$CFG" ] || continue
    case "$(basename "$CFG")" in
        agent.conf|icewarp.conf) source "$CFG" ;;
    esac
done

# ---------- Read Version from VERSION file ----------
if [ -f "${PROJECT_ROOT}/VERSION" ]; then
    AGENT_VERSION="$(cat "${PROJECT_ROOT}/VERSION" | tr -d '[:space:]')"
else
    AGENT_VERSION="unknown"
fi

# ---------- Help Function ----------
show_help() {
    echo "IceWarp Health Agent v${AGENT_VERSION}"
    echo ""
    echo "Usage: ./agent.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --report                Run collectors and print summary to console"
    echo "  --list                  List all available collectors"
    echo "  --config                Run configurator (dry-run, no changes applied)"
    echo "  --config --apply        Apply recommended settings to IceWarp"
    echo "  --only=<filter>         Run only collectors matching the filter (comma-separated)"
    echo "  --technician=\"Name\"     Override technician name in reports"
    echo "  --company=\"Name\"        Override company name in reports"
    echo "  --help                  Show this help message"
    echo ""
    exit 0
}

# ---------- Parse arguments ----------
MODE="run"
ARG_TECHNICIAN=""
ARG_COMPANY=""
COLLECTOR_FILTER=""

for ARG in "$@"; do
    case "$ARG" in
        --help) show_help ;;
        --config) MODE="--config" ;;
        --list) MODE="--list" ;;
        --report) MODE="--report" ;;
        --only=*) COLLECTOR_FILTER="${ARG#--only=}" ;;
        --company=*) ARG_COMPANY="${ARG#--company=}" ;;
        --technician=*) ARG_TECHNICIAN="${ARG#--technician=}" ;;
    esac
done

# ---------- Source libraries ----------
[ -f "$LIB_DIR/common.sh" ] && source "$LIB_DIR/common.sh"
[ -f "$LIB_DIR/health.sh" ] && source "$LIB_DIR/health.sh"
[ -f "$LIB_DIR/pdf.sh" ] && source "$LIB_DIR/pdf.sh"
[ -f "$LIB_DIR/json.sh" ] && source "$LIB_DIR/json.sh"
[ -f "$LIB_DIR/json_v2.sh" ] && source "$LIB_DIR/json_v2.sh"
[ -f "$LIB_DIR/management_report.sh" ] && source "$LIB_DIR/management_report.sh"
[ -f "$LIB_DIR/transport.sh" ] && source "$LIB_DIR/transport.sh"
[ -f "$LIB_DIR/configurator.sh" ] && source "$LIB_DIR/configurator.sh"

if [ "$MODE" = "--list" ]; then
    list_collectors
    exit 0
fi

if [ "$MODE" = "--config" ]; then
    configurator_parse_args "$@"
    configurator_run
    exit 0
fi

# ---------- Initialize ----------
agent_init
AGENT_RUN_START_MS="$(date +%s%3N)"

if [ -n "$ARG_TECHNICIAN" ]; then
    DATA["general.technician"]="$ARG_TECHNICIAN"
else
    DATA["general.technician"]="Parsavan"
fi

# ---------- Run all collectors ----------
echo "[INFO] Running all collectors..."

while IFS= read -r COLLECTOR; do
    if [ -n "$COLLECTOR_FILTER" ]; then
        MATCH=0
        IFS=',' read -ra FILTERS <<< "$COLLECTOR_FILTER"
        for F in "${FILTERS[@]}"; do
            [[ "$COLLECTOR" == *"$F"* ]] && MATCH=1
        done
        [ "$MATCH" -eq 0 ] && continue
    fi

    echo "[RUN ] ${COLLECTOR#$PROJECT_ROOT/}"
    run_collector "$COLLECTOR"
done < <(find "$COLLECTOR_DIR" -type f -name "*.sh" | sort)

# ---------- Post-processing ----------
if [ -n "$ARG_COMPANY" ]; then
    DATA["general.company"]="$ARG_COMPANY"
elif [ -z "${DATA[general.company]:-}" ]; then
    DOMAIN_FALLBACK="$(resolve_mail_domain)"
    DATA["general.company"]="${DOMAIN_FALLBACK:-${DATA[agent.hostname]:-Unknown Host}}"
fi

# Keep one stable key for the domain that carries mail. Some collectors set it
# late; the fallback makes reports and JSON consistent even on partial runs.
if [ -z "${DATA[domain.primary.name]:-}" ]; then
    DOMAIN_FALLBACK="$(resolve_mail_domain)"
    [ -n "$DOMAIN_FALLBACK" ] && DATA["domain.primary.name"]="$DOMAIN_FALLBACK"
fi

echo "[INFO] Evaluating health..."
evaluate_health

echo "[INFO] Building JSON..."
build_json

echo "[INFO] Building JSON v2..."
if declare -F build_json_v2 >/dev/null; then
    build_json_v2 || echo "[WARN] health.v2.json could not be written" >&2
fi

echo "[INFO] Sending JSON to monitoring server (if enabled)..."
if send_json; then
    echo "[INFO] Transport: health.json posted successfully"
else
    TRANSPORT_RC=$?
    echo "[WARN] Transport: send_json failed (exit ${TRANSPORT_RC}) - see logs for details"
fi

echo "[INFO] Building PDF..."
build_pdf

echo "[INFO] Building management report..."
build_management_pdf

if [ "$MODE" = "--report" ]; then
    print_report
fi

echo "[INFO] Agent finished successfully."
exit 0
