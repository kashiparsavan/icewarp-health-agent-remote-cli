# CLAUDE.md — IceWarp Health Agent (Linux)

## 1. Project Overview

**IceWarp Health Agent** is a dependency-free, Bash-based health-check and reporting tool for IceWarp mail servers. It runs directly on the mail server, collects data from `tool.sh`, OS commands, and DNS queries, evaluates results against the IceWarp Checklist (v1.14), and produces structured outputs for monitoring and executive reporting.

**As of v0.8.1, the agent is fully stateless, self-contained, and independent of git.** It has no auto-update mechanism, no persistent state, and no run locks. It runs its collectors, generates outputs in the `output/` folder, and exits cleanly.

### Key Characteristics
- **Platform:** Linux (RHEL/Rocky/AlmaLinux, Debian/Ubuntu)
- **Version:** 0.8.1
- **Runtime:** Bash 4+, GNU coreutils only — no package manager, database, or web server
- **Schema:** 411-key flat dotted namespace in `output/health.json`
- **Outputs:**
  - `output/health.json` — type-aware JSON for monitoring systems
  - `output/report.pdf` — full technical report (native PDF generation)
  - `output/management_report.pdf` — non-technical executive summary

### Collector Coverage
- **81 collector scripts** across 14 categories
- Collectors run alphabetically by path; order matters for dependencies
- All values stored in `DATA[]` associative array with flat dotted keys

---

## 2. CODE STYLE

- Always write failing tests BEFORE implementation.
- Use Bash/Pester for tests (depending on platform).
- Test names must describe behavior (e.g., "should_return_warn_when_disk_full").
- For any new feature or bug fix, write the test first, show it fails, then implement the minimal code to pass it.

---

## 3. TDD & Testing Conventions

- Always write failing tests BEFORE implementation.
- Use Bash/Pester for tests (depending on platform).
- Test names must describe behavior (e.g., "should_return_warn_when_disk_full").
- For any new feature or bug fix, write the test first, show it fails, then implement the minimal code to pass it.

---

