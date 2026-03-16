#!/bin/bash
# ============================================================
#  OPENFANG UNINSTALLER
#  Removes all OpenFang components from Debian 11/12
# ============================================================

set -uo pipefail

R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' W='\033[1m' N='\033[0m'
log()   { echo -e "${G}[+]${N} $1"; }
warn()  { echo -e "${Y}[!]${N} $1"; }
error() { echo -e "${R}[x]${N} $1"; exit 1; }

[[ "$EUID" -ne 0 ]] && error "Run as root: sudo bash $0"

echo -e "${R}${W}"
echo "  =============================================="
echo "   OpenFang UNINSTALLER"
echo "  =============================================="
echo -e "${N}"
echo -e "${Y}  This will remove:${N}"
echo "    - openfang systemd service"
echo "    - /etc/openfang.env (secrets)"
echo "    - /home/openfang/.openfang/ (config + data)"
echo "    - /etc/nginx/sites-available/openfang"
echo "    - Certbot certificate for the domain (optional)"
echo "    - System user 'openfang' (optional)"
echo ""
read -rp "  Are you sure? Type YES to continue: " CONFIRM
[[ "$CONFIRM" != "YES" ]] && { echo "Aborted."; exit 0; }

# ── Stop and disable service ──────────────────────────────────
if systemctl is-active --quiet openfang 2>/dev/null; then
  systemctl stop openfang
  log "Service stopped"
fi

if systemctl is-enabled --quiet openfang 2>/dev/null; then
  systemctl disable openfang
  log "Service disabled"
fi

if [[ -f /etc/systemd/system/openfang.service ]]; then
  rm -f /etc/systemd/system/openfang.service
  systemctl daemon-reload
  log "Systemd unit removed"
fi

# ── Remove secrets file ───────────────────────────────────────
if [[ -f /etc/openfang.env ]]; then
  # Wipe content before delete (sensitive data)
  shred -uz /etc/openfang.env 2>/dev/null || rm -f /etc/openfang.env
  log "Secrets file removed"
fi

# ── Remove Nginx config ───────────────────────────────────────
if [[ -f /etc/nginx/sites-enabled/openfang ]]; then
  rm -f /etc/nginx/sites-enabled/openfang
fi
if [[ -f /etc/nginx/sites-available/openfang ]]; then
  rm -f /etc/nginx/sites-available/openfang
  log "Nginx config removed"
fi

# Restore default site if nothing else is enabled
if [[ -z "$(ls /etc/nginx/sites-enabled/ 2>/dev/null)" ]]; then
  if [[ -f /etc/nginx/sites-available/default ]]; then
    ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    warn "Nginx default site restored"
  fi
fi

if systemctl is-active --quiet nginx 2>/dev/null; then
  if nginx -t 2>/dev/null; then
    systemctl reload nginx
    log "Nginx reloaded"
  fi
fi

# ── Remove SSL certificate (optional) ────────────────────────
echo ""
read -rp "  Remove SSL certificate? [y/N]: " RMSSL
RMSSL="${RMSSL:-n}"
if [[ "$RMSSL" =~ ^[Yy]$ ]]; then
  read -rp "  Domain to revoke certificate for: " CERT_DOMAIN
  if [[ -n "$CERT_DOMAIN" ]]; then
    certbot delete --cert-name "$CERT_DOMAIN" --non-interactive 2>/dev/null && \
      log "Certificate removed for $CERT_DOMAIN" || \
      warn "Certbot delete failed -- remove manually: certbot delete"
  fi
fi

# ── Remove data directory ─────────────────────────────────────
echo ""
read -rp "  Remove /home/openfang/.openfang/ (config + data)? [y/N]: " RMDATA
RMDATA="${RMDATA:-n}"
if [[ "$RMDATA" =~ ^[Yy]$ ]]; then
  if [[ -d /home/openfang/.openfang ]]; then
    rm -rf /home/openfang/.openfang
    log "Data directory removed"
  fi
fi

# ── Remove system user (optional) ────────────────────────────
echo ""
read -rp "  Remove system user 'openfang'? [y/N]: " RMUSR
RMUSR="${RMUSR:-n}"
if [[ "$RMUSR" =~ ^[Yy]$ ]]; then
  if id "openfang" &>/dev/null; then
    userdel -r openfang 2>/dev/null || userdel openfang
    log "User 'openfang' removed"
  fi
fi

echo ""
echo -e "${G}${W}  Uninstall complete.${N}"
echo ""
