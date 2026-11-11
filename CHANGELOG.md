# Changelog - IceWarp Health Agent

All notable changes to this project are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added

- **15) Configure RPC Access (Domain & IPs) — the console settings are now
  editable in the TUI.** `action_configure_rpc` shows the current console DNS
  name and the current trusted networks, prompts for both (the address list is
  comma separated), validates them — a hostname must look like a hostname and
  every address must look like an IP or CIDR — writes
  `${AGENT_DIR}/config/console_sni.conf` and
  `${AGENT_DIR}/config/admin_ips.conf`, then calls `configure_nginx` and prints
  `[OK] RPC Access updated. Console Domain: <domain>, Allowed IPs: <ips>`.
  Empty input keeps the current value; Esc cancels without writing anything.
  No RPC setting has to be created or edited by hand any more.
  The menu grows to 17 items (System is 15, Quit is 16).

- **Comma-separated address lists are accepted everywhere.** `admin_ips_save`
  splits on commas and writes one CIDR per line, and `admin_ips_list` also
  splits on commas, so a hand-edited file keeps working.

- **Remote Console routed by SNI on port 443 — no extra public port.**
  The console speaks raw TCP, which the HTTP core cannot proxy. Instead of
  exposing a second port, `install_nginx` now builds with
  `--with-stream --with-stream_ssl_module --with-stream_ssl_preread_module` and
  `configure_nginx` writes a managed `stream { }` block into `nginx.conf`
  (between `# BEGIN/END IceWarp RPC stream` markers, replaced in place):

  ```nginx
  geo $admin_ip { default 0; 127.0.0.1 1; 192.168.75.0/24 1; }
  map "$admin_ip:$ssl_preread_server_name" $icewarp_route {
      "1:<console-sni>" 127.0.0.1:10444;
      default           127.0.0.1:10443;
  }
  server { listen 443; ssl_preread on; proxy_protocol on; proxy_pass $icewarp_route; }
  server { listen 127.0.0.1:10444 proxy_protocol; proxy_pass 127.0.0.1:8443; }
  ```

  The console branch requires **both** a trusted source IP (geo) and the
  dedicated console SNI; everything else goes to the webmail path. The console
  hop consumes the PROXY header and forwards raw TCP to IceWarp 8443.

- **Webmail keeps full ModSecurity coverage.** The vhost no longer listens on
  public 443; it is `listen 127.0.0.1:10443 ssl proxy_protocol;` with
  `set_real_ip_from 127.0.0.1; real_ip_header proxy_protocol;`. Every webmail
  request therefore still passes through the HTTP server and the CRS, with the
  genuine client IP restored from the PROXY protocol.

- **`${AGENT_DIR}/config/` is persistent.** It holds `console_sni.conf` (the
  console DNS name) and `admin_ips.conf` (trusted admin networks), so
  `cleanup()` was extended with `! -name 'config'`.

- **ModSecurity cannot inspect the console hop** (Layer-7 WAF vs Layer-4
  stream). Documented in the generated `stream` block, in `configure_nginx`, in
  `CLAUDE.md` §5.6 and in the README; the console is protected instead by the
  IP allow-list, the SNI match, the firewall and IceWarp's own authentication.

### Removed

- **The dedicated 4443 listener and its port setting.** The old
  `15) Set Custom Port for RemoteConfig`, `action_set_rpc_port`, the
  `rpc_port.conf` / `rpc_allow.conf` files and the CSF port injection are gone.
  Only 22/80/443 stay public. Menu slot 15 now hosts
  **Configure RPC Access (Domain & IPs)** instead.

### Fixed

- **CORS errors and asset 301s: the backend is now reached over TLS.**
  Proxying to IceWarp's plain `8080` port made every request look insecure, so
  IceWarp answered `/admin/apicss`, `/admin/framework.js` and `icewarpapi/` with
  **301s to its own `https://…:8443` origin**. Those cross-origin redirects are
  what the browser reported as a CORS failure, and no amount of response
  rewriting fixes a redirect the client follows to another origin. The upstream
  is now `https://127.0.0.1:8443` with `proxy_ssl_verify off` (self-signed cert,
  loopback-only hop) and `proxy_ssl_session_reuse on`. The `sub_filter` and
  `proxy_redirect` rules stay as a second line of defence.

- **Automatic fallback if 8443 is not listening.** Writing an HTTPS upstream
  against a dead port would answer 502 for every page, so `configure_nginx`
  probes the port first, warns, and falls back to `http://127.0.0.1:8080`
  (pointing at *Switch Web Ports*) instead of breaking the proxy.

- **`X-Forwarded-Ssl` and `X-Url-Scheme` removed.** They only existed to
  compensate for IceWarp believing the request was insecure; now that the hop
  speaks real TLS they are dead weight. `X-Forwarded-Proto` is kept, because it
  still tells IceWarp the *client's* scheme for URL generation.

- **IceWarp's ports are single-sourced.** `IW_HTTP_PORT` / `IW_HTTPS_PORT` drive
  the upstream, the console stream hop and the messages, so they cannot drift.

- **CORS failure on `icewarpapi/` and 301s on every asset through the proxy.**
  IceWarp emits absolute URLs containing its **internal ports**
  (`http://host:8080`, `https://host:8443`). The previous blind
  `sub_filter 'http://' 'https://'` turned `http://host:8080` into
  `https://host:8080` — TLS on a plain-HTTP port — and left `:8443` URLs intact.
  The browser treated both as a foreign origin, so the API call failed with a
  CORS error and assets bounced through 301s. `configure_nginx` now replaces the
  whole origin, port included, for the public host, `127.0.0.1`, `localhost` and
  the server's LAN address, and rewrites redirects with
  `proxy_redirect ~^https?://[^/]+:(8080|8443)(/.*)$ $scheme://$host$1`.

- **`Host` no longer carries a port.** It is `$host` instead of `$http_host`, so
  IceWarp stops echoing a port into the URLs it generates; `X-Forwarded-Host`
  follows the same rule.

- **White login page / mixed content: `http://` URLs behind a TLS terminator.**
  The page returned `<base href="http://host/-.._._.--.._1791471461/admin/">`,
  and the browser blocked the resulting assets and API calls. Covered by the same
  origin rewrite, plus `http://$host/` for scheme-only leftovers.

- **`X-Forwarded-Port` advertised the internal port.** It was `$server_port`,
  which is **10443** on the webmail listener after the SNI refactor, so IceWarp
  built absolute URLs containing `:10443`. It is now the literal `443`.

