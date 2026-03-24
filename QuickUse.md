# WebTunnelHub — Quick use guide

This guide is for **people who run the Hub** day to day: expose a local web app on the internet through the tunnel.  
First-time server setup, security groups, and Caddy install are in **`SETUP.md`** (简体中文). Extra detail in Traditional Chinese: **`Manual.md`**.

---

## What you need on your machine

1. **Configuration file** — Copy **`.env.example`** to **`.env`** and fill in every value you were given (SSH host, key path, public URL, etc.). Without a complete **`.env`**, the scripts will stop with an error.
2. **Where to run commands** — Open a terminal in the **folder that contains these scripts** (the project root).
3. **Which terminal to use** — On **Windows**, use **Git Bash** (or WSL) to run the **`.sh`** scripts. On Mac or Linux, use the normal terminal.
4. **Keep keys private** — Do not share your **`.env`** file or private key.

---

## How it fits together (simple)

| Part | What it does |
|------|----------------|
| **Your program** | Listens on your computer (for example `http://127.0.0.1:8080`). |
| **Tunnel script** | Keeps an SSH connection open so traffic from the server can reach that port on your PC. **Leave it running** while you want the site live. |
| **Server (Caddy)** | Handles **HTTPS** at your public address and sends requests to the tunnel. |
| **Register script** | Tells the server **once** to accept a name like `myapp` at `https://myapp.yourhub…`. It does **not** start the tunnel by itself. |

**Reliable order:** register the name on the server (once) → start your app locally → start the tunnel with the **same** app name and **same local port** your app uses.

---

## Add a new app (subdomain)

1. **Pick a name** — Use **lowercase only** (for example `myapp`, not `MyApp`).

2. **Register once** — You must include a short **note** (for records). The note must contain **at least five English letters** after cleanup (spaces and punctuation may be removed).

   ```bash
   ./hub-register.sh --note 'Description of who owns this app' myapp
   ```

   If this name is already registered, the script will say so. Only use **`--force`** if you really mean to replace the existing setup.

3. **Start your app** on your PC on a fixed port (example: **9080**).

4. **Start the tunnel** — The port here is **your computer’s** port, not the public port.

   ```bash
   ./hub-tunnel.sh --port 9080 myapp
   ```

   To run in the background with a log file:

   ```bash
   ./hub-tunnel.sh -b --port 9080 myapp
   ```

5. **Check** — Run **`./hub-status.sh`** or, if you use the local helper page, open **`http://127.0.0.1:8080/`** (tunnel links) or **`/status`** (full report).

**Shortcut** — To start a small local test site **and** the tunnel in one go:

```bash
./hub-serve-tunnel.sh --port 9080 myapp
```

---

## Commands you’ll use often

| What you want | Command |
|----------------|---------|
| See tunnels, routes, and listeners | `./hub-status.sh` |
| List registered app names | `./hub-applist.sh` |
| Quick check of settings and SSH | `./hub-doctor.sh` or `./hub-doctor.sh --port 9080 myapp` |
| Open a shell on the server | `./hub-ssh.sh` |
| Remove an app from the hub and stop its tunnel on this PC | `./hub-unregister.sh myapp` |
| Local browser pages for status | `python3 serve.py` then open **`http://127.0.0.1:8080/`** |

---

## If something goes wrong

| Problem | What to check |
|---------|----------------|
| Browser loads forever or errors | Is **your app** running? Is the **tunnel** still running? Start the app first, then the tunnel. |
| Wrong site or no site | App name in **`hub-tunnel.sh`** must match the name you registered (**lowercase**). Run **`./hub-applist.sh`** to see names on the server. |
| Subdomain never works | You still need **`hub-register.sh`** once; the tunnel alone does not create the public name. |
| Register script complains | **`--note`** is required and must meet the **five English letters** rule. |
| You changed custom ports | The same port choices must be used everywhere you were told to set them (register, tunnel, server). Ask whoever maintains the server if unsure. |

---

## Local status page (`serve.py`, optional)

If you run **`python3 serve.py`** on your machine:

- **`http://127.0.0.1:8080/`** — Short list of local links and your Hub app URLs (needs working **`.env`** and SSH like the status script).
- **`http://127.0.0.1:8080/quickuse`** — This **Quick use** guide as a readable page (**QuickUse.md**), rendered in the browser (loads **marked.js** from the internet once).
- **`http://127.0.0.1:8080/status`** — Full text report from **`hub-status.sh`** (can take a little time).

Useful options: **`PORT`** and **`HOST`** (where it listens), **`HUB_STATUS_TIMEOUT`** (how long to wait for the report). On Windows, **`HUB_BASH`** can point to Bash if it is not on your `PATH`.

---

## More documentation

| File | Contents |
|------|-----------|
| **`SETUP.md`** | Install from scratch, EC2, Caddy, firewall, what to do after a reboot |
| **`Manual.md`** | Traditional Chinese reference |
| **`.env.example`** | Names of all settings your **`.env`** must provide |
