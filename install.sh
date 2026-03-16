#!/bin/bash
# ============================================================
#  OPENFANG MASTER INSTALLER
#  Handles: Install → Config → Nginx → SSL → Hostinger DNS
#  OS: Debian 11 / 12
#  Channels: Telegram + Web Dashboard
# ============================================================

# Use pipefail but NOT set -e (we handle errors explicitly)
set -uo pipefail

# ── COLORS ───────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m'
B='\033[0;34m' C='\033[0;36m' W='\033[1m' N='\033[0m'

log()     { echo -e "${G}[+]${N} $1"; }
info()    { echo -e "${B}[>]${N} $1"; }
warn()    { echo -e "${Y}[!]${N} $1"; }
error()   { echo -e "${R}[x]${N} $1"; exit 1; }
ask()     { echo -e "${C}[?]${N} $1"; }
divider() { echo -e "${C}$(printf '%.0s-' $(seq 1 50))${N}"; }
section() { echo ""; divider; echo -e "${W}  $1${N}"; divider; }

# ── TRAP: cleanup on unexpected exit ─────────────────────────
cleanup() {
  local code=$?
  if [ $code -ne 0 ]; then
    echo ""
    echo -e "${R}[x] Script failed at line $BASH_LINENO with exit code $code${N}"
    echo -e "${R}    Check output above for details.${N}"
  fi
}
trap cleanup EXIT

# ── ROOT CHECK ────────────────────────────────────────────────
[[ "$EUID" -ne 0 ]] && error "Run as root: sudo bash $0"

