# CTO Agent Deployment Pack (OpenClaw)

This repo installs OpenClaw and deploys a CTO agent (`cto-factory`) that delegates implementation to **Codex CLI**.

Implementation policy inside CTO agent:
- code generation must go through `codex`
- configuration must pass `openclaw config validate --json`
- deployment flow follows guarded steps (backup, test, validate, apply)

## What You Need

- An EC2 Ubuntu server (SSH access as `ubuntu` with `sudo`)
- OpenAI API key
- Telegram bot token (if using Telegram)
- Telegram destination:
  - topic link (for example `https://t.me/c/1234567890/42` - just copy from the topic page), or
  - direct chat with your bot
- Your Telegram user ID you can get it via @userinfobot in Telegram

## Recommended Install Order

### 0) Bootstrap dependencies
Run this on the server first:

```bash
curl -fsSL https://raw.githubusercontent.com/smart-spine/cto-agent/main/scripts/00_bootstrap_dependencies.sh | bash
```

What this does:
- installs base dependencies
- clones this repo to `~/cto-agent`
- uses `main` by default (no automatic switch to `codex/*` branches)
- prints next commands

## Standard Install Order
Run from repo root:

```bash
cd ~/cto-agent
chmod +x scripts/lib/common.sh scripts/00_bootstrap_dependencies.sh scripts/01_install_openclaw.sh scripts/02_setup_telegram_pairing.sh scripts/03_deploy_cto_agent.sh
```

### 1) Install OpenClaw + Codex + local runtime config

```bash
./scripts/01_install_openclaw.sh
```

Script 1 will ask for:
- `OPENAI_API_KEY`
- gateway token mode:
  - auto-generate (recommended)
  - manual input

This deployment pack is tuned for **OpenAI only**.

### 2) Telegram setup + pairing

```bash
./scripts/02_setup_telegram_pairing.sh
```

What script 2 does:
- enables Telegram plugin if disabled
- configures bot token
- validates config
- restarts gateway
- waits for pairing request
- auto-approves pairing code
- auto-whitelists paired user ID in Telegram allowlists

### 3) Deploy CTO agent and choose Telegram binding mode

```bash
./scripts/03_deploy_cto_agent.sh
```

The script now asks where to bind the CTO bot:
- `topic`: paste a Telegram topic link, and the script auto-parses group/topic
  - supports `https://t.me/c/<group>/<topic>`
  - also supports links like `https://t.me/<public_group_username>/<topic>` (requires valid bot token to resolve group ID)
- `direct`: bind to direct chat with a Telegram user ID

Non-interactive examples:

```bash
# Topic binding via link
NON_INTERACTIVE=true \
BIND_MODE=topic \
BIND_TELEGRAM_LINK="https://t.me/c/1234567890/42" \
./scripts/03_deploy_cto_agent.sh

# Direct-chat binding
NON_INTERACTIVE=true \
BIND_MODE=direct \
BIND_DIRECT_USER_ID="7153051303" \
./scripts/03_deploy_cto_agent.sh
```

## [AUTO]Post-Install Checks

```bash
openclaw --version
codex --version
openclaw config validate --json
openclaw health --json
```

Quick local smoke:

```bash
openclaw agent --local --agent cto-factory --message "Reply with CTO_FACTORY_OK" --json
```

## Common Failures and Fixes

### `Malformed entry ... /etc/apt/sources.list.d/nodesource.sources (URI)`

Cause: broken stale NodeSource source file from previous installs.

Fix:
```bash
sudo rm -f /etc/apt/sources.list.d/nodesource.sources /etc/apt/sources.list.d/nodesource.list /etc/apt/sources.list.d/nodesource.list.save
sudo apt-get update
```

### `Unknown channel: telegram`

Cause: Telegram plugin is disabled.

Fix:
```bash
openclaw plugins enable telegram
./scripts/02_setup_telegram_pairing.sh
```

### Pairing message arrived, but script says no pending code

Cause: timing race or insufficient wait.

Fix:
```bash
export TELEGRAM_PAIRING_TIMEOUT_SECONDS=180
./scripts/02_setup_telegram_pairing.sh
```

### `You are not authorized to use this command`

Cause: group policy is `allowlist`, but sender ID is not in allowlists.

Fix:
- run script 2 again with `PAIRING_TELEGRAM_USER_ID` set
- or manually add user ID to:
  - `channels.telegram.groupAllowFrom`
  - `channels.telegram.accounts.default.groupAllowFrom`
  - `channels.telegram.groups["<group_id>"].allowFrom`

Then restart gateway.

## Security Notes

- Never commit real API keys or bot tokens.
- Keep secrets in `.env` or SecretRef-backed files.
- Do not put plaintext tokens in public config files.

## Runtime User Model (Read This Carefully)

Current behavior in this repo:
- **OpenClaw runs as the same Linux user that runs the scripts** (typically `ubuntu` on EC2).
- No dedicated `openclaw` OS user is created automatically.

### Evidence (from this repo)

- `scripts/01_install_openclaw.sh` sets:
  - `OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"`
  - this resolves to the current user home by default (for EC2, `/home/ubuntu/.openclaw`).
- `scripts/lib/common.sh` starts gateway with `nohup openclaw gateway run ...` in the current user context.
- `scripts/01_install_openclaw.sh` configures gateway with:
  - `gateway.bind = "loopback"` (not public bind by default)
  - `gateway.auth.mode = "token"` with `OPENCLAW_GATEWAY_TOKEN`
- `scripts/lib/common.sh` writes `.env` with `chmod 600`.

### Is this safe?

For a **single-tenant dev VM** or controlled internal setup, this is generally acceptable because:
- gateway is loopback-bound by default,
- token auth is enabled,
- secrets are kept in user-owned state files.

### Risks you should explicitly accept

- The `ubuntu` account becomes a larger trust boundary:
  - compromise of that account exposes OpenClaw state and secrets under `$HOME/.openclaw`.
- Process isolation is weaker than a hardened dedicated service account/container setup.
- Any other workload running as `ubuntu` can potentially read or alter the same user-scoped files.
- Operational mistakes in `ubuntu` shell context can affect OpenClaw runtime and config directly.
