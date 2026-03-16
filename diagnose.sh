#!/bin/bash
# ============================================================
#  OPENFANG DIAGNOSTICS
#  Full system health check — run as root on the VPS
# ============================================================

set -uo pipefail

R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m'
B='\033[0;34m' C='\033[0;36m' W='\033[1m' N='\033[0m'

PASS=0; FAIL=0; WARN=0

ok()   { echo -e "  ${G}[PASS]${N} $1"; PASS=$((PASS+1)); }
fail() { echo -e "  ${R}[FAIL]${N} $1"; FAIL=$((FAIL+1)); }
warn() { echo -e "  ${Y}[WARN]${N} $1"; WARN=$((WARN+1)); }
info() { echo -e "  ${B}[INFO]${N} $1"; }
section() { echo ""; echo -e "${C}${W}--- $1 ---${N}"; }

[[ "$EUID" -ne 0 ]] && { echo "Run as root for full diagnostics"; }

OFDIR="/home/openfang/.openfang"
ENVFILE="/etc/openfang.env"

echo -e "${C}${W}"
echo "  =============================================="
echo "   OpenFang Diagnostics"
echo "   $(date)"
echo "  =============================================="
echo -e "${N}"

# ── SECTION 1: OS ────────────────────────────────────────────
section "System"
OS=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo "unknown")
info "OS: $OS"
info "Kernel: $(uname -r)"
info "Uptime: $(uptime -p 2>/dev/null || uptime)"
info "Load: $(cat /proc/loadavg | awk '{print $1, $2, $3}')"
FREE_MEM=$(free -m | awk '/^Mem:/{print $4}')
TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
info "Memory: ${FREE_MEM}MB free / ${TOTAL_MEM}MB total"
DISK_USE=$(df -h / | awk 'NR==2{print $5}')
DISK_FREE=$(df -h / | awk 'NR==2{print $4}')
info "Disk: $DISK_USE used, $DISK_FREE free on /"
if [[ "${DISK_USE%\%}" -ge 90 ]]; then
  fail "Disk usage critical: $DISK_USE"
elif [[ "${DISK_USE%\%}" -ge 75 ]]; then
  warn "Disk usage high: $DISK_USE"
else
  ok "Disk usage OK: $DISK_USE"
fi

# ── SECTION 2: User ──────────────────────────────────────────
section "System User"
if id "openfang" &>/dev/null; then
  ok "User 'openfang' exists"
else
  fail "User 'openfang' not found"
fi

if [[ -d "$OFDIR" ]]; then
  ok "Data dir exists: $OFDIR"
  OWNER=$(stat -c '%U' "$OFDIR" 2>/dev/null || echo "unknown")
  if [[ "$OWNER" == "openfang" ]]; then
    ok "Data dir ownership correct (openfang)"
  else
    fail "Data dir owned by '$OWNER', expected 'openfang'"
  fi
else
  fail "Data dir missing: $OFDIR"
fi

# ── SECTION 3: Binary ────────────────────────────────────────
section "OpenFang Binary"
OF_BIN=$(su - openfang -c 'command -v openfang 2>/dev/null || echo ""' 2>/dev/null || echo "")
[[ -z "$OF_BIN" ]] && OF_BIN="/home/openfang/.cargo/bin/openfang"

if [[ -x "$OF_BIN" ]]; then
  ok "Binary found: $OF_BIN"
  VERSION=$(su - openfang -c "'$OF_BIN' --version" 2>/dev/null || echo "unknown")
  info "Version: $VERSION"
else
  fail "Binary not found or not executable at $OF_BIN"
fi

# ── SECTION 4: Config ────────────────────────────────────────
section "Configuration"
if [[ -f "$OFDIR/config.toml" ]]; then
  ok "config.toml exists"
  CFGPERMS=$(stat -c '%a' "$OFDIR/config.toml" 2>/dev/null || echo "???")
  info "Permissions: $CFGPERMS"
  # Check required sections
  for section_name in "kernel" "dashboard" "provider" "memory"; do
    if grep -q "^\[$section_name\]" "$OFDIR/config.toml" 2>/dev/null; then
      ok "TOML section [$section_name] present"
    else
      fail "TOML section [$section_name] missing"
    fi
  done
