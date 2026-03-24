# Quick use

**Prereq:** `cp .env.example .env`, fill all values, run scripts from this repo folder. On **Windows**, use **Git Bash** or **WSL** (the `*.sh` helpers need Bash).

**Do not skip registration.** Every new app name needs **`hub-register.sh` once** before **`hub-tunnel.sh`** will work on the public URL—unless you use **`hub-managed-tunnel.sh`**, which runs **`hub-register.sh`** and then **`hub-tunnel.sh`** for you. If you start the tunnel first without a route, Caddy on the hub has nothing to proxy.

**Typical order:** register → run your local app → start the tunnel (same app name everywhere). **Exception:** **`./hub-managed-tunnel.sh`** expects your local HTTP server to **already be listening**; it then registers and opens the tunnel in one step (see below). **`./example/start.sh`** starts the example server first, then calls **`hub-managed-tunnel.sh`**.

---

## 1. Register

Pick a **lowercase** app name. **`--note`** is required and must contain **at least five English letters** after sanitization.

**Order:** register → run your local app → start the tunnel (same app name in both scripts).

```bash
./hub-register.sh --note 'Short note describing the app' myapp
```

---

## 1b. `hub-managed-tunnel.sh` (register + tunnel)

Use this when your service is **already listening** on a local port and you want **registration and the SSH tunnel in one command** (like **`example/start.sh`**, but without starting a server for you).

```bash
./hub-managed-tunnel.sh --name myapp --note 'Short note describing the app' --port 9080
```

**Also accepted:** `--name=myapp`, `--note='…'`, `--port=9080` (single-argument form).

- **Ctrl+C:** stops the tunnel and, by default, runs **`hub-unregister.sh`** for that app (`UNREGISTER_ON_INTERRUPT=0` to disable).
- **Example stack:** **`./example/start.sh`** runs **`example/serve.py`** on **`PORT`** (default **8080**), waits until HTTP is ready, then runs **`hub-managed-tunnel.sh`** with app **`hub-serve`** and a demo note.

---

## 2. Run the tunnel

Start your service locally (e.g. on port **9080**), then:

```bash
./hub-tunnel.sh --port 9080 myapp
```

Your app is reachable at **`https://myapp.<your-hub-host>:1080/`** (see **`HUB_PUBLIC_URL`** in `.env` for the exact base).

Keep this terminal open while you need the tunnel. For a **background** tunnel with logs under `logs/`:

```bash
./hub-tunnel.sh -b --port 9080 myapp
```

---

## 3. Unregister when done

Removes the Hub route and stops matching local tunnel processes for that app:

```bash
./hub-unregister.sh myapp
```

---

## Caveats

- Use a **registered** app name for new work. Do **not** rely on **`https://<hub>:1080/`** with **no** app subdomain—that path is **legacy** only.
- **`hub-register.sh` is easy to forget**—without it, the tunnel may run but the hub will not proxy your app. Re-run registration if you change app names or re-create routes.
- Registration and tunnel scripts expect a working **SSH** setup to the Hub host (keys, `.env` values). Server-side Caddy setup is documented in **[README.md](README.md)**.
