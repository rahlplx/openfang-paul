#!/bin/bash
# ============================================================
#  OPENFANG UPDATER
#  Updates OpenFang binary + restarts service
# ============================================================

set -uo pipefail

G='\033[0;32m' Y='\033[1;33m' R='\033[0;31m' W='\033[1m' N='\033[0m'
log()   { echo -e "${G}[+]${N} $1"; }
warn()  { echo -e "${Y}[!]${N} $1"; }
error() { echo -e "${R}[x]${N} $1"; exit 1; }

[[ "$EUID" -ne 0 ]] && error "Run as root: sudo bash $0"

OF_BIN=$(su - openfang -c 'command -v openfang 2>/dev/null || echo ""')
[[ -z "$OF_BIN" ]] && OF_BIN="/home/openfang/.cargo/bin/openfang"

echo -e "${W}  OpenFang Updater${N}"
echo ""
log "Current version: $(su - openfang -c "'$OF_BIN' --version" 2>/dev/null || echo 'unknown')"

# ── Stop service ───────────────────────────────────────────────
info() { echo -e "\033[0;34m[>]\033[0m $1"; }
info "Stopping service..."
systemctl stop openfang 2>/dev/null || true

# ── Attempt official installer update ─────────────────────────
info "Running update via official installer..."
if su - openfang -c 'curl -fsSL https://openfang.sh/install | sh' 2>&1; then
  log "Update via installer succeeded"
else
  warn "Installer failed -- trying cargo update..."
  if su - openfang -c 'command -v cargo' &>/dev/null; then
    if su - openfang -c \
      'source ~/.cargo/env && cargo install --git https://github.com/RightNow-AI/openfang openfang-cli --quiet' 2>&1; then
      log "Cargo update succeeded"
    else
      systemctl start openfang
      error "Update failed -- service restarted on old version"
    fi
  else
    systemctl start openfang
    error "No cargo available and installer failed -- service restarted on old version"
  fi
fi

# ── Restart service ────────────────────────────────────────────
info "Restarting service..."
systemctl start openfang
sleep 3

if systemctl is-active --quiet openfang; then
  log "Service running on new version"
  log "New version: $(su - openfang -c "'$OF_BIN' --version" 2>/dev/null || echo 'unknown')"
else
  warn "Service failed to start -- check: journalctl -u openfang -n 30"
  journalctl -u openfang -n 20 --no-pager 2>/dev/null || true
  exit 1
fi

echo ""
echo -e "${G}${W}  Update complete.${N}"
echo ""