# ── BANNER ────────────────────────────────────────────────────
clear
echo -e "${C}${W}"
cat << 'EOF'
   ___                 _____
  / _ \ _ __  ___ _ _|  ___|_ _ _ _  __ _
 | | | | '_ \/ _ \ ' \ |_ / _` | ' \/ _` |
 | |_| | |_) |  __/ || |  _| (_| | | | (_| |
  \___/| .__/ \___|_||_|_|  \__,_|_|_|\__, |
       |_|    Master Installer v1.0    |___/
EOF
echo -e "${N}"
echo -e "  ${W}Debian 11/12 | Telegram + Dashboard | Nginx | SSL | Hostinger DNS${N}"
echo ""

# ── INPUT VALIDATION HELPERS ─────────────────────────────────
require_nonempty() {
  local val="$1" field="$2"
  if [[ -z "$val" ]]; then
    error "$field cannot be empty"
  fi
}

require_numeric() {
  local val="$1" field="$2"
  if ! [[ "$val" =~ ^[0-9]+$ ]]; then
    error "$field must be numeric, got: '$val'"
  fi
}

require_domain() {
  local val="$1" field="$2"
  if ! [[ "$val" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
    error "$field must be a valid domain, got: '$val'"
  fi
}

require_email() {
  local val="$1" field="$2"
  if ! [[ "$val" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
    error "$field must be a valid email, got: '$val'"
  fi
}

# ════════════════════════════════════════════════════════════
#  SECTION 1 — COLLECT ALL CREDENTIALS UPFRONT
# ════════════════════════════════════════════════════════════
section "STEP 1 -- Configuration"

# ── LLM Provider ─────────────────────────────────────────────
echo ""
echo -e "${W}LLM Provider:${N}"
echo "  1) Groq        (free tier, fastest -- recommended)"
echo "  2) OpenRouter  (multi-provider pool, free models)"
echo "  3) Anthropic   (Claude)"
echo "  4) OpenAI"
echo ""
ask "Choose provider [1-4]:"
read -rp "  > " PROVIDER_CHOICE

case $PROVIDER_CHOICE in
  1) PNAME="groq";       PTYPE="openai_compatible"
     PURL="https://api.groq.com/openai/v1"
     PENV="GROQ_API_KEY"; PMODEL="llama-3.3-70b-versatile" ;;
  2) PNAME="openrouter"; PTYPE="openai_compatible"
     PURL="https://openrouter.ai/api/v1"
     PENV="OPENROUTER_API_KEY"; PMODEL="meta-llama/llama-3.3-70b-instruct:free" ;;
  3) PNAME="anthropic";  PTYPE="anthropic"
     PURL=""
     PENV="ANTHROPIC_API_KEY"; PMODEL="claude-haiku-4-5-20251001" ;;
  4) PNAME="openai";     PTYPE="openai_compatible"
     PURL="https://api.openai.com/v1"
     PENV="OPENAI_API_KEY"; PMODEL="gpt-4o-mini" ;;
  *) error "Invalid choice" ;;
esac

ask "$PNAME API key:"
read -rsp "  > " API_KEY; echo ""
require_nonempty "$API_KEY" "API key"

# ── Telegram ─────────────────────────────────────────────────
echo ""
ask "Telegram Bot Token (from @BotFather):"
read -rsp "  > " TG_TOKEN; echo ""
require_nonempty "$TG_TOKEN" "Telegram bot token"

ask "Your Telegram numeric User ID (get from @userinfobot):"
read -rp "  > " TG_USER_ID
require_numeric "$TG_USER_ID" "Telegram User ID"

# ── Dashboard ────────────────────────────────────────────────
echo ""
ask "Dashboard username [default: admin]:"
read -rp "  > " DASH_USER; DASH_USER="${DASH_USER:-admin}"

ask "Dashboard password:"
read -rsp "  > " DASH_PASS; echo ""
require_nonempty "$DASH_PASS" "Dashboard password"

ask "Dashboard internal port [default: 4200]:"
read -rp "  > " DASH_PORT; DASH_PORT="${DASH_PORT:-4200}"
require_numeric "$DASH_PORT" "Dashboard port"

# ── Domain ───────────────────────────────────────────────────
echo ""
ask "Your subdomain for OpenFang (e.g. openfang.yourdomain.com):"
read -rp "  > " DOMAIN
require_domain "$DOMAIN" "Domain"

ask "Your Hostinger API key (Portal > Account > API):"
read -rsp "  > " HOSTINGER_KEY; echo ""
require_nonempty "$HOSTINGER_KEY" "Hostinger API key"

ask "Root domain registered in Hostinger (e.g. yourdomain.com):"
read -rp "  > " ROOT_DOMAIN
require_domain "$ROOT_DOMAIN" "Root domain"

ask "SSL email for Let's Encrypt:"
read -rp "  > " SSL_EMAIL
require_email "$SSL_EMAIL" "SSL email"

# ── Agent Name ───────────────────────────────────────────────
echo ""
ask "Agent name [default: assistant]:"
read -rp "  > " AGENT_NAME; AGENT_NAME="${AGENT_NAME:-assistant}"

# ── Confirm ──────────────────────────────────────────────────
echo ""
divider
echo -e "${W}  Summary${N}"
divider
echo "  Provider    : $PNAME > $PMODEL"
echo "  Telegram    : user ID $TG_USER_ID"
echo "  Dashboard   : port $DASH_PORT (user: $DASH_USER)"
echo "  Domain      : $DOMAIN"
echo "  Root domain : $ROOT_DOMAIN"
echo "  SSL email   : $SSL_EMAIL"
echo "  Agent name  : $AGENT_NAME"
divider
echo ""
ask "Everything correct? Proceed with full install? [Y/n]:"
read -rp "  > " GO; GO="${GO:-y}"
[[ ! "$GO" =~ ^[Yy]$ ]] && { echo "Aborted."; exit 0; }

# Derive subdomain prefix for Hostinger API
SUBDOMAIN_PREFIX="${DOMAIN%%.$ROOT_DOMAIN}"

# ── Detect server IP with validation ────────────────────────
info "Detecting server IP..."
SERVER_IP=""
for svc in "https://ifconfig.me" "https://api.ipify.org" "https://icanhazip.com"; do
  SERVER_IP=$(curl -s --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]')
  if [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    break
  fi
  SERVER_IP=""
done

if [[ -z "$SERVER_IP" ]]; then
  SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
fi

if [[ -z "$SERVER_IP" ]] || ! [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  error "Could not determine server IP. Set SERVER_IP manually and re-run."
fi
log "Server IP: $SERVER_IP"

# ════════════════════════════════════════════════════════════
#  SECTION 2 — SYSTEM PREP
# ════════════════════════════════════════════════════════════
section "PHASE 1 -- System Preparation"

info "Updating system..."
if ! apt-get update -qq; then
  error "apt-get update failed — check network/sources"
fi

info "Upgrading packages..."
apt-get upgrade -y -qq || warn "Some packages failed to upgrade (non-fatal)"

info "Installing dependencies..."
if ! apt-get install -y -qq \
  curl wget git ufw nginx \
  certbot python3-certbot-nginx \
  ca-certificates gnupg lsb-release \
  dnsutils jq; then
  error "Failed to install required packages"
fi

log "System ready"

# ════════════════════════════════════════════════════════════
#  SECTION 3 — HOSTINGER DNS
# ════════════════════════════════════════════════════════════
section "PHASE 2 -- Hostinger DNS Record"

info "Creating A record: $SUBDOMAIN_PREFIX > $SERVER_IP"

DNS_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
  "https://api.hostinger.com/v1/domains/${ROOT_DOMAIN}/dns/records" \
  -H "Authorization: Bearer ${HOSTINGER_KEY}" \
  -H "Content-Type: application/json" \
  -d "{
    \"type\": \"A\",
    \"name\": \"${SUBDOMAIN_PREFIX}\",
    \"content\": \"${SERVER_IP}\",
    \"ttl\": 300
  }" 2>/dev/null) || true

DNS_BODY=$(echo "$DNS_RESPONSE" | head -n -1)
DNS_CODE=$(echo "$DNS_RESPONSE" | tail -n 1)

if [[ "$DNS_CODE" == "200" || "$DNS_CODE" == "201" ]]; then
  log "DNS A record created: $DOMAIN > $SERVER_IP"
  warn "DNS propagation takes 2-10 min. SSL step will wait."
else
  warn "DNS API returned HTTP $DNS_CODE"
  warn "Response: $DNS_BODY"
  warn "Continuing -- add DNS manually if needed"
fi

# ════════════════════════════════════════════════════════════
#  SECTION 4 — CREATE USER
# ════════════════════════════════════════════════════════════
section "PHASE 3 -- System User"

if id "openfang" &>/dev/null; then
  warn "User 'openfang' exists, skipping"
else
  useradd -m -s /bin/bash openfang || error "Failed to create user"
  log "Created user: openfang"
fi

OFDIR="/home/openfang/.openfang"

# ── Backup existing config if re-running ─────────────────────
if [[ -f "$OFDIR/config.toml" ]]; then
  BACKUP="$OFDIR/config.toml.bak.$(date +%s)"
  cp "$OFDIR/config.toml" "$BACKUP"
  warn "Existing config backed up to $BACKUP"
fi
if [[ -f "/etc/openfang.env" ]]; then
  ENVBAK="/etc/openfang.env.bak.$(date +%s)"
  cp "/etc/openfang.env" "$ENVBAK"
  warn "Existing env backed up to $ENVBAK"
fi

mkdir -p "$OFDIR"

# ════════════════════════════════════════════════════════════
#  SECTION 5 — INSTALL OPENFANG
# ════════════════════════════════════════════════════════════
section "PHASE 4 -- Install OpenFang Binary"

info "Running official installer..."
if su - openfang -c 'curl -fsSL https://openfang.sh/install | sh' 2>&1; then
  log "Official installer succeeded"
else
  warn "Official installer failed -- falling back to cargo build"

  if ! su - openfang -c 'command -v cargo' &>/dev/null; then
    info "Installing Rust toolchain..."
    if ! su - openfang -c \
      'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --quiet' 2>&1; then
      error "Failed to install Rust toolchain"
    fi
  fi

  info "Building from source (takes 5-10 min)..."
  if ! su - openfang -c \
    'source ~/.cargo/env && cargo install --git https://github.com/RightNow-AI/openfang openfang-cli --quiet' 2>&1; then
    error "Cargo build failed -- check build output above"
  fi
fi

# ── Find the binary (use command -v, not which) ──────────────
OF_BIN=$(su - openfang -c 'command -v openfang 2>/dev/null || echo ""')
if [[ -z "$OF_BIN" ]]; then
  OF_BIN="/home/openfang/.cargo/bin/openfang"
fi

# Verify binary actually exists
if ! su - openfang -c "test -x '$OF_BIN'"; then
  error "OpenFang binary not found at $OF_BIN -- install failed"
fi

log "Binary: $OF_BIN"
OF_VERSION=$(su - openfang -c "'$OF_BIN' --version" 2>/dev/null || echo "unknown")
log "Version: $OF_VERSION"

# ════════════════════════════════════════════════════════════
#  SECTION 6 — WRITE CONFIG
# ════════════════════════════════════════════════════════════
section "PHASE 5 -- Write Configuration"

# Build base_url line conditionally
PURL_LINE=""
if [[ -n "$PURL" ]]; then
  PURL_LINE="base_url = \"$PURL\""
fi

cat > "$OFDIR/config.toml" << TOML
# OpenFang Master Config
# Generated: $(date)

[kernel]
log_level = "info"
dashboard_port = $DASH_PORT

[dashboard]
username = "$DASH_USER"
password = "$DASH_PASS"

[provider]
default = "$PNAME"

[[providers]]
name = "$PNAME"
type = "$PTYPE"
${PURL_LINE:+$PURL_LINE
}api_key_env = "$PENV"
default_model = "$PMODEL"

[memory]
backend = "sqlite"
vector_embeddings = true
compaction_threshold = 20
session_ttl_days = 90
cross_channel = true

[[channels]]
type = "telegram"
bot_token_env = "TELEGRAM_BOT_TOKEN"
allowed_users = [$TG_USER_ID]

[approval]
auto_approve = false

[[agents]]
name = "$AGENT_NAME"
provider = "$PNAME"
model = "$PMODEL"
TOML

chown -R openfang:openfang "$OFDIR"
log "config.toml written"

# ── Env / secrets file (values quoted for safety) ────────────
cat > /etc/openfang.env << ENV
${PENV}="${API_KEY}"
TELEGRAM_BOT_TOKEN="${TG_TOKEN}"
OPENFANG_DATA_DIR="${OFDIR}"
ENV
chmod 600 /etc/openfang.env
log "Secrets written to /etc/openfang.env"

# ════════════════════════════════════════════════════════════
#  SECTION 7 — SYSTEMD
# ════════════════════════════════════════════════════════════
section "PHASE 6 -- Systemd Service"

cat > /etc/systemd/system/openfang.service << SERVICE
[Unit]
Description=OpenFang Agent Operating System
Documentation=https://openfang.sh/docs
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=openfang
Group=openfang
EnvironmentFile=/etc/openfang.env
ExecStart=$OF_BIN start
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=openfang
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=$OFDIR

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable openfang

# Stop existing if re-running
systemctl stop openfang 2>/dev/null || true
systemctl start openfang
sleep 4

if systemctl is-active --quiet openfang; then
  log "OpenFang service running"
else
  warn "Service may need a moment -- check: journalctl -u openfang -n 50"
  journalctl -u openfang -n 10 --no-pager 2>/dev/null || true
fi

# ════════════════════════════════════════════════════════════
#  SECTION 8 — FIREWALL
# ════════════════════════════════════════════════════════════
section "PHASE 7 -- Firewall (UFW)"

# Preserve existing rules — only add what's needed, don't reset
ufw default deny incoming > /dev/null 2>&1 || true
ufw default allow outgoing > /dev/null 2>&1 || true
ufw allow ssh > /dev/null 2>&1 || true
ufw allow 80/tcp > /dev/null 2>&1 || true
ufw allow 443/tcp > /dev/null 2>&1 || true

if ! ufw status | grep -q "Status: active"; then
  ufw --force enable > /dev/null 2>&1
fi

log "UFW: SSH + 80 + 443 open, dashboard port internal only"

# ════════════════════════════════════════════════════════════
#  SECTION 9 — NGINX
# ════════════════════════════════════════════════════════════
section "PHASE 8 -- Nginx Reverse Proxy"

cat > /etc/nginx/sites-available/openfang << NGINX
server {
    listen 80;
    server_name ${DOMAIN};

    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header Referrer-Policy "strict-origin-when-cross-origin";
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()";

    location / {
        proxy_pass http://127.0.0.1:${DASH_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
        proxy_buffering off;
    }
}
NGINX

ln -sf /etc/nginx/sites-available/openfang /etc/nginx/sites-enabled/openfang
rm -f /etc/nginx/sites-enabled/default

if nginx -t 2>&1; then
  systemctl restart nginx
  log "Nginx configured for $DOMAIN"
else
  error "Nginx config test failed -- check syntax above"
fi

# ════════════════════════════════════════════════════════════
#  SECTION 10 — SSL (wait for DNS propagation)
# ════════════════════════════════════════════════════════════
section "PHASE 9 -- SSL Certificate"

info "Waiting for DNS propagation (up to 3 min)..."
MAX_TRIES=18
COUNT=0
DNS_OK=false

while [ $COUNT -lt $MAX_TRIES ]; do
  # Try dig first (installed dnsutils), fall back to getent
  RESOLVED=""
  if command -v dig &>/dev/null; then
    RESOLVED=$(dig +short "$DOMAIN" 2>/dev/null | grep -E '^[0-9.]+$' | tail -1)
  fi
  if [[ -z "$RESOLVED" ]] && command -v getent &>/dev/null; then
    RESOLVED=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1)
  fi
  if [[ -z "$RESOLVED" ]]; then
    RESOLVED=$(nslookup "$DOMAIN" 2>/dev/null | awk '/^Address: / { print $2 }' | tail -1) || true
  fi

  if [ "$RESOLVED" = "$SERVER_IP" ]; then
    DNS_OK=true
    log "DNS confirmed: $DOMAIN > $SERVER_IP"
    break
  fi
  COUNT=$((COUNT + 1))
  info "  DNS not ready yet ($COUNT/$MAX_TRIES) -- waiting 10s... (got: ${RESOLVED:-none})"
  sleep 10
done

if [ "$DNS_OK" = true ]; then
  info "Requesting Let's Encrypt certificate..."
  if certbot --nginx \
    -d "$DOMAIN" \
    --non-interactive \
    --agree-tos \
    -m "$SSL_EMAIL" \
    --redirect 2>&1; then
    log "SSL installed -- HTTPS active"
    FINAL_URL="https://$DOMAIN"
  else
    warn "Certbot failed. Run manually after checking DNS:"
    warn "  certbot --nginx -d $DOMAIN -m $SSL_EMAIL --agree-tos"
    FINAL_URL="http://$DOMAIN"
  fi
else
  warn "DNS not propagated in time -- run certbot manually after DNS resolves:"
  warn "  certbot --nginx -d $DOMAIN -m $SSL_EMAIL --agree-tos"
  FINAL_URL="http://$DOMAIN"
fi

# ════════════════════════════════════════════════════════════
#  SECTION 11 — HEALTH CHECK
# ════════════════════════════════════════════════════════════
section "PHASE 10 -- Health Check"

sleep 2
HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
  "http://127.0.0.1:$DASH_PORT" 2>/dev/null || echo "000")

