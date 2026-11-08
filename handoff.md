# IceWarp Health Agent — Session Handoff (Remote CLI)

## 1. Project Context
**Repository:** `C:\Users\mrkashi\Documents\Default Project\icewarp-health-agent-remote-cli`  
**Remote:** `https://github.com/kashiparsavan/icewarp-health-agent-remote-cli.git`  
**Branch:** `step3/health-registry-rollup`  
**Current Version:** `0.8.1`  
**Tech Stack:** Bash 4+, GNU coreutils only — no package manager, database, or web server. Native PDF generation (no external tools). 81 collectors across 14 categories.  
**Outputs:** Timestamped files in `output/` — `health_YYYY-MM-DD_HH-MM.json`, `report_YYYY-MM-DD_HH-MM.pdf`, `management_report_YYYY-MM-DD_HH-MM.pdf` (and `.v2.json` envelope).

---

## 2. Current Status (as of 2026-11-03)

### ✅ Completed Work

#### 2.1 Stateless Architecture (v0.8.0)
- **Removed all git/auto-update logic:** Deleted `lib/auto_update.sh`, `docs/auto-update.md`. Removed `--check-update`, `--no-auto-update`, `--auto-update`, `--no-update` flags and all `AUTO_UPDATE_*` config variables from `config/agent.conf`. Removed run lock (`acquire_lock`/`release_lock`) from `lib/common.sh`.
- **Agent runs fully stateless:** Creates `output/` and `logs/`, runs collectors, evaluates health, emits JSON/PDFs, exits cleanly. No persistent state, no re-exec.

#### 2.2 Repository Minimalism
- **Deleted all non-essential files:** `docker-compose.yml`, `tool.*` help files, `tool-search.tar.gz`, `.env.example`, `maintenance/`, `patches/`, `tests/`, `health/`, `docs/tool-search/`, and all auxiliary `.md` files (LESSONS_LEARNED, TESTING_GUIDE, WORKFLOW, api-update-*, roadmap, tool-index, auto-update).
- **Only allowed files tracked:** `agent.sh`, `VERSION`, `package.sh`, `bootstrap.sh`, `README.md`, `CLAUDE.md`, `CHANGELOG.md`, `handoff.md`, `config/`, `lib/`, `collectors/`, `docs/PROJECT_OVERVIEW.md`, `docs/checklist-map.md`, `docs/update-log.md`, `docs/schema/health.v2.schema.json`.

#### 2.3 Packaging Script (`package.sh`)
- Creates `linux-agent.tar.gz` containing **ONLY**: `agent.sh`, `VERSION`, `config/`, `lib/`, `collectors/`
- Explicit `--exclude='.git*'` for safety
- Excludes: `package.sh`, `bootstrap.sh`, `README.md`, `CLAUDE.md`, `docs/`, `maintenance/`, `tests/`, `*.md`

#### 2.4 Bootstrap Script (`bootstrap.sh`) — **FIXED**
- **Complete rewrite with advanced TUI dashboard** (pure Bash, `tput`, ANSI escape codes, box-drawing characters)
- **Phase 1 — Initialization & Path Detection:**
  - Uses `</dev/tty` for ALL `read` commands (works via `curl | bash`)
  - Auto-detects IceWarp path (`/opt/icewarp`, `/usr/local/icewarp`, etc., fallback to `find`)
  - Downloads and extracts package to secure `TMP_DIR` with spinner
- **Phase 2 — TUI Dashboard Layout (Fixed, Non-scrolling):**
  - **Header Box (Rows 1-5, Cyan border):** Title "IceWarp Health Agent v0.8.0" (Bold Magenta), OS + IceWarp version + detected path
  - **Menu Box (Left, Row 7+, Blue border):** `[1] Run Full Assessment`, `[2] Check Configuration`, `[3] Apply Configuration`, `[4] Exit`
  - **Execution Area (Right, Row 7+, Cyan border):** Live command output with auto-scroll
- **Phase 3 — Color Palette:** Cyan borders, Bright Green success, Bright Yellow prompts/actions, Bold Magenta title, Bright Cyan info
- **Phase 4 — Interaction Loop:**
  - Prompt at Row 20: `Select an option [1-4]: `
  - `read -r choice </dev/tty` (protected with `|| true`)
  - Executes command in Execution Area, shows live output
  - After completion: `[ENTER] to return to dashboard...` (protected with `|| true`)
  - Redraws static parts on return

#### 2.5 Crash Bug Fixes (Critical — Applied 2026-11-03)
| Root Cause | Fix |
|------------|-----|
| Missing HTTP auth on `curl` download | Added `-u "parsavan:P@rsavan.com@123"` |
| `set -e` + `read` failure crashes script | All `read </dev/tty` protected with `|| true` |
| Process substitution loses `agent.sh` exit code | Temp file captures real exit code in subshell |
| `cleanup` trap clears screen on normal exit | `SCRIPT_EXITING` flag; cleanup only clears on crash/interrupt |
| `set -e` propagates from command subshell | `set +e` inside command subshell |
| Empty read leaves unbound variable | Fallback `choice=""` on read failure |

#### 2.6 Documentation Updates
- **`README.md`**: Rewritten for minimal structure, exact tarball contents, deployment workflow
- **`CLAUDE.md`**: Added §5.2 "Repository Minimalism" strict rules (pure Bash only, forbidden dirs/files)
- **`docs/PROJECT_OVERVIEW.md`**: New file — architecture, data flow, packaging/bootstrap mechanism
- **`.gitignore`**: Added `*.py`, `*.ps1`, `*.pyc`, `__pycache__/`
- **`CHANGELOG.md`**: Updated with v0.8.0 entries

