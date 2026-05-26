# Installing Roost on bare metal — the long version

This walks through `install.sh` step by step. The point is to make
**every layer Docker normally hides explicit**. By the end you will have
deployed Roost without Docker, and you will know what Docker was actually
doing for you.

If you just want the short version, run `sudo ./install.sh` and read the
"Health check" output at the bottom.

> **Audience.** Comfortable on a Linux shell. Knows what systemd, apt,
> and a reverse-proxy do. Doesn't need to be a Python expert — `pip`
> and `venv` are explained as we go.

> **Target.** Ubuntu 24.04 LTS or Debian 12, ≥1 GB RAM, ≥10 GB disk,
> a public IPv4, a domain you control (A record pre-set), `sudo` access.

---

## Step 0 — Pre-flight

```bash
# 1. DNS — point an A record at your VPS before starting.
dig +short roost.example.com   # → should show your VPS IP

# 2. SSH in as a user with sudo.
ssh you@your-vps.example.com

# 3. Clone this repo somewhere readable. (The installer will move it
#    to /opt/roost-bare-metal/ but a sibling clone is fine too.)
git clone https://github.com/crazyguy106/roost-bare-metal.git
cd roost-bare-metal
```

**Why?** TLS issuance via Let's Encrypt fails if the A record isn't live
when Caddy starts. Set DNS first, wait ~5 minutes for propagation.

---

## Step 1 — System packages

```bash
sudo apt update
sudo apt install -y python3 python3-venv python3-pip sqlite3 git curl
# Plus Caddy via its official repo (apt has only a stale version).
```

| Package | Purpose | Docker equivalent |
|---|---|---|
| `python3` | Python runtime | The `FROM python:3.12` in the Dockerfile |
| `python3-venv` | Isolated virtualenvs | What the Dockerfile sets up by being a fresh image |
| `sqlite3` | DB CLI for inspection | (none — the lib was already in the image) |
| `git` | Clone Roost | The `git clone` in the Dockerfile / cache mount |
| `caddy` | TLS + reverse proxy | The `caddy` container in `docker-compose.public.yml` |

**Why a separate apt repo for Caddy?** Distro packages lag Caddy releases
by 6–18 months. Caddy's `cloudsmith` repo gives you the same binary that
runs in the official container image.

---

## Step 2 — A dedicated `roost` system user

```bash
sudo useradd --system --create-home \
             --home-dir /var/lib/roost \
             --shell /usr/sbin/nologin roost
```

**Why a system user instead of running as root?** The same reason Docker
images don't run as root — limit blast radius if the app is compromised.
A bare-metal install gets this for free with `useradd --system`.

**Docker equivalent:** the `USER dev` directive in the Dockerfile, and
the `cap_drop: ALL` block in `docker-compose.yml`. Bare-metal goes
further — systemd hardening (`NoNewPrivileges`, `ProtectSystem=strict`,
`PrivateTmp`) restricts the running process at the kernel level rather
than at the container boundary.

---

## Step 3 — Clone Roost into `/opt/roost`

```bash
sudo git clone https://github.com/crazyguy106/roost.git /opt/roost
sudo chown -R roost:roost /opt/roost
sudo mkdir -p /opt/roost/data /opt/roost/logs
```

**Docker equivalent:** the `COPY . /app` line in the Dockerfile. There,
the source is baked into the image. Here it lives on disk and you
can `cat` it.

**Why `/opt/roost` specifically?** The FHS convention: `/opt/<vendor>`
is for self-contained third-party software trees. `/srv/roost` would
also be reasonable. Avoid `/home/<user>/roost` for system services —
home directories shouldn't be searched by systemd.

---

## Step 4 — Create a Python virtualenv

```bash
sudo -u roost bash -c "
  cd /opt/roost
  python3 -m venv .venv
  source .venv/bin/activate
  pip install -r requirements/base.txt
  pip install -r requirements/telegram.txt   # if you want the bot
  pip install -e .                          # install the console scripts
"
```

**What `python3 -m venv .venv` actually does:**
- Creates `.venv/bin/python3` symlinked to system Python.
- Creates `.venv/bin/activate` which prepends `.venv/bin` to `$PATH`.
- Creates `.venv/lib/python3.12/site-packages/` — where pip installs
  packages, isolated from the system's `/usr/lib/python3/`.

**Docker equivalent:** every container layer in the Roost Dockerfile
that installs Python dependencies. The `.venv/` directory is to a
bare-metal install what an OCI image's `/usr/local/lib/python3.12/`
directory is to a container.

**Why `pip install -e .`?** Editable install — symlinks `roost/` into
the venv's `site-packages/`. Lets you `git pull` and pick up changes
without reinstalling. Also installs the console scripts (`roost-web`,
`roost-bot`, `roost-mcp`, `roost-cli`, `roost-onboard`) into
`.venv/bin/`.

---

## Step 5 — Configuration: `/etc/roost/roost.env`

```bash
sudo mkdir -p /etc/roost
sudo nano /etc/roost/roost.env
```

Minimum viable contents:

```bash
WEB_HOST=127.0.0.1
WEB_PORT=8080
SESSION_SECRET=<32 random bytes>
WEB_USERNAME=admin
WEB_PASSWORD=<your password>
SIDECAR_PUBLIC_URL=https://roost.example.com/sidecar
```

The installer auto-generates these from `/dev/urandom` so you don't have
to think about it.

