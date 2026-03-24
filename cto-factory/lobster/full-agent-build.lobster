name: full-agent-build
# Complete agent build pipeline: research → codex build (T1-T6) → validate → test →
# register → restart → functional smoke → approval gate.
#
# CTO writes T1.txt..T6.txt + SMOKE.json to prompts_dir BEFORE invoking this pipeline.
# Sends Telegram progress notifications between major steps.
#
# Args:
#   agent_id      — workspace name suffix, e.g. "reddit-pain-finder"
#   openclaw_root — absolute path to OPENCLAW_ROOT
#   prompts_dir   — directory containing T1.txt..T6.txt + SMOKE.json
#   workspace     — absolute path to workspace-<agent_id>
#   chat_id       — Telegram chat ID for progress notifications
#   topic_id      — Telegram topic ID for progress notifications
#   test_cmd      — test command (default: pytest -q)

args:
  agent_id:
    default: ""
  openclaw_root:
    default: ""
  prompts_dir:
    default: ""
  workspace:
    default: ""
  chat_id:
    default: ""
  topic_id:
    default: ""
  test_cmd:
    default: "python3 -m pytest -q"

steps:
  # ── PREFLIGHT ──────────────────────────────────────────────────
  - id: preflight
    command: >
      bash -c '
        set -e
        [ -z "$LOBSTER_ARG_AGENT_ID" ] && echo "BLOCKED: agent_id not set" >&2 && exit 1
        [ -z "$LOBSTER_ARG_OPENCLAW_ROOT" ] && echo "BLOCKED: openclaw_root not set" >&2 && exit 1
        [ -z "$LOBSTER_ARG_PROMPTS_DIR" ] && echo "BLOCKED: prompts_dir not set" >&2 && exit 1
        COUNT=$(ls "$LOBSTER_ARG_PROMPTS_DIR"/T*.txt 2>/dev/null | wc -l)
        [ "$COUNT" -eq 0 ] && echo "BLOCKED: no T*.txt prompt files found in $LOBSTER_ARG_PROMPTS_DIR" >&2 && exit 1
        mkdir -p "$LOBSTER_ARG_WORKSPACE" 2>/dev/null || true
        echo "{\"ok\":true,\"agent\":\"$LOBSTER_ARG_AGENT_ID\",\"task_count\":$COUNT,\"prompts_dir\":\"$LOBSTER_ARG_PROMPTS_DIR\"}"
      '

  - id: notify_start
    command: >
      bash -c '
        if [ -n "$LOBSTER_ARG_CHAT_ID" ] && [ -n "$LOBSTER_ARG_TOPIC_ID" ]; then
          COUNT=$(ls "$LOBSTER_ARG_PROMPTS_DIR"/T*.txt 2>/dev/null | wc -l)
          openclaw message send --channel telegram \
            --target "$LOBSTER_ARG_CHAT_ID:topic:$LOBSTER_ARG_TOPIC_ID" \
            -m "🔨 Build pipeline started for $LOBSTER_ARG_AGENT_ID ($COUNT tasks)" \
            --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  # ── CODEX BUILD TASKS (T1-T6) ─────────────────────────────────
  - id: t1
    command: >
      bash -c '
        PFILE="$LOBSTER_ARG_PROMPTS_DIR/T1.txt"
        if [ ! -f "$PFILE" ]; then
          echo "BLOCKED: T1.txt is required but missing" >&2
          exit 1
        fi
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/codex_guarded_exec.py" \
          --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" \
          --prompt-file "$PFILE" \
          --timeout 600
      '

  - id: notify_t1
    command: >
      bash -c '
        if [ -n "$LOBSTER_ARG_CHAT_ID" ] && [ -n "$LOBSTER_ARG_TOPIC_ID" ]; then
          FILES=$(find "$LOBSTER_ARG_WORKSPACE" -type f 2>/dev/null | wc -l)
          openclaw message send --channel telegram \
            --target "$LOBSTER_ARG_CHAT_ID:topic:$LOBSTER_ARG_TOPIC_ID" \
            -m "✅ T1 scaffold done ($FILES files). Running T2..." \
            --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  - id: t2
    command: >
      bash -c '
        PFILE="$LOBSTER_ARG_PROMPTS_DIR/T2.txt"
        if [ ! -f "$PFILE" ]; then
          echo "{\"skipped\":true,\"reason\":\"no T2.txt\"}"
          exit 0
        fi
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/codex_guarded_exec.py" \
          --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" \
          --prompt-file "$PFILE" \
          --timeout 600
      '

  - id: notify_t2
    command: >
      bash -c '
        if [ -n "$LOBSTER_ARG_CHAT_ID" ] && [ -n "$LOBSTER_ARG_TOPIC_ID" ]; then
          FILES=$(find "$LOBSTER_ARG_WORKSPACE" -type f 2>/dev/null | wc -l)
          openclaw message send --channel telegram \
            --target "$LOBSTER_ARG_CHAT_ID:topic:$LOBSTER_ARG_TOPIC_ID" \
            -m "✅ T2 done ($FILES files). Running T3..." \
            --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  - id: t3
    command: >
      bash -c '
        PFILE="$LOBSTER_ARG_PROMPTS_DIR/T3.txt"
        if [ ! -f "$PFILE" ]; then
          echo "{\"skipped\":true,\"reason\":\"no T3.txt\"}"
          exit 0
        fi
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/codex_guarded_exec.py" \
          --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" \
          --prompt-file "$PFILE" \
          --timeout 600
      '

  - id: notify_t3
    command: >
      bash -c '
        if [ -n "$LOBSTER_ARG_CHAT_ID" ] && [ -n "$LOBSTER_ARG_TOPIC_ID" ]; then
          FILES=$(find "$LOBSTER_ARG_WORKSPACE" -type f 2>/dev/null | wc -l)
          openclaw message send --channel telegram \
            --target "$LOBSTER_ARG_CHAT_ID:topic:$LOBSTER_ARG_TOPIC_ID" \
            -m "✅ T3 done ($FILES files). Running T4..." \
            --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  - id: t4
    command: >
      bash -c '
        PFILE="$LOBSTER_ARG_PROMPTS_DIR/T4.txt"
        if [ ! -f "$PFILE" ]; then
          echo "{\"skipped\":true,\"reason\":\"no T4.txt\"}"
          exit 0
        fi
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/codex_guarded_exec.py" \
          --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" \
          --prompt-file "$PFILE" \
          --timeout 600
      '

  - id: notify_t4
    command: >
      bash -c '
        if [ -n "$LOBSTER_ARG_CHAT_ID" ] && [ -n "$LOBSTER_ARG_TOPIC_ID" ]; then
          FILES=$(find "$LOBSTER_ARG_WORKSPACE" -type f 2>/dev/null | wc -l)
          openclaw message send --channel telegram \
            --target "$LOBSTER_ARG_CHAT_ID:topic:$LOBSTER_ARG_TOPIC_ID" \
            -m "✅ T4 done ($FILES files). Running T5..." \
            --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  - id: t5
    command: >
      bash -c '
        PFILE="$LOBSTER_ARG_PROMPTS_DIR/T5.txt"
        if [ ! -f "$PFILE" ]; then
          echo "{\"skipped\":true,\"reason\":\"no T5.txt\"}"
          exit 0
        fi
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/codex_guarded_exec.py" \
          --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" \
          --prompt-file "$PFILE" \
          --timeout 600
      '

  - id: t6
    command: >
      bash -c '
        PFILE="$LOBSTER_ARG_PROMPTS_DIR/T6.txt"
        if [ ! -f "$PFILE" ]; then
          echo "{\"skipped\":true,\"reason\":\"no T6.txt\"}"
          exit 0
        fi
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/codex_guarded_exec.py" \
          --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" \
          --prompt-file "$PFILE" \
          --timeout 600
      '

  - id: notify_build_done
    command: >
      bash -c '
        if [ -n "$LOBSTER_ARG_CHAT_ID" ] && [ -n "$LOBSTER_ARG_TOPIC_ID" ]; then
          FILES=$(find "$LOBSTER_ARG_WORKSPACE" -type f 2>/dev/null | wc -l)
          openclaw message send --channel telegram \
            --target "$LOBSTER_ARG_CHAT_ID:topic:$LOBSTER_ARG_TOPIC_ID" \
            -m "🔧 Build complete ($FILES files). Running validation..." \
            --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  # ── VALIDATION ─────────────────────────────────────────────────
  - id: validate_config
    command: >
      bash -c '
        cd "$LOBSTER_ARG_OPENCLAW_ROOT" &&
        RESULT=$(openclaw config validate --json 2>&1 | tail -1) &&
        echo "$RESULT" &&
        echo "$RESULT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); sys.exit(0 if d.get(\"valid\") else 1)" 2>/dev/null || exit 1
      '

  - id: workspace_check
    command: >
      bash -c '
        WS="$LOBSTER_ARG_WORKSPACE"
        MISSING=""
        for f in IDENTITY.md TOOLS.md PROMPTS.md; do
          [ ! -f "$WS/$f" ] && MISSING="$MISSING $f"
        done
        for d in skills config tools tests; do
          [ ! -d "$WS/$d" ] && MISSING="$MISSING $d/"
        done
        if [ -n "$MISSING" ]; then
          echo "{\"ok\":false,\"missing\":\"$(echo $MISSING | xargs)\"}" >&2
          exit 1
        fi
        echo "{\"ok\":true,\"workspace\":\"$WS\"}"
      '

  - id: unit_tests
    command: >
      bash -c '
        WS="$LOBSTER_ARG_WORKSPACE"
        if [ -d "$WS/tests" ]; then
          cd "$WS" && eval "$LOBSTER_ARG_TEST_CMD" 2>&1
          RC=$?
          if [ $RC -ne 0 ]; then
            echo "{\"ok\":false,\"tests\":\"failed\",\"exit_code\":$RC}" >&2
            exit 1
          fi
          echo "{\"ok\":true,\"tests\":\"passed\"}"
        else
          echo "{\"ok\":true,\"tests\":\"skipped\",\"reason\":\"no tests dir\"}"
        fi
      '

  # ── REGISTER AGENT ─────────────────────────────────────────────
  - id: register_agent
    command: >
      bash -c '
        set -e
        ROOT="$LOBSTER_ARG_OPENCLAW_ROOT"
        AGENT="$LOBSTER_ARG_AGENT_ID"
        WS="$LOBSTER_ARG_WORKSPACE"
        python3 - "$ROOT/openclaw.json" "$AGENT" "$WS" <<'"'"'PY'"'"'