- **`sub_filter` needs `--with-http_sub_module`** (not built by default) and an
  uncompressed body. The flag is now in the `./configure` line,
  `_nginx_has_sub_module` probes for it (an older binary degrades to a comment
  instead of failing `nginx -t`), and `Accept-Encoding ""` is sent upstream -
  without it the rewrite silently does nothing. `sub_filter_types` is limited to
  text types rather than `*`, so binary payloads cannot be corrupted.
  `WEBMAIL_HTTP_REWRITE=0` disables the whole rewrite.

- **Remote Config documented as end-to-end HTTPS.** The console hop forwards the
  still-encrypted stream to IceWarp's TLS listener on 8443; nginx never decrypts
  and never downgrades it, so the console cannot fall back to HTTP. Comments in
  the generated stream block and in the docs now state this explicitly.

- **Nginx could be left with a configuration it refused to load.** The generated
  `stream` block was written straight into the live `nginx.conf` and only then
  tested. On failure the broken file stayed on disk: nginx kept serving from
  memory, but the next reload, restart or reboot failed to start - taking 443,
  every site and the console offline. `_nginx_write_stream_routing` now backs up
  `nginx.conf` first and `_nginx_stream_rollback` restores it when `nginx -t`
  rejects the new content, reporting whether the restored file is itself valid.

- **A PROXY-protocol mismatch is rejected before it reaches nginx.**
  `_nginx_stream_matrix_ok` verifies that 443's sender setting and the two
  receivers (10443 webmail, 10444 console) agree, and fails with the exact
  mismatch (`webmail listener expects a PROXY header that 443 never sends`)
  instead of writing a config that breaks every connection. Both sides are
  generated from the single `STREAM_USE_PROXY_PROTOCOL` switch (default `1`) so
  they cannot drift apart.

- **Port 443 held by IceWarp is reported clearly.** If another process still
  owns 443 (`Switch Web Ports` not run), nginx cannot bind and silently fails to
  start, which looks like `ERR_CONNECTION_TIMED_OUT` on everything.
  `configure_nginx` now names the holding process and points at menu 8.

- **`proxy_connect_timeout 10s` on the public 443 listener**, so a dead backend
  fails fast instead of waiting out the 60-second default.

### Changed

- **Manage SSL is now a two-stage flow.** After choosing the certificate type,
  a second prompt asks **where to install it**:

  ```
  Where do you want to install this certificate?
  1) For IceWarp (Save to /root/agent/ssl/ for manual installation)
  2) For Nginx (Auto-install and configure Nginx)
  3) Cancel
  ```

  *For IceWarp* keeps the previous behaviour: files under
  `${AGENT_DIR}/ssl/<name>/`, then
  `[OK] Certificate saved to … You can manually install it in IceWarp.`
  *For Nginx* additionally repoints `/etc/nginx/conf.d/icewarp.conf` at the new
  certificate, runs `nginx -t`, and reloads — or starts Nginx if it is not
  running. The vhost is backed up first and restored if the test fails.

- **Nginx terminates TLS; the IceWarp hop is plain HTTP.** The upstream is now
  `127.0.0.1:8080` with `proxy_pass http://icewarp_backend;`, and
  `proxy_ssl_verify` is gone (there is no TLS on that hop any more). The
  `X-Forwarded-Port $server_port` header was added alongside the existing
  `Host`/`X-Real-IP`/`X-Forwarded-For`/`X-Forwarded-Proto`/`Upgrade`/
  `Connection "upgrade"` set, so Remote Console redirects and WebSocket
  upgrades stay on the public port.

- **Certificate selection prefers a domain certificate over an IP one.**
  Every directory in the store is classified: a name that is an IPv4 address is
  only a fallback, anything else (Let's Encrypt `<domain>/` or
  `self-signed-<domain>/`) wins. With no domain certificate it prints
  `[WARN] No Custom Domain certificate found. Using IP certificate.`

### Added

- **ModSecurity bypass for the RPC endpoint.** `icewarp-exclusions.conf` now
  contains
  `SecRule REQUEST_URI "@beginsWith /RPC/" "id:1000002,phase:1,pass,nolog,ctl:ruleEngine=Off"`,
  so Remote Console / webmail RPC traffic is not misread as an attack (and is
  not broken by the CRS). Every other URI stays protected.

### Fixed

- **`modsec.conf` no longer contains directives that ModSecurity v3 removed.**
  `nginx -t` aborted with
  `"modsecurity_rules_file" Directive Rules error. File: /etc/nginx/modsec/modsec.conf.
  Line: 7 ... As of ModSecurity version 3.0, SecRequestBodyInMemoryLimit is no long...`.
  `SecRequestBodyInMemoryLimit` and `SecRequestBodyNoFilesLimit` are v2-only and
  are gone from the generated file. The header now lists explicit v3 limits:
  `SecRequestBodyLimit` + `SecRequestBodyLimitAction` and
  `SecResponseBodyLimit` + `SecResponseBodyLimitAction`. As a safety net,
  **both** `configure_modsecurity` and `configure_nginx` strip any of those
  deprecated directives from an existing `modsec.conf` before running
  `nginx -t`, so a file left by an older build cannot block the action. The
  failure path of `configure_modsecurity` now also prints the nginx error-log
  tail.

- **The ModSecurity module's own dependency is now resolvable at `dlopen()`.**
  With the module in place, `nginx -t` failed with
  `dlopen() "/etc/nginx/modules/ngx_http_modsecurity_module.so" failed`
  `(libmodsecurity.so.3: cannot open shared object file: No such file or directory)`.
  The module links against a library that ModSecurity installs into
  `/usr/local/lib`, and that directory is not on the default loader path. A new
  `_nginx_ensure_modsec_ldpath()` writes
  `/etc/ld.so.conf.d/modsecurity.conf` listing the directories that actually
  hold `libmodsecurity.so*`, runs `ldconfig`, and verifies the result with
  `ldconfig -p | grep libmodsecurity`. It runs **before** `nginx -t` (the config
  test is what loads the module), is idempotent, and aborts the action with a
  clear message when the library still cannot be resolved — which also catches a
  genuinely missing library and points at *Install ModSecurity* (force rebuild).

### Added

- **Force rebuild prompts for ModSecurity and Nginx.** Lingering artefacts can
  make a cache look satisfied while the server is unusable. Both actions now
  offer `Do you want to force a complete clean rebuild? (y/N)` when the
  component is already installed. `y` removes the stale pieces:
  `install_modsecurity` deletes `/usr/local/lib{,64}/libmodsecurity.so*`,
  `/usr/local/include/modsecurity`, `/usr/src/ModSecurity-nginx` and the build
  tree; `install_nginx` deletes the compiled
  `/etc/nginx/modules/ngx_http_modsecurity_module.so` and the Nginx build tree.

### Fixed

