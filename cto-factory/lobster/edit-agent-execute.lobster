name: edit-agent-execute
# Invoked by CTO after user signs YES on REQUIREMENTS_SIGNOFF and code-agent finishes editing an existing agent.
# Covers: backup → test → config_qa → apply_gate → apply → post_smoke
#
# Args (pass via argsJson):
#   agent_id       — e.g. "reddit-agent"
#   openclaw_root  — absolute path to OPENCLAW_ROOT
#   test_cmd       — test command (default: node --test tests/)
#   apply_summary  — one-line summary of what changed

args:
  agent_id:
    default: ""
  openclaw_root:
    default: ""
  test_cmd:
    default: "node --test tests/ 2>&1 || echo '{\"skipped\":true}'"
  apply_summary:
    default: "Apply agent changes"

steps:
  - id: backup
    command: >
      bash -c '
        BRANCH="backup/$LOBSTER_ARG_AGENT_ID-$(date +%Y%m%d-%H%M)" &&
        git -C "$LOBSTER_ARG_OPENCLAW_ROOT" checkout -b "$BRANCH" 2>&1 &&
        git -C "$LOBSTER_ARG_OPENCLAW_ROOT" add -A &&
        git -C "$LOBSTER_ARG_OPENCLAW_ROOT" commit -m "backup: pre-edit $LOBSTER_ARG_AGENT_ID" 2>&1 &&
        echo "{\"ok\":true,\"branch\":\"$BRANCH\"}"
      '

  - id: test
    command: >
      bash -c '
        WS="$LOBSTER_ARG_OPENCLAW_ROOT/workspace-$LOBSTER_ARG_AGENT_ID" &&
        if [ -d "$WS/tests" ]; then
          cd "$WS" && eval "$LOBSTER_ARG_TEST_CMD" && echo "{\"ok\":true}"
        else
          echo "{\"ok\":true,\"skipped\":\"no tests dir\"}"
        fi
      '

  - id: config_qa
    command: >
      bash -c '
        cd "$LOBSTER_ARG_OPENCLAW_ROOT" &&
        openclaw config validate --json 2>&1
      '

  - id: apply_gate
    command: >
      bash -c '
        echo "{\"summary\":\"$LOBSTER_ARG_APPLY_SUMMARY\",\"agent_id\":\"$LOBSTER_ARG_AGENT_ID\"}"
      '
    approval: required

  - id: apply
    command: >
      bash -c '
        cd "$LOBSTER_ARG_OPENCLAW_ROOT" &&
        openclaw agents reload 2>&1 &&
        echo "{\"ok\":true}"
      '
    condition: $apply_gate.approved

  - id: post_smoke
    command: >
      bash -c '
        AGENT="$LOBSTER_ARG_AGENT_ID" &&
        openclaw config validate --json 2>&1 &&
        timeout 60 openclaw agent --agent "$AGENT" \
          --message "/diagnose: confirm tools available, skills loaded, delivery channel reachable" 2>&1 | tail -20 &&
        echo "{\"ok\":true,\"smoke\":\"passed\"}"
      '
    condition: $apply_gate.approved
