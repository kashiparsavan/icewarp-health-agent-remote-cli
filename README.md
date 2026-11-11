# IceWarp Health Agent (Remote CLI)

The Linux agent is a dependency-free, Bash-based health checking and reporting
tool for IceWarp mail servers. It runs locally on the mail server, collects data
via `tool.sh`, OS commands, and DNS lookups, evaluates the results against a
defined checklist, and generates three output files.

**As of v0.8.1, the agent is fully stateless, self-contained, and independent of git.**
It has no auto-update mechanism, no persistent state, and no run locks. It runs
its collectors, generates outputs in the `output/` folder, and exits cleanly.

---

## IceWarp Update Protocol

The TUI's **Install / Update IceWarp** action follows these rules. The *branch*
is the first two components of a version — `14.2.0.16` belongs to branch `14.2`.

- **Rule 1 — Major version jumps are STRICTLY FORBIDDEN.** You cannot update
  `14.2` directly to `14.3`. The installer menu refuses to offer a package from
  another branch, and a custom URL pointing at a different branch is rejected
  with `[WARN] Major version jumps are not supported directly`.
- **Rule 2 — Always find and install the highest build within the SAME major
  branch.** On a server running `14.2`, the correct target is the newest
  `14.2.x.y` package (for example `14.2.0.16`), never a newer branch.
- **Rule 3 — The TUI blinking warning compares the installed version against
  the target version of the same branch.** `14.2.0.5` with a branch target of
  `14.2.0.16` blinks in the header; `14.2.0.16` (already the branch maximum)
  does not blink, even when a `14.3` package exists. Nothing blinks when
  IceWarp is not installed.
- **Rule 4 — If IceWarp is not installed, the absolute latest version across all
  branches is offered.**

The Pars Avan mirror is subject to the same rule: a package outside the
installed branch is displayed as `Different major branch - not installable`
rather than being selectable.

---

## Persistent Data on the Server

The TUI keeps its working directory at `/root/agent` (override with
`HEALTH_AGENT_DIR`). On exit it cleans up after itself, but **operator data is
never deleted**:

| Kept | Contents |
|------|----------|
| `/root/agent/ssl/` | Certificates from **Manage SSL** (Let's Encrypt per domain, `self-signed-<IP>`, or `self-signed-<domain>`) |
| `/root/agent/backups/` | Backups from **Backup / Restore** (`icewarp_backup_<YYYYmmdd-HHMM>.tar.gz`) |
| `/root/agent/*.tar.gz` | Cached installer packages |
| `/root/agent/*.log` | Agent logs |

Only scratch material is removed: `tmp/` (FIFOs, extracted VERSION) and any
unpacked installer tree such as `IceWarpServer-14.3/`.

Certificates are written under `/root/agent/ssl/` and are **not** pushed into
IceWarp. Use **Manage SSL → 2) For Nginx** to install one into the proxy, or
copy the files into the IceWarp console yourself.

### Security Modules — install order matters

Run these in order. Each step depends on the previous one; out of order you end
up with a half-configured proxy.

| # | Menu item | What it does |
|---|-----------|--------------|
| 8 | **Switch Web Ports (Nginx Prep)** | Moves IceWarp to **8080** (HTTP) / 8443 (TLS), freeing 80/443 for Nginx |
| 9 | **Install ModSecurity** | Builds `libmodsecurity` into `/usr/local/lib` and the Nginx connector into `/usr/src/ModSecurity-nginx` |
| 10 | **Configure ModSecurity** | Writes `/etc/nginx/modsec/modsec.conf` + the OWASP CRS |
| 11 | **Install Nginx** | Builds Nginx with `--add-dynamic-module=/usr/src/ModSecurity-nginx`, then saves `ngx_http_modsecurity_module.so` to `/etc/nginx/modules/` |
| 12 | **Configure Nginx** | Writes the vhost, loads the module, registers the library with the linker, creates cache dirs, verifies 80 + 443 |
| 13 | **Install CSF** | Firewall, installed last so the build is not interrupted |
| 14 | **Configure CSF** | Applies the IceWarp port set. Only 22/80/443 are public — the console shares 443 |
| 15 | **Configure RPC Access (Domain & IPs)** | Sets the console DNS name and the trusted admin networks from the TUI, then reapplies Nginx |