## 4. Architecture Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ agent.sh (Entry Point)                                                      │
│  ├─ 1. Source config/agent.conf, config/icewarp.conf                        │
│  ├─ 2. Source libraries: common.sh, health.sh, pdf.sh, json.sh,             │
│  │                 management_report.sh, transport.sh, configurator.sh      │
│  ├─ 3. Discover collectors/**.sh (alphabetical) → source + collector_run()  │
│  │     └─ Collectors write: collector_set "<dotted.key>" "<value>" → DATA[] │
│  ├─ 4. evaluate_health() → HEALTH[] + health.<item>.result/.message         │
│  ├─ 5. build_json() → output/health.json (sorted, type-coerced)            │
│  │     build_json_v2() → output/health.v2.json (envelope, schema v2.0)      │
│  ├─ 6. send_json() → POST to $MONITOR_URL (if SEND_DATA=1)                 │
│  ├─ 7. build_pdf() → output/report.pdf                                      │
│  └─ 8. build_management_pdf() → output/management_report.pdf                │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Data Flow
1. **Collection Phase:** 81 collectors gather data into `DATA[]` (flat dotted keys: `os.cpu.load1`, `icewarp.backup.auto_enabled`, `disk.*`, etc.)
2. **Health Evaluation:** `lib/health.sh` reads `DATA[]`, applies rules, writes `HEALTH[]` and `health.*` keys
3. **JSON Export:** `lib/json.sh` type-coerces and sorts all keys → `output/health.json`
4. **PDF Generation:** Native PDF writers (no external tools) produce technical and management reports

### Key Design Principles
- **Stateless execution:** No persistent state, no run locks, no auto-update
- **Collector isolation:** Failures recorded but don't abort the run
- **Health independence:** `health.sh` reads `DATA[]` only; never calls `tool.sh`
- **Type-aware JSON:** Empty → `null`, numeric → unquoted, `true`/`false` → unquoted booleans

### Packaging & Bootstrap Mechanism (v0.8.1+)
- **`package.sh`**: Creates `linux-agent.tar.gz` containing all runtime files (`agent.sh`, `VERSION`, `config/`, `lib/`, `collectors/`, `maintenance/`). Excludes `.git`, `output/`, `docs/`, `tests/`, `*.md`, `windows/`, `graphify-out/`, and the packaging scripts themselves.
- **`bootstrap.sh`**: The `curl | bash` entry point. Downloads the tarball from `BASE_URL`, extracts to a secure temporary directory (`mktemp -d`), runs `./agent.sh --report`, copies `output/` back to the caller's `$PWD`, and uses `trap cleanup EXIT INT TERM` to guarantee 100% cleanup of temporary files on success, failure, or signal.
- **Hosted URL**: `https://parsavan.com/support/iceautochecker/linux-agent/`
- **End-user command**: `curl -sSL https://parsavan.com/support/iceautochecker/linux-agent/bootstrap.sh | bash`

---

## 5. Strict Rules (ABSOLUTE — NEVER BREAK)

### 5.1 Line Endings
- **ALL `.sh` files MUST have LF (Unix) line endings.** Never save with CRLF.

### 5.2 IceWarp Update Protocol (STRICT)

IceWarp is upgraded **within a major branch only**. The branch is the first two
components of the version (`14.2.0.16` → branch `14.2`).

- **Rule 1 — Major version jumps are STRICTLY FORBIDDEN.** You cannot update
  `14.2` directly to `14.3`. Any attempt is refused by the installer menu and by
  a custom-URL check.
- **Rule 2 — Always find and install the highest build of the SAME branch.**
  For an installed `14.2`, the correct target is the newest `14.2.x.y` package
  (e.g. `14.2.0.16`), never a newer branch.
- **Rule 3 — The TUI blinking warning compares the installed version against the
  target version OF THE SAME BRANCH.** `14.2.0.5` vs target `14.2.0.16` blinks;
  `14.2.0.16` (already the branch maximum) does not blink, even when a `14.3`
  package exists. Nothing blinks when IceWarp is not installed.
- **Rule 4 — If IceWarp is not installed, default to the absolute latest version
  across all branches.**

Implementation: `branch_of()` derives the branch, `enumerate_official_versions()`
lists the published packages, `highest_in_branch()` selects the branch maximum,
and `recompute_stale()` decides the header warning. The Pars Avan mirror is gated
by the same rule: a package outside the installed branch is shown as
`Different major branch - not installable` instead of being offered.

### 5.3 Persistent Agent Data (NEVER delete)

`cleanup()` runs on every exit and wipes the working tree. It MUST NOT touch
operator data. The contract for `${AGENT_DIR}` (default `/root/agent`) is:

**Persistent — always preserved**

| Path | Contents |
|------|----------|
| `${AGENT_DIR}/ssl/` | Generated certificates (Let's Encrypt and self-signed) |
| `${AGENT_DIR}/backups/` | IceWarp configuration/data backups |
| `${AGENT_DIR}/*.tar.gz` | Cached installers, reused to avoid re-downloading |
| `${AGENT_DIR}/*.log` | Agent logs |

**Disposable — safe to delete**

| Path | Why |
|------|-----|
| `${AGENT_DIR}/tmp/` | FIFOs, scratch files, extracted VERSION |
| `${AGENT_DIR}/<extracted>/` | Any unpacked installer tree (e.g. `IceWarpServer-14.3/`) |
| `${AGENT_DIR}/*.tmp` | Interrupted atomic downloads |

Rules for future changes:

- The directory sweep is
  `find "${AGENT_DIR}" -mindepth 1 -maxdepth 1 -type d ! -name 'ssl' ! -name 'backups' -exec rm -rf {} +`.
  **Any new feature that persists data under `${AGENT_DIR}` MUST add its
  directory to that exclusion list in the same commit.**
- The file sweep keeps `*.log` and `*.tar.gz`; a new persistent file type needs
  its pattern added there too.
- Never replace the guarded `find` with a blanket `rm -rf "${AGENT_DIR}"/*`
  or an unguarded `-type d -exec rm -rf`.
- Certificate output paths are derived from `ssl_store()`, which resolves to
  `${AGENT_DIR}/ssl` — never hardcode a different location.

### 5.4 Repository Minimalism (NEW — v0.8.1+)
- **This repository must remain minimal.** Do not add tool documentation, Docker files, test fixtures, or development scripts. Only the core agent (`agent.sh`), `VERSION`, `config/`, `lib/`, and `collectors/` are allowed in the repository.
- **Pure Bash only** — Never use Python, Node.js, PowerShell, or any other interpreter in any script.
- The following are explicitly FORBIDDEN:
  - `maintenance/` directory (dev testing only)
  - `patches/` directory (patches belong in git history)
  - `tests/` directory (test fixtures)
  - `health/` directory
  - `docs/tool-search/` (tool.sh output exports)
  - Any `.py`, `.ps1`, `.js`, `.ts`, `.md` files beyond `README.md`, `CLAUDE.md`, `CHANGELOG.md`, and `docs/PROJECT_OVERVIEW.md`
  - `docker-compose.yml`, `tool.*` help files, `tool-search.tar.gz`, `.env.example`
- The tarball `linux-agent.tar.gz` must contain ONLY: `agent.sh`, `VERSION`, `config/`, `lib/`, `collectors/`

### 5.5 Minimal Packages — NEVER install a desktop stack (ABSOLUTE)

These servers are production mail relays, often on slow or filtered mirrors.
A single over-broad `dnf` transaction has already cost a live server 201
packages (101 MB), including `doxygen`, `graphviz`, `flatpak`, `pipewire`,
`xdg-desktop-portal-gtk`, `tracker-miners` and dozens of X/URW fonts, with
`curl (28) Timeout` failures on most of them.

**HARD RULES**

- **NEVER** install `doxygen`, `graphviz`, `flatpak`, `pipewire`, GTK/desktop
  libraries, `xdg-desktop-portal*`, `tracker*`, X11 packages, or any font
  package (`*-fonts`, `abattis-*`, `dejavu-*`, `urw-base35-*`, `xorg-x11-fonts-*`).
  Nothing on this server renders a document or a window.
- **NEVER** use `dnf groupinstall`, `dnf group install`, `@development`,
  `@"Development Tools"`, or any `@`-prefixed group. Groups are the single
  fastest way to pull an entire desktop environment.
- **ALWAYS** pass `--setopt=install_weak_deps=False` to every `dnf install`.
  Without it, dnf follows `Recommends` and drags in documentation and GUI
  libraries that were never requested.
- **ALWAYS** install from the explicit array `SEC_BUILD_PKGS` in `bootstrap.sh`.
  Do not add a package to a `dnf` command line; add it to that array so both
  build steps stay identical.
- The only allowed build packages are these 14:
  `gcc gcc-c++ make cmake flex bison pcre2-devel libxml2-devel yajl-devel
  curl-devel openssl-devel zlib-devel libtool automake`
- Any new required tool must be justified in the commit message and added to
  `SEC_BUILD_PKGS`, never to an ad-hoc command.
- When a disabled/missing package is suspected, prefer `dnf install --downloadonly`
  or `dnf repoquery --requires` to inspect the transaction **before** running it.

If a `dnf` summary shows more than ~30 packages for a build step, stop and
inspect the list — that is the signature of a group, weak deps, or a docs
package sneaking in.

### 3.2 PDF Renderer Sync
- Thresholds live **only** in `lib/health.sh`. `lib/pdf.sh` and `lib/management_report.sh` read the result through
  `health_row_for_label` (see 3.11); changing a rule in `health.sh` updates both PDFs automatically.
- Never add a threshold or a comparison against a number to a PDF renderer. If a checklist row needs a new rule,
  add the check to `health.sh` and the label to `HEALTH_LABEL_MAP`.

### 3.3 Health Status Discipline
- **NO arbitrary INFO statuses:** Missing/invalid settings → `WARN` or `CRITICAL`, never `INFO`
- **NO placeholders:** Never add fake values (e.g., `admin@example.com`) to silence health checks
- If a setting requires human input (Admin Email), health **MUST** remain `CRITICAL` until explicitly set

### 3.4 Health vs. Configurator Sync
- Whenever you change a threshold in `lib/health.sh`, **MUST** update `config/recommended.conf`
- Examples: Intrusion 50/360, Admin Email, IMAP/POP3 settings
- Configurator and Health Engine **MUST** be in perfect sync

### 3.5 Strict Threshold Rules (Hardcoded in health.sh)

| Check | Condition | Result | Message |
|-------|-----------|--------|---------|
| **Intrusion Prevention** | `security.intrusion.block_connections_per_minute.value` ≠ 50 | `warn` | Expected 50 |
| **Intrusion Prevention** | `security.intrusion.block_duration_minutes` ≠ 360 | `warn` | Expected 360 minutes |
| **Intrusion Prevention** | Missing connections setting | `critical` | Setting not found |
| **Intrusion Prevention** | Missing duration setting | `critical` | Setting not found |
| **Admin Email** | `monitor.alert_email` empty/null/N/A | `critical` | Admin email is not set |
| **Admin Email** | Invalid email format | `warn` | Invalid format |
| **DIGEST-MD5** | `security.digest_md5.enabled` = `true` | `critical` | DIGEST-MD5 is ENABLED (weak, legacy) |
| **DIGEST-MD5** | `security.digest_md5.enabled` = `false` | `pass` | DIGEST-MD5 is disabled |
| **DIGEST-MD5** | Missing value | `critical` | Cannot verify status |
| **IMAP Service** | `service.imap.active` = `1` or `true` | `pass` | IMAP is running |
| **IMAP Service** | Disabled | `warn` | IMAP is disabled |
| **POP3 Service** | `service.pop3.active` = `1` or `true` | `pass` | POP3 is running |
| **POP3 Service** | Disabled | `warn` | POP3 is disabled |
| **Database Type** | `database.type` = `mysql` | `pass` | MySQL is active |
| **Database Type** | `database.type` = `sqlite` | `warn` | SQLite in use; MySQL recommended |
| **Database Type** | Unknown/empty | `warn` | Type could not be determined |
| **Intrusion (5 count rules)** | Unknown user / relay denied / RSET / failed logins ≠ 5, spam score ≠ 9.00 | `warn` | Expected value; missing = `critical` |
| **Watchdog (per service)** | SMTP / POP3-IMAP / IM-VoIP / GroupWare disabled | `critical` | Feeds `monitoring` |
| **Directory Cache** | Schedule empty / not scheduled | `critical` | Feeds `database` |
| **TLS certificate** | < 90 days warn, < 30 days or expired fail | `warn` / `fail` | Feeds `tls` |
| **2FA** | Bypass enabled | `warn` | Feeds `access` |

### 3.6 License Fallback (Evaluation Licenses)
If `C_License_TrialExpire` is empty:
1. **ALWAYS** fallback to parsing `license.xml`
2. Try multiple XML tags in order:
   - `TrialExpire`, `TrialExpiration`, `Expire`, `ExpirationDate`, `LicenseExpiration`
   - `TrialDaysRemaining`, `DaysRemaining` (calculate expiration from days remaining)
3. **NEVER** assume missing value means 'perpetual'

### 3.7 Docker Config Paths
- **Container path:** `/opt/icewarp-data/config/` (mounted from host `/opt/icewarp/config`)
- **Bare metal:** `/opt/icewarp/`
- Collectors **MUST** check `/opt/icewarp-data/config/` first when running in Docker
- Example: `license.xml` at `/opt/icewarp-data/config/license.xml` in Docker

### 3.8 JSON Coercion Rules (lib/json.sh)
- **Empty string or literal `null`** → `null`
- **Numeric pattern** (`^-?(0|[1-9][0-9]{0,14})(\.[0-9]{1,6})?$` — no leading zeros) → unquoted number
- **Keys ending `version`, `.ip`, `.domain`, `.hostname`, `.host`** → always string
- **Boolean** (`true` or `false`) → unquoted boolean
- **Everything else** → escaped string
- Keys sorted alphabetically in output

### 3.11 health.v2.json and the check registry
- `build_json_v2` is read-only over `DATA[]`/`HEALTH[]`; `health.json` (v1) may gain `health.<id>.*` keys but must not lose or rename any.
- **One registry** (`HEALTH_REGISTRY_LINES` in `lib/health.sh`, `id|pillar|title|flags`) is the single source for pillar
  membership. Flags: `d` = detail only (not rolled up), `opt` = optional feature, `p` = the check is the pillar itself.
  Pillar roll-ups (`_pillar_rollup`), v2 `checks[]` and `rolled_up` all read it. A new check = one registry line +
  one `_health_set <id> <result> <msg> <expected> <actual> <display>` call. No hand-written pillar lists.
- Every check passes `expected`/`actual` where a threshold exists; `display` is the PDF "Value" column.
- **PDF renderers hold no thresholds.** `lib/pdf.sh` and `lib/management_report.sh` call
  `health_row_for_label "$LABEL" "$NOTE"` (map: `HEALTH_LABEL_MAP`) and render `HR_KIND/HR_VALUE/HR_NOTE`.
  To show a new checklist row from health, add the label to `HEALTH_LABEL_MAP`; never re-implement the rule in a renderer.
- Validate with `docs/schema/health.v2.schema.json` after any change to the envelope.

### 3.10 Dates and Secrets
- **Never pass an IceWarp date string to `date -d`.** Use `norm_date` / `_days_ago` from `lib/common.sh`
  (the only copy; do not redefine). `_days_ago` prints nothing for an unparseable date: callers must
  treat empty as unknown (`warn`), never as `0` or `999`.
- Date keys in `DATA[]` are ISO `YYYY-MM-DD`; keep the original string in a sibling `*_raw` key.
- **Never put a DSN password into `DATA[]`.** Wrap every DSN value in `redact_dsn` at collection time.
  `lib/json.sh` re-applies it to `*dsn*|*connection_string*` keys as a safety net.

### 3.9 Nine Executive Pillars (SUMMARY_KEYS)
The health summary roll-up uses exactly these 9 keys:
```bash
backup, mail_flow, tls, access, threat, resources, os_update, monitoring, database
```
- `health.summary.total_checks` — count of non-skip pillars
- `health.summary.failed` — fail/critical count
- `health.summary.warnings` — warn count
- `health.summary.overall` — `pass`/`warn`/`fail`

---

## 4. Agent Protocol (OMP ↔ OpenCode)

### Roles
- **OMP (Supervisor):** Task assignment, scope definition, approval gates, final verification
- **OpenCode (Worker):** Implementation, testing, documentation updates

### Workflow
1. **Task Receipt:** OMP provides clear scope with acceptance criteria
2. **Research Phase:** OpenCode reads relevant files, identifies affected code paths
3. **Implementation:** OpenCode makes changes following repository conventions
4. **Verification:** OpenCode runs smoke tests, validates outputs
5. **Documentation:** OpenCode updates CLAUDE.md, CHANGELOG.md, docs/ as needed
6. **Completion:** OpenCode reports evidence of success or blockers

### Communication Protocol
- Use `agents_bridge.md` patterns for multi-agent coordination (when applicable)
- Cross-file changes: update all callers, tests, docs in single commit
- Breaking changes (key renames): require explicit OMP approval

### Change Checklist (for OpenCode)
For **configurator key** additions:
1. Confirm key exists in `tool.help` and is writable (not `r/o`)
2. Add to `config/recommended.conf` as `key|value|description`
3. Run `./agent.sh --config` on lab server; verify no `key not found` lines

For **collector** changes:
1. Add/modify `collectors/<area>/<name>.sh` with `collector_run()`
2. Use `collector_set` and namespaced keys; timeout external calls
3. Run `maintenance/collector_tester.sh <name>` on lab server
4. Update `lib/health.sh` if item is evaluated
5. Update `docs/checklist-map.md` / `docs/checklist-coverage.md`
6. Run full agent; inspect `output/health.json` and both PDFs
7. Verify JSON validity and key name stability

For **health rule** changes:
1. Update `lib/health.sh` with new threshold/logic
2. **IMMEDIATELY** sync `lib/pdf.sh` and `lib/management_report.sh`
3. Update `config/recommended.conf` if threshold changed
4. Update this CLAUDE.md §3.5 Strict Threshold Rules
5. Run full agent; verify all three outputs

---

## 5. Graphify Context

### Code Graph Location
The repository includes a **Graphify-generated code graph** at:
```
graphify-out/
├── graph.json          # 313 nodes, 249 edges, 92 communities
├── GRAPH_REPORT.md     # Human-readable analysis
├── graph.html          # Interactive visualization
└── cache/              # AST cache for incremental updates
```

### How to Query
```bash
# Symbol relationships
graphify query "how does health evaluation reach the PDF reports?"

# Function explanation
graphify explain "evaluate_health()"

# Path tracing between functions
graphify path "evaluate_health()" "build_pdf()"

# Find highly-connected nodes
graphify god-nodes

# Rebuild graph
graphify extract . --code-only
graphify cluster-only . --no-label
```

### Limitations
- Collectors are loaded dynamically with `source` — cross-file call edges are **not** fully resolved
- Graph represents static analysis only; runtime behavior may differ
- Use for symbol inventory and intra-file relationships, not complete call graph

---

## 6. Repository Structure

```
icewarp-health-agent-remote-cli/
├── agent.sh                    # Entry point (stateless, no auto-update)
├── VERSION                     # Agent version (0.8.1)
├── CLAUDE.md                   # This file
├── README.md                   # User documentation
├── CHANGELOG.md                # Version history
├── config/
│   ├── agent.conf              # Agent settings (MONITOR_URL, timeouts, etc.)
│   ├── icewarp.conf            # IceWarp paths, SSL, DNS, hostname
│   ├── recommended.conf        # Configurator desired state
│   └── checklist.conf.pdf      # Checklist source of truth
├── lib/
│   ├── common.sh               # Shared helpers, DATA[], collector_set()
│   ├── health.sh               # Health evaluation + check registry (9 pillars)
│   ├── json.sh                 # Type-aware JSON builder (v1, flat)
│   ├── json_v2.sh              # health.v2.json envelope builder
│   ├── pdf.sh                  # Technical report (native PDF)
│   ├── management_report.sh    # Executive report (native PDF)
│   ├── transport.sh            # JSON POST to monitoring server
│   └── configurator.sh         # --config dry-run and --apply
├── collectors/                 # 81 collectors in 14 categories
│   ├── icewarp/                # IceWarp-specific settings
│   ├── security/               # Security policies, DNSBL, intrusion
│   ├── smtp/                   # SMTP limits, relay
│   ├── storage/                # Disk usage
│   ├── system/                 # OS-level checks
│   ├── watchdog/               # Watchdog percentages
│   ├── logging/                # Mail queue, SQL auth log
│   ├── mailserver/             # Advanced mail server settings
│   ├── os/                     # CPU, memory, updates, time sync
│   ├── queue/                  # Incoming queue, retry
│   ├── general/                # Date, OS, version
│   ├── http/                   # HTTP service
│   ├── dns/                    # DNS records (SPF, DKIM, DMARC, PTR)
│   └── fulltext/               # Full-text search
├── maintenance/                # Development tools
│   ├── collector_tester.sh     # Run single collector
│   └── collectors_validity_checker.sh  # Validate all collectors
├── docs/                       # Documentation
│   ├── schema/health.v2.schema.json  # JSON Schema for health.v2.json
│   ├── checklist-map.md        # Checklist item → collector mapping
│   ├── checklist-coverage.md   # Coverage analysis
│   ├── update-log.md           # Change ledger
│   └── tool-search/            # tool.sh output exports
├── graphify-out/               # Code graph (regenerate as needed)
├── output/                     # Runtime artifacts (gitignored)
│   ├── health.json
│   ├── report.pdf
│   └── management_report.pdf
└── logs/                       # Runtime logs (gitignored)
```

---

## 7. Commands Reference

### Normal Operation
```bash
./agent.sh                                  # Full run: collect + evaluate + JSON + PDFs
./agent.sh --report                         # Above + console summary
./agent.sh --list                           # List all 81 collectors
./agent.sh --only=dns,backup                # Filter by path substring (comma-separated)
./agent.sh --technician="Name" --company="Company"
```

### Configurator
```bash
./agent.sh --config                         # Dry-run: show recommended vs. current
./agent.sh --config --apply                 # Apply changes via tool.sh set system
```

### Development/Diagnostics
```bash
bash -n agent.sh lib/*.sh collectors/**/*.sh        # Syntax check
./maintenance/collector_tester.sh <collector>       # Run one collector, print DATA keys
./maintenance/collectors_validity_checker.sh        # Run all + validate health.json
./maintenance/collectors_validity_checker.sh --list # List validation checks
```

---

## 8. Health Evaluation Summary

### Result Vocabulary
- `pass` — Check passed
- `warn` — Warning (needs attention but not critical)
- `fail` — Failure (requires immediate action)
- `critical` — Critical failure (production-impacting)
- `skip` — Check skipped (missing prerequisites)
- `info` — Informational (explicitly allowed only for optional features)

### Key Thresholds (from lib/health.sh)

| Area | Threshold | Result |
|------|-----------|--------|
| **Memory** | Used > 90% | `critical` |
| **Memory** | Used > 40% | `warn` |
| **Disk** | Free MB < `monitor.disk.alert_below_mb` | `fail` |
| **CPU** | 1-min load > cores × threshold% | `warn` |
| **Password** | Policy inactive | `fail` |
| **Password** | Min length < 8 | `warn` |
| **Login Blocking** | Threshold > 10 | `warn` |
| **Backup** | Auto disabled | `critical` |
| **Backup** | DB (Accounts) disabled | `critical` |
| **Backup** | Last run ≥ 2 days | `warn` |
| **Backup** | Last run ≥ 7 days | `critical` |
| **Watchdog** | Master/service disabled | `critical` |
| **OS Update** | > 30 days | `critical` |
| **OS Update** | 8–30 days | `warn` |
| **Directory Cache** | Schedule missing | `critical` |

---

## 9. Configuration Files

### config/agent.conf
```
AGENT_VERSION=0.8.1
CHECKLIST_VERSION=1.14
MONITOR_URL=<webhook_url>
SEND_DATA=0|1
OUTPUT_JSON=output/health.json
OUTPUT_JSON_V2=output/health.v2.json
TOOL_TIMEOUT=5
STARTTLS_TIMEOUT=15
COMPANY_NAME=
```

### config/icewarp.conf
```
IW_ROOT=/opt/icewarp
IW_TOOL=${IW_ROOT}/tool.sh
IW_CONFIG_DIR=${IW_ROOT}/config
IW_SSL_CERT=
IW_DNS_RESOLVER=
MAIL_HOSTNAME=
MAIL_PUBLIC_IP=
```

### config/recommended.conf
```
# Format: key|value|description
# Used ONLY by configurator (--config), NOT sourced by agent.sh
Security.IntrusionPrevention.BlockConnectionsPerMinute|50|Block IP after 50 connections in 1 minute
Security.IntrusionPrevention.BlockDuration|360|Block IP for 360 minutes (6 hours)
Monitor.AlertEmail|admin@example.com|Alert email for notifications
```

---

## 10. Known Issues / Documentation Drift

- **README.md** says "12 categories" — actual: **14 collector directories**, **81 collector scripts**
- **README thresholds** for disk (80/95) and CPU (15-min load, 50/95) are stale — see §3.5 above
- **docs/checklist-map.md** and **docs/checklist-coverage.md** may reference removed collectors — code is source of truth
- **LICENSE** file not present in repository

---

## 11. Change Ledger

For every intentional change, update:
1. `docs/update-log.md` — detailed change description
2. `CHANGELOG.md` — user-facing summary
3. This `CLAUDE.md` — if rules, thresholds, or architecture changed
4. Affected guides (`README.md`, checklist docs)

After committing, replace the `pending` commit hash in the activity log.

---

**Last Updated:** 2026-11-02  
**Agent Version:** 0.8.1  
**Checklist Version:** 1.14
