# roost-bare-metal

**Bare-metal install of [Roost](https://github.com/crazyguy106/roost) — no Docker.**

This is a *deployment companion* for Roost, not a fork. It pulls upstream
Roost source at install time and runs it directly on the host as Python +
systemd. Use it when you want to *see* what Docker normally hides:

- a Python virtualenv  (= the container image layer)
- two systemd services (= the compose restart policy)
- a host-installed Caddy (= the `caddy` container)
- a SQLite file on disk (= the `roost-data` volume)
- an optional headless Chromium under systemd (= the `chromium` container)

If you don't care about that — install Roost the normal way (Docker).
See [crazyguy106/roost](https://github.com/crazyguy106/roost).

---

## Who this is for

- **Learners** who want to understand the moving parts of a self-hosted
  AI agent stack, with the intent of building their own.
- **Operators** on a small VPS who already use systemd + Caddy for other
  services and want Roost to fit the same model.
- **People uninterested in Docker.** Air-gapped boxes, ARM SBCs, hosts
  where Docker is policy-blocked.

---

## Quick install (Ubuntu 24.04 / Debian 12)

```bash
curl -fsSL https://raw.githubusercontent.com/crazyguy106/roost-bare-metal/main/install.sh | bash
```

Or, if you'd rather read the script first (recommended):

```bash
git clone https://github.com/crazyguy106/roost-bare-metal.git
cd roost-bare-metal
less install.sh
sudo ./install.sh
```

The installer does everything:

1. Installs system packages (`python3.12`, `python3.12-venv`, `sqlite3`, `git`, `caddy`).
2. Creates a `roost` system user.
3. Clones Roost into `/opt/roost/`.
4. Creates a venv at `/opt/roost/.venv`.
5. Installs Roost + Telegram deps via `pip`.
6. Writes a minimal starter `/etc/roost/roost.env`.
7. Installs systemd units (`roost-web.service`, optionally `roost-bot.service`).
8. Installs a host Caddyfile for TLS via Let's Encrypt.
9. Starts everything.

End state: `https://your-domain.tld/` serves Roost. No Docker daemon
running. `journalctl -u roost-web` shows the logs.

---

## What's in this repo

| File | What it is |
|---|---|
| `install.sh` | One-shot installer. Idempotent. Reads `ROOST_DOMAIN` / `ROOST_ADMIN_EMAIL` from env or prompts. |
| `deploy/systemd/roost-web.service` | Runs `roost-web` console script under the `roost` user. |
| `deploy/systemd/roost-bot.service` | Runs `roost-bot` (optional — only enable if you set `TELEGRAM_BOT_TOKEN`). |
| `deploy/caddy/Caddyfile` | Host-Caddy config — auto-TLS, WebSocket upgrades for `/sidecar`. |
| `docs/install.md` | Detailed walk-through with "what Docker would have done" annotations. Recommended reading. |

This repo contains **zero Roost source code.** It clones upstream Roost
at install time. To upgrade Roost: `cd /opt/roost && git pull && systemctl restart roost-web roost-bot`.

---

## Chromium for RPA

Roost's RPA framework needs a headless Chromium with CDP enabled. Two paths:

- **Hybrid (recommended).** Run *only* chromium under `docker run`. Everything
  else stays bare-metal. The chromium image is just `ghcr.io/browserless/chromium`;
  one container, one published port. Easier and more reliable than apt-Chromium.
- **Pure bare-metal.** Install Chromium via apt, run with
  `--remote-debugging-port=3000` under a `chromium.service` systemd unit.
  No sandbox unless you bring AppArmor / firejail. Documented in `docs/install.md`.

If you don't need RPA, skip this — Roost's other 270+ MCP tools work without
a browser sidecar.

---

## Roadmap (untested, will validate before publish)

- [ ] Test on Ubuntu 24.04 (Hetzner CX23)
- [ ] Test on Debian 12 (DigitalOcean basic droplet)
- [ ] Test on a Raspberry Pi 5 (ARM64, Bookworm)
- [ ] Document non-Caddy reverse proxies (nginx, Traefik)
- [ ] Backup / restore guide for `data/roost.db`

---

## Licence

MIT — same as Roost itself.
