name: system-diagnostic
# Full system health check. No mutations, no approvals — read-only diagnostic.
#
# Args:
#   openclaw_root — absolute path to OPENCLAW_ROOT
#   chat_id       — Telegram chat ID for report (optional)
#   topic_id      — Telegram topic ID for report (optional)

args:
  openclaw_root:
    default: ""
  chat_id:
    default: ""
  topic_id:
    default: ""

steps:
  - id: config_validate
    command: >
      bash -c '
        cd "$LOBSTER_ARG_OPENCLAW_ROOT"
        RESULT=$(openclaw config validate --json 2>&1 | tail -1)
        echo "$RESULT"
        echo "$RESULT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); sys.exit(0 if d.get(\"valid\") else 1)" 2>/dev/null || exit 1
      '

  - id: gateway_health
    command: >
      bash -c '
        STATUS=$(openclaw gateway status 2>&1 || true)
        if echo "$STATUS" | grep -q "probe: ok"; then
          echo "{\"ok\":true,\"gateway\":\"healthy\"}"
        else
          echo "{\"ok\":false,\"gateway\":\"unhealthy\",\"output\":\"$(echo $STATUS | head -3)\"}" >&2
          exit 1
        fi
      '

  - id: list_agents
    command: >
      bash -c '
        python3 -c "
import json
with open(\"$LOBSTER_ARG_OPENCLAW_ROOT/openclaw.json\") as f:
    d = json.load(f)
agents = d.get(\"agents\",{}).get(\"list\",[])
result = []
for a in agents:
    result.append({\"id\": a.get(\"id\"), \"workspace\": a.get(\"workspace\",\"\"), \"model\": a.get(\"model\",{}).get(\"primary\",\"\")})
print(json.dumps({\"ok\": True, \"agent_count\": len(result), \"agents\": result}))
"
      '

  - id: agent_workspaces
    command: >
      bash -c '
        MISSING=""
        python3 -c "
import json
with open(\"$LOBSTER_ARG_OPENCLAW_ROOT/openclaw.json\") as f:
    d = json.load(f)
for a in d.get(\"agents\",{}).get(\"list\",[]):
    ws = a.get(\"workspace\",\"\")
    aid = a.get(\"id\",\"\")
    import os
    exists = os.path.isdir(ws) if ws else False
    has_identity = os.path.isfile(os.path.join(ws,\"IDENTITY.md\")) if exists else False
    has_tools = os.path.isfile(os.path.join(ws,\"TOOLS.md\")) if exists else False
    print(json.dumps({\"agent\": aid, \"workspace_exists\": exists, \"identity\": has_identity, \"tools\": has_tools}))
"
      '

  - id: lobster_check
    command: >
      bash -c '
        if command -v lobster >/dev/null 2>&1; then
          VER=$(lobster version 2>&1 || echo "unknown")
          echo "{\"ok\":true,\"lobster\":\"$VER\"}"
        else
          echo "{\"ok\":false,\"lobster\":\"not found\"}" >&2
          exit 1
        fi
      '

  - id: disk_space
    command: >
      bash -c '
        USAGE=$(df -h "$LOBSTER_ARG_OPENCLAW_ROOT" | tail -1 | awk "{print \$5}")
        AVAIL=$(df -h "$LOBSTER_ARG_OPENCLAW_ROOT" | tail -1 | awk "{print \$4}")
        echo "{\"ok\":true,\"disk_usage\":\"$USAGE\",\"disk_available\":\"$AVAIL\"}"
      '

  - id: notify_report
    command: >
      bash -c '
        if [ -n "$LOBSTER_ARG_CHAT_ID" ] && [ -n "$LOBSTER_ARG_TOPIC_ID" ]; then
          openclaw message send --channel telegram --target "$LOBSTER_ARG_CHAT_ID:topic:$LOBSTER_ARG_TOPIC_ID" -m "🔍 System diagnostic complete. Config: valid. Gateway: healthy. Lobster: available." --json 2>/dev/null || true
        fi
        echo "{\"ok\":true,\"diagnostic\":\"complete\"}"
      '
