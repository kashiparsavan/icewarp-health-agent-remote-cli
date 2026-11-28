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
| 9 | **Proxy-First Mode** | Frees port 80 from Nginx's wildcard listener, stops Nginx, **clears** the global `BindIPAddress` (empty keeps mail on every address), moves `Control_Port/SSLPort` to 8080/8443 through `tool.sh`, restarts only the control service, then **iptables-drops 8080/8443 from non-loopback**. One action: rewire, restart, verify |
| 10 | **Install ModSecurity** | Builds `libmodsecurity` into `/usr/local/lib` and the Nginx connector into `/usr/src/ModSecurity-nginx` |
| 11 | **Configure ModSecurity** | Writes `/etc/nginx/modsec/modsec.conf` + the OWASP CRS |
| 12 | **Install Nginx** | Builds Nginx with `--add-dynamic-module=/usr/src/ModSecurity-nginx`, then saves `ngx_http_modsecurity_module.so` to `/etc/nginx/modules/` |
| 13 | **Configure Nginx** | Writes the vhost, loads the module, registers the library with the linker, creates cache dirs, verifies 80 + 443 |
| 14 | **Install CSF** | Firewall, installed last so the build is not interrupted |
| 15 | **Configure CSF** | Applies the IceWarp port set. Only 22/80/443 are public — the console shares 443 |
| 16 | **RPC Access** | Sets the console DNS name and the trusted admin networks from the TUI, then reapplies Nginx |

Both **Install ModSecurity** and **Install Nginx** ask
`Do you want to force a complete clean rebuild? (y/N)` when the component already
exists — answer `y` to discard stale artefacts when a previous run half-finished.

### Reverse proxy — how traffic flows

```
client ──443/TLS──▶ nginx stream ──▶ nginx http (127.0.0.1:10443) ──8443/TLS──▶ IceWarp 127.0.0.1:8443
```

Nginx accepts TLS on 443 and proxies to IceWarp's **TLS** port on loopback, so
IceWarp sees a secure request and stops redirecting to its own HTTPS origin:

```nginx
upstream icewarp_backend { server 127.0.0.1:8443; keepalive 32; }

location / {
    proxy_pass https://icewarp_backend;
    proxy_ssl_verify off;            # IceWarp's cert is self-signed
    proxy_http_version 1.1;

    proxy_hide_header Strict-Transport-Security;   # see the HSTS note below

proxy_set_header Host              $host;          # NO port - the :8443 fix
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $remote_addr;      # never $proxy_add_*; see M1
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host  $host;             # no port
    proxy_set_header X-Forwarded-Port  443;

    proxy_set_header Upgrade    $http_upgrade;
    proxy_set_header Connection "upgrade";
}
```

That is the entire proxy. There is deliberately **no `sub_filter`, no
`proxy_redirect` and no synthetic `Access-Control-*` header**: those rewrite
IceWarp's own responses, fight its single-page app and duplicate the CORS
handling IceWarp already does itself.

### Which certificate the webmail vhost uses

The vhost serves the **webmail hostname**, and the browser validates the
certificate against *that* name. Using the console's certificate here gives every
visitor a name-mismatch error, and if the name has ever been HSTS-pinned they
cannot click through at all. So **Configure Nginx** resolves the name first:

1. `WEBMAIL_DOMAIN` (environment override), else
2. `/root/agent/config/webmail_domain.conf`, else
3. a domain certificate already in the store that is **not** the console name.

Then it picks the certificate for that name:

