# IceWarp Health Agent — Handoff (State of the Union)

> **Read this together with `CLAUDE.md` and `README.md`.** If the context was
> compacted, those three files are the source of truth — read them before acting.

**Last updated:** 2026-11-21
**Branch:** `step3/health-registry-rollup`
**Version:** `0.8.1` (VERSION is frozen; never edit it without an explicit order)

---

## 1. What this project is

- `bootstrap.sh` — a single-file, 100% Bash TUI (~6,300 lines) that installs,
  configures and secures IceWarp on Rocky/RHEL 9. Deployed with `curl | bash`.
  Alternate screen, ANSI TrueColor, SGR mouse, FIFO streaming of child output,
  double-buffered rendering (one `printf` per frame).
- `agent.sh` + `lib/` + `collectors/` — the health-check engine (81 collectors,
  14 categories, 9 executive pillars, native PDF/JSON writers).
- Everything the operator touches lives under `/root/agent/`
  (`ssl/`, `backups/`, `*.log`, `*.tar.gz` — all preserved by `cleanup()`).

## 2. Current state — COMPLETE and verified

| Area | Status | Evidence |
|------|--------|----------|
| `cleanup()` preserves `ssl/`, `backups/`, `*.tar.gz`, `*.log` | done | 10/10 assertions |
| SSL: LE + self-signed IP + self-signed custom domain | done | 31/31, 20/20 |
| SSL: two-stage menu (type → target IceWarp/Nginx) | done | 38/38 |
| Nginx: vhost, dynamic ModSecurity module, `load_module` at line 1 | done | 21/21 |
| Nginx: linker path for `libmodsecurity.so.3` | done | 11/11 |
| Nginx: cache dirs (`/var/cache/nginx/*`) before `nginx -t` | done | 17/17 |
| Nginx: start vs. reload + verify 80 **and** 443 | done | 25/25 |
| Nginx: auto-repair of the `conf.d` include | done | 21/21 |
| Nginx: TLS termination, TLS backend on `127.0.0.1:443` | done | 31/31 |
| Proxy-first: Web ports moved to 0.0.0.0:8080/8443, global bind cleared | done | 29/29 |
| Proxy-first: firewall rejects 8080/8443, loopback still reaches IceWarp | done | 29/29 |
| Proxy-first: menu-8 gating (cancel, listener gate, firewall stop) | done | 19/19 |
| Nginx: no wildcard port-80 listener (`_nginx_sanitize_port80`) | done | 31/31 |
| Proxy-first: five-listener verification with socket owner | done | 19/19 |
| ModSecurity: build cache, force rebuild, library verification | done | 18/18 |
| ModSecurity: v3-only `modsec.conf` (no v2 directives) | done | 22/22 |
| ModSecurity: RPC bypass `id:1000002` | done | 38/38 |
| Web Ports: property discovery + never leaves IceWarp stopped | done | 42/42 |
| Packages: 14-package `SEC_BUILD_PKGS`, weak deps off | done | 8/8 |

**Total: 300+ assertions across isolated harnesses. Every fix was proven by
reproducing the live failure first.**

## 3. Architecture decisions that must not be undone

1. **Menu order** — 8 Configure Proxy-First Mode → 9 Install ModSecurity →
   10 Configure ModSecurity → 11 Install Nginx → 12 Configure Nginx →
   13 Install CSF → 14 Configure CSF → 15 Configure RPC Access. The dependencies
   are real: the connector must exist before Nginx is configured,
   `modsec.conf` before the vhost, and IceWarp must own `127.0.0.1:80/443` before
   Nginx takes the primary address.
