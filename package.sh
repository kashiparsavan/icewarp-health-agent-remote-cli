#!/bin/bash
# ============================================================
# IceWarp Health Agent - Packaging Script
# ============================================================
# Creates a tarball (linux-agent.tar.gz) containing ONLY the
# runtime files needed for the stateless agent.
# ============================================================

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_ROOT"

OUTPUT_TARBALL="linux-agent.tar.gz"

echo "[INFO] Creating package: $OUTPUT_TARBALL"

# Remove old tarball if exists
rm -f "$OUTPUT_TARBALL"

# Create tarball with ONLY the minimum required runtime files
# Explicitly exclude any .git* files for safety
tar -czf "$OUTPUT_TARBALL" --exclude='.git*' agent.sh VERSION config/ lib/ collectors/

echo "[INFO] Package created: $OUTPUT_TARBALL"
echo "[INFO] Size: $(du -h "$OUTPUT_TARBALL" | cut -f1)"
echo "[INFO] Contents:"
tar -tzf "$OUTPUT_TARBALL" | head -20
echo "..."
echo "[INFO] Total files: $(tar -tzf "$OUTPUT_TARBALL" | wc -l)"