else
  fail "config.toml missing: $OFDIR/config.toml"
fi

if [[ -f "$ENVFILE" ]]; then
  ok "Env file exists: $ENVFILE"
  ENVPERMS=$(stat -c '%a' "$ENVFILE" 2>/dev/null || echo "???")
  if [[ "$ENVPERMS" == "600" ]]; then
    ok "Env file permissions: $ENVPERMS (correct)"
  else
    fail "Env file permissions: $ENVPERMS (should be 600)"
  fi
  # Check required keys present (without printing values)
  for key in "TELEGRAM_BOT_TOKEN" "OPENFANG_DATA_DIR"; do
    if grep -q "^${key}=" "$ENVFILE" 2>/dev/null; then
      ok "Env key present: $key"
    else
      fail "Env key missing: $key"
    fi
  done
else
  fail "Env file missing: $ENVFILE"
fi

# ── SECTION 5: Systemd ───────────────────────────────────────
section "Systemd Service"
if [[ -f /etc/systemd/system/openfang.service ]]; then
  ok "Service unit file present"
else
  fail "Service unit file missing: /etc/systemd/system/openfang.service"
fi

if systemctl is-enabled --quiet openfang 2>/dev/null; then
  ok "Service enabled (auto-start on boot)"
else
  warn "Service not enabled — won't start on reboot"
fi

SVC_STATE=$(systemctl is-active openfang 2>/dev/null || echo "inactive")
if [[ "$SVC_STATE" == "active" ]]; then
  ok "Service is active/running"
  SVC_PID=$(systemctl show openfang --property=MainPID --value 2>/dev/null || echo "unknown")
  SVC_UPTIME=$(systemctl show openfang --property=ActiveEnterTimestamp --value 2>/dev/null || echo "unknown")
  info "PID: $SVC_PID | Running since: $SVC_UPTIME"
elif [[ "$SVC_STATE" == "activating" ]]; then
  warn "Service is still starting up"
else
  fail "Service is $SVC_STATE"
  info "Last 5 log lines:"
  journalctl -u openfang -n 5 --no-pager 2>/dev/null | sed 's/^/    /' || true
fi

# ── SECTION 6: Network / Ports ───────────────────────────────
section "Network & Ports"
DASH_PORT=$(grep 'dashboard_port' "$OFDIR/config.toml" 2>/dev/null | grep -oP '\d+' | head -1 || echo "4200")
info "Expected dashboard port: $DASH_PORT"

if command -v ss &>/dev/null; then
  if ss -tlnp 2>/dev/null | grep -q ":$DASH_PORT "; then
    ok "Dashboard port $DASH_PORT is listening"
  else
    fail "Nothing listening on port $DASH_PORT"
  fi
  if ss -tlnp 2>/dev/null | grep -q ':80 '; then
    ok "Port 80 is listening (Nginx)"
  else
    fail "Port 80 not listening"
  fi
  if ss -tlnp 2>/dev/null | grep -q ':443 '; then
    ok "Port 443 is listening (HTTPS)"
  else
    warn "Port 443 not listening — SSL may not be configured yet"
  fi
fi

# ── SECTION 7: Dashboard HTTP ────────────────────────────────
section "Dashboard HTTP"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
  "http://127.0.0.1:${DASH_PORT}" 2>/dev/null || echo "000")

if [[ "$HTTP" =~ ^(200|302|401|403)$ ]]; then
  ok "Dashboard responding: HTTP $HTTP"
else
  fail "Dashboard not responding: HTTP $HTTP"
fi

# ── SECTION 8: Nginx ─────────────────────────────────────────
section "Nginx"
if systemctl is-active --quiet nginx 2>/dev/null; then
  ok "Nginx is running"
else
  fail "Nginx is not running"
fi

if [[ -f /etc/nginx/sites-enabled/openfang ]]; then
  ok "OpenFang nginx site is enabled"
else
  fail "OpenFang nginx site not enabled"
fi

if nginx -t 2>/dev/null; then
  ok "Nginx config syntax valid"
else
  fail "Nginx config syntax error"
fi

