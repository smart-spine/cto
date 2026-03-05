# CTO Bot Deployment (OpenClaw + OpenAI)

This repository installs OpenClaw and deploys the **CTO Factory Agent** (`cto-factory`).

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
- Your Telegram user ID (Covered in step 5 but can also be received from @userinfobot in Telegram)
- [Optional] Your Telegram group's topic link (can be copied from the topic page in Telegram)

## Quick Start (Clean EC2)
### 0) Bootstrap dependencies
Run this on the server:

```bash
curl -fsSL https://raw.githubusercontent.com/smart-spine/cto/main/scripts/00_bootstrap_dependencies.sh | bash
```

What script `00` does:
- installs system dependencies
- cleans stale NodeSource apt records if present
- clones this repo to `~/cto`
- tries to open an interactive shell in `~/cto` (interactive terminals only)
- if shell handoff is unavailable (for example `curl | bash`), it prints a clear manual `cd ~/cto` step
- prints color-highlighted next commands

## Step-by-Step

### 1) Create OpenAI API key

1. Open [OpenAI Platform](https://platform.openai.com/) and sign in.
2. Ensure billing is enabled for API usage (Pay-as-you-go).
3. Open [API keys](https://platform.openai.com/api-keys) and create a new secret key.
4. Copy the key once and store it in a password manager.

Key format usually starts with `sk-...`.
You will paste this key into Script 1 when prompted for `OPENAI_API_KEY`.

### 2) Install OpenClaw + Codex CLI

```bash
./scripts/01_install_openclaw.sh
```

You will be prompted for:
- `OPENAI_API_KEY`

Important:
- Script 1 auto-generates `OPENCLAW_GATEWAY_TOKEN` when not provided.
- Script 1 prints the generated token and where it is stored (`~/.openclaw/.env`).
- Save the generated gateway token in a password manager.
- Script 1 also performs Codex CLI authentication using your OpenAI key.
- Script 1 runs a Codex healthcheck (`codex exec`) with retries before deployment continues.
- Temporary healthcheck artifacts are auto-cleaned after the check.

### 3) Create Telegram bot and get token

In BotFather:
- create a bot (detailed walkthrough in the community guide:
  https://www.skool.com/ai-agents-openclaw/classroom/2a105da6?md=4501a64424d045de97b98683c8181b8c)
- copy bot token

### 4) Connect Telegram and approve pairing

```bash
./scripts/02_setup_telegram_pairing.sh
```

This script:
- enables Telegram plugin
- writes token into OpenClaw config
- restarts gateway
- waits for pairing request
- auto-approves pairing code

### 5) Get your Telegram user ID

Send this to your bot in Telegram:

```text
/whoami
```

Save the numeric user ID.

### 6) Deploy CTO agent and choose binding mode

```bash
./scripts/03_deploy_cto_agent.sh
```

The script shows a numeric menu and asks you to choose one option:

1. `1` = `direct` (DM with bot)
- bind CTO to your private chat with the bot
- best for admin/ops workflows

2. `2` = `topic` (group topic)
- bind CTO to a specific Telegram topic
- script accepts a link like `https://t.me/c/<group>/<topic>` and parses IDs automatically

## BETA Notes (Existing OpenClaw Install)

> **BETA:** The scripts are designed to be additive and safe, but this is not a zero-risk migration path for a busy multi-agent instance.

### Backup first (required)

Script 3 creates timestamped backups of `~/.openclaw/openclaw.json` before patching.

Still take your own manual backup before running deploy on a live system:

```bash
cp ~/.openclaw/openclaw.json ~/.openclaw/openclaw.json.manual-backup.$(date +%Y%m%d-%H%M%S)
```

You can run this repository on top of an already configured OpenClaw instance.

What is relatively safe:
- files are isolated to `workspace-factory` and `.cto-brain` paths
- script 3 updates or adds only the `cto-factory` agent entry
- script 3 replaces bindings for `cto-factory` only, not all bindings
- final `openclaw config validate --json` is executed before completion

Known side-effect risks:
- script 3 restarts gateway more than once, so active agent runs can be interrupted
- Telegram global/account policy fields may be updated for CTO routing and allowlists
- tool-level settings can be changed globally (`tools.sessions.visibility`, `tools.agentToAgent`)
- if your existing setup depends on stricter session isolation or broader Telegram access, behavior can change

Still recommended:
- run in a maintenance window
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

## Usage

### Create your first agent

After deployment, open your CTO chat (DM or bound topic) and send a direct task.

Example:

```text
Create a new agent called reddit-scraper.
It should monitor selected subreddits, extract top posts every 30 minutes,
and publish a short summary with links.
Ask me the required intake questions before implementation.
Stop at READY_FOR_APPLY.
```

### Quick sanity flow

- ask CTO to create an agent
- review generated files and config changes
- approve apply
- run a smoke check in chat

## Security Notes

- Never commit real API keys or Telegram tokens.
- Keep secrets in `~/.openclaw/.env` (0600 permissions).
- Gateway defaults to loopback bind and token auth.