| Priority | Path |
|----------|------|
| 1 | `/root/agent/ssl/self-signed-<webmail-host>/` (Manage SSL option 3) |
| 2 | `/root/agent/ssl/<webmail-host>/` (Let's Encrypt) |
| 3 | any other non-console domain certificate — **warns**: name mismatch |
| 4 | an IP certificate — **warns** |
| 5 | a temporary certificate in `/etc/nginx/ssl/` — **warns** |

If no certificate exists for the webmail name, the run ends with:

```
[FAIL] No certificate for the webmail host 'icemail2.example.com'.
[WARN] Serving 'console.example.com' instead - browsers will
[WARN] report a certificate name mismatch on icemail2.example.com.
[INFO] Run 'Manage SSL' -> '3) Self-Signed (Custom Domain)'
[INFO] with 'icemail2.example.com', then run this again.
```

The console certificate is **never** used for the webmail vhost.

### HSTS: clear it in the browser or the page stays blocked

IceWarp can send `Strict-Transport-Security`. The proxy now strips it
(`proxy_hide_header`), but a browser that already cached an HSTS policy for the
hostname will refuse to let you accept a self-signed certificate — the page
stays blocked no matter how correct Nginx is. Clear the cached policy first:

1. Open `chrome://net-internals/#hsts`
2. Under **Delete domain security policies**, enter the webmail hostname
   (e.g. `icemail2.example.com`)
3. Click **Delete**
4. Reload the page in a fresh tab

Firefox keeps the same state in `SiteSecurityServiceState.txt` in the profile
directory.

### Mandatory IceWarp console settings

Two settings must be correct, and the agent cannot change either of them.
**12) Configure Nginx** prints both at the end of its run.

| Where | Setting | Required value |
|-------|---------|----------------|
| WebAdmin → **Web Service → General** | **Require SSL** | **CHECKED** in proxy-first mode (the proxy speaks TLS to `127.0.0.1:8443`). **UNCHECKED** only for the `http://…:8080` fallback, where leaving it on makes IceWarp 301-redirect every request. The run prints the correct one for the backend it actually chose. |
| **System → Advanced → General** | **Use X-Forwarded-For IP address** | **CHECKED.** Otherwise IceWarp logs and blocks the loopback address instead of the real client. |
| WebAdmin → **Domains & Accounts → <domain> → SmartDiscover** | Public URL fields | Must be `https://<webmail-host>/webmail/` etc. — **no port, no other host**. Values pinned to `https://old-host:8443/...` are the original cause of the redirect loops; proxy-first mode makes IceWarp emit them correctly, but it cannot rewrite a stale one. |

**Configure Nginx** proxies to `https://127.0.0.1:8443` in proxy-first mode. When
nothing is listening on IceWarp's TLS port it falls back to
`http://127.0.0.1:8080` instead of writing a vhost that answers 502
everywhere — with a warning, and with the "Require SSL" advice flipped to match.

The generated vhost (`/etc/nginx/conf.d/icewarp.conf`) always contains valid
absolute paths to `ssl_certificate` and `ssl_certificate_key`, so Nginx never
fails to start because of a missing file.

### Remote Console — SNI routing, no extra port

The IceWarp Remote Console uses a raw TCP protocol that an HTTP reverse proxy
cannot carry. Instead of opening a second public port, everything enters on
**443** and Nginx's `stream` layer routes it after reading the TLS ClientHello:

```
                 ┌─ trusted IP + console SNI ─▶ 127.0.0.1:10444 ─▶ IceWarp 127.0.0.1:8443
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

**Port 80 redirects with `308`, not `301`** — a 301 lets the browser turn a POST
into a bodiless GET, which breaks API calls that arrive over `http://`. Nothing
else is injected into that redirect.

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

Both values are set from the menu — **16) RPC Access (Domain & IPs)**
prompts for the console name and for the allowed addresses (comma separated),
saves them and reapplies Nginx. Nothing has to be edited by hand.

| File | Contents |
|------|----------|
| `/root/agent/config/console_sni.conf` | The console DNS name, e.g. `console.example.com`. While it is still the placeholder the agent prints a warning and no connection matches the console branch. |
| `/root/agent/config/admin_ips.conf` | Trusted admin networks, one CIDR or IP per line. Defaults to `127.0.0.1` and `192.168.75.0/24`. Lines starting with `#` are ignored, and a hand-edited comma-separated list still parses. |

Leave either prompt empty to keep the current value. The console hostname also
needs a DNS record pointing at the server.

