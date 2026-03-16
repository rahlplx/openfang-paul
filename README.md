# OpenFang Master Installer

One-command installer for OpenFang on Debian 11/12 with Telegram + Web Dashboard, Nginx reverse proxy, SSL, and Hostinger DNS.

---

## Quick Start (manual, on VPS as root)

```bash
ssh root@YOUR_VPS_IP
curl -fsSL https://raw.githubusercontent.com/rahlplx/openfang-paul/claude/create-new-repo-7zWrU/install.sh -o install.sh
chmod +x install.sh
bash install.sh
```

---

## GitHub Actions Deploy (recommended for CI/CD)

### Step 1 — Add Repository Secrets

Go to: **GitHub repo → Settings → Secrets and variables → Actions → New repository secret**

| Secret name | Value |
|-------------|-------|
| `VPS_HOST` | `178.104.62.75` |
| `VPS_USER` | `root` |
| `VPS_PASSWORD` | your VPS root password |
| `OF_API_KEY` | your LLM provider API key (Groq/OpenRouter/Anthropic/OpenAI) |
| `OF_TG_TOKEN` | Telegram bot token from @BotFather |
| `OF_TG_USER_ID` | your Telegram numeric user ID (from @userinfobot) |
| `OF_DASH_PASS` | dashboard password |
| `OF_HOSTINGER_KEY` | Hostinger API key (Portal → Account → API) |
| `OF_SSL_EMAIL` | email for Let's Encrypt SSL |

### Step 2 — Trigger the Workflow

Go to: **Actions → Deploy OpenFang to VPS → Run workflow**

Fill in the inputs:

| Input | Example | Description |
|-------|---------|-------------|
| `provider` | `groq` | LLM provider |
| `domain` | `agency.trendtoksocial.com` | Full subdomain |
| `root_domain` | `trendtoksocial.com` | Root domain in Hostinger |
| `agent_name` | `assistant` | Agent display name |
| `dash_port` | `4200` | Internal dashboard port |
| `mode` | `install` | install / update / diagnose / uninstall |

### Step 3 — Watch it run

The workflow has 3 jobs that run in sequence:

```
Pre-flight (lint + secret check)
     ↓
Deploy (SSH → VPS → run script)
     ↓
Health Check (diagnose.sh + HTTPS endpoint)
```

---

## Scripts

| Script | Purpose |
|--------|---------|
| `install.sh` | Full install: deps → DNS → binary → config → nginx → SSL |
| `update.sh` | Update binary + restart service |
| `uninstall.sh` | Clean removal with optional data/cert/user wipe |
| `diagnose.sh` | Full health check: service, ports, SSL, Telegram, firewall |

---

## Non-interactive Mode (env var driven)

All scripts support `OPENFANG_NONINTERACTIVE=1` to skip prompts:

```bash
export OPENFANG_NONINTERACTIVE=1
export OF_PROVIDER=groq
export OF_API_KEY=your-key
export OF_TG_TOKEN=bot-token
export OF_TG_USER_ID=123456789
export OF_DASH_PASS=password
export OF_DOMAIN=agency.trendtoksocial.com
export OF_ROOT_DOMAIN=trendtoksocial.com
export OF_HOSTINGER_KEY=hostinger-key
export OF_SSL_EMAIL=you@email.com
bash install.sh
```

---

## Install Phases

| Phase | Action |
|-------|--------|
| **Config** | Collect/validate: LLM provider, API key, Telegram, dashboard, domain, SSL |
| **Phase 1** | System update + dependency install (incl. dnsutils, jq) |
| **Phase 2** | Hostinger DNS API — creates A record automatically |
| **Phase 3** | Creates `openfang` system user |
| **Phase 4** | Installs binary (official script with cargo fallback) |
| **Phase 5** | Writes `config.toml` + `/etc/openfang.env` (mode 600) |
| **Phase 6** | Systemd service (enable + start + auto-restart) |
| **Phase 7** | UFW firewall (SSH + 80 + 443 only, no reset of existing rules) |
| **Phase 8** | Nginx reverse proxy with security headers |
| **Phase 9** | DNS propagation wait (3 min max) + certbot SSL |
| **Phase 10** | Health check — dashboard HTTP + Telegram bot verify |

---

## Requirements

- Debian 11 or 12
- Root access
- A domain managed in Hostinger DNS
- Telegram bot token (from @BotFather)