- **A missing `libmodsecurity.so` can no longer be mistaken for a finished
  build.** The live run reported `lib exists? NO, connector exists? YES`: an
  earlier `make install` had left `/usr/local/include/modsecurity` behind, the
  cache check trusted the headers, and the build that would have produced the
  library was skipped forever. `sec_libmodsec_installed` now checks **only** for
  the shared library (`/usr/local/lib{,64}/libmodsecurity.so*`,
  `/usr/lib{,64}/libmodsecurity.so*`); headers and `ldconfig` are no longer
  accepted as proof.

- **`install_modsecurity` builds with an explicit prefix and verifies the
  result.** `./configure` is now called as
  `--prefix=/usr/local --with-yajl`, and after `make install && ldconfig` the
  action requires the library to exist, failing with
  `[FAIL] ModSecurity built, but libmodsecurity.so is MISSING!` plus the
  directory listings instead of reporting a false success.

- **ModSecurity detection uses hardcoded absolute paths and reports first.**
  The live run skipped the module while the connector was demonstrably present,
  and the promised `[DEBUG]` line never appeared — the check was buried behind
  earlier steps and depended on `${NGINX_SRC_DIR}` / `${NGINX_PREFIX}`. The
  detection now runs as the **first thing** in `install_nginx`, before the port
  check, and uses fixed paths only:
  `/usr/local/lib{,64}/libmodsecurity.so*` and
  `/usr/src/ModSecurity-nginx/config`. It always prints
  `[DEBUG] Check: lib exists? YES/NO, connector exists? YES/NO`, so the state is
  visible in the pane regardless of what happens later. When both exist the
  module flag is forced on with
  `--add-dynamic-module=/usr/src/ModSecurity-nginx`. When it cannot be enabled,
  the reason is printed together with `ls -la /usr/src/ModSecurity-nginx/` and
  `ls -la /usr/local/lib/ | grep modsecurity`, so the missing file is identified
  instead of guessed. Helper defaults (`${NGINX_SRC_DIR:-/usr/src}`,
  `${NGINX_PREFIX:-/etc/nginx}`) were also hardened so an unset variable can no
  longer redirect a path.

- **No more false "Ports 80/443 are in use by IceWarp".** `install_nginx` only
  checked whether the ports were open, so a re-run — where nginx itself owns
  them — produced a bogus warning and an unnecessary prompt. The listener is now
  identified from `ss -lntp` (`users:(("name",pid=…))`); nginx is ignored, and
  the warning names the real owner (`[WARN] Ports 80/443 are in use by: control`)
  only when a non-nginx process holds 80 or 443.

- **ModSecurity builds are cached.** Compiling libmodsecurity takes ~15 minutes.
  `install_modsecurity` now returns immediately with
  `[OK] ModSecurity and Connector are already built - skipping compilation.`
  when libmodsecurity is installed **and**
  `${NGINX_SRC_DIR}/ModSecurity-nginx/config` exists — before touching `dnf` or
  the compiler.

- **`install_nginx` no longer decides "Built without ModSecurity" when the
  module is available.** `sec_libmodsec_installed` only trusted
  `/usr/local/include` and `ldconfig -p`; ModSecurity installs its library into
  `/usr/local/lib`, which is not always indexed by ldconfig, so the check
  returned NO and the dynamic module was skipped. The helper now looks for
  `libmodsecurity.so*` in `/usr/local/lib{,64}` and `/usr/lib{,64}` first, then
  the headers, then `ldconfig -p`. `install_nginx` also logs
  `[DEBUG] Checking ModSecurity: connector exists? YES/NO, lib exists? YES/NO`
  and explains each branch, so a skip is never silent.

- **The compiled module is always preserved and verified.** When
  `--add-dynamic-module` is used, `ngx_http_modsecurity_module.so` is located in
  the build tree, copied to `${NGINX_PREFIX}/modules/`, verified with `-f`, and
  only then is the build tree removed. If it cannot be found, the install fails
  instead of reporting success.

- **Nginx cache directories are created before `nginx -t`.** The live run failed

- **Nginx cache directories are created before `nginx -t`.** The live run failed
  with
  `nginx: [emerg] mkdir() "/var/cache/nginx/icewarp" failed (2: No such file or directory)`.
  `proxy_cache_path` is validated at config-test time, and nginx only creates the
  final path component, so a missing parent aborts the test. A new
  `_nginx_ensure_cache_dirs()` creates `${NGINX_CACHE_BASE}` plus `icewarp`,
  `client_temp`, `proxy_temp`, `fastcgi_temp`, `uwsgi_temp` and `scgi_temp`,
  hands them to the worker account (`nginx`/`www-data`/`wwwrun`) and runs before
  `nginx -t`. The vhost's `proxy_cache_path` now uses the same
  `${NGINX_CACHE_BASE}` variable, so the two can never drift apart.

- **`install_nginx` verifies the dynamic module really was produced.** When the
  build was configured with `--add-dynamic-module`, the agent now requires
  `ngx_http_modsecurity_module.so` to appear and be copied to
  `${NGINX_PREFIX}/modules/` before the build tree is deleted; otherwise the
  install fails with `[FAIL] The ModSecurity module was requested but was not
  built.` instead of reporting success and leaving *Configure Nginx* to fail
  later with `unknown directive modsecurity`. A build that deliberately skips
  the module (no connector / no libmodsecurity) still succeeds and says so.

- **`modsecurity` is no longer an unknown directive.** After the conf.d include
  was repaired, `nginx -t` failed with
  `nginx: [emerg] unknown directive "modsecurity" in .../icewarp.conf:29`,
  because ModSecurity is built as a **dynamic** module and nothing loaded it.
  The old code looked for the `.so` only at `${NGINX_PREFIX}/modules/` and
  inserted a *relative* `load_module` with `sed`, silently skipping when the
  file was not there.
  - `_nginx_find_modsec_module()` searches the prefix, `/usr/lib64/nginx`,
    `/usr/lib/nginx`, `/usr/local/nginx`, `/etc/nginx/modules` and the build
    tree, then copies the module to `${NGINX_PREFIX}/modules/` so the path is
    stable.
  - `_nginx_ensure_load_module()` writes an **absolute**
    `load_module <path>;` as the **first line** of `nginx.conf` (the only valid
    context), rewrites an existing line that points elsewhere, and never adds a
    second copy.
  - `install_nginx` now copies `objs/ngx_http_modsecurity_module.so` to the
    stable path **before** deleting the build tree — previously the module was
    thrown away unless `make install` happened to place it.
  - If no module can be found, the vhost is written **without** any
    `modsecurity` directive (so nginx still starts) and a clear warning tells
    the operator to run *Install ModSecurity* then *Install Nginx* again. When
    the module exists but `modsec.conf` does not, only `modsecurity on;` is
    emitted and a warning asks for *Configure ModSecurity*.