2. **Nginx terminates TLS for the client and proxies to IceWarp's TLS port on
   loopback** — `https://127.0.0.1:443` in proxy-first mode (menu 8), which is
   what makes IceWarp stop emitting `:8443` in its absolute URLs. The
   `http://127.0.0.1:8080` backend is only the *fallback* used when nothing is
   listening on IceWarp's TLS port, and it is announced with a `[WARN]`.
   `proxy_ssl_verify off` is required (IceWarp's certificate is self-signed) and
   the hop never leaves loopback. Do not "simplify" this back to plain HTTP: it
   is the CORS/301 fix itself.
3. **No HSTS** — deliberate; it cannot be quickly undone if a cert breaks.
4. **Certificate priority** — domain cert > IP cert > temporary.
5. **`load_module` on line 1** of `nginx.conf`, absolute path, idempotent.
   `/etc/ld.so.conf.d/modsecurity.conf` must list the library directory.
6. **`sec_bundle_dir()` is a function, not a variable** — `TMP_DIR` is empty at
   load time, and a top-level assignment froze into `/sec-sources` once.
7. **`sec_libmodsec_installed` trusts only the `.so` file**, never headers or
   `ldconfig` — headers left by a partial install caused a permanent skip.
8. **Never leave IceWarp stopped** — web-port switching verifies writes first,
   and a safety net restarts the server on any failure path.
9. **Minimal packages** — 14 packages, `--setopt=install_weak_deps=False`, no
   `doxygen`/`graphviz`/`@group`. A stray group install once pulled 201 packages.
10. **IceWarp's Web service is NOT bound to loopback.** It stays on
    `0.0.0.0:8080` and `0.0.0.0:8443`, Nginx owns the public 80/443, and the
    **firewall** rejects 8080/8443 from outside. Every attempt to move the bind
    failed: `webserver.dat` was ignored, the global bind took mail with it, and
    `servicebind.dat` is not honoured for mail on this build. Do not reintroduce
    any of them.
11. **The global `BindIPAddress` stays EMPTY.** Empty means "all addresses" for
    every service, which is what keeps mail reachable; the Web service is kept
    private by the firewall instead.

## 4. Known operational caveats

- **Deployment must be binary mode.** A stale/truncated `bootstrap.sh` on the
  server caused several "the fix did nothing" reports. Always verify:
  `wc -l bootstrap.sh` and `sha256sum bootstrap.sh` on the server.
- The vhost points at IceWarp's **TLS** port on loopback (`8443` after menu 8),
  so *Configure Proxy-First Mode* must run before *Configure Nginx*. The vhost
  still writes and verifies correctly on its own; running 12 first only means
  the backend falls back to `http://…:8080` with a warning.
- A leftover `/sec-sources` at the filesystem root may exist from the old bug;
  `rm -rf /sec-sources` once — nothing references it any more.
- `CLAUDE.md` contains legacy duplicated section numbers (two `## 4`, two
  `## 5`) from earlier revisions. Content is correct; numbering is cosmetic.

## 5. Not done / possible next steps

- **Menu 8 has not completed successfully on a live server yet — three bind
  mechanisms failed there:**
  1. `webserver.dat` with `<IP>127.0.0.1</IP>` — ignored;
  2. the same file with the console's own `<IPNOT>1</IPNOT>` pair — also ignored;
  3. global `BindIPAddress=127.0.0.1` + `servicebind.dat` for mail — the global
     bind applied to mail anyway, with lowercase and capitalised names. The
     guard restored mail both times, so no outage.

  The current implementation stops fighting the bind: IceWarp keeps
  `0.0.0.0:8080/8443`, Nginx takes 80/443, and **iptables drops 8080/8443**
  from outside. **This has not been run on a live server either** — it is the
  next action.
- **The `:8443` URL question is still open.** IceWarp builds absolute URLs from
  its Web port. If the login page still carries `:8443` after menu 8, the fix is
  the console's SmartDiscover *Public URL* fields — the agent prints the exact
  path but cannot set it. The run's `_url_port_check` line says which case you
  are in.
- CSF is installed and configured but not yet exercised on a live server in this
  session.
- ModSecurity is written in **DetectionOnly**; switching `SecRuleEngine` to `On`
  after reviewing `modsecurity_audit.log` is an operator decision, not automated.
- Nginx vhost has no per-location exclusions for `/admin/` yet (documented as an
  option in `icewarp-exclusions.conf`, not applied).
- No automated test suite lives in the repo (repository minimalism rule), so all
  verification harnesses were temporary and are gone by design.

## 6. Files

| File | Purpose |
|------|---------|
| `bootstrap.sh` | The TUI — install, SSL, security stack. **The main deliverable.** |
| `agent.sh`, `lib/`, `collectors/` | Health-check engine |
| `VERSION` | Frozen at `0.8.1` |
| `CLAUDE.md` | Rules, architecture, post-compaction protocol |
| `README.md` | Operator documentation |
| `CHANGELOG.md` | Every change, with the live symptom it fixed |
| `handoff.md` | This file |