Both **Install ModSecurity** and **Install Nginx** ask
`Do you want to force a complete clean rebuild? (y/N)` when the component already
exists — answer `y` to discard stale artefacts when a previous run half-finished.

### Reverse proxy — how traffic flows

```
client ──443/TLS──▶ nginx stream ──▶ nginx http (127.0.0.1:10443) ──8443/TLS──▶ IceWarp
```

Nginx accepts TLS on 443, then proxies to IceWarp over **TLS as well**
(`https://127.0.0.1:8443`). The extra hop costs nothing on loopback and matters a
great deal: if IceWarp is reached on its plain 8080 port it considers the request
insecure and answers `/admin/apicss`, `/admin/framework.js` and the API with
**301s to its own `https://…:8443` origin** — cross-origin redirects that break
the webmail login with CORS errors.

```nginx
upstream icewarp_backend { server 127.0.0.1:8443; keepalive 32; }
proxy_ssl_verify off;    # IceWarp's certificate is self-signed; hop is loopback-only
proxy_pass https://icewarp_backend;
```

The vhost carries the full forwarding header set (`Host` without a port,
`X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`, `X-Forwarded-Port 443`,
`Upgrade`, `Connection "upgrade"`) so Remote Console redirects and WebSocket
upgrades work, and **no HSTS header** is written.

**Configure Nginx** resolves the certificate in this order:

1. a **domain** certificate — `ssl/self-signed-<domain>/` or a Let's Encrypt
   `ssl/<domain>/`;
2. an **IP** certificate, with
   `[WARN] No Custom Domain certificate found. Using IP certificate.`;
3. a temporary self-signed certificate in `/etc/nginx/ssl/` when the store is
   empty.

The generated vhost (`/etc/nginx/conf.d/icewarp.conf`) always contains valid
absolute paths to `ssl_certificate` and `ssl_certificate_key`, so Nginx never
fails to start because of a missing file.

### Remote Console — SNI routing, no extra port

The IceWarp Remote Console uses a raw TCP protocol that an HTTP reverse proxy
cannot carry. Instead of opening a second public port, everything enters on
**443** and Nginx's `stream` layer routes it after reading the TLS ClientHello:

```
                 ┌─ trusted IP + console SNI ─▶ 127.0.0.1:10444 ─▶ IceWarp 8443
client ──443/TCP─┤
                 └─ everything else ─────────▶ 127.0.0.1:10443 (HTTPS + ModSecurity)
```

- The console branch needs **both** conditions: the client IP must be in the
  trusted list **and** the TLS SNI must equal the dedicated console hostname.
  Anything else — a port scan, a browser opening the webmail name — falls
  through to the webmail path.
- Webmail still terminates as HTTPS (on loopback `10443`), so the certificate,
  the vhost and **ModSecurity inspection of all webmail traffic** are unchanged.
  The loopback hop carries the real client IP via PROXY protocol, which the
  vhost restores with `set_real_ip_from 127.0.0.1; real_ip_header proxy_protocol;`.
- Only **22, 80 and 443** are public. No extra firewall port is opened.

**HTTPS is enforced on the backend response.** IceWarp builds absolute URLs from
its own idea of the scheme *and* its own ports, so behind a TLS terminator it
returns `<base href="http://host:8080/admin/">` and `https://host:8443/...`.
Rewriting only the scheme makes that worse — `http://host:8080` becomes
`https://host:8080`, i.e. TLS on a plain-HTTP port, and the browser reports the
failure as a **CORS error** against a foreign origin. **12) Configure Nginx**
therefore rewrites the whole origin:

