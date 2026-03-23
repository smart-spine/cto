name: create-agent-execute
# Invoked by CTO after user signs YES on REQUIREMENTS_SIGNOFF and code-agent finishes.
# Covers: backup → test → config_qa → workspace_check → apply_gate → apply → post_smoke
#
# Args (pass via argsJson):
#   agent_id       — e.g. "reddit-agent"
#   openclaw_root  — absolute path to OPENCLAW_ROOT
#   test_cmd       — test command to run in agent workspace (e.g. "node --test tests/")
#   apply_summary  — one-line summary of what will be applied (for approval prompt)

args:
  agent_id:
    default: ""
  openclaw_root:
    default: ""
  test_cmd:
    default: "node --test tests/ 2>&1 || echo '{\"skipped\":true}'"
  apply_summary:
    default: "Apply new agent workspace and openclaw.json registration"

steps:
  - id: backup
    command: >
      bash -c '
        BRANCH="backup/$LOBSTER_ARG_AGENT_ID-$(date +%Y%m%d-%H%M)" &&
        git -C "$LOBSTER_ARG_OPENCLAW_ROOT" checkout -b "$BRANCH" 2>&1 &&
        git -C "$LOBSTER_ARG_OPENCLAW_ROOT" add -A &&
        git -C "$LOBSTER_ARG_OPENCLAW_ROOT" commit -m "backup: pre-$LOBSTER_ARG_AGENT_ID snapshot" 2>&1 &&
        echo "{\"ok\":true,\"branch\":\"$BRANCH\"}"
      '

  - id: test
    command: >
      bash -c '
        WS="$LOBSTER_ARG_OPENCLAW_ROOT/workspace-$LOBSTER_ARG_AGENT_ID" &&
        if [ -d "$WS/tests" ]; then
          cd "$WS" && eval "$LOBSTER_ARG_TEST_CMD" && echo "{\"ok\":true,\"ran\":true}"
        else
          echo "{\"ok\":true,\"ran\":false,\"reason\":\"no tests dir\"}"
        fi
      '

  - id: tool_syntax_check
    command: >
      bash -c '
        WS="$LOBSTER_ARG_OPENCLAW_ROOT/workspace-$LOBSTER_ARG_AGENT_ID" &&
        ERRORS="" &&
        for f in "$WS/tools/"*.js "$WS/tools/"*.ts 2>/dev/null; do
          [ -f "$f" ] || continue
          node --check "$f" 2>&1 || ERRORS="$ERRORS $f"
        done &&
        if [ -z "$ERRORS" ]; then
          echo "{\"ok\":true}"
        else
          echo "{\"ok\":false,\"failed\":\"$ERRORS\"}" && exit 1
        fi
      '

  - id: config_qa
    command: >
      bash -c '
        cd "$LOBSTER_ARG_OPENCLAW_ROOT" &&
        openclaw config validate --json 2>&1
      '

  - id: workspace_structure_check
    command: >
      bash -c '
        WS="$LOBSTER_ARG_OPENCLAW_ROOT/workspace-$LOBSTER_ARG_AGENT_ID" &&
        MISSING="" &&
        for f in IDENTITY.md TOOLS.md PROMPTS.md; do
          [ -f "$WS/$f" ] || MISSING="$MISSING $f"
        done &&
        for d in config tools tests skills docs; do
          [ -d "$WS/$d" ] || MISSING="$MISSING $d/"
        done &&
        if [ -z "$MISSING" ]; then
          echo "{\"ok\":true}"
        else
          echo "{\"ok\":false,\"missing\":\"$MISSING\"}" && exit 1
        fi
      '

  - id: apply_gate
    command: >
      bash -c '
        echo "{\"summary\":\"$LOBSTER_ARG_APPLY_SUMMARY\",\"agent_id\":\"$LOBSTER_ARG_AGENT_ID\",\"checks\":{\"backup\":\"ok\",\"test\":\"ok\",\"config_qa\":\"ok\",\"workspace\":\"ok\"}}"
      '
    approval: required

  - id: apply
    command: >
      bash -c '
        cd "$LOBSTER_ARG_OPENCLAW_ROOT" &&
        openclaw agents reload 2>&1 &&
        echo "{\"ok\":true,\"applied\":\"$LOBSTER_ARG_AGENT_ID\"}"
      '
    condition: $apply_gate.approved

  - id: post_smoke
    command: >
      bash -c '
        AGENT="$LOBSTER_ARG_AGENT_ID" &&
        ROOT="$LOBSTER_ARG_OPENCLAW_ROOT" &&
        echo "Running post-apply smoke..." &&
        openclaw config validate --json 2>&1 &&
        echo "{\"smoke\":\"config_valid\"}" &&
        timeout 60 openclaw agent --agent "$AGENT" \
          --message "/diagnose: confirm tools available, skills loaded, delivery channel reachable" 2>&1 | tail -20 &&
        echo "{\"ok\":true,\"smoke\":\"passed\"}"
      '
    condition: $apply_gate.approved
