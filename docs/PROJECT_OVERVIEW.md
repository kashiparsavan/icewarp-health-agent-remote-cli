# IceWarp Health Agent — Project Overview

## Architecture

The IceWarp Health Agent is a **stateless, self-contained Bash script** that performs health checks on IceWarp mail servers running on Linux. It has no external dependencies beyond Bash 4+ and GNU coreutils.

### Core Components

| Component | Description |
|-----------|-------------|
| `agent.sh` | Entry point — orchestrates the entire run |
| `config/` | Configuration files (`agent.conf`, `icewarp.conf`, `recommended.conf`) |
| `lib/` | Shared libraries (common.sh, health.sh, json.sh, json_v2.sh, pdf.sh, management_report.sh, transport.sh, configurator.sh) |
| `collectors/` | 81 collector scripts across 14 categories that gather data from `tool.sh`, OS commands, and DNS |

### Data Flow

```
agent.sh
  ├─ Source config files
  ├─ Source all lib/*.sh
  ├─ Discover collectors/**.sh (alphabetical)
  │   └─ Each collector runs collector_run() → writes to DATA[] associative array
  ├─ evaluate_health() → reads DATA[], writes HEALTH[] and health.* keys
  ├─ build_json() → output/health_YYYY-MM-DD_HH-MM.json (sorted, type-coerced)
  ├─ build_json_v2() → output/health_YYYY-MM-DD_HH-MM.v2.json (envelope format)
  ├─ send_json() → POST to MONITOR_URL (if SEND_DATA=1)
  ├─ build_pdf() → output/report_YYYY-MM-DD_HH-MM.pdf (technical)
  └─ build_management_pdf() → output/management_report_YYYY-MM-DD_HH-MM.pdf (executive)
```

### Output Files

Every run produces **timestamped, unique output files** in `output/`:
- `health_YYYY-MM-DD_HH-MM.json`
- `health_YYYY-MM-DD_HH-MM.v2.json`
- `report_YYYY-MM-DD_HH-MM.pdf`
- `management_report_YYYY-MM-DD_HH-MM.pdf`

## Packaging & Bootstrap Mechanism

### `package.sh` (run by maintainers)
Creates a minimal `linux-agent.tar.gz` containing ONLY:
- `agent.sh`
- `VERSION`
- `config/`
- `lib/`
- `collectors/`

**Excluded:** `package.sh`, `bootstrap.sh`, `README.md`, `CLAUDE.md`, `docs/`, `.git/`, `maintenance/`, `tests/`, `patches/`, `health/`, and all `.md` files.

### `bootstrap.sh` (run by end users via `curl | bash`)
```
curl -sSL https://parsavan.com/support/iceautochecker/linux-agent/bootstrap.sh | bash
```

1. Captures `START_DIR="$(pwd)"` before any `cd`
2. Creates secure temp dir with `mktemp -d`
3. Shows terminal spinner during download/extract
4. Downloads `linux-agent.tar.gz` with `curl -sSL -f`
5. Extracts with `tar -xzf`
6. Runs `./agent.sh --report`
6. Copies results: `cp -r "$TMP_DIR/output/." "$START_DIR/output/"`
7. `trap cleanup EXIT INT TERM` guarantees 100% temp-dir cleanup

### Hosting URL
All files are served from: `https://parsavan.com/support/iceautochecker/linux-agent/`

## Strict Rules

1. **Pure Bash only** — No Python, Node.js, PowerShell, or other interpreters
2. **LF line endings** on all `.sh` files
3. **Minimal repository** — Only core agent, lib, collectors, and config are tracked
4. **Stateless** — No auto-update, no persistent state, no run locks
5. **Timestamped outputs** — Never overwrite previous runs