---

## 3. Credentials & Server Paths

| Item | Value |
|------|-------|
| **Server Base URL** | `https://parsavan.com/support/iceautochecker/linux-agent/` |
| **Package URL** | `https://parsavan.com/support/iceautochecker/linux-agent/linux-agent.tar.gz` |
| **Bootstrap URL** | `https://parsavan.com/support/iceautochecker/linux-agent/bootstrap.sh` |
| **Auth User** | `parsavan` |
| **Auth Pass** | `P@rsavan.com@123` |
| **`.htaccess` Location** | `iceautochecker/` (parent directory) |
| **`.htpasswd` Location** | `linux-agent/` (same directory as files) |

**Authentication Note:** The server uses HTTP Basic Auth. The `bootstrap.sh` script now includes the credentials in the `curl` command:
```bash
curl -sSL -f -u "${AUTH_USER}:${AUTH_PASS}" "$package_url" -o "$TMP_DIR/linux-agent.tar.gz"
```

---

## 4. Next Steps (For Next Session)

### 4.1 Upload Updated Files to Server
The user must upload the following to `https://parsavan.com/support/iceautochecker/linux-agent/`:
1. `linux-agent.tar.gz` (rebuild with `./package.sh` first)
2. `bootstrap.sh` (the fixed TUI version)

### 4.2 Test the TUI Deployment
**Recommended test sequence:**
```bash
# 1. Download the bootstrap script to a test file
curl -sSL -u parsavan:'P@rsavan.com@123' \
  https://parsavan.com/support/iceautochecker/linux-agent/bootstrap.sh \
  -o run.sh

# 2. Make executable and run
chmod +x run.sh
bash run.sh
```

**Expected TUI behavior:**
1. Spinner shows "Downloading package..." → "Extracting package..."
2. Dashboard renders: Header box (cyan), Menu box (blue, left), Execution area (cyan, right)
3. **Select Option 1** → `./agent.sh --report` runs in Execution Area
4. Live output appears line-by-line in right box (auto-scrolls if needed)
5. On completion: `✓ Command completed successfully (exit 0)` or `✗ Command failed (exit N)`
6. Press **ENTER** → returns to dashboard (menu redrawn, execution area reset)
7. **Select Option 4** → "Thank you..." message, clean exit
8. **Verify:** `output/` folder copied back to original `START_DIR` with timestamped files

### 4.3 Verification Checklist
- [ ] TUI renders correctly (no garbled characters, boxes aligned)
- [ ] Menu navigation works (1-4, invalid input handled)
- [ ] Option 1 runs full assessment without crashing
- [ ] Live output visible in right-side Execution Area
- [ ] Exit code displayed correctly (green for 0, red for non-zero)
- [ ] ENTER returns to dashboard (state preserved)
- [ ] Option 4 exits cleanly, final message visible
- [ ] `output/` folder created in starting directory with timestamped files
- [ ] No screen clear on normal exit (only on crash/interrupt)

---

## 5. Strict Rules for Next Agent

1. **Read `CLAUDE.md` first** — source of truth for architecture, strict rules (§3, §5.2), and change checklist.
2. **Use `verification-before-completion` skill** before claiming anything works. Evidence before assertions, always.
3. **One commit per task** — descriptive messages, never generic.
4. **PowerShell commands only** — the user runs `git add/commit/push` from the Windows host. Provide exact commands after each step.
5. **Do not modify core logic** of `agent.sh`, `lib/`, or `collectors/` unless explicitly asked.
6. **LF line endings** on all `.sh` files — never CRLF.
7. **Stage files explicitly** — never `git add -A` (`.gitignore` excludes `output/`, `logs/`, but `tests/` may exist on disk).
8. **Verify before push**: `git show HEAD -- <file>` for diff, then `git ls-remote origin step3/health-registry-rollup` to confirm remote hash moved.
9. **Repository must remain minimal** — no tool docs, Docker files, test fixtures, Python, Node.js, PowerShell. Only core agent, lib, collectors, config allowed.

---

## 6. Git State (as of last commit)

```
HEAD → ref: refs/heads/step3/health-registry-rollup
Recent commits:
  - fix(bootstrap.sh): resolve TUI crash on menu selection
  - feat(bootstrap.sh): rewrite with advanced TUI dashboard
  - chore(package.sh): add explicit --exclude='.git*' safety check
  - chore: strip repository to bare minimum required for the agent
  - [previous v0.8.0 stateless/packaging commits]
```

---

## 7. Key Files Reference

| File | Purpose |
|------|---------|
| `agent.sh` | Entry point (stateless, no auto-update) |
| `package.sh` | Creates minimal `linux-agent.tar.gz` |
| `bootstrap.sh` | **Fixed TUI** — curl\|bash entry point with dashboard |
| `config/agent.conf` | Agent settings (timeouts, monitor URL) |
| `config/icewarp.conf` | IceWarp paths, SSL, DNS, hostname |
| `config/recommended.conf` | Configurator desired state |
| `lib/common.sh` | Shared helpers, DATA[], collector_set() |
| `lib/health.sh` | Health evaluation + check registry (9 pillars) |
| `lib/json.sh` / `json_v2.sh` | Type-aware JSON builders |
| `lib/pdf.sh` | Technical PDF generator |
| `lib/management_report.sh` | Executive PDF generator |
| `lib/transport.sh` | HTTP transport (disabled by default) |
| `lib/configurator.sh` | `--config` dry-run and `--apply` |
| `collectors/` | 81 collectors in 14 categories |

---

**Last Updated:** 2026-11-03  
**Agent Version:** 0.8.1  
**Checklist Version:** 1.14