# ── SECTION 9: SSL ───────────────────────────────────────────
section "SSL Certificate"
DOMAIN=$(grep 'server_name' /etc/nginx/sites-available/openfang 2>/dev/null | awk '{print $2}' | tr -d ';' | head -1 || echo "")

if [[ -n "$DOMAIN" ]]; then
  info "Domain: $DOMAIN"
  CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  if [[ -f "$CERT_PATH" ]]; then
    ok "SSL certificate exists"
    EXPIRY=$(openssl x509 -in "$CERT_PATH" -noout -enddate 2>/dev/null | cut -d= -f2 || echo "unknown")
    info "Expires: $EXPIRY"
    # Check days until expiry
    EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null || echo "0")
    NOW_EPOCH=$(date +%s)
    DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
    if [[ $DAYS_LEFT -gt 30 ]]; then
      ok "Certificate valid for $DAYS_LEFT days"
    elif [[ $DAYS_LEFT -gt 0 ]]; then
      warn "Certificate expires in $DAYS_LEFT days — renew soon"
    else
      fail "Certificate has expired!"
    fi
  else
    warn "No SSL certificate found — run certbot or check DNS"
  fi
else
  warn "Could not detect domain from nginx config"
fi

# ── SECTION 10: Telegram ─────────────────────────────────────
section "Telegram Bot"
if [[ -f "$ENVFILE" ]]; then
  TG_TOKEN=$(grep '^TELEGRAM_BOT_TOKEN=' "$ENVFILE" | cut -d'"' -f2 | head -1 || echo "")
  if [[ -n "$TG_TOKEN" ]]; then
    TG_RESP=$(curl -s --max-time 8 "https://api.telegram.org/bot${TG_TOKEN}/getMe" 2>/dev/null || echo '{}')
    TG_OK=$(echo "$TG_RESP" | grep -o '"ok":true' || echo "")
    if [[ -n "$TG_OK" ]]; then
      TG_NAME=$(echo "$TG_RESP" | grep -o '"username":"[^"]*"' | cut -d'"' -f4)
      ok "Telegram bot reachable: @$TG_NAME"
    else
      fail "Telegram bot API error — check token"
      info "Response: $TG_RESP"
    fi
  else
    fail "TELEGRAM_BOT_TOKEN empty in $ENVFILE"
  fi
else
  warn "Env file not found — cannot check Telegram"
fi

# ── SECTION 11: Firewall ─────────────────────────────────────
section "Firewall (UFW)"
if command -v ufw &>/dev/null; then
  UFW_STATUS=$(ufw status 2>/dev/null | head -1 || echo "unknown")
  if echo "$UFW_STATUS" | grep -q "active"; then
    ok "UFW is active"
    for PORT in "22" "80" "443"; do
      if ufw status 2>/dev/null | grep -qE "^${PORT}[/ ]"; then
        ok "Port $PORT allowed"
      else
        warn "Port $PORT may not be allowed in UFW"
      fi
    done
    # Check dashboard port is NOT exposed externally
    if ufw status 2>/dev/null | grep -qE "^${DASH_PORT}[/ ]"; then
      warn "Dashboard port $DASH_PORT is open externally (should be internal only)"
    else
      ok "Dashboard port $DASH_PORT correctly blocked externally"
    fi
  else
    warn "UFW is not active"
  fi
else
  warn "UFW not installed"
fi

# ── SUMMARY ──────────────────────────────────────────────────
echo ""
echo -e "${C}$(printf '%.0s-' $(seq 1 50))${N}"
echo -e "${W}  RESULTS${N}"
echo -e "${C}$(printf '%.0s-' $(seq 1 50))${N}"
echo -e "  ${G}PASS: $PASS${N}  |  ${Y}WARN: $WARN${N}  |  ${R}FAIL: $FAIL${N}"
echo ""

if [[ $FAIL -eq 0 && $WARN -eq 0 ]]; then
  echo -e "  ${G}${W}All checks passed. OpenFang looks healthy.${N}"
elif [[ $FAIL -eq 0 ]]; then
  echo -e "  ${Y}${W}$WARN warning(s) — review above.${N}"
else
  echo -e "  ${R}${W}$FAIL failure(s) detected — review above.${N}"
  exit 1
fi
echo ""