The console client opens TLS on 443 with the console name; the proxy forwards the
**still-encrypted** stream to IceWarp's own TLS listener — `127.0.0.1:8443` in
proxy-first mode. Nginx never decrypts it and nothing downgrades it to HTTP, so
Remote Config is HTTPS end to end — the loopback hop is TCP only, the TLS session
is browser ↔ IceWarp.

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
| **2) Self-Signed Certificate (Server IP)** | The server has no domain, or you only need the IP — **never on a cloud instance, see below** | `/root/agent/ssl/self-signed-<IP>/` |
| **3) Self-Signed Certificate (Custom Domain)** | You have a domain but **cannot validate it for Let's Encrypt** — no DNS access, no spare host, no cPanel to add a temporary record | `/root/agent/ssl/self-signed-<domain>/` |

Option 3 asks for a fully qualified name (e.g. `mail.example.com`), then
generates a 3650-day RSA-2048 certificate with that name as the **CN** and as a
**subjectAltName** (`DNS:<domain>`), so current browsers and mail clients
accept it after you trust it. The full path to both files is printed when it
finishes.

> **Cloud servers (AWS, Azure, GCP): use option 3, not option 2.**
>
> On a cloud instance `hostname -I` reports the **private VPC address**
> (`172.31.x.x`, `10.x.x.x`), which no browser outside that network can reach.
> Option 2 detects a private address, prints a prominent warning, and then
> certifies the **public** address instead — discovered through the default
> route or an echo service — keeping the private address as a second SAN. That
> still only helps people who browse `https://<public-ip>`. Anyone typing
> `https://icemail3.designhost.ir` needs a certificate whose SAN is that name,
> so the correct choice on a cloud server is **option 3) Custom Domain** (or
> option 1) Let's Encrypt when you control the DNS).

After choosing the certificate type, pick **where it should be installed**:

| Target | What happens |
|--------|--------------|
| **1) For IceWarp** | Files land in `/root/agent/ssl/<name>/` and you install them manually in the IceWarp console |
| **2) For Nginx** | The same files are written, then `/etc/nginx/conf.d/icewarp.conf` is repointed at them, `nginx -t` runs, and Nginx reloads. The previous vhost is backed up and restored automatically if the test fails |

**Configure Nginx** terminates TLS for the client and proxies to IceWarp's own
TLS port on loopback (`127.0.0.1:8443` in proxy-first mode), so the vhost needs a
certificate the browser accepts for the **webmail** name — and the loopback hop
needs none, since IceWarp's self-signed certificate is not verified there. When
picking a certificate the precedence is fixed and deliberate:

1. `self-signed-<webmail-host>/` — option 3
2. `<webmail-host>/` — Let's Encrypt
3. any other non-console **domain** certificate, preferring one whose
   `subjectAltName` actually covers the webmail host
4. an **IP** certificate (public address preferred over a private one), with
   `[WARN] Only an IP certificate ... exists` and the exact fix to print
5. a temporary self-signed certificate

A domain certificate always wins over an IP certificate, because a browser that
asked for a hostname can never accept a certificate naming an address. The
chosen certificate's SAN is verified with `openssl x509` before the vhost is
written; a name it does not cover is reported instead of being served silently.
No HSTS header is written.

Since a self-signed certificate is not signed by a public CA, every client must
still accept it once — but it encrypts traffic and needs no DNS or HTTP
validation, which is exactly what makes it the fallback when Let's Encrypt is
not possible.

#### No SmartDiscover pre-flight (removed, deliberately)

Earlier versions read `<base href="...">` out of IceWarp's own pages before
writing a vhost and aborted when the URL carried a port. **That check is gone**
— `check_icewarp_smartdiscover` and its three helpers were deleted, and
`SMARTDISCOVER_CHECK` no longer exists.

It was a workaround for a symptom. IceWarp builds its absolute URLs from the
port its Web service is bound to, so on `8443` every URL carried `:8443`
and no proxy could hide it. Menu 9 leaves that service on 8443 by necessity,
the URLs are port-free **by construction** — so the pre-flight could only ever
produce false positives, or block a box that was already correct.

The operator-facing part of that knowledge survives where it belongs: the
**SmartDiscover public URL fields** are still listed among the console
prerequisites below, because they are set once by hand and are not something the
agent can read or write.

#### Proxy-first mode

**Menu 9 → 1)** performs the whole transition in the only order that works:

1. **Nginx's port-80 listener is made address-qualified** so the rest of the
   step can reason about ``<private>:80`` rather than a wildcard;
2. **Nginx is stopped**, releasing the primary address on 80/443;
3. **IceWarp's Web ports move to 8080/8443** and the **global bind is cleared** —
   empty is the state that lets every service listen on every address, so mail
   stays reachable;
4. IceWarp is restarted **only if the ports actually changed**;
5. **iptables drops 8080 and 8443** from outside (`! -i lo`), while leaving
   loopback alone so Nginx can still reach IceWarp;
6. the vhost and the stream block are written and Nginx is started, proxying to
   ``https://127.0.0.1:8443``;
7. the layout is verified, and the run reports whether IceWarp still writes
   ``:8443`` into its absolute URLs.

| | Before | After |
|---|---|---|
| IceWarp Web | ``*:8080``, ``*:8443`` | ``0.0.0.0:8080``, **``0.0.0.0:8443``** (firewall-closed) |
| Nginx | ``*:80``, ``*:443`` | **private IP** ``:80``, ``:443`` |
| Webmail upstream | ``127.0.0.1:8443`` | **``127.0.0.1:8443``** (loopback, never public) |
| Mail | ``0.0.0.0:25/143/993`` | unchanged |

```nginx
stream {
    server {
        listen <PRIVATE_IP>:443;        # not 0.0.0.0, not 127.0.0.1
        ssl_preread on;
        proxy_pass $icewarp_route;
    }
    server {
        listen 127.0.0.1:10444 proxy_protocol;
        proxy_pass 127.0.0.1:8443;      # console hop
    }
}

upstream icewarp_backend { server 127.0.0.1:8443; keepalive 32; }
server {
    listen 127.0.0.1:10443 ssl proxy_protocol;
    location / { proxy_pass https://icewarp_backend; proxy_ssl_verify off; }
}
```

The private address is detected with ``ip route get 1.1.1.1`` (the default-route
source). That is the address the provider delivers traffic to; a cloud public
IPv4 is 1:1 NAT and cannot be bound.

**Notes**

- **1–2 minutes of downtime** are expected: IceWarp and Nginx both restart.
- **Why IceWarp is not bound to loopback.** Three approaches were tried on live
  servers. ``webserver.dat` ``<IP>`` (with and without ``<IPNOT>``) was
  ignored. The global ``C_System_Services_BindIPAddress=127.0.0.1`` **was**
  honoured — and took mail with it, because it applies to every service.
  ``servicebind.dat`` did not override mail, with lowercase or capitalised
  names. IceWarp therefore keeps every address at 8080/8443, and the
  **firewall** is what keeps those ports private.
- **The global ``BindIPAddress` must stay empty.** Anything specific drags
  SMTP/IMAP/POP3 to that address; that is how 25/143/993 once ended up on
  loopback. Menu 9 clears it (empty, ``0.0.0.0`` fallback) and verifies the
  read-back.
- **The firewall is iptables, and the script installs it.** firewalld is not
  installed on these servers; neither is iptables on a minimal Rocky 9. Menu 9
  therefore handles the dependency itself: it installs `iptables-nft` and
  `iptables-services` (`iptables-services` carries only the unit files, so the
  service package alone leaves no binary), prints
  `[INFO] iptables is not installed. Installing iptables-nft iptables-services...`, then
  drops the two ports:

  ```bash
  iptables -A INPUT -p tcp --dport 8080 ! -i lo -j DROP
  iptables -A INPUT -p tcp --dport 8443 ! -i lo -j DROP
  iptables-save > /etc/sysconfig/iptables
  systemctl enable --now iptables
  ```

  `! -i lo` is what keeps Nginx working, because it connects over loopback.
  `enable --now` runs only after a successful save — it performs an
  `iptables-restore`, so after a failed save it would reload an older file and
  wipe the rules just added. CSF is deliberately not involved: it is installed
  later from menu 14, and CSF builds its ruleset from the live configuration.