**Docker equivalent:** the `env_file: .env` block in `docker-compose.yml`,
combined with the bind-mount `./.env:/app/.env`. Bare-metal has one
canonical location instead of two — `/etc/roost/roost.env` is read by
systemd via `EnvironmentFile=`.

**Permissions** are `640 root:roost` — root owns it, roost reads it.
This is more restrictive than Docker, where any process in the
container can read the bind-mounted file.

---

## Step 6 — systemd units

```bash
sudo install -m 0644 deploy/systemd/roost-web.service /etc/systemd/system/
sudo install -m 0644 deploy/systemd/roost-bot.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now roost-web
```

The unit file (`roost-web.service`) is conceptually identical to the
`restart: unless-stopped` block in `docker-compose.yml`, but exposes the
mechanism. Worth reading top to bottom — see `deploy/systemd/roost-web.service`.

**Most important lines:**

```ini
ExecStart=/opt/roost/.venv/bin/roost-web
EnvironmentFile=/etc/roost/roost.env
Restart=on-failure
ProtectSystem=strict
ReadWritePaths=/opt/roost/data /opt/roost/logs /var/lib/roost
```

`ProtectSystem=strict` makes the entire filesystem read-only to the
process *except* for the paths listed in `ReadWritePaths`. This is what
Docker calls a read-only root filesystem with explicit volume mounts.

**Tail the logs** with:

```bash
journalctl -u roost-web -f
```

This is `docker compose logs -f roost` in Docker terms.

---

## Step 7 — Caddy on the host

```bash
sudo install -m 0644 deploy/caddy/Caddyfile /etc/caddy/Caddyfile
echo "ROOST_DOMAIN=roost.example.com" | sudo tee /etc/default/caddy
echo "ROOST_ADMIN_EMAIL=you@example.com" | sudo tee -a /etc/default/caddy
sudo systemctl restart caddy
```

Caddy reads `/etc/default/caddy` at startup, exposing both variables
to the Caddyfile via `{$ROOST_DOMAIN}` and `{$ROOST_ADMIN_EMAIL}`.

**Docker equivalent:** the `caddy` service in `docker-compose.public.yml`
plus the env variables passed through compose. Same Caddy, same
Caddyfile syntax — just one less layer of indirection.

**TLS issuance** takes 5–30 seconds the first time. If the homepage
returns a 502 or `connection refused`, give Caddy a minute and re-curl.
Watch issuance in real time with:

```bash
journalctl -u caddy -f | grep -E "(certificate|tls)"
```

---

## Step 8 — Verify

```bash
curl -fsSL -o /dev/null -w "%{http_code}\n" https://roost.example.com/
# 307 (redirect to /auth/login-page) — expected on first boot.

# Log in via the web UI with the WEB_USERNAME / WEB_PASSWORD from your env file.
```

If you got 307 on the homepage and 200 after login, you're done.

---

## Optional: Chromium for RPA

The RPA framework needs a headless Chromium speaking CDP on port 3000.
Roost's Docker stack ships `ghcr.io/browserless/chromium` for this.
Bare-metal has two paths:

### Path A — Hybrid (recommended): run only Chromium under `docker run`

If Docker is available on the host (apt-installed; no compose needed):

```bash
sudo docker run -d --name roost-chromium --restart unless-stopped \
  -p 127.0.0.1:3000:3000 \
  ghcr.io/browserless/chromium:latest
```

Then in `/etc/roost/roost.env`:

```bash
SIDECAR_INTERNAL_HTTP_URL=http://127.0.0.1:3000
```

Why this is fine even in a "no Docker" install: you're not orchestrating
anything. It's one container, one port, one image. Treat it like an
appliance.

### Path B — Pure bare-metal Chromium

```bash
sudo apt install -y chromium-browser
```

Then a `chromium.service` unit:

```ini
[Unit]
Description=Headless Chromium for Roost RPA
After=network.target

[Service]
ExecStart=/usr/bin/chromium --headless \
  --no-sandbox \
  --remote-debugging-port=3000 \
  --remote-debugging-address=127.0.0.1 \
  --disable-gpu \
  --user-data-dir=/var/lib/chromium
User=roost
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

**Tradeoffs.** Faster boot, no Docker daemon at all. But you're
responsible for the sandbox story (`--no-sandbox` is what you get
without AppArmor / firejail wrappers), and Chromium updates are on
your apt schedule rather than Browserless's release cadence.

---

## Operating the install

| Task | Command |
|---|---|
| Tail web logs | `journalctl -u roost-web -f` |
| Tail bot logs | `journalctl -u roost-bot -f` |
| Restart after edit | `sudo systemctl restart roost-web roost-bot` |
| Upgrade Roost | `sudo -u roost git -C /opt/roost pull && sudo systemctl restart roost-web roost-bot` |
| Backup DB | `sudo -u roost cp /opt/roost/data/roost.db /var/lib/roost/backup-$(date +%F).db` |
| Inspect DB | `sudo -u roost sqlite3 /opt/roost/data/roost.db '.schema tasks'` |
| Renew TLS (auto) | (nothing — Caddy renews automatically) |

---

## What you learned

If you went through all eight steps, you now know that a "Docker app"
is, in this case:

- A Python virtualenv with some pip-installed packages.
- Two processes (`roost-web`, `roost-bot`) managed by an init system.
- A reverse proxy (Caddy) terminating TLS and forwarding to loopback.
- A SQLite file on disk for state.
- Optionally a headless browser sidecar.

Docker bundles all five into one declarative config. Bare-metal makes
each one a separate, named, inspectable thing. Same software, different
operating model.

Now you can build your own.
