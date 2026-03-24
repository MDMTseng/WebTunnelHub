# Quick use

**Prereq:** `cp .env.example .env`, fill all values, run scripts from this repo folder. On **Windows**, use **Git Bash** or **WSL** (the `*.sh` helpers need Bash).

**Do not skip step 1.** Every new app name needs **`hub-register.sh` once** before **`hub-tunnel.sh`** (or helpers like **`./example/start.sh`**) will work on the public URL. If you start the tunnel first, Caddy on the hub has no route for that name—register, then tunnel.

---

## 1. Register

Pick a **lowercase** app name. **`--note`** is required and must contain **at least five English letters** after sanitization.

**Order:** register → run your local app → start the tunnel (same app name in both scripts).

```bash
./hub-register.sh --note 'Short note describing the app' myapp
```

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