- **Configure Nginx no longer reports success while nothing is listening.**
  Three defects from a live server:
  - The action ran `nginx -s reload` unconditionally. With nginx dead and a
    stale `/run/nginx.pid` this failed with `invalid PID number ""`, the exit
    code was ignored, and `[OK] Nginx is serving 80/443` was still printed. A
    new `nginx_running` helper checks the process (and validates the pid inside
    the file) and the action now **starts** a dead nginx, reloads a live one,
    and captures the exit code.
  - Nothing verified the listeners. The agent now polls `ss` for up to 8s and
    prints the success line **only** when both 80 and 443 are listening. If 443
    is missing it prints
    `[FAIL] Nginx started, but port 443 is not listening. Check the SSL config.`
    along with the certificate path in use, whether it is readable, its size,
    and the tail of `/var/log/nginx/error.log`.
  - The certificate was never validated. The action now refuses to touch nginx
    when the cert/key are missing, empty or unreadable, or when a path contains
    whitespace (the vhost writes them unquoted).
  - The vhost is also checked for being actually loaded: `nginx -T` must contain
    `icewarp_backend`. If it does not, the agent now **repairs `nginx.conf`
    automatically** — a source-built nginx ships a minimal config with no
    `conf.d` include, so the vhost would never load and nginx would serve its
    built-in default server on 80 with nothing on 443. The include is inserted
    directly after the `http {` line by awk (no sed escaping pitfalls), a
    timestamped backup of `nginx.conf` is kept, `nginx -t` is re-run, and the
    vhost is re-checked. The step is idempotent: an existing conf.d include
    means no second line is ever added, and a config without an `http {` block
    is left untouched with a clear error.

- **Connector now lands at `<dir>/config`, which is what nginx checks.** The
  Nginx build still failed with `./configure: error: no
  /usr/src/ModSecurity-nginx/config was found`. The tarball ships the connector
  one level down (`ModSecurity-nginx-1.0.4/config`), and moving that directory
  was not reliable. A new `sec_install_connector()` extracts into a scratch dir,
  locates the root by the `config` file itself, and **copies its contents** into
  `/usr/src/ModSecurity-nginx/` so `config` sits exactly where nginx looks. It
  verifies `<target>/config` before returning success and is idempotent.
  `install_nginx` calls the same helper, so a missing connector is repaired at
  build time rather than failing the build.

- **Nginx is never configured with `--add-dynamic-module` unless it can work.**
  The flag is now added only when `<dir>/config` exists **and**
  libmodsecurity is installed (`sec_libmodsec_installed`). Previously a missing
  library made the module fail to compile and lost the whole Nginx build;
  now the module is skipped with an explicit warning instead.

- **`git` is not installed; a build-tree shim answers the version query.**
  ModSecurity's autotools step calls `git describe` and falls back to a default
  when git is absent — git is not a build dependency, so adding it to the
  package list was wrong. The agent now writes a two-line `git` shim into the
  build directory, prepends it to `PATH` for the compile step only, and answers
  the version query with `v3.0.17`. No package is added to the server, the
  `git: command not found` noise is gone, and the shim disappears with the
  build tree. The package list is back to the strict 14.

- **Temporary build trees are removed on success and on failure.**
  `modsecurity-build`, `nginx-build` and `modsec-nginx-build` are deleted on
  every exit path, so a retry always starts from a clean tree.

- **Security menu reordered to the correct build sequence.** The menu now reads:
  `8) Switch Web Ports (Nginx Prep)`, `9) Install ModSecurity`,
  `10) Configure ModSecurity`, `11) Install Nginx`, `12) Configure Nginx`,
  `13) Install CSF`, `14) Configure CSF`. Labels, actions and the
  "run Switch Web Ports first" hint (now item 8) were updated together.

- **ModSecurity source root is detected, not assumed.** `install_modsecurity`
  failed on a live server with `Unexpected modsecurity-v3.0.17.tar.gz layout`.
  The folder inside a release tarball is not fixed (`ModSecurity-3.0.17/`,
  `modsecurity-3.0.17/`, or a flat archive with the files at the root), so a
  name pattern could not be relied on. `sec_find_srcdir()` locates the
  source root by looking for a marker file (`build.sh` for libmodsecurity,
  `config` for the connector), case-insensitively and at any depth, so every
  packaging variant works. On failure the agent prints the archive contents
  instead of a bare message.

- **Build packages reduced to a strict minimum.** The prerequisite step now
  installs exactly 14 packages from the `SEC_BUILD_PKGS` array —
  `gcc gcc-c++ make cmake flex bison pcre2-devel libxml2-devel yajl-devel
  curl-devel openssl-devel zlib-devel libtool automake` — with
  `--setopt=install_weak_deps=False`. `doxygen` is gone (documentation only,
  never needed to build the module), and `make`, `cmake`, `gcc` and `libtool`,
  which the build actually requires, are now explicit. Previously a single
  transaction pulled 201 packages / 101 MB including `graphviz`, `flatpak`,
  `pipewire`, `xdg-desktop-portal-gtk`, `tracker-miners` and dozens of fonts,
  most of which timed out on slow mirrors.

### Added

- **§5.5 Minimal Packages** in `CLAUDE.md` and a matching section in
  `README.md`: `doxygen`, `graphviz`, GUI/desktop libraries, fonts and any
  `dnf groupinstall` are forbidden; `--setopt=install_weak_deps=False` is
  mandatory; the 14-package list is the only allowed build set, and `git` is
  explicitly excluded.

- **Self-signed certificate for a custom domain.** `Manage SSL` now offers
  `3) Self-Signed Certificate (Custom Domain)` for servers whose domain cannot
  be validated for Let's Encrypt — no DNS access, no spare host to point at the
  server, no cPanel to add a temporary record. It prompts for a fully qualified
  name, rejects an empty or dot-less value, and writes a 3650-day RSA-2048
  certificate to `/root/agent/ssl/self-signed-<domain>/`. The domain is used as
  both CN and `subjectAltName` (`DNS:<domain>`), because current browsers and
  mail clients ignore CN when a SAN is present. The full paths to
  `fullchain.pem` and `privkey.pem` are printed when it finishes.

- **Dynamic SSL path resolution in Configure Nginx.** The Nginx vhost no longer
  hardcodes `/etc/letsencrypt/live/CHANGEME/`. Instead:
  - If a self-signed certificate exists in `/root/agent/ssl/self-signed-*/`,
    it is used automatically.
  - If none exists, a temporary self-signed certificate is generated in
    `/etc/nginx/ssl/` so that `nginx -t` passes and Nginx starts immediately.
    A `[WARN]` message reminds the operator to replace it with a real certificate.