- **The rule is verified, not assumed.**
  `iptables -L INPUT -v -n | grep -E 'dpt:(8080|8443)'` must show both ports;
  otherwise the run prints `[FAIL] Rules missing.` /
  `[FAIL] Firewall rules failed to apply. IceWarp is exposed.` and stops before
  Nginx.
- **The `:8443` URL problem is fixed at the source.** IceWarp builds absolute
  URLs from the Host header it receives, and the vhost sends `Host $host` —
  the bare hostname, no port — so IceWarp never writes one. That is why there
  is no `sub_filter`, no `proxy_redirect` and no gzip workaround. If a port
  still appears (SmartDiscover public URLs override the header), the run warns
  with the exact console path; it cannot set that field itself.
- **The layout is verified strictly:**

  | listener | owner |
  |---|---|
  | ``<private>`:80 and :443 | Nginx |
  | ``0.0.0.0`:8080 and :8443 | IceWarp control |
  | ``0.0.0.0`:25, :143, :993 | mail |

  The owning process is checked, not just the address: "something is
  listening" is not "the right process is listening". Any mismatch prints
  ``[FAIL]`` per listener plus the full ``ss -lntp``, never a warning.
- **Another interface on 8080/8443** would collide with IceWarp. Nothing else
  should use those two ports on this host.
- **Cancel is safe.** Answer anything but ``y`` to the prompt (or let it time
  out) and menu 9 stops, leaving IceWarp untouched and starting Nginx again
  with its previous vhost.
- If ``webserver.dat``, ``servicebind.dat`` or ``<IP>`` appear in older notes,
  they are history: none of them is read or written any more.

### Port handling — menu 9 only

There is no separate "Switch Web Ports" item any more: **Configure Proxy-First
Mode** owns the ports, because moving them without moving the bind is what broke
the server. It sets `Control_Port=80` and `Control_SSLPort=443` through
`tool.sh` and leaves it on every address; see *Proxy-first mode* above.

The property **names** are still discovered at runtime, because they are not the
same in every build — IceWarp 14.3 has no `c_server_http_port`. The agent
reads the names this build actually publishes (convention:
`c_config_services_<service>_port` / `_sslport`) and then **reads the value
back after writing it**, so a rejected write is detected instead of assumed.

Safety rules built into the step:

| Situation | What happens |
|-----------|--------------|
| No port property found | `[FAIL]`, nothing is written, **IceWarp keeps running** |
| IceWarp rejects the value | `[FAIL]`, the change is reported, **IceWarp keeps running** |
| Ports written and verified | IceWarp is stopped, the config is edited, then started on 80/443 |
| Start fails or is slow | Start retried, then a last-resort guard starts IceWarp again |
| `servicebind.dat` cannot be written | `[FAIL]` **before** the global bind is touched — mail is never left unprotected |
| Mail ends up on loopback | backup table restored, global bind cleared, restart, `[FAIL]` |
| IceWarp comes back on `0.0.0.0` | `[FAIL]`, and **Nginx is not started**, so nothing collides |

The agent never returns to the menu with IceWarp stopped: whether the step
succeeds or fails, the mail server is running when the action finishes.

---

## Security hardening

An external audit found five issues; all are fixed and are now invariants.

| ID | Was | Now |
|----|-----|-----|
| C1 | Download credentials and the bundle password hardcoded in the script | `AGENT_DL_USER` / `AGENT_DL_PASS` / `AGENT_BUNDLE_PASS`, or one prompt |
| H1 | `--no-check-certificate`, no checksums, a 401 page accepted as a tarball | TLS enforced, HTML rejected, magic-number + SHA-256 verified |
| H3 | Engine switched to DetectionOnly for **any** `multipart/form-data` | Scoped to the upload endpoints, engine never disabled |
| H4 | `ctl:ruleEngine=Off` for **any** `/RPC/` | Chained with `@ipMatch` on trusted console sources, DetectionOnly only |
| M1 | `X-Forwarded-For` appended to a client-supplied header | `$remote_addr` only; `X-Forwarded-Host` is `$host` |

**Credentials.** Nothing is stored in the repository. Supply them before an
authenticated download:

```bash
export AGENT_DL_USER='...'
export AGENT_DL_PASS='...'
export AGENT_BUNDLE_PASS='...'   # only if the security bundle is password-protected
```

If they are unset the script asks once, reading from the **terminal** — not
stdin, because under `curl | bash` stdin is the script itself — and caches the
answer in `/root/agent/.sys_profile` (`root:root`, mode `600`, created under
`umask 077`). Later runs reuse it without asking.

The cache is a plaintext file with strict permissions, not an encrypted blob: a
key shipped in a public repository would be obfuscation, not protection, so the
file mode is the control. Delete the file to force a re-prompt. It is parsed
line by line and never sourced, so a tampered cache cannot execute anything.

**Downloads are verified.** Every archive is checked four ways: TLS is valid,
the body is not an HTML/XML page, the magic number matches the extension, and
the SHA-256 matches `SEC_SHA256`. A mismatch deletes the file and prints both
hashes. `AGENT_INSECURE_TLS=1` disables TLS verification and says so — use it
only for a mirror whose chain the host genuinely cannot verify.

**The WAF stays on.** Exclusions are scoped: uploads keep every rule except the
ones that misread business files, and `/RPC/` is relaxed only for sources listed
in `${AGENT_DIR}/config/admin_ips.conf`. If the Remote Console suddenly gets
403s, check that file first — the list is generated from it, not hardcoded.

**The internal Web ports are closed.** `iptables` drops 8080/8443 from every
interface except loopback, so Nginx keeps working and nobody else can reach
IceWarp's origin directly. The script installs `iptables-nft` and
`iptables-services` itself, saves the rules to `/etc/sysconfig/iptables`, and
runs `systemctl enable --now iptables`.

**A Web port change does not touch mail.** Menu 9 restarts only the control
service and verifies SMTP/POP3 PIDs are unchanged.
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

`curl`, `dig`, `openssl`, `awk`, `date`, `find`, `grep`, `sed`, `iptables`.

**No `git` required.** The agent runs entirely from the downloaded package.

### Build packages for the security modules (STRICT — keep minimal)

**Install CSF / Install Nginx / Install ModSecurity** compile from source and
therefore need a toolchain. They install **exactly these 15 packages**, and
nothing else:

```
gcc  gcc-c++  make  cmake  flex  bison
pcre2-devel  libxml2-devel  yajl-devel
curl-devel  openssl-devel  zlib-devel
libtool  autoconf  automake
```

`git` is **not** installed. ModSecurity's autotools step only calls
`git describe` to learn a version string and carries on without it; the agent
supplies a tiny PATH shim inside the build tree so the version is still correct
and no `git: command not found` noise appears.

Every `dnf install` in the agent is run with
`--setopt=install_weak_deps=False`.

**The install is verified before the build starts.** The agent runs the
transaction, keeps its output in `/root/agent/tmp/dnf-build-tools.log`, checks
the exit status, and then confirms each tool resolves:

```
[OK] All build tools verified: gcc g++ make libtoolize autoconf automake
```

If any is still missing it aborts the menu item — instead of letting `configure`
fail minutes later with `C++ compiler cannot create executables` — and prints the
dnf log tail plus the exact command to fix it.

**The transaction cannot prompt and cannot hang.** `-y` alone is not enough on a
minimal Rocky install: a GPG key import still asks, and a prompt inside the TUI
either blocks the menu or dies as exit `130`. The agent therefore always runs:

```bash
timeout 300 dnf install -y \
    --setopt=assumeyes=1 --setopt=install_weak_deps=False \
    <packages> </dev/null
```

- `</dev/null` — a prompt gets EOF and fails at once instead of waiting.
- `timeout 300` — a slow or unreachable mirror cannot wedge the menu; a timeout
  is reported as `exit 124` with the log tail.
- `exit 130` is reported as an interruption, with the cause.

Recovery is automatic but **announced**: a package conflict retries once with
`--allowerasing` (may replace a package), and a GPG/key problem retries once with
`--nogpgcheck` (signatures not verified for that transaction). Both warnings name
what changed. To skip signature checking from the first attempt, set
`DNF_NOGPGCHECK=1`; the preferred fix is importing the repository key:

```bash
rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-*
```

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