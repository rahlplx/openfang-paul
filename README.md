# OpenFang Master Installer

One-command installer for OpenFang on Debian 11/12 with Telegram + Web Dashboard, Nginx reverse proxy, SSL, and Hostinger DNS.

## Quick Start

On your VPS as root:

```bash
bash <(curl -fsSL YOUR_HOSTED_SCRIPT_URL)
```

Or manually:

```bash
nano install.sh      # paste the script
chmod +x install.sh
bash install.sh
```

## What It Does

| Phase | Action |
|-------|--------|
| **Config** | Prompts for: LLM provider, API key, Telegram creds, dashboard creds, domain, Hostinger key, SSL email |
| **Phase 1** | System update + dependency install |
| **Phase 2** | Hostinger DNS API — creates A record automatically |
| **Phase 3** | Creates `openfang` system user |
| **Phase 4** | Installs binary (official script with cargo fallback) |
| **Phase 5** | Writes `config.toml` + `/etc/openfang.env` |
| **Phase 6** | Systemd service (enable + start + auto-restart) |
| **Phase 7** | UFW firewall (SSH + 80 + 443 only) |
| **Phase 8** | Nginx reverse proxy with security headers |
| **Phase 9** | DNS propagation wait + certbot SSL |
| **Phase 10** | Health check — dashboard + Telegram bot verify |

## Supported LLM Providers

- **Groq** (recommended — free tier, fastest)
- **OpenRouter** (multi-provider, free models)
- **Anthropic** (Claude)
- **OpenAI**

## Requirements

- Debian 11 or 12
- Root access
- A domain with Hostinger DNS
- Telegram bot token (from @BotFather)
