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
#
#  Two modes:
#    Interactive (default): prompts user for each value
#    Non-interactive:       set OPENFANG_NONINTERACTIVE=1 and
#                           provide all OF_* env vars (used by CI/CD)
#
#  Required env vars for non-interactive mode:
#    OF_PROVIDER        groq | openrouter | anthropic | openai
#    OF_API_KEY         LLM provider API key
#    OF_TG_TOKEN        Telegram bot token
#    OF_TG_USER_ID      Telegram numeric user ID
#    OF_DASH_USER       Dashboard username        (default: admin)
#    OF_DASH_PASS       Dashboard password
#    OF_DASH_PORT       Dashboard internal port   (default: 4200)
#    OF_DOMAIN          Full subdomain (e.g. openfang.example.com)
#    OF_HOSTINGER_KEY   Hostinger API key
#    OF_ROOT_DOMAIN     Root domain (e.g. example.com)
#    OF_SSL_EMAIL       Let's Encrypt email
#    OF_AGENT_NAME      Agent name                (default: assistant)
# ════════════════════════════════════════════════════════════
section "STEP 1 -- Configuration"

NONINTERACTIVE="${OPENFANG_NONINTERACTIVE:-0}"

# ── Helper: prompt or use env var ────────────────────────────
# Usage: prompt_or_env VARNAME "Prompt text" [default] [secret]
prompt_or_env() {
  local varname="$1" prompt="$2" default="${3:-}" secret="${4:-}"
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    # In CI mode — value must already be set via env
    local val="${!varname:-$default}"
    printf -v "$varname" '%s' "$val"
  else
    ask "$prompt${default:+ [default: $default]}:"
    if [[ "$secret" == "secret" ]]; then
      read -rsp "  > " "$varname"; echo ""
    else
      read -rp "  > " "$varname"
    fi
    # Apply default if empty
    if [[ -z "${!varname}" && -n "$default" ]]; then
      printf -v "$varname" '%s' "$default"
    fi
  fi
}

# ── LLM Provider ─────────────────────────────────────────────
if [[ "$NONINTERACTIVE" == "1" ]]; then
  PROVIDER_NAME="${OF_PROVIDER:-groq}"
  case "$PROVIDER_NAME" in
    groq)       PROVIDER_CHOICE=1 ;;
    openrouter) PROVIDER_CHOICE=2 ;;
    anthropic)  PROVIDER_CHOICE=3 ;;
    openai)     PROVIDER_CHOICE=4 ;;
    *) error "OF_PROVIDER must be: groq | openrouter | anthropic | openai" ;;
  esac
else
  echo ""
  echo -e "${W}LLM Provider:${N}"
  echo "  1) Groq        (free tier, fastest -- recommended)"
  echo "  2) OpenRouter  (multi-provider pool, free models)"
  echo "  3) Anthropic   (Claude)"
  echo "  4) OpenAI"
  echo ""
  ask "Choose provider [1-4]:"
  read -rp "  > " PROVIDER_CHOICE
fi

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
  *) error "Invalid choice: $PROVIDER_CHOICE" ;;
esac

# In non-interactive mode read all values from OF_* env vars
if [[ "$NONINTERACTIVE" == "1" ]]; then
  API_KEY="${OF_API_KEY:-}"
  TG_TOKEN="${OF_TG_TOKEN:-}"
  TG_USER_ID="${OF_TG_USER_ID:-}"
  DASH_USER="${OF_DASH_USER:-admin}"
  DASH_PASS="${OF_DASH_PASS:-}"
  DASH_PORT="${OF_DASH_PORT:-4200}"
  DOMAIN="${OF_DOMAIN:-}"
  HOSTINGER_KEY="${OF_HOSTINGER_KEY:-}"
  ROOT_DOMAIN="${OF_ROOT_DOMAIN:-}"
  SSL_EMAIL="${OF_SSL_EMAIL:-}"
  AGENT_NAME="${OF_AGENT_NAME:-assistant}"