### Changed

- The SSL sub-menu has four entries — Let's Encrypt (Domain), Self-Signed
  (Server IP), Self-Signed (Custom Domain), Cancel — so Cancel moved from `3`
  to `4`.

### Fixed

- **Switch Web Ports no longer strands the mail server.** Two defects reported
  from a live IceWarp 14.3.0.13 server:
  - `c_server_http_port` / `c_server_https_port` do not exist in 14.3, so both
    writes were rejected (`Property not found`, `Settings save problem`) and the
    switch silently did nothing. The property names are now discovered at
    runtime from the names the build publishes — the documented convention is
    `c_config_services_<service>_port` / `_sslport` — and each write is verified
    by reading the value back.
  - The services were cycled even when the writes failed, leaving the server on
    the old ports after an outage. IceWarp is now stopped only after both values
    are written **and** confirmed; on any failure nothing is stopped, any partial
    write is rolled back, and a `[FAIL]` line states that IceWarp is still
    running. After a successful write the agent stops IceWarp, waits, confirms
    80/443 are free, starts it again, waits for the listener, and reports
    `[OK] IceWarp is back online on ports 8080/8443.`
  - A last-resort guard starts IceWarp again if the restart leaves no listener,
    and a server already on the target ports is never restarted at all.

## [0.8.1] - 2026-11-08

### Added

- **Categorized TUI menu:** sections for Installation, Configuration and
  Reporting, numbered 1-10 with `0) Quit`. Section headers are not selectable.
- **New placeholder modules:** Check Firewall / Ports, Manage Services and
  Backup / Restore (menu wiring complete, logic to follow).
- **Interactive-install scrolling:** PageUp / PageDown scroll the output pane
  during an interactive install; answering a prompt snaps back to the newest
  line. An `[↓ Scroll down for more]` hint marks a pane scrolled away from the tail.
- **Exact remote version:** the real IceWarp build is read from the package
  header with a 2 MB ranged fetch instead of trusting the file name.
- **Single-line download progress bar** rendered in place by the TUI; the
  downloader itself is silent and logs to `bootstrap.log`.
- **Cached installer:** a previously downloaded `.tar.gz` is reused, so a
  repeat install does not fetch 650 MB again.
- **Persistent workdir:** all downloads, extractions and logs live in
  `/root/agent/`.

### Fixed

- **Arrow keys in the installer:** escape sequences are now forwarded whole, so
  `[B` can no longer be typed into the installer's stdin.
- **Mouse escape flooding:** mouse reporting is disabled for every action and
  restored afterwards; keystrokes are drained before and after a child runs.
- **Ctrl+C / Esc during a run** aborts the child and returns to the menu
  instead of killing the TUI.
- **Version false positive:** a mirror shipping `14.3.0` is no longer treated
  as older than the official `14.3.0.13` (branch-level comparison).
- **Truncated downloads:** `.tmp` + atomic rename, plus stale `.tmp` cleanup.
- **`tar: command not found`** on a restricted PATH (absolute `tar` resolution).

### Changed

- **Bumped version to 0.8.1:** Updated `VERSION`, `bootstrap.sh`, `CLAUDE.md`,
  `README.md`, and this changelog.

## [0.8.0] - 2026-11-02

### Changed

- **Removed all git and auto-update logic:** The agent is now fully stateless and
  self-contained. Deleted `lib/auto_update.sh` and `docs/auto-update.md`.
  Removed `--check-update`, `--no-auto-update`, `--auto-update`, `--no-update`
  flags and all `AUTO_UPDATE_*` configuration variables from `config/agent.conf`.
  Removed run lock mechanism (`acquire_lock`/`release_lock` in `lib/common.sh`).
- **Updated README for hosted deployment:** Added curl-based deployment examples
  showing how to run the agent directly from a web host without git.
- **Bumped version to 0.8.0:** Updated `VERSION`, `config/agent.conf`,
  `CLAUDE.md`, `README.md`, and this changelog.

### Removed

- Auto-update mechanism (git fast-forward, validation, re-exec)
- Run lock files (`.agent.lock`, `.agent.update.lock`)
- Auto-update log (`logs/auto_update.log`)
- Configuration: `AUTO_UPDATE_ENABLED`, `AUTO_UPDATE_REMOTE`, `AUTO_UPDATE_BRANCH`,
  `AUTO_UPDATE_TIMEOUT`, `AUTO_UPDATE_EXPECTED_ORIGIN`, `AUTO_UPDATE_REEXEC`,
  `AUTO_UPDATE_VALIDATE`, `AUTO_UPDATE_LOG`, `AUTO_UPDATE_LOG_MAX_BYTES`

## [0.7.3] - 2026-11-02

### Changed

- Release housekeeping for the fixes landed on the `step3/health-registry-rollup`
  branch: `VERSION`, `config/agent.conf` (`AGENT_VERSION=0.7.3`), `README.md`,
  `CLAUDE.md` and the changelog/version footer all moved to 0.7.3.

### Fixed

- Technical report (`lib/pdf.sh`): a stray ellipsis character in
  `_pdf_text_trunc` (`${TXT:0:$((MAXC…-1))}`) made the truncation arithmetic
  invalid, so `build_pdf` aborted with
  `syntax error: invalid arithmetic operator (error token is "…-1")` and
  `output/report.pdf` was never written. Restored to `${TXT:0:$((MAXCHARS-1))}`.

## [0.7.2] - 2026-11-02

### Added

- `tests/` directory with a Bash test harness (`tests/run_tests.sh`, `tests/lib.sh`)
  and four cases: `test_norm_date.sh`, `test_json_value.sh`,
  `test_health_rollup.sh` and a fake-SMTP `test_starttls.sh`. Fixtures live in
  `tests/fixtures/`; `tests/render_pdfs.sh` renders both PDFs from a sample
  `DATA[]` and extracts their text for inspection.
- `## 2. CODE STYLE` and `## 3. TDD & Testing Conventions` sections to
  `CLAUDE.md` (write the failing test first, then the minimal fix).

### Fixed

- **Health label map (lib/health.sh).** `HEALTH_LABEL_MAP` now maps
  `Password Policy Min Length` -> `password_policy`, `Use TLS/SSL (Secured
  Delivery)` and `Enable SSL/TLS` -> `tls_delivery`, and `RBL Valli Check (is
  our IP blacklisted)` -> `threat.rbl`. Four rolled-up checks had no checklist
  row, so a pillar could read red with no matching action card: `config/checklist.conf.pdf`
  now carries a `Health Evaluation` section with rows for `login_blocking`,
  `threat.antispam`, `threat.antivirus` and `dnsbl_zones`, so every rolled-up
  check appears in both PDFs.