import json, sys, pathlib
config_path = pathlib.Path(sys.argv[1])
agent_id = sys.argv[2]
workspace = sys.argv[3]
d = json.loads(config_path.read_text())
agents = d.setdefault("agents", {}).setdefault("list", [])
found = False
for a in agents:
    if a.get("id") == agent_id:
        a["workspace"] = workspace
        a["agentDir"] = workspace
        found = True
        break
if not found:
    agents.append({
        "id": agent_id,
        "default": False,
        "name": agent_id.replace("-", " ").title(),
        "workspace": workspace,
        "agentDir": workspace,
        "model": {"primary": "openai-codex/gpt-5.4"},
        "identity": {"name": agent_id.replace("-", " ").title()}
    })
config_path.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
print(json.dumps({"ok": True, "registered": agent_id, "found_existing": found}))
PY
      '

  - id: validate_after_register
    command: >
      bash -c '
        cd "$LOBSTER_ARG_OPENCLAW_ROOT" &&
        RESULT=$(openclaw config validate --json 2>&1 | tail -1) &&
        echo "$RESULT" &&
        echo "$RESULT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); sys.exit(0 if d.get(\"valid\") else 1)" 2>/dev/null || exit 1
      '

  # ── FUNCTIONAL SMOKE ───────────────────────────────────────────
  - id: functional_smoke
    command: >
      bash -c '
        set -e
        AGENT="$LOBSTER_ARG_AGENT_ID"
        ROOT="$LOBSTER_ARG_OPENCLAW_ROOT"
        SMOKE_FILE="$LOBSTER_ARG_PROMPTS_DIR/SMOKE.json"
        RESULTS=""
        PASS=0
        FAIL=0

        if [ ! -f "$SMOKE_FILE" ]; then
          echo "{\"ok\":true,\"smoke\":\"skipped\",\"reason\":\"no SMOKE.json\"}"
          exit 0
        fi

        COMMANDS=$(python3 -c "import json; d=json.load(open('"'"'$SMOKE_FILE'"'"')); [print(c['"'"'command'"'"']) for c in d.get('"'"'smoke_commands'"'"',[])]")
        EXPECTS=$(python3 -c "import json; d=json.load(open('"'"'$SMOKE_FILE'"'"')); [print(c.get('"'"'expect'"'"','"'"''"'"')) for c in d.get('"'"'smoke_commands'"'"',[])]")
        TIMEOUTS=$(python3 -c "import json; d=json.load(open('"'"'$SMOKE_FILE'"'"')); [print(c.get('"'"'timeout'"'"',60)) for c in d.get('"'"'smoke_commands'"'"',[])]")

        IDX=0
        while IFS= read -r CMD; do
          IDX=$((IDX+1))
          EXPECT=$(echo "$EXPECTS" | sed -n "${IDX}p")
          TMO=$(echo "$TIMEOUTS" | sed -n "${IDX}p")
          TMO=${TMO:-60}

          OUTPUT=$(timeout "$TMO" openclaw agent --agent "$AGENT" \
            --message "$CMD" --json 2>&1 || true)

          if [ -n "$EXPECT" ] && echo "$OUTPUT" | grep -qi "$EXPECT"; then
            PASS=$((PASS+1))
            RESULTS="$RESULTS\n✅ $CMD"
          elif [ -z "$EXPECT" ] && echo "$OUTPUT" | grep -q "payloads"; then
            PASS=$((PASS+1))
            RESULTS="$RESULTS\n✅ $CMD (got response)"
          else
            FAIL=$((FAIL+1))
            RESULTS="$RESULTS\n❌ $CMD (expected: $EXPECT)"
          fi
        done <<< "$COMMANDS"

        TOTAL=$((PASS+FAIL))
        printf "{\"ok\":%s,\"pass\":%d,\"fail\":%d,\"total\":%d}" \
          "$([ $FAIL -eq 0 ] && echo true || echo false)" "$PASS" "$FAIL" "$TOTAL"

        if [ $FAIL -gt 0 ]; then
          echo "" >&2
          printf "$RESULTS\n" >&2
          exit 1
        fi
      '

  - id: notify_smoke_results
    command: >
      bash -c '
        if [ -n "$LOBSTER_ARG_CHAT_ID" ] && [ -n "$LOBSTER_ARG_TOPIC_ID" ]; then
          SMOKE_FILE="$LOBSTER_ARG_PROMPTS_DIR/SMOKE.json"
          if [ -f "$SMOKE_FILE" ]; then
            MSG="✅ All checks passed for $LOBSTER_ARG_AGENT_ID. Waiting for apply approval."
          else
            MSG="⚠️ No SMOKE.json — functional smoke skipped. Waiting for apply approval."
          fi
          openclaw message send --channel telegram \
            --target "$LOBSTER_ARG_CHAT_ID:topic:$LOBSTER_ARG_TOPIC_ID" \
            -m "$MSG" \
            --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  # ── APPROVAL GATE ──────────────────────────────────────────────
  - id: apply_gate
    command: >
      bash -c '
        WS="$LOBSTER_ARG_WORKSPACE"
        FILES=$(find "$WS" -type f 2>/dev/null | wc -l)
        echo "{\"agent_id\":\"$LOBSTER_ARG_AGENT_ID\",\"workspace\":\"$WS\",\"files\":$FILES,\"ready\":true}"
      '
    approval: required

  # ── APPLY ──────────────────────────────────────────────────────
  - id: restart_gateway
    command: >
      bash -c '
        openclaw gateway stop 2>&1 || true
        sleep 2
        openclaw gateway start 2>&1 || true
        sleep 5
        STATUS=$(openclaw gateway status 2>&1 || true)
        if echo "$STATUS" | grep -q "probe: ok"; then
          echo "{\"ok\":true,\"gateway\":\"running\"}"
        else
          echo "{\"ok\":false,\"gateway\":\"failed\",\"status\":\"$STATUS\"}" >&2
          exit 1
        fi
      '
    condition: $apply_gate.approved

  - id: post_apply_smoke
    command: >
      bash -c '
        AGENT="$LOBSTER_ARG_AGENT_ID"
        OUTPUT=$(timeout 60 openclaw agent --agent "$AGENT" \
          --message "Confirm you are alive. List your commands." --json 2>&1 || true)
        if echo "$OUTPUT" | grep -q "payloads"; then
          echo "{\"ok\":true,\"agent_alive\":true}"
        else
          echo "{\"ok\":false,\"agent_alive\":false}" >&2
          exit 1
        fi
      '
    condition: $apply_gate.approved

  - id: notify_done
    command: >
      bash -c '
        if [ -n "$LOBSTER_ARG_CHAT_ID" ] && [ -n "$LOBSTER_ARG_TOPIC_ID" ]; then
          openclaw message send --channel telegram \
            --target "$LOBSTER_ARG_CHAT_ID:topic:$LOBSTER_ARG_TOPIC_ID" \
            -m "🚀 $LOBSTER_ARG_AGENT_ID is LIVE. Build + smoke + deploy complete." \
            --json 2>/dev/null || true
        fi
        echo "{\"ok\":true,\"done\":true}"
      '
    condition: $apply_gate.approved
