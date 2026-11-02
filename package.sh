#!/bin/bash
# ============================================================
# IceWarp Health Agent - Packaging Script
# ============================================================
# Creates a tarball (linux-agent.tar.gz) containing all runtime
# files needed for the stateless agent.
# ============================================================

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_ROOT"

OUTPUT_TARBALL="linux-agent.tar.gz"

echo "[INFO] Creating package: $OUTPUT_TARBALL"

# Remove old tarball if exists
rm -f "$OUTPUT_TARBALL"

# Create tarball with all runtime files
tar -czf "$OUTPUT_TARBALL" agent.sh VERSION config/ lib/ collectors/ maintenance/

echo "[INFO] Package created: $OUTPUT_TARBALL"
echo "[INFO] Size: $(du -h "$OUTPUT_TARBALL" | cut -f1)"
echo "[INFO] Contents:"
tar -tzf "$OUTPUT_TARBALL" | head -20
echo "..."
echo "[INFO] Total files: $(tar -tzf "$OUTPUT_TARBALL" | wc -l)"