- **Management report counters (lib/management_report.sh).** `build_management_pdf`
  now resets `_MR_TOTAL/_MR_PASS/_MR_WARN/_MR_CRIT/_MR_INFO/_MR_NA/_MR_SECTION_ORDER/
  _MR_ISSUES/MR_SEC*` at its start, so a second build no longer doubles the
  counts. The overall posture and the cover score agree with
  `health.summary.overall` (worst of the health summary and the row-derived
  result); skipped and INFO-only checks are excluded from the denominator and
  never inflate the score.
- **Text fitting (lib/pdf.sh, lib/management_report.sh).** The technical report's
  Value column is truncated at 46 chars instead of 34, so
  `Total(KB)=<n> / Available KB=<n>` and `Total(GB)=<n> / Used %=<n>` are never
  cut. Health-summary notes are no longer clipped at 100 chars: they wrap to
  two lines, the note baseline is raised and the row height is 28 pt so
  descenders are not hidden. `_mr_paragraph` appends `...` when `MAXLINES`
  truncates and never emits an empty first line for an over-long word; cover
  company/domain text is truncated; the rounding remainder of both status bars
  is left as the muted track background instead of being painted as the
  INFO/N-A colour.
- **STARTTLS (collectors/dns/starttls.sh).** The probe now targets the real mail
  host: `MAIL_HOSTNAME`, else the primary domain's MX target, never just the
  first mail domain. The loopback message is cleaned so `lib/health.sh` no
  longer duplicates `via host:port`; `smtp.starttls.target` carries the host
  only. `smtp.starttls.trust` is recorded as `not verified` (the probe never
  validates the chain), and the health message states it. A wall-clock budget
  (`STARTTLS_BUDGET`, default 45 s) caps the total probe time.
- **Health semantics (lib/health.sh).** `2FA`, `watchdog.interval` and
  `monitor.enabled` now report `skip`/`warn` (never an invented `pass` or a
  default threshold) when their data key is missing. Disk de-duplication is
  deterministic: mounts are iterated in sorted key order and every comparison
  is numeric-safe. `health.summary.total_checks` counts evaluated registry
  checks (not pillars); `health.summary.areas_assessed` is the pillar count, so
  the cover text "X checks run across Y areas" is truthful.
- **JSON (lib/json.sh).** `*.name`, `*.company`, `*.technician` and license
  identifier keys are forced to strings (a numeric company name can no longer
  become a number). `health.json` is now written atomically via temp file +
  `mv`, so a monitoring client reading mid-write never sees a truncated
  document.
- **Transport (lib/transport.sh).** `MONITOR_URL` and the payload file are
  validated before posting; curl now takes `--connect-timeout`/`--max-time`,
  `--retry`/`--retry-delay` and an optional `MONITOR_AUTH_HEADER`; the curl
  exit status is returned and logged by `agent.sh`. Documented decision: the
  posted payload is `health.json` (v1, the flat namespace) - `health.v2.json`
  is a separate artifact and is not posted.

## [0.7.1] - 2026-11-01

Findings from the first live run of 0.7.0.

### Fixed

- STARTTLS false-fail (`collectors/dns/starttls.sh`): the probe ran once, with the shared 5 s
  `TOOL_TIMEOUT`, and counted success only when openssl printed "Verify return code". A server that
  answers slowly (IceWarp does reverse-DNS/DNSBL lookups per connection) was killed before the TLS
  summary and reported as "STARTTLS failed". Reproduced with a fake SMTP server whose banner is
  delayed 7 s: old collector `false`, new collector `true`. Now: `STARTTLS_TIMEOUT` (15 s), one retry,
  loopback fallback, strict success criterion (a real TLS session) and recorded evidence
  (`smtp.starttls.via|protocol|attempts|error|target`). `mail.starttls` is `warn` when only loopback
  works and `fail` with the reason when nothing works.
- PDF rows `Check PTR/SPF/DKIM/DMARC/TLS and Start TLS/Test DNS Lookup` and `Set customers-stat`
  now read their health check, so they agree with the Mail Flow / Access pillars (the PTR row said
  PASS while the pillar said WARN). New detail-only check `access.stats_mailbox`.
- Management report: Key Signals show the four worst pillars (the fixed set hid the CRITICAL
  Database pillar); Priority/Recommended actions list Action before Review.
- Swap collector: the 7-day journal search matched dracut/initramfs file listings
  (`swap.target`, `swapoff`) and reported "swap usage detected" on every kernel update. It now only
  matches real swap events; swap in use is still CRITICAL by policy.
- `disk.overall` carries the lowest free MB as `actual`; certificate display is
  `40 days left (2026-12-11)` instead of a truncated openssl date; messages read "Antispam
  definitions: 5 days old"; `smtp.hide_server_version` is a number, not the string `"1"`.

## [0.7.0] - 2026-11-01

### Added

- Check registry in `lib/health.sh` (`HEALTH_REGISTRY_LINES`): one line per check
  (`id|pillar|title|flags`). Pillar roll-ups, `health.v2.json` `checks[]` and the PDF/management
  statuses all derive from it. Every check now carries `pillar`, `expected` and `actual`.
- New checks (new `health.<id>.result|message` keys; no existing key removed or renamed):
  `intrusion.unknown_user|relay_denied|rset|spam_score|failed_logins` (expected 5/5/5/9.00/5),
  `tls.certificate`, `access.2fa`, `mail.spf|dkim|dmarc|ptr|starttls|dns_lookup`,
  `threat.antispam|antivirus|rbl|cyren`, `smtp.threads`, `swap`, `database.platform`.
- `health_row_for_label` / `health_kind` / `health_meta` / `health_rolled_up` helpers.
  `_health_set` takes a 6th `display` argument (the PDF "Value" column).

### Changed

- **Roll-ups now include** intrusion 50/360 and the five other intrusion rules (threat),
  IMAP/POP3 running (mail_flow), per-service watchdogs SMTP/POP3-IMAP/IM-VoIP/GroupWare
  (monitoring), Directory Cache schedule and database platform (database), TLS certificate expiry
  (tls) and 2FA bypass (access). They affect the pillar status, overall score and both PDFs.
  `backup.db.accounts|as|gw`, `backup.db.cache`, `smtp.threads` and `swap` stay detail-only.
