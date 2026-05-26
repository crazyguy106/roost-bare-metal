#!/usr/bin/env bash
# Roost — bare-metal installer.
#
# Idempotent. Safe to re-run. Run with sudo or as root.
#
# Reads ROOST_DOMAIN and ROOST_ADMIN_EMAIL from env, or prompts.
#
#   ROOST_DOMAIN=roost.example.com \
#   ROOST_ADMIN_EMAIL=you@example.com \
#   sudo ./install.sh
#
# What this does (each step has a "Docker equivalent" comment):
#   1. apt deps                  (= the FROM line in Dockerfile)
#   2. create `roost` user       (= the USER directive)
#   3. clone roost into /opt     (= the COPY directive)
#   4. venv + pip install        (= pip install inside the image)
#   5. seed /etc/roost/roost.env (= env_file in compose)
#   6. systemd units             (= restart: unless-stopped)
#   7. host Caddyfile            (= the caddy container)
#   8. start everything          (= docker compose up -d)

set -euo pipefail

# ── 0. Sanity checks ─────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run as root or with sudo." >&2
  exit 1
fi

ROOST_REPO_URL="${ROOST_REPO_URL:-https://github.com/crazyguy106/roost.git}"
ROOST_BARE_REPO_URL="${ROOST_BARE_REPO_URL:-https://github.com/crazyguy106/roost-bare-metal.git}"
ROOST_INSTALL_DIR="${ROOST_INSTALL_DIR:-/opt/roost}"
ROOST_BARE_DIR="${ROOST_BARE_DIR:-/opt/roost-bare-metal}"
ROOST_USER="${ROOST_USER:-roost}"
WEB_PORT="${WEB_PORT:-8080}"
SKIP_CADDY="${SKIP_CADDY:-0}"

# Locate this install.sh — either we're running from a clone, or we cloned
# ourselves above. Either way, we need deploy/systemd/*.service and
# deploy/caddy/Caddyfile to be on disk.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$HERE/deploy/systemd/roost-web.service" ]]; then
  echo "==> deploy/ artifacts not next to install.sh — cloning roost-bare-metal"
  if [[ ! -d "$ROOST_BARE_DIR/.git" ]]; then
    git clone "$ROOST_BARE_REPO_URL" "$ROOST_BARE_DIR"
  else
    git -C "$ROOST_BARE_DIR" pull --ff-only
  fi
  HERE="$ROOST_BARE_DIR"
fi

# ── 1. Prompt for domain / email if not set ──────────────────────────
if [[ -z "${ROOST_DOMAIN:-}" ]]; then
  read -rp "Domain (e.g. roost.example.com): " ROOST_DOMAIN
fi
if [[ -z "${ROOST_ADMIN_EMAIL:-}" ]]; then
  read -rp "Admin email for Let's Encrypt: " ROOST_ADMIN_EMAIL
fi

# ── 2. apt deps ──────────────────────────────────────────────────────
echo "==> Installing system packages"
apt update -qq
apt install -y -qq \
  python3 python3-venv python3-pip \
  sqlite3 git curl ca-certificates \
  debian-keyring debian-archive-keyring apt-transport-https

# Caddy: official repo (apt has only a stale version on most distros)
if ! command -v caddy >/dev/null 2>&1; then
  echo "==> Adding Caddy apt repo"
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
    | sed 's|deb https|deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https|' \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt update -qq
  apt install -y -qq caddy
fi

# ── 3. roost system user ─────────────────────────────────────────────
# Docker equivalent: USER dev (uid 1000) inside the container.
if ! id "$ROOST_USER" >/dev/null 2>&1; then
  echo "==> Creating system user '$ROOST_USER'"
  useradd --system --create-home --home-dir "/var/lib/$ROOST_USER" \
          --shell /usr/sbin/nologin "$ROOST_USER"
fi

# ── 4. Clone Roost ───────────────────────────────────────────────────
# Docker equivalent: COPY . /app in the Dockerfile.
echo "==> Cloning Roost into $ROOST_INSTALL_DIR"
if [[ ! -d "$ROOST_INSTALL_DIR/.git" ]]; then
  git clone "$ROOST_REPO_URL" "$ROOST_INSTALL_DIR"
else
  git -C "$ROOST_INSTALL_DIR" pull --ff-only
fi

mkdir -p "$ROOST_INSTALL_DIR/data" "$ROOST_INSTALL_DIR/logs"
chown -R "$ROOST_USER:$ROOST_USER" "$ROOST_INSTALL_DIR"

# ── 5. venv + pip install ────────────────────────────────────────────
# Docker equivalent: RUN pip install ... inside the image build.
echo "==> Creating Python venv + installing Roost"
sudo -u "$ROOST_USER" bash -c "
  cd '$ROOST_INSTALL_DIR'
  if [[ ! -d .venv ]]; then python3 -m venv .venv; fi
  source .venv/bin/activate
  pip install --quiet --upgrade pip
  pip install --quiet -r requirements/base.txt
  # AI deps are required by roost.web.app's import chain (api_agentic →
  # planner → gemini_agent imports google.genai unconditionally). Install
  # them alongside base so the web tier boots.
  if [[ -f requirements/ai.txt ]]; then
    pip install --quiet -r requirements/ai.txt
  fi
  if [[ -n '${TELEGRAM_BOT_TOKEN:-}' ]] || [[ -f requirements/telegram.txt ]]; then
    pip install --quiet -r requirements/telegram.txt
  fi
  pip install --quiet -e .
"

# ── 6. /etc/roost/roost.env ──────────────────────────────────────────
# Docker equivalent: the env_file: .env in docker-compose.yml.
mkdir -p /etc/roost
if [[ ! -f /etc/roost/roost.env ]]; then
  echo "==> Writing starter /etc/roost/roost.env"
  cat > /etc/roost/roost.env <<EOF
