# CTO Bot Deployment (OpenClaw + OpenAI)

This repository installs OpenClaw and deploys the **CTO Factory Agent** (`cto-factory`).

What CTO bot is for:
- safer agent creation workflow
- controlled rollout with backup and rollback
- config validation before apply
- operational helper flows for OpenClaw

This deployment package is tuned for **OpenAI API** (not OpenRouter).

## Prerequisites

You need:
- Ubuntu EC2 host
- SSH access as user `ubuntu` with `sudo`
- OpenAI API key (Pay-as-you-go), instruction provided in the first step
- Telegram bot token (from BotFather)
- Telegram numeric user ID

Out of scope in this guide:
- EC2 provisioning
- SSH key setup

If needed, use AWS docs:
- <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/EC2_GetStarted.html>

## Deploy On A Clean EC2

### 0) Get required tokens first

Before running any script on EC2, prepare both tokens:
- `OPENAI_API_KEY`
- `TELEGRAM_BOT_TOKEN`

#### 0.1) Create OpenAI API key

1. Open [OpenAI Platform](https://platform.openai.com/) and sign in.
2. Enable billing (Pay-as-you-go) for API usage.
3. Open [API Keys](https://platform.openai.com/api-keys) and create a new secret key.
4. Copy it once and store it in your password manager.

Notes:
- The key usually starts with `sk-...`
- You will paste it into Script `01` when prompted.

#### 0.2) Create Telegram bot token

In BotFather:
- create a bot
- copy bot token

Optional reference guide: [OpenClaw Community Guide](https://www.skool.com/ai-agents-openclaw/classroom/2a105da6?md=4501a64424d045de97b98683c8181b8c)

### 1) Bootstrap dependencies and clone repo

Run on the server:

```bash
curl -fsSL https://raw.githubusercontent.com/smart-spine/cto/main/scripts/00_bootstrap_dependencies.sh | bash
```

Script `00` will:
- install base dependencies
- clean stale NodeSource apt entries (if present)
- clone this repo into `~/cto`
- try to switch you into `~/cto`
- print color-highlighted next steps

If shell handoff is not available (common with `curl | bash`), run manually:

```bash
cd ~/cto
```

### 2) Install OpenClaw + Codex CLI

```bash
./scripts/01_install_openclaw.sh
```

What Script `01` asks from you:
- `OPENAI_API_KEY`

What Script `01` does:
- installs Node.js, OpenClaw CLI, Codex CLI
- authenticates Codex CLI with your OpenAI API key
- runs Codex connectivity healthcheck with retries
- writes runtime files under `~/.openclaw`
- auto-generates `OPENCLAW_GATEWAY_TOKEN` if missing and stores it in `~/.openclaw/.env`

### 3) Connect Telegram and approve pairing

```bash
./scripts/02_setup_telegram_pairing.sh
```

What Script `02` asks from you:
- `TELEGRAM_BOT_TOKEN`

What Script `02` does:
- enables Telegram plugin
- writes token into OpenClaw config
- restarts gateway
- waits for pairing trigger
- auto-approves pairing code

### 4) Get your Telegram numeric user ID

In Telegram, send this to your bot:

```text
/whoami
```

Save the numeric user ID.

### 5) Deploy CTO agent (direct chat binding)

```bash
./scripts/03_deploy_cto_agent.sh
```

Script `03` deploys `cto-factory` and binds it to **direct chat** with your Telegram user.

## Verify Deployment

Run on server:

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

## First Run Checklist

1. Open direct chat with your bot.
2. Send a simple test message.
3. Verify CTO replies.

Prompt example for first real task:

```text
Create a new agent called reddit-scraper.
It should monitor selected subreddits, extract top posts every 30 minutes,
and publish a short summary with links.
Ask me the required intake questions before implementation.
Stop at READY_FOR_APPLY.
```

Screenshot placeholders:
- `[TODO screenshot] BotFather token created`
- `[TODO screenshot] Pairing approved`
- `[TODO screenshot] CTO first reply in direct chat`

## Advanced: Rebind CTO To Group Topic

Default flow uses direct chat only.

For advanced users, to route CTO into a Telegram group topic after Script `03`:

```bash
./scripts/04_rebind_cto_to_topic.sh
```

You can pass either:
- `BIND_TELEGRAM_LINK="https://t.me/c/<group>/<topic>"`
- or explicit `BIND_GROUP_ID` + `BIND_TOPIC_ID`

## Update CTO Agent (Existing Install)

When new CTO changes are released, run:

```bash
cd ~/cto
./scripts/05_update_cto_agent.sh
```

What Script `05` does:
- updates this repository to latest `main` by default
- creates rollback backup under `~/.openclaw/backups/cto-update-<timestamp>`
- syncs updated `cto-factory` files into `~/.openclaw/workspace-factory`
- validates `openclaw.json`
- restarts gateway and runs CTO smoke check

Useful options:
- `UPDATE_REPO=false` (skip git pull, use local repo state)
- `CTO_REPO_REF=<tag-or-branch>` (pin update source)
- `SKIP_CTO_HEALTH_SMOKE=true` (skip local agent smoke)
- `RESTART_GATEWAY=false` (update files/config without restart)

## BETA Notes (Existing OpenClaw Installation)

> BETA: Scripts are designed to be additive, but this is not zero-risk for a busy multi-agent host.

Recommended before deployment:

```bash
cp ~/.openclaw/openclaw.json ~/.openclaw/openclaw.json.manual-backup.$(date +%Y%m%d-%H%M%S)
```

Known side effects in existing installs:
- gateway restarts can interrupt active runs
- global Telegram policy fields can be updated for CTO routing
- tool-level global settings may be updated (`tools.sessions.visibility`, `tools.agentToAgent`)

Use a maintenance window for production systems.

## Uninstall / Rollback Script

To remove OpenClaw/CTO stack from the host:

```bash
./scripts/99_uninstall_openclaw.sh
```

Options:
- `REMOVE_REPO=true` to also delete `~/cto`
- `WIPE_NODE_STACK=true` (default) to remove Node/OpenClaw/Codex binaries

## Security Notes

- Never commit real API keys or Telegram tokens.
- Keep secrets in `~/.openclaw/.env` with strict permissions.
- Keep gateway token in a password manager.