- The PDF renderers no longer hold thresholds. `lib/pdf.sh` and `lib/management_report.sh` read the
  health result for every mapped checklist row (`HEALTH_LABEL_MAP`); about 650 lines of duplicated
  threshold code were removed. Where they disagreed, `health.sh` now wins: backup age (warn 2-6,
  critical 7+ days; PDFs used 4), certificate (30 days is now warn), CPU (System Monitor
  threshold on 1-min load; PDFs used 15-min load 50/95%), disk (System Monitor free-space floor;
  PDFs used 80/95% used), the management report no longer ignores `critical` in grouped rows.
- Pillar `database` is now `database.platform` + `directory_cache`; the check formerly named
  `database` is `database.platform` (the pillar keeps the id `database`).
- Directory Cache: an empty schedule value is "not scheduled" (CRITICAL), confirmed on the lab server.
- `collectors/security/dnsbl_zones.sh` reads `rbl.dat` first (IceWarp's DNSBL server list).
- `config/checklist.conf.pdf` notes no longer quote thresholds.
- `VERSION` and `config/agent.conf` bumped to `0.7.0`.

### Added

- `lib/json_v2.sh` / `build_json_v2`: writes `output/health.v2.json`, a versioned envelope
  (`schema_version`, `agent`, `server` with a persistent `.server_id` UUID, `run`, `summary`
  with the nine pillars and a 0-100 score, `checks[]` with `expected`/`actual`, typed `metrics`,
  and the unchanged flat keys under `raw`). Schema: `docs/schema/health.v2.schema.json`.
  `health.json` (v1) keeps its key set. Status vocabulary in v2: `ok|warn|crit|unknown`.
- `_health_set` accepts optional `expected` and `actual` arguments (used by the intrusion and
  password-policy checks); they only feed v2 and never enter `DATA[]`.
- New keys: `security.dnsbl.zones.source`, `directory_cache.schedule_source`.

### Changed

- JSON coercion (`lib/json.sh`) is strict: `007`/`00123` and numbers over 15 digits are strings
  (they were emitted as invalid JSON numbers), the literal `null` becomes JSON `null`, control
  characters are stripped, and `*version`/`*.ip`/`*.domain`/`*.hostname`/`*.host` keys are always
  strings (`general.os.version` `9.8` -> `"9.8"`, `icewarp.antispam.update_version` is always a string).
- `health.backup.db.cache.result` is `pass` (optional feature) instead of `info`.

### Fixed

- DNSBL zones: the collector read guessed `C_*` properties that do not exist, so every server
  reported "No DNSBL zones configured". It now scans the IceWarp config files for known zones and
  records the source; `health.sh` says "could not be read" when no config file is readable.
- Directory Cache schedule was always empty (single-field `awk` parse of a multi-field Schedule
  value). It is now read whole via `display`, then `get`, then the config files.

### Security

- DSN passwords are redacted at collection time (`redact_dsn`): `database.connection_string_raw`,
  `directory_cache.connection_string` and all `backup.db.*.target_dsn` now show
  `db;user;***;host;type;flag`. `lib/json.sh` re-applies the redaction to any key matching
  `*dsn*|*connection_string*` as a safety net. Real MySQL installs previously exposed the
  password in `health.json`, both PDFs and the monitoring POST.

### Fixed

- Date parsing: IceWarp `D-M-YY` strings (e.g. `27-10-26`) were fed to `date -d`, which read
  them as year 2027 / 2005 / 0009, producing false passes (future date) or false failures
  (thousands of days old). New shared `norm_date` / `_days_ago` in `lib/common.sh` (ISO, `D-M-YY`
  and `M/D/YYYY`); the three duplicate `_days_ago` copies are removed. Unparseable dates now
  give `warn`, never `0`/`999`.
- `icewarp.antispam.last_update` and `icewarp.antivirus.last_update` are now ISO `YYYY-MM-DD`
  (empty when never updated); the original string is kept in `*.last_update_raw`.
- `database.type` was `unknown` for MySQL DSNs whose host carries a port
  (`127.0.0.1:3306`), which also raised a false `health.database` warning.

### Added

- `tool.v14.3.0.13.help`, the IceWarp 14.3.0.13 Linux `APIConst.pas` API
  reference. The supplied Linux file is byte-identical to the Linux 14.3.0.12
  reference; no Linux API keys changed.
- `docs/api-update-v14.3.0.12-to-14.3.0.13.md` with the Linux comparison,
  Windows hash check, and verification commands.

### Changed

- `docs/checklist-coverage.md` now records that the Linux 14.3.0.13 API
  reference is unchanged, so the existing 113-item mapping still applies.
- `docs/api-update-v14.3.0.12-to-14.3.0.13.md` and `windows/README.md` now
  point to the Windows-vs-Linux comparison.

### Added

- `tool.v14.3.0.13.windows.help`, the IceWarp 14.3.0.13 Windows
  `APIConst.pas`. Kept alongside the Linux reference; the two files are not
  byte-identical.
- `docs/api-windows-vs-linux-v14.3.0.13.md` with the Windows-vs-Linux key,
  ID, type, description, and read-only comparison.

### Notes

- The Windows 14.3.0.13 `APIConst.pas` has a different SHA-256 from the Linux
  file. A key-level comparison has since been completed: all Linux keys are
  present on Windows, Windows adds 4 keys, and 2 keys differ in
  capitalization. No collector or checklist changes are required.

## [windows-0.1.0] - 2026-10-26

### Added

- Independent Windows PowerShell 5.1 scaffold under `windows/` with its own
  `VERSION`, PSD1 configuration, logging, IceWarp `tool.exe` wrapper, flat JSON
  output, and collector runner.
- Windows JSON keeps native booleans and numbers and maps empty strings to
  `null`, matching the Linux JSON contract.
- `windows/collectors/General/Version.ps1` as the first sample collector.
- Pester smoke tests with a Pester 3.4/5-compatible runner.
- Windows setup, deployment, and troubleshooting documentation.

### Changed

- Added PowerShell line-ending rules and Windows runtime/config exclusions to
  `.gitattributes` and `.gitignore`.
- Added the Windows platform status and usage section to `README.md`.

### Notes

- The Linux agent and its auto-updater are unchanged. The Windows tree does not
  call `agent.sh` or source anything from the Linux `lib/` directory.
- Windows releases use independent `windows-v*` tags.
- The Windows scaffold is not feature parity: the full checklist, health rules,
  PDF reports, DNS collectors, and automatic updates are not ported yet.

## [0.6.0] - 2026-10-20

### Added

- Modern management report with a soft-cyberpunk dark cover, score arc,
  executive overview, control-area scorecards, stacked status bars, status
  key, management takeaway, and prioritized recommended actions.
- Management report evaluates all 113 checklist items while printing only
  management-level findings and display-friendly action labels.
- Nine-pillar technical Health Summary: Backup & Recovery, Mail Flow & DNS,
  Transport Security, Access & Authentication, Threat Protection, Server
  Resources, OS & Patching, Monitoring & Watchdog, and Database Platform.
- Grouped technical appendix tables. Raw keys are organized by subsystem,
  sorted, and rendered with repeating table headers on page breaks instead of
  a flat key dump.
- Running report name and page numbers on non-cover technical pages.
- `CHECKLIST_VERSION` setting in `config/agent.conf`; both PDFs reference
  IceWarp CheckList v1.14.
- Company fallback to the domain that carries mail when `--company` is omitted.
- Technician default `Parsavan` when `--technician` is omitted.

### Changed

- `VERSION` and `config/agent.conf` bumped to `0.6.0`.
- Technical report cover now shows Mail Domain and the v1.14 checklist label.
- Management distribution bar and legend include informational and N/A
  controls alongside healthy, review, and action; the score is labelled as a
  pass rate of scored controls.
- Technical section headers keep a minimum block of rows together to avoid
  orphan headers and near-empty pages; Collector Status no longer forces a new
  page.
- Appendix values use a darker, higher-contrast gray for small table text.
- README, CLAUDE.md, checklist coverage/map, roadmap, and update log updated
  for the report redesign and v1.14 label.

### Fixed

- Bash `local` initialization failures in management layout helpers under
  `set -u`.
- Management paragraph line-height arithmetic with decimal values.
- Malformed management score-arc stream output that produced literal `\n` and
  invalid path operators.
- Duplicate management cover footer.

### Notes

- v1.14 is an internal IceWarp checklist edition. The item set remains the
  existing v1.12-mapped 113-item set; only the displayed report version changed.
  No item-level v1.14 diff was available in the repository.

## [0.5.0] - 2026-10-19

### Added

- Automatic self-update before every agent invocation. The updater follows
  `origin/main` by default, fast-forwards only, and re-executes the agent so
  the current run uses the new code (`lib/auto_update.sh`).
- `--check-update` to report whether a newer revision is available without
  changing files.
- `--no-auto-update` to skip the update check for one run, and
  `--auto-update` to force a check when disabled in configuration.
- Append-only update audit log at `logs/auto_update.log`, with size-based
  rotation and credential redaction.
- Update lock (`.agent.update.lock`) to prevent concurrent Git operations.
- Normal runs hold `.agent.lock` across the update and re-exec; lock ownership
  is preserved by PID, so a second scheduled run cannot rewrite files under an
  active run.
- Pre-merge guards: checked-out branch, expected origin, clean tracked working
  tree, and fast-forward-only merge.
- Post-update `bash -n` validation of `agent.sh` and all shell scripts. A
  failed revision is automatically reverted to the previous commit.
- `docs/auto-update.md` and `docs/update-log.md` for operating and auditing
  automatic updates.

### Fixed

- Configurator property names now use canonical IceWarp v14.3 `tool.help`
  keys instead of guessed/legacy names. This removes the large number of
  `[SKIP] ... key not found` results during `./agent.sh --config`.
- Configurator key matching is case-insensitive and tolerates leading
  whitespace in `tool.sh display system` output.
- Configurator calls honor `TOOL_TIMEOUT` instead of a hardcoded 5 seconds.

### Changed

- `VERSION` and `config/agent.conf` bumped to `0.5.0`.
- `--no-update` remains a deprecated no-op; use `--no-auto-update` for agent
  updates.
- `maintenance/collectors_validity_checker.sh` disables auto-update during
  validation runs.

## [0.4.0] - 2026-09-23

### Major Overhaul

This release consolidates several months of development work. All main
checklist sections are now fully implemented and evaluated.

### Added

- Management report (`lib/management_report.sh`): non-technical PDF with
  visual status grid.
- License evaluation: uses `c_evalexpirationtime`, `c_licensestatus`, and
  `c_license_type`. Handles On-Premise Evaluation, Perpetual, and SaaS
  and Cloud correctly.
- Backup database checks: 4 separate items (Accounts, AntiSpam,
  GroupWare, Directory Cache).
- Archive Settings section: 5 dedicated items (Active, Directory, IMAP
  integration, Do Not Archive Spam, Backup Deleted Messages).
- Watchdog per-service: 4 individual services (SMTP, POP3/IMAP, IM/VoIP,
  GroupWare) plus main control and interval.
- Swap monitoring: checks swap usage in the last 7 days.
- OS Update time-based thresholds: under 7 days PASS, 7 to 30 days WARN,
  over 30 days CRITICAL.
- Intrusion Prevention validation: numeric values compared against
  expected defaults (10, 5, 5, 5, 9.00, 5, 30).
- File section indexing: all core files now have English section banners
  for easier maintenance.

### Fixed

- Logging (KIND changed from B to L): non-zero log level means PASS, zero
  means CRITICAL. Previously all logging items were false-CRITICAL.
- Backup key confusion: `icewarp.backup.auto_enabled` (main) versus
  `icewarp.database_backup.enabled` (database) resolved. Uses correct
  `c_system_tools_autobackup_*` keys.
- VRFY key: now uses `c_mail_security_protocols_denyvrfy`.
- DIGEST-MD5: now checks presence in `c_auth_schemes`.
- Cloud Features polarity: disabled means PASS, enabled means WARN. Was
  incorrectly CRITICAL before.
- Archive settings: uses `c_system_tools_autoarchive_*` keys.
- Health Summary filtering: only 8 key categories appear in the cover
  summary.

### Changed

- Memory, Disk, and CPU evaluation: percentage-based instead of
  absolute thresholds.
- Backup Last Time: separate item with PASS, WARN, or CRITICAL based on
  age (under 2 days, 2 to 7 days, over 7 days).
- Directory Cache Schedule: reports CRITICAL if not configured.
- `bc` dependency removed: all comparisons use `awk`.
- All Persian comments removed from code. English only.

### Removed

- Redundant "Process Incoming Messages in MDA Queue" merged with MDA
  Internal Delivery.

## [0.3.0] - 2026-07-11

### Added

- Initial Health Rules engine (`lib/health.sh`).
- PDF report writer (`lib/pdf.sh`).
- 60+ collectors across 12 categories.
- JSON exporter.
- First audit of checklist versus collectors.

### Known Issues at Release

- License not fully tested.
- Backup keys partially confusing.
- No management report yet.

## [0.2.0] - 2026-06-28

### Added

- Storage architecture refactor.
- Initial collectors for IceWarp core (version, license, database,
  services).
- Config fallback logic (`iw_get`).

## [0.1.0] - 2026-06-15

### Added

- Initial framework (`agent.sh`).
- Dynamic collector discovery.
- Locking mechanism.
- Base utility functions (`lib/common.sh`).