| Layer | Directive | Handles |
|-------|-----------|---------|
| Headers | `Host $host` (no port), `X-Forwarded-Proto $scheme`, `X-Forwarded-Port 443`, `X-Forwarded-Ssl`, `X-Url-Scheme` | IceWarp emitting correct URLs in the first place, and not answering plain-HTTP requests with 301s |
| Redirects | `proxy_redirect ~^https?://[^/]+:8080(/.*)$ …` and the `:8443` equivalent | 301/302 pointing at an internal port |
| Body | `sub_filter 'http://$host:8080' 'https://$host'` (plus `:8443`, `127.0.0.1`, `localhost`, the LAN IP) | absolute URLs left in HTML/JS/JSON |

`sub_filter` needs two things that are easy to miss, and both are handled: nginx
must be compiled with `--with-http_sub_module`, and the body must be uncompressed
(`Accept-Encoding ""`), otherwise the rewrite silently does nothing. The rewrite
is limited to text content types so binary payloads cannot be corrupted, and
`WEBMAIL_HTTP_REWRITE=0` disables it entirely.

> **Port 443 accepts ordinary TLS.** `proxy_protocol on` inside the stream
> block is a *sender* setting — it prepends the client address on the hop to the
> local backend. It never asks the browser for a PROXY header, so normal clients
> and mail apps are unaffected. The console hop consumes that header and
> forwards raw TCP, because IceWarp does not speak PROXY protocol.
>
> Both ends of the hop are generated from one switch
> (`STREAM_USE_PROXY_PROTOCOL`, default `1`), and **12) Configure Nginx**
> refuses to write a configuration where one side expects the header and the
> other does not — that mismatch is what breaks the proxy. If `nginx -t` still
> rejects the generated file, the previous `nginx.conf` is restored automatically
> so a restart can never leave the server without a proxy.

Both values are set from the menu — **15) Configure RPC Access (Domain & IPs)**
prompts for the console name and for the allowed addresses (comma separated),
saves them and reapplies Nginx. Nothing has to be edited by hand.

| File | Contents |
|------|----------|
| `/root/agent/config/console_sni.conf` | The console DNS name, e.g. `console.example.com`. While it is still the placeholder the agent prints a warning and no connection matches the console branch. |
| `/root/agent/config/admin_ips.conf` | Trusted admin networks, one CIDR or IP per line. Defaults to `127.0.0.1` and `192.168.75.0/24`. Lines starting with `#` are ignored, and a hand-edited comma-separated list still parses. |

Leave either prompt empty to keep the current value. The console hostname also
needs a DNS record pointing at the server.

The console client opens TLS on 443 with the console name; the proxy forwards the
**still-encrypted** stream to IceWarp's own TLS listener on `8443`. Nginx never
decrypts it and nothing downgrades it to HTTP, so Remote Config is HTTPS end to
end — the loopback hop is TCP only, the TLS session is browser ↔ IceWarp.

> **ModSecurity cannot inspect the console hop.** It is a Layer-7 HTTP WAF and
> the stream module forwards bytes without ever parsing a request. That is
> inherent to proxying a raw protocol. The protection is the IP allow-list, the
> SNI match, the firewall in front of 443, and IceWarp's own authentication.

If your Nginx was built before this feature it lacks `--with-stream` and
`--with-stream_ssl_preread_module`; the agent detects that, warns, and skips the
block. Run **11) Install Nginx** and answer `y` to the rebuild prompt.

### Manage SSL

| Option | Use when | Output |
|--------|----------|--------|
| **1) Let's Encrypt (Domain)** | You control the domain's DNS and can add a `_acme-challenge` TXT record | `/root/agent/ssl/<domain>/` |
| **2) Self-Signed Certificate (Server IP)** | The server has no domain, or you only need the IP | `/root/agent/ssl/self-signed-<IP>/` |
| **3) Self-Signed Certificate (Custom Domain)** | You have a domain but **cannot validate it for Let's Encrypt** — no DNS access, no spare host, no cPanel to add a temporary record | `/root/agent/ssl/self-signed-<domain>/` |

