# CTO Bot Deployment (OpenClaw + OpenAI)

This repository installs OpenClaw and deploys a production-ready **CTO Factory Agent** (`cto-factory`).

What this bot is for:
- safer agent creation workflow
- controlled rollout with backup/rollback
- config validation before apply
- operational helper flows for OpenClaw

The deployment package is tuned for **OpenAI** (not OpenRouter).

## Prerequisites

Out of scope in this guide:
- creating an EC2 instance
- SSH key management

If you need help with that, use AWS docs:
- https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/EC2_GetStarted.html

You need:
- Ubuntu EC2 host
- SSH access as user `ubuntu` (with `sudo`)
- OpenAI API key (Pay-as-you-go key from OpenAI Platform)
- Telegram bot token (from BotFather)
- Your Telegram user ID

## Quick Start (Clean EC2)

Run this on the server:

```bash
curl -fsSL https://raw.githubusercontent.com/smart-spine/cto/main/scripts/00_bootstrap_dependencies.sh | bash
```

What script `00` does:
- installs system dependencies
- cleans stale NodeSource apt records if present
- clones this repo to `~/cto`
- prints next commands

## Step-by-Step

### 1) Install OpenClaw + Codex CLI

```bash
cd ~/cto
chmod +x scripts/lib/common.sh scripts/00_bootstrap_dependencies.sh scripts/01_install_openclaw.sh scripts/02_setup_telegram_pairing.sh scripts/03_deploy_cto_agent.sh
./scripts/01_install_openclaw.sh
```

You will be prompted for:
- `OPENAI_API_KEY`
- gateway token mode:
  - `Auto-generate` (recommended)
  - `Manual input`

Important:
- Save the generated gateway token in a password manager.
- Script 1 also performs Codex CLI authentication using your OpenAI key.

### 2) Create Telegram bot and get token

In BotFather:
- create a bot
- copy bot token

### 3) Connect Telegram and approve pairing

```bash
./scripts/02_setup_telegram_pairing.sh
```

This script:
- enables Telegram plugin
- writes token into OpenClaw config
- restarts gateway
- waits for pairing request
- auto-approves pairing code

### 4) Get your Telegram user ID

Send this to your bot in Telegram:

```text
/whoami
```

Save the numeric user ID.

### 5) Deploy CTO agent and choose binding mode

```bash
./scripts/03_deploy_cto_agent.sh
```

You can bind CTO in two modes:

1. `direct` (DM with bot)
- bind CTO to your private chat with the bot
- best for admin/ops workflows

2. `topic` (group topic)
- bind CTO to a specific Telegram topic
- script accepts a link like `https://t.me/c/<group>/<topic>` and parses IDs automatically

## Existing OpenClaw Install (With Other Agents)

You can run this repository on top of an already configured OpenClaw instance.

Behavior:
- script 3 **adds/updates only** `cto-factory` agent and its bindings
- existing agents stay intact
- config is backed up before changes
- final config validation runs before completion

Still recommended:
- keep your own config backup
- review changes after deploy

## Verify Everything

Run:

```bash
openclaw --version
codex --version
openclaw config validate --json
openclaw health --json
```

Local CTO smoke:

```bash
openclaw agent --local --agent cto-factory --message "Reply with CTO_FACTORY_OK" --json
```

## How to Talk to CTO

If you selected **direct binding**:
- open bot DM
- send a normal text message
- all DM messages route to `cto-factory`

If you selected **topic binding**:
- send messages in that topic
- routing goes to `cto-factory` by binding match

Note:
- `/agents` in OpenClaw is informational. It does not "switch" your route by itself.
- Routing is defined by `bindings` in `openclaw.json`.

## Docker Validation (Maintainer)

Repository includes a Docker matrix test:

```bash
./scripts/90_test_docker_matrix.sh
```

Modes:
- `TEST_MODE=offline` (default): no live OpenAI calls
- `TEST_MODE=live`: full live flow (requires real `OPENAI_API_KEY`)

## Security Notes

- Never commit real API keys or Telegram tokens.
- Keep secrets in `~/.openclaw/.env` (0600 permissions).
- Gateway defaults to loopback bind and token auth.

## Reset EC2 to Near-Clean State

Use this if you want to remove OpenClaw/CTO stack after testing:

```bash
sudo bash -lc '
set -euo pipefail
pkill -f "openclaw gateway run" || true
pkill -f "openclaw" || true
rm -rf /home/ubuntu/.openclaw /home/ubuntu/.codex /home/ubuntu/cto
rm -rf /root/.openclaw /root/.codex /root/cto
npm uninstall -g openclaw @openai/codex >/dev/null 2>&1 || true
apt-get purge -y nodejs npm >/dev/null 2>&1 || true
apt-get autoremove -y >/dev/null 2>&1 || true
apt-get clean
'
```

For truly factory-state parity, recreate the EC2 instance from a fresh AMI.