if [[ "$HTTP" =~ ^(200|302|401|403)$ ]]; then
  log "Dashboard responding (HTTP $HTTP)"
else
  warn "Dashboard HTTP $HTTP -- may still be booting"
  warn "Debug: journalctl -u openfang -n 20"
fi

TG_CHECK=$(curl -s --max-time 5 \
  "https://api.telegram.org/bot${TG_TOKEN}/getMe" 2>/dev/null | \
  jq -r '.result.username // "error"' 2>/dev/null || echo "check manually")
log "Telegram bot: @$TG_CHECK"

# ════════════════════════════════════════════════════════════
#  FINAL SUMMARY
# ════════════════════════════════════════════════════════════
echo ""
divider
echo -e "${G}${W}  OpenFang Deployed Successfully${N}"
divider
echo ""
echo -e "  ${W}Dashboard URL:${N}  $FINAL_URL"
echo -e "  ${W}Login:${N}          $DASH_USER / [your password]"
echo -e "  ${W}Telegram bot:${N}   @$TG_CHECK -- send /start to test"
echo ""
echo -e "  ${W}Service commands:${N}"
echo "    systemctl status openfang"
echo "    systemctl restart openfang"
echo "    journalctl -u openfang -f"
echo ""
echo -e "  ${W}Activate first Hand:${N}"
echo "    su - openfang -c 'openfang hand activate researcher'"
echo ""
echo -e "  ${W}Config file:${N}"
echo "    $OFDIR/config.toml"
divider
echo ""