else
  ask "$PNAME API key:"
  read -rsp "  > " API_KEY; echo ""

  echo ""
  ask "Telegram Bot Token (from @BotFather):"
  read -rsp "  > " TG_TOKEN; echo ""

  ask "Your Telegram numeric User ID (get from @userinfobot):"
  read -rp "  > " TG_USER_ID

  echo ""
  ask "Dashboard username [default: admin]:"
  read -rp "  > " DASH_USER; DASH_USER="${DASH_USER:-admin}"

  ask "Dashboard password:"
  read -rsp "  > " DASH_PASS; echo ""

  ask "Dashboard internal port [default: 4200]:"
  read -rp "  > " DASH_PORT; DASH_PORT="${DASH_PORT:-4200}"

  echo ""
  ask "Your subdomain for OpenFang (e.g. openfang.yourdomain.com):"
  read -rp "  > " DOMAIN

  ask "Your Hostinger API key (Portal > Account > API):"
  read -rsp "  > " HOSTINGER_KEY; echo ""

  ask "Root domain registered in Hostinger (e.g. yourdomain.com):"
  read -rp "  > " ROOT_DOMAIN

  ask "SSL email for Let's Encrypt:"
  read -rp "  > " SSL_EMAIL

  echo ""
  ask "Agent name [default: assistant]:"
  read -rp "  > " AGENT_NAME; AGENT_NAME="${AGENT_NAME:-assistant}"
fi

# ── Validate all collected values ────────────────────────────
require_nonempty "$API_KEY"       "API key"
require_nonempty "$TG_TOKEN"      "Telegram bot token"
require_numeric  "$TG_USER_ID"    "Telegram User ID"
require_nonempty "$DASH_PASS"     "Dashboard password"
require_numeric  "$DASH_PORT"     "Dashboard port"
require_domain   "$DOMAIN"        "Domain"
require_nonempty "$HOSTINGER_KEY" "Hostinger API key"
require_domain   "$ROOT_DOMAIN"   "Root domain"
require_email    "$SSL_EMAIL"     "SSL email"

# ── Summary (always shown) ────────────────────────────────────
echo ""
divider
echo -e "${W}  Summary${N}"
divider
echo "  Mode        : ${NONINTERACTIVE/1/non-interactive (CI)}"
echo "  Mode        : ${NONINTERACTIVE/0/interactive}"
echo "  Provider    : $PNAME > $PMODEL"
echo "  Telegram    : user ID $TG_USER_ID"
echo "  Dashboard   : port $DASH_PORT (user: $DASH_USER)"
echo "  Domain      : $DOMAIN"
echo "  Root domain : $ROOT_DOMAIN"
echo "  SSL email   : $SSL_EMAIL"
echo "  Agent name  : $AGENT_NAME"
divider
echo ""

if [[ "$NONINTERACTIVE" != "1" ]]; then
  ask "Everything correct? Proceed with full install? [Y/n]:"
  read -rp "  > " GO; GO="${GO:-y}"
  [[ ! "$GO" =~ ^[Yy]$ ]] && { echo "Aborted."; exit 0; }
else
  log "Non-interactive mode: proceeding automatically"
fi

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

DNS_RESPONSE=$(curl -s -w "\n%{http_code}" --max-time 15 -X PUT \
  "https://developers.hostinger.com/api/dns/v1/zones/${ROOT_DOMAIN}" \
  -H "Authorization: Bearer ${HOSTINGER_KEY}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -H "User-Agent: openfang-installer/1.0" \
  -d "{
    \"overwrite\": false,
    \"zone\": [
      {
        \"name\": \"${SUBDOMAIN_PREFIX}\",
        \"type\": \"A\",
        \"ttl\": 300,
        \"records\": [
          { \"content\": \"${SERVER_IP}\" }
        ]
      }
    ]
  }" 2>/dev/null) || true

DNS_BODY=$(echo "$DNS_RESPONSE" | head -n -1)
DNS_CODE=$(echo "$DNS_RESPONSE" | tail -n 1)

if [[ "$DNS_CODE" == "200" || "$DNS_CODE" == "201" ]]; then
  log "DNS A record created: $DOMAIN > $SERVER_IP"
  warn "DNS propagation takes 2-10 min. SSL step will wait."
elif echo "$DNS_BODY" | grep -q "Request accepted"; then
  log "DNS A record accepted: $DOMAIN > $SERVER_IP"
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
