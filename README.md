# IceWarp Health Agent (Remote CLI)

The Linux agent is a dependency-free, Bash-based health checking and reporting
tool for IceWarp mail servers. It runs locally on the mail server, collects data
via `tool.sh`, OS commands, and DNS lookups, evaluates the results against a
defined checklist, and generates three output files.

**As of v0.8.0, the agent is fully stateless, self-contained, and independent of git.**
It has no auto-update mechanism, no persistent state, and no run locks. It runs
its collectors, generates outputs in the `output/` folder, and exits cleanly.

## Output Files

The Linux agent generates these files:

| File | Purpose |
|------|---------|
| `output/health.json` | Raw structured data (type-aware JSON) for monitoring systems |
| `output/report.pdf` | Full technical report with all checklist items, values, and notes |
| `output/management_report.pdf` | Non-technical executive summary with scorecards and prioritized actions |

## Quick Start (Hosted Deployment)

### Option 1: Direct curl + execute (stateless, no git required)

```bash
# On the IceWarp mail server, download and run directly:
curl -fsSL https://raw.githubusercontent.com/kashiparsavan/icewarp-health-agent-remote-cli/main/agent.sh -o agent.sh
chmod +x agent.sh
./agent.sh --report --technician="Your Name" --company="Your Company"
```

Outputs will be in `./output/`:
- `output/health.json` — for monitoring ingestion
- `output/report.pdf` — full technical report
- `output/management_report.pdf` — executive summary

### Option 2: One-liner (no local file saved)

```bash
curl -fsSL https://raw.githubusercontent.com/kashiparsavan/icewarp-health-agent-remote-cli/main/agent.sh | bash -s -- --report --technician="Your Name" --company="Your Company"
```

### Option 3: With custom config

```bash
# Download once, configure, then run
curl -fsSL https://raw.githubusercontent.com/kashiparsavan/icewarp-health-agent-remote-cli/main/agent.sh -o agent.sh
curl -fsSL https://raw.githubusercontent.com/kashiparsavan/icewarp-health-agent-remote-cli/main/config/agent.conf -o config/agent.conf
curl -fsSL https://raw.githubusercontent.com/kashiparsavan/icewarp-health-agent-remote-cli/main/config/icewarp.conf -o config/icewarp.conf

# Edit config/icewarp.conf with your IceWarp paths and SSL cert
# Edit config/agent.conf with your MONITOR_URL if using transport

chmod +x agent.sh
./agent.sh --report --technician="Your Name" --company="Your Company"
```

### Command-Line Options

| Option | Description |
|--------|-------------|
| `./agent.sh` | Full run: collect, evaluate, JSON, PDF |
| `./agent.sh --report` | Same, and print summary to stdout |
| `./agent.sh --list` | List all available collectors |
| `--only=<filter>` | Run only collectors containing `<filter>` (comma-separated) |
| `--technician="Name"` | Override technician name in reports (default: `Parsavan`) |
| `--company="Name"` | Override company name in reports (default: the domain that carries mail) |
| `--config` / `--config --apply` | Preview or apply recommended IceWarp settings |
| `--help` | Show help message |

**Current Linux version: 0.8.0**

When `--company` is omitted, the agent uses `domain.primary.name`, then
`MAIL_DOMAIN`, then the first domain returned by `tool.sh`, then the configured
mail hostname. When `--technician` is omitted, it uses `Parsavan`. Both defaults
are overridden by the command-line flags.

## Architecture

```
icewarp-health-agent-remote-cli/
├── agent.sh                    # Entry point (stateless, no auto-update)
├── VERSION                     # Agent version (0.8.0)
├── config/
│   ├── agent.conf              # General settings (timeouts, monitor URL)
│   ├── icewarp.conf            # IceWarp-specific paths, SSL, DNS, hostname
│   ├── recommended.conf        # Configurator desired state
│   └── checklist.conf.pdf      # Checklist definition (source of truth)
├── lib/
│   ├── common.sh               # Shared utilities (collector_set, iw_get, etc.)
│   ├── health.sh               # Health evaluation rules
│   ├── pdf.sh                  # Full technical PDF generator
│   ├── management_report.sh    # Executive summary PDF generator
│   ├── json.sh                 # JSON exporter
│   ├── json_v2.sh              # health.v2.json envelope builder
│   ├── transport.sh            # HTTP transport (disabled by default)
│   └── configurator.sh         # --config dry-run and --apply
├── collectors/                 # Data collectors organized by category (81 total)
├── maintenance/                # Development tools (collector_tester, validity_checker)
├── docs/                       # Documentation (checklist-map, update-log, schema)
├── output/                     # Generated reports (created at runtime)
└── logs/                       # Runtime logs (created at runtime)
```

### Key Design Principles

- **Stateless execution:** No persistent state, no run locks, no auto-update
- **Collector isolation:** Failures recorded but don't abort the run
- **Health independence:** `lib/health.sh` reads `DATA[]` only; never calls `tool.sh`
- **Type-aware JSON:** Empty → `null`, numeric → unquoted, `true`/`false` → unquoted booleans

## Dependencies

The Linux agent has no runtime, package manager, database, or web server. It is
pure Bash plus standard Unix tools:

`curl`, `dig`, `openssl`, `awk`, `date`, `find`, `grep`, `sed`, `firewall-cmd`.

**No `git` required.** The agent runs entirely from the downloaded files.

## Checklist

Reports reference IceWarp CheckList **v1.14** (the internal edition label
configured by `CHECKLIST_VERSION`). The item set is the v1.12-mapped
113-item checklist; the v1.14 label changes the report metadata, not the
collector coverage. See `docs/checklist-map.md` for item-by-item mapping between
checklist entries and collectors.

## Configuration

Default settings work out of the box. Optional customization:

`config/agent.conf`: General settings (timeouts, monitor URL), the report
`CHECKLIST_VERSION` label.

`config/icewarp.conf`: IceWarp-specific paths.

`MAIL_HOSTNAME` and `MAIL_PUBLIC_IP` are required for DNS collectors
(PTR, SPF, DKIM, DMARC).

`IW_SSL_CERT` is the path to the SSL certificate.

## Reports

**Technical PDF (`report.pdf`):** All checklist items with values and notes. The
cover carries the v1.14 checklist label and the nine-pillar Health Summary;
the appendix groups raw keys by subsystem into readable tables. Pages carry
report name and page numbers.

**Management PDF (`management_report.pdf`):** Modern management summary with a
score arc, executive overview, control-area scorecards, stacked status bars,
and prioritized recommended actions. It evaluates the full checklist but does
not print every item.

Both PDFs are generated natively in Bash. No wkhtmltopdf, no pdflatex, no
additional dependencies.

## Remote Execution

```bash
# From a monitoring server:
ssh root@icewarp-server "curl -fsSL https://raw.githubusercontent.com/kashiparsavan/icewarp-health-agent-remote-cli/main/agent.sh | bash -s -- --report"
scp root@icewarp-server:~/output/*.pdf .
```

## Documentation

- `docs/checklist-map.md`: Mapping between checklist items and collectors.
- `docs/update-log.md`: Human-readable activity ledger.
- `docs/schema/health.v2.schema.json`: JSON Schema for health.v2.json.
- `CLAUDE.md`: Guidance for AI agents and maintainers working in the repository.
- `CHANGELOG.md`: Linux version history.

## License

See the LICENSE file.