# Roost — bare-metal environment.
# Edit then: sudo systemctl restart roost-web roost-bot

# Web binds to loopback; Caddy fronts it on $ROOST_DOMAIN.
WEB_HOST=127.0.0.1
WEB_PORT=$WEB_PORT

# Session secret — DO NOT use this default in production.
SESSION_SECRET=$(head -c 32 /dev/urandom | base64 | tr -d '=+/' | head -c 32)

# Web login (the wizard sets this; defaults are placeholders).
WEB_USERNAME=admin
WEB_PASSWORD=$(head -c 16 /dev/urandom | base64 | tr -d '=+/' | head -c 16)

# Sidecar — only relevant if you set up chromium. See docs/install.md.
SIDECAR_PUBLIC_URL=https://$ROOST_DOMAIN/sidecar
SIDECAR_INTERNAL_HTTP_URL=http://127.0.0.1:3000

# AI agent provider. Add API keys or enable subprocess CLI providers.
# AGENT_PROVIDER=claude_cli

# Bundles — all on by default. Toggle off whatever you don't need.
RPA_ENABLED=true
PROPERTY_AGENT_ENABLED=true
SME_OPS_ENABLED=true
CRM_ENABLED=true
CRM_PROVIDER=local
LEAD_NURTURE_ENABLED=true
GUARDIAN_ENABLED=true
MESSAGING_EXTERNAL_ENABLED=true

# Telegram — optional. Set BOT_TOKEN and enable roost-bot.service.
TELEGRAM_ENABLED=false
# TELEGRAM_BOT_TOKEN=
EOF
  chmod 640 /etc/roost/roost.env
  chown root:"$ROOST_USER" /etc/roost/roost.env
  echo "    → Generated WEB_PASSWORD: $(grep ^WEB_PASSWORD= /etc/roost/roost.env | cut -d= -f2-)"
else
  echo "==> /etc/roost/roost.env already exists — leaving alone"
fi

# Make a stable data dir under /var/lib too.
mkdir -p /var/lib/roost
chown "$ROOST_USER:$ROOST_USER" /var/lib/roost

# ── 7. systemd units ─────────────────────────────────────────────────
# Docker equivalent: the restart: unless-stopped policy in compose.
echo "==> Installing systemd units"
install -m 0644 "$HERE/deploy/systemd/roost-web.service" /etc/systemd/system/roost-web.service
install -m 0644 "$HERE/deploy/systemd/roost-bot.service" /etc/systemd/system/roost-bot.service
systemctl daemon-reload

# ── 8. Caddy ─────────────────────────────────────────────────────────
# Docker equivalent: the caddy container in docker-compose.public.yml.
# Skip with SKIP_CADDY=1 (useful for sandbox testing where ports 80/443
# are already taken by an existing reverse proxy or Docker stack).
if [[ "$SKIP_CADDY" != "1" ]]; then
  echo "==> Installing Caddyfile"
  install -m 0644 "$HERE/deploy/caddy/Caddyfile" /etc/caddy/Caddyfile
  cat > /etc/default/caddy <<EOF
ROOST_DOMAIN=$ROOST_DOMAIN
ROOST_ADMIN_EMAIL=$ROOST_ADMIN_EMAIL
EOF
  systemctl restart caddy
else
  echo "==> Skipping Caddy install (SKIP_CADDY=1)"
fi

# ── 9. Start Roost ───────────────────────────────────────────────────
# Docker equivalent: docker compose up -d roost
echo "==> Enabling + starting roost-web"
systemctl enable --now roost-web

# Bot only if a token was provided.
if grep -qE '^TELEGRAM_BOT_TOKEN=.+' /etc/roost/roost.env \
   && grep -qE '^TELEGRAM_ENABLED=true' /etc/roost/roost.env; then
  echo "==> Enabling + starting roost-bot"
  systemctl enable --now roost-bot
else
  echo "    Skipping roost-bot (TELEGRAM_BOT_TOKEN unset or TELEGRAM_ENABLED=false)."
  echo "    Enable later with: sudo systemctl enable --now roost-bot"
fi

# ── 10. Health check ─────────────────────────────────────────────────
sleep 4
echo ""
echo "==> Health check"
if [[ "$SKIP_CADDY" == "1" ]]; then
  curl -fsSL -o /dev/null -w "  http://127.0.0.1:$WEB_PORT/  HTTP %{http_code}\n" \
       "http://127.0.0.1:$WEB_PORT/" 2>&1 || \
       echo "  (loopback check failed — see: journalctl -u roost-web -n 30)"
elif curl -fsSL -o /dev/null -w "  https://$ROOST_DOMAIN/  HTTP %{http_code}\n" \
       "https://$ROOST_DOMAIN/" 2>&1; then
  :
else
  echo "  (homepage check failed — Caddy may still be issuing TLS;"
  echo "   wait 30s then re-run:  curl -I https://$ROOST_DOMAIN/  )"
fi

echo ""
echo "============================================================"
echo "Roost is installed."
if [[ "$SKIP_CADDY" == "1" ]]; then
  echo "  Web:   http://127.0.0.1:$WEB_PORT/  (Caddy skipped)"
else
  echo "  Web:   https://$ROOST_DOMAIN/"
fi
echo "  Login: admin / $(grep ^WEB_PASSWORD= /etc/roost/roost.env | cut -d= -f2-)"
echo "  Logs:  journalctl -u roost-web -f"
echo "  Edit:  sudo nano /etc/roost/roost.env  &&  sudo systemctl restart roost-web"
echo "============================================================"
