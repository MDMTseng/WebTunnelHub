# WebTunnelHub

Expose **local HTTP services** on the public internet through **SSH reverse tunnels** to a **hub host** (`SSH_TARGET` in `.env`), with **Caddy** terminating **HTTPS** (typically on port **1080**) and routing **`https://<app>.<your-domain>:1080/`** to each tunnel.

**Day-to-day commands** → **[QuickUse.md](QuickUse.md)** (operators).

---

## Recommended vs legacy

**Use a registered Hub app for every new service** (`hub-register.sh` + `hub-tunnel.sh --port … <AppName>` → `https://<AppName>.<host>:1080/`).

**Do not** build new flows on the bare root URL `https://<host>:1080/` or on `./hub-tunnel.sh` **without** an app name (that maps to hub `127.0.0.1:10080`). That path exists for **legacy** setups only. Details: [QuickUse.md](QuickUse.md).

---

## Architecture

```
Browser --HTTPS--> hub:1080 (Caddy: TLS + route by Host)
                       |
                       +--> 127.0.0.1:<port> --SSH -R--> your laptop :<local port>
```

- **1080** is served by **Caddy** on the hub host. Do not bind the same port with `ssh -R …:1080` while Caddy uses it.
- Each **app name** gets a stable hub loopback port (see `hub_remote_port` in `hub-common.sh`).
- **`HUB_PUBLIC_URL`** in `.env` is the HTTPS **base** (scheme + host + port) used for messages and URL building; prefer app subdomains for real traffic.

---

## What you need

| Item | Notes |
|------|--------|
| **Hub server** (e.g. Ubuntu VM) | Public IP; firewall: **22** (SSH), **80** (ACME), **1080** (HTTPS) as needed |
| **DNS** | Apex and `*.<apex>` (or per-app) **A** records → hub host |
| **SSH** | Key-based login; path in `.env` (Windows/Git Bash: `C:/Users/.../key.pem`) |
| **This repo** on your machine | Python 3 for optional **`example/serve.py`**; **Bash** for `*.sh` (Git Bash / WSL on Windows) |

---

## Configuration

```bash
cp .env.example .env
# Edit .env — every variable in .env.example is required (no defaults in hub-common.sh).
```

See **`.env.example`** for `SSH_TARGET`, `SSH_KEY`, `HUB_DIR`, `MAIN_CFG`, `HUB_PUBLIC_URL`, etc.

Make scripts executable once (Unix):

```bash
chmod +x example/serve.py example/start.sh hub-tunnel.sh hub-register.sh hub-unregister.sh hub-status.sh \
  hub-applist.sh hub-doctor.sh hub-serve-tunnel.sh hub-ssh.sh
```

---

## Hub server: Caddy (first time)

1. Install Caddy per [official install docs](https://caddyserver.com/docs/install).
2. Align **`/etc/caddy/Caddyfile`** with **[Caddyfile.hub.example](Caddyfile.hub.example)**. Replace the sample apex **`db.example.com`** with the hostname from **`HUB_PUBLIC_URL`** in `.env` (same apex you use for DNS `*` records). **`import /etc/caddy/hub-routes/*.caddy`** must be **top-level**, not inside the `:1080` block.
3. Ensure **`/etc/caddy/hub-routes/`** exists (scripts create **`_keep.caddy`** if needed).
4. `sudo caddy validate --config /etc/caddy/Caddyfile` then `sudo systemctl reload caddy`.

**OpenSSH `GatewayPorts`:** only required if you use **raw HTTP on 1080** without Caddy (see comments in `hub-tunnel.sh`). For the usual Caddy setup, reverse forwards bind to **127.0.0.1** and you typically **do not** need to change `sshd_config`.

---

## Hub workflow (summary)

1. **Register once** (lowercase app name; **`--note`** required, ≥ 5 English letters after sanitization):

   ```bash
   ./hub-register.sh --note 'Team or purpose description' myapp
   ```

2. Run your app locally on a fixed port (e.g. **9080**).

3. **Tunnel** (keep running):

   ```bash
   ./hub-tunnel.sh --port 9080 myapp
   # background + log: ./hub-tunnel.sh -b --port 9080 myapp
   ```

4. Check **`./hub-status.sh`** or run **`python3 example/serve.py`** and open **`http://127.0.0.1:8080/`** / **`/status`**.

Shortcut: **`./hub-serve-tunnel.sh --port 9080 myapp`** (starts **`example/serve.py`** + tunnel).

**`./example/start.sh`** is a **short demo**: register **`hub-serve`**, **`example/serve.py`** on **8080**, then **`hub-tunnel.sh`**. If the name is already taken, it prints what to run next. It does **not** unregister on exit (use **`hub-unregister.sh hub-serve`** when done).

---

## Main scripts

| Script | Role |
|--------|------|
| `hub-register.sh` | Writes hub Caddy snippet + reload |
| `hub-tunnel.sh` | SSH `-R` (prefer **`--port` + AppName**) |
| `hub-unregister.sh` | Remove route + stop matching local `ssh -R` |
| `hub-status.sh` | Registered apps, local tunnels, hub listeners, routes |
| `hub-applist.sh` | List registered app names |
| `hub-doctor.sh` | Quick `.env` / SSH checks |
| `hub-ssh.sh` | Interactive SSH to hub host |
| `example/serve.py` | Local **`/`** (links + tunnel list), **`/status`**, **`/readme`**, **`/quickuse`** |
| `example/start.sh` | **Demo only**: **`hub-register.sh`** → **`example/serve.py`** :**8080** → **`hub-tunnel.sh`** **`hub-serve`**; prints hints if register fails (no auto-unregister) |

---

## `example/serve.py` (optional)

| Path | Purpose |
|------|---------|
| `/` | Local routes + Hub public links (uses `hub-status.sh` data) |
| `/status` | Full `hub-status.sh` HTML |
| `/readme` | Renders **README.md** in the browser (loads [marked](https://marked.js.org/) from jsDelivr) |
| `/quickuse` | Renders **QuickUse.md** in the browser (same CDN **marked**) |

Env: **`PORT`**, **`HOST`**, **`HUB_STATUS_TIMEOUT`**, **`HUB_BASH`** (Windows), **`HUB_STATUS_REFRESH_SEC`**.

---

## After reboot

On your **laptop**: start local HTTP **first**, then each **`hub-tunnel.sh`** (or `-b` services). Hub **Caddy** and **`hub-routes/*.caddy`** usually persist; you **do not** re-run `hub-register.sh` unless you changed names or config.

---

## More in the repo

- **[QuickUse.md](QuickUse.md)** — Operator checklist and common mistakes  
- **[Caddyfile.hub.example](Caddyfile.hub.example)** — Hub main Caddy config + hub import  
- **[Caddyfile.snippet-basicauth.example](Caddyfile.snippet-basicauth.example)** — Optional basic auth for sensitive dev sites  