Option 3 asks for a fully qualified name (e.g. `mail.example.com`), then
generates a 3650-day RSA-2048 certificate with that name as the **CN** and as a
**subjectAltName** (`DNS:<domain>`), so current browsers and mail clients
accept it after you trust it. The full path to both files is printed when it
finishes.

After choosing the certificate type, pick **where it should be installed**:

| Target | What happens |
|--------|--------------|
| **1) For IceWarp** | Files land in `/root/agent/ssl/<name>/` and you install them manually in the IceWarp console |
| **2) For Nginx** | The same files are written, then `/etc/nginx/conf.d/icewarp.conf` is repointed at them, `nginx -t` runs, and Nginx reloads. The previous vhost is backed up and restored automatically if the test fails |

**Configure Nginx** terminates TLS itself and proxies to IceWarp over plain
HTTP on `127.0.0.1:8080`, so the local hop needs no certificate. When picking a
certificate it prefers a **domain** certificate (`self-signed-<domain>/` or a
Let's Encrypt `<domain>/`) and only falls back to an IP certificate with
`[WARN] No Custom Domain certificate found. Using IP certificate.` No HSTS
header is written.

Since a self-signed certificate is not signed by a public CA, every client must
still accept it once — but it encrypts traffic and needs no DNS or HTTP
validation, which is exactly what makes it the fallback when Let's Encrypt is
not possible.

### Switch Web Ports (Nginx Prep)

IceWarp listens on 80/443 by default. Before Nginx can take those ports, IceWarp
must move to 8080 (HTTP) and 8443 (HTTPS).

The port properties are **discovered at runtime**, because they are not the same
in every build — IceWarp 14.3 has no `c_server_http_port`. The agent reads the
names this build actually publishes (convention:
`c_config_services_<service>_port` / `_sslport`) and then **reads the value back
after writing it**, so a rejected write is detected instead of assumed.

Safety rules built into the switch:

| Situation | What happens |
|-----------|--------------|
| No port property found | `[FAIL]`, nothing is written, **IceWarp keeps running** |
| IceWarp rejects the value | `[FAIL]`, partial changes rolled back, **IceWarp keeps running** |
| Ports written and verified | IceWarp is stopped, 80/443 are confirmed free, then started on the new ports |
| Start fails or is slow | Start retried, then a last-resort guard starts IceWarp again |
| Ports already correct | No restart at all — a healthy server is never taken down |

The agent never returns to the menu with IceWarp stopped: whether the switch
succeeds or fails, the mail server is running when the action finishes.

---

## Output Files

The Linux agent generates timestamped output files in the **current directory** where the `curl` command is run. Each run creates uniquely named files (format: `YYYY-MM-DD_HH-MM`) so previous results are never overwritten.

| File Pattern | Purpose |
|--------------|---------|
| `output/health_YYYY-MM-DD_HH-MM.json` | Raw structured data (type-aware JSON) for monitoring systems |
| `output/report_YYYY-MM-DD_HH-MM.pdf` | Full technical report with all checklist items, values, and notes |
| `output/management_report_YYYY-MM-DD_HH-MM.pdf` | Non-technical executive summary with scorecards and prioritized actions |

**Example:** After running at 2026-11-02 14:30, you'll see:
```
output/
├── health_2026-11-02_14-30.json
├── health_2026-11-02_14-30.v2.json
├── report_2026-11-02_14-30.pdf
└── management_report_2026-11-02_14-30.pdf
```

---

## Quick Start: One-Liner Deployment (Recommended)

The agent is designed to be deployed and run via a single `curl | bash` command.
This leaves **no trace** on the server — all files are extracted to a temporary
directory, the check runs, results are saved to `./output/`, and the temporary
directory is automatically deleted.

### For End Users (Run the Health Check)

```bash
curl -sSL https://parsavan.com/support/iceautochecker/linux-agent/bootstrap.sh | bash
```

**What happens:**
1. Downloads `linux-agent.tar.gz` from the hosted URL
2. Extracts everything into a secure temporary directory (`/tmp/icewarp-health-agent.XXXXXX`)
3. Runs `./agent.sh --report` (full collection, evaluation, JSON, and PDF generation)
4. Copies the `output/` folder (with timestamped files: `health_YYYY-MM-DD_HH-MM.json`, `report_YYYY-MM-DD_HH-MM.pdf`, `management_report_YYYY-MM-DD_HH-MM.pdf`) back to your current directory
5. **Automatically deletes all temporary files** — the server is left clean

### Command-Line Options

Pass options to `agent.sh` by appending them after `bash -s --`:

```bash
# With custom technician and company name
curl -sSL https://parsavan.com/support/iceautochecker/linux-agent/bootstrap.sh | bash -s -- --report --technician="John Doe" --company="Acme Corp"

# List available collectors only
curl -sSL https://parsavan.com/support/iceautochecker/linux-agent/bootstrap.sh | bash -s -- --list

# Run only specific collectors (comma-separated filter)
curl -sSL https://parsavan.com/support/iceautochecker/linux-agent/bootstrap.sh | bash -s -- --only=dns,backup
```

---

## For Administrators: Packaging & Hosting

If you are hosting the agent yourself, follow these steps:

### 1. Create the Package

```bash
# In the repository root:
./package.sh
```

This creates `linux-agent.tar.gz` containing **ONLY** the minimum required runtime files:
- `agent.sh` — entry point
- `VERSION` — version file
- `config/` — configuration files (`agent.conf`, `icewarp.conf`, `recommended.conf`, `checklist.conf.pdf`)
- `lib/` — all library files (`common.sh`, `health.sh`, `pdf.sh`, `json.sh`, `json_v2.sh`, `management_report.sh`, `transport.sh`, `configurator.sh`)
- `collectors/` — all 81 collector scripts

**Excluded from tarball:** `.git`, `output/`, `docs/`, `tests/`, `*.md`, `windows/`, `graphify-out/`, scripts themselves (`package.sh`, `bootstrap.sh`), `maintenance/`, `patches/`, `health/`

### 2. Upload to Your Host

Upload these two files to your web server (e.g., `https://parsavan.com/support/iceautochecker/linux-agent/`):

- `linux-agent.tar.gz` — the agent package
- `bootstrap.sh` — the bootstrap script (this file)

Ensure both are publicly accessible via HTTPS.

### 3. Verify

```bash
# Test the bootstrap script
curl -sSL https://your-host.com/linux-agent/bootstrap.sh | bash -s -- --list
```

---

## Repository Structure (Minimal)

The repository contains **only** the files required to build and run the agent:

```
icewarp-health-agent-remote-cli/
├── agent.sh                    # Entry point (stateless, no auto-update)
├── VERSION                     # Agent version (0.8.1)
├── package.sh                  # Creates linux-agent.tar.gz
├── bootstrap.sh                # curl | bash entry point
├── CLAUDE.md                   # Guidance for AI agents and maintainers
├── README.md                   # This file
├── CHANGELOG.md                # Version history
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
│   ├── icewarp/
│   ├── security/
│   ├── smtp/
│   ├── storage/
│   ├── system/
│   ├── watchdog/
│   ├── logging/
│   ├── mailserver/
│   ├── os/
│   ├── queue/
│   ├── general/
│   ├── http/
│   ├── dns/
│   └── fulltext/
└── docs/
    ├── PROJECT_OVERVIEW.md     # High-level architecture and packaging docs
    ├── schema/health.v2.schema.json  # JSON Schema for health.v2.json
    ├── update-log.md           # Human-readable activity ledger
    └── checklist-map.md        # Checklist item → collector mapping
```

### Key Design Principles

- **Stateless execution:** No persistent state, no run locks, no auto-update
- **Collector isolation:** Failures recorded but don't abort the run
- **Health independence:** `lib/health.sh` reads `DATA[]` only; never calls `tool.sh`
- **Type-aware JSON:** Empty → `null`, numeric → unquoted, `true`/`false` → unquoted booleans
- **Zero-trace deployment:** `bootstrap.sh` uses `trap` to guarantee temp directory cleanup on exit, signal, or error
- **Minimal repository:** Only core agent, lib, collectors, and config are tracked. No tool documentation, Docker files, test fixtures, or development scripts.

---

## Dependencies

The Linux agent has no runtime, package manager, database, or web server. It is
pure Bash plus standard Unix tools:

`curl`, `dig`, `openssl`, `awk`, `date`, `find`, `grep`, `sed`, `firewall-cmd`.

**No `git` required.** The agent runs entirely from the downloaded package.

### Build packages for the security modules (STRICT — keep minimal)

**Install CSF / Install Nginx / Install ModSecurity** compile from source and
therefore need a toolchain. They install **exactly these 14 packages**, and
nothing else:

```
gcc  gcc-c++  make  cmake  flex  bison
pcre2-devel  libxml2-devel  yajl-devel
curl-devel  openssl-devel  zlib-devel
libtool  automake
```

`git` is **not** installed. ModSecurity's autotools step only calls
`git describe` to learn a version string and carries on without it; the agent
supplies a tiny PATH shim inside the build tree so the version is still correct
and no `git: command not found` noise appears.

Every `dnf install` in the agent is run with
`--setopt=install_weak_deps=False`.

> **Never** install `doxygen`, `graphviz`, `flatpak`, `pipewire`,
> `xdg-desktop-portal*`, `tracker*`, GTK/X11 libraries, or any `*-fonts`
> package on these servers. **Never** use `dnf groupinstall` or an
> `@`-prefixed group (`@development`, `@Development Tools`, …).

A mail relay renders no documents and opens no windows. An over-broad
transaction once pulled **201 packages / 101 MB** of documentation and desktop
software onto a live server, and most of it failed with `curl (28) Timeout` on
slow mirrors. If a `dnf` summary shows more than ~30 packages for a build step,
stop and inspect it.

To verify a transaction before committing to it:

```bash
dnf install --setopt=install_weak_deps=False --assumeno <packages>
```

---

## Checklist

Reports reference IceWarp CheckList **v1.14** (the internal edition label
configured by `CHECKLIST_VERSION`). The item set is the v1.12-mapped
113-item checklist; the v1.14 label changes the report metadata, not the
collector coverage. See `docs/checklist-map.md` for item-by-item mapping between
checklist entries and collectors.

---

## Configuration

Default settings work out of the box. Optional customization:

`config/agent.conf`: General settings (timeouts, monitor URL), the report
`CHECKLIST_VERSION` label.

`config/icewarp.conf`: IceWarp-specific paths.

`MAIL_HOSTNAME` and `MAIL_PUBLIC_IP` are required for DNS collectors
(PTR, SPF, DKIM, DMARC).

`IW_SSL_CERT` is the path to the SSL certificate.

---

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

---

## Documentation

- `docs/PROJECT_OVERVIEW.md`: High-level architecture and packaging/bootstrap mechanism
- `docs/checklist-map.md`: Mapping between checklist items and collectors
- `docs/update-log.md`: Human-readable activity ledger
- `docs/schema/health.v2.schema.json`: JSON Schema for health.v2.json
- `CLAUDE.md`: Guidance for AI agents and maintainers working in the repository
- `CHANGELOG.md`: Linux version history

---

## License

See the LICENSE file.