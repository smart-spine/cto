name: full-agent-build
# Complete agent build pipeline.
# CTO writes RESEARCH.txt, T1.txt..T6.txt, SMOKE.txt to prompts_dir BEFORE invoking.
# Each prompt is self-contained: codex builds, tests, fixes, and reports.
# Pipeline adds deterministic validation gates + Telegram progress notifications.
#
# Args:
#   agent_id      — e.g. "reddit-pain-finder"
#   openclaw_root — absolute path to OPENCLAW_ROOT
#   prompts_dir   — directory with RESEARCH.txt, T1.txt..T6.txt, SMOKE.txt
#   workspace     — absolute path to workspace-<agent_id>
#   chat_id       — Telegram chat ID for notifications (optional)
#   topic_id      — Telegram topic ID for notifications (optional)
#   test_cmd      — test runner command (default: python3 -m pytest -q)

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
        [ "$COUNT" -eq 0 ] && echo "BLOCKED: no T*.txt prompt files in $LOBSTER_ARG_PROMPTS_DIR" >&2 && exit 1
        mkdir -p "$LOBSTER_ARG_WORKSPACE" 2>/dev/null || true
        echo "{\"ok\":true,\"agent\":\"$LOBSTER_ARG_AGENT_ID\",\"task_count\":$COUNT}"
      '

  - id: notify_start
    command: >
      bash -c '
        if [ -n "$LOBSTER_ARG_CHAT_ID" ] && [ -n "$LOBSTER_ARG_TOPIC_ID" ]; then
          COUNT=$(ls "$LOBSTER_ARG_PROMPTS_DIR"/T*.txt 2>/dev/null | wc -l)
          HAS_RESEARCH="no"; [ -f "$LOBSTER_ARG_PROMPTS_DIR/RESEARCH.txt" ] && HAS_RESEARCH="yes"
          openclaw message send --channel telegram --target "$LOBSTER_ARG_CHAT_ID:topic:$LOBSTER_ARG_TOPIC_ID" -m "🔨 Build started: $LOBSTER_ARG_AGENT_ID | $COUNT tasks | research=$HAS_RESEARCH" --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  # ── RESEARCH (optional) ───────────────────────────────────────
  - id: research
    command: >
      bash -c '
        PFILE="$LOBSTER_ARG_PROMPTS_DIR/RESEARCH.txt"
        if [ ! -f "$PFILE" ]; then
          echo "{\"skipped\":true,\"reason\":\"no RESEARCH.txt\"}"
          exit 0
        fi
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/codex_guarded_exec.py" --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" --prompt-file "$PFILE" --timeout 600
      '

  # ── BUILD TASKS (T1-T6, each includes own tests+fixes) ────────
  - id: t1
    command: >
      bash -c '
        PFILE="$LOBSTER_ARG_PROMPTS_DIR/T1.txt"
        [ ! -f "$PFILE" ] && echo "BLOCKED: T1.txt required" >&2 && exit 1
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/codex_guarded_exec.py" --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" --prompt-file "$PFILE" --timeout 900
      '

  - id: notify_t1
    command: >
      bash -c '
        if [ -n "$LOBSTER_ARG_CHAT_ID" ] && [ -n "$LOBSTER_ARG_TOPIC_ID" ]; then
          FILES=$(find "$LOBSTER_ARG_WORKSPACE" -type f 2>/dev/null | wc -l)
          openclaw message send --channel telegram --target "$LOBSTER_ARG_CHAT_ID:topic:$LOBSTER_ARG_TOPIC_ID" -m "✅ T1 done ($FILES files)" --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  - id: t2
    command: >
      bash -c '
        PFILE="$LOBSTER_ARG_PROMPTS_DIR/T2.txt"
        [ ! -f "$PFILE" ] && echo "{\"skipped\":true}" && exit 0
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/codex_guarded_exec.py" --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" --prompt-file "$PFILE" --timeout 900
      '

  - id: notify_t2
    command: >
      bash -c '
        if [ -n "$LOBSTER_ARG_CHAT_ID" ] && [ -n "$LOBSTER_ARG_TOPIC_ID" ]; then
          FILES=$(find "$LOBSTER_ARG_WORKSPACE" -type f 2>/dev/null | wc -l)
          openclaw message send --channel telegram --target "$LOBSTER_ARG_CHAT_ID:topic:$LOBSTER_ARG_TOPIC_ID" -m "✅ T2 done ($FILES files)" --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  - id: t3
    command: >
      bash -c '
        PFILE="$LOBSTER_ARG_PROMPTS_DIR/T3.txt"
        [ ! -f "$PFILE" ] && echo "{\"skipped\":true}" && exit 0
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/codex_guarded_exec.py" --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" --prompt-file "$PFILE" --timeout 900
      '

  - id: notify_t3
    command: >
      bash -c '
        if [ -n "$LOBSTER_ARG_CHAT_ID" ] && [ -n "$LOBSTER_ARG_TOPIC_ID" ]; then
          FILES=$(find "$LOBSTER_ARG_WORKSPACE" -type f 2>/dev/null | wc -l)
          openclaw message send --channel telegram --target "$LOBSTER_ARG_CHAT_ID:topic:$LOBSTER_ARG_TOPIC_ID" -m "✅ T3 done ($FILES files)" --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  - id: t4
    command: >
      bash -c '
        PFILE="$LOBSTER_ARG_PROMPTS_DIR/T4.txt"
        [ ! -f "$PFILE" ] && echo "{\"skipped\":true}" && exit 0
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/codex_guarded_exec.py" --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" --prompt-file "$PFILE" --timeout 900
      '

  - id: t5
    command: >
      bash -c '
        PFILE="$LOBSTER_ARG_PROMPTS_DIR/T5.txt"
        [ ! -f "$PFILE" ] && echo "{\"skipped\":true}" && exit 0
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/codex_guarded_exec.py" --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" --prompt-file "$PFILE" --timeout 900
      '

  - id: t6
    command: >
      bash -c '
        PFILE="$LOBSTER_ARG_PROMPTS_DIR/T6.txt"
        [ ! -f "$PFILE" ] && echo "{\"skipped\":true}" && exit 0
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/codex_guarded_exec.py" --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" --prompt-file "$PFILE" --timeout 900
      '

  - id: notify_build_done
    command: >
      bash -c '
        if [ -n "$LOBSTER_ARG_CHAT_ID" ] && [ -n "$LOBSTER_ARG_TOPIC_ID" ]; then
          FILES=$(find "$LOBSTER_ARG_WORKSPACE" -type f 2>/dev/null | wc -l)
          openclaw message send --channel telegram --target "$LOBSTER_ARG_CHAT_ID:topic:$LOBSTER_ARG_TOPIC_ID" -m "🔧 Build complete ($FILES files). Validating..." --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  # ── VALIDATION GATES ───────────────────────────────────────────
  - id: validate_config
    command: >
      bash -c '
        cd "$LOBSTER_ARG_OPENCLAW_ROOT"
        RESULT=$(openclaw config validate --json 2>&1 | tail -1)
        echo "$RESULT"
        echo "$RESULT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); sys.exit(0 if d.get(\"valid\") else 1)" 2>/dev/null || exit 1
      '

  - id: workspace_check
    command: >
      bash -c '
        WS="$LOBSTER_ARG_WORKSPACE"
        MISSING=""
        for f in IDENTITY.md TOOLS.md PROMPTS.md; do [ ! -f "$WS/$f" ] && MISSING="$MISSING $f"; done
        for d in skills config tools tests; do [ ! -d "$WS/$d" ] && MISSING="$MISSING $d/"; done
        if [ -n "$MISSING" ]; then echo "{\"ok\":false,\"missing\":\"$(echo $MISSING | xargs)\"}" >&2; exit 1; fi
        echo "{\"ok\":true}"
      '

  - id: unit_tests
    command: >
      bash -c '
        WS="$LOBSTER_ARG_WORKSPACE"
        if [ -d "$WS/tests" ]; then
          cd "$WS" && eval "$LOBSTER_ARG_TEST_CMD" 2>&1
          if [ $? -ne 0 ]; then echo "{\"ok\":false,\"tests\":\"failed\"}" >&2; exit 1; fi
          echo "{\"ok\":true,\"tests\":\"passed\"}"
        else
          echo "{\"ok\":true,\"tests\":\"skipped\"}"
        fi
      '

  # ── REGISTER + VALIDATE ────────────────────────────────────────
  - id: register_agent
    command: >
      bash -c '
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/lobster_register_agent.py" "$LOBSTER_ARG_OPENCLAW_ROOT/openclaw.json" "$LOBSTER_ARG_AGENT_ID" "$LOBSTER_ARG_WORKSPACE"
      '

  - id: validate_after_register
    command: >
      bash -c '
        cd "$LOBSTER_ARG_OPENCLAW_ROOT"
        RESULT=$(openclaw config validate --json 2>&1 | tail -1)
        echo "$RESULT"
        echo "$RESULT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); sys.exit(0 if d.get(\"valid\") else 1)" 2>/dev/null || exit 1
      '

  # ── SMOKE TEST (codex runs real agent calls) ───────────────────
  - id: smoke_test
    command: >
      bash -c '
        PFILE="$LOBSTER_ARG_PROMPTS_DIR/SMOKE.txt"
        if [ ! -f "$PFILE" ]; then
          echo "{\"skipped\":true,\"reason\":\"no SMOKE.txt\"}"
          exit 0
        fi
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/codex_guarded_exec.py" --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" --prompt-file "$PFILE" --timeout 900
      '

  - id: notify_smoke
    command: >
      bash -c '
        if [ -n "$LOBSTER_ARG_CHAT_ID" ] && [ -n "$LOBSTER_ARG_TOPIC_ID" ]; then
          PFILE="$LOBSTER_ARG_PROMPTS_DIR/SMOKE.txt"
          if [ -f "$PFILE" ]; then
            MSG="✅ Smoke test passed for $LOBSTER_ARG_AGENT_ID. Ready for apply approval."
          else
            MSG="⚠️ No SMOKE.txt — smoke skipped. Ready for apply approval."
          fi
          openclaw message send --channel telegram --target "$LOBSTER_ARG_CHAT_ID:topic:$LOBSTER_ARG_TOPIC_ID" -m "$MSG" --json 2>/dev/null || true
        fi
        echo "{\"ok\":true}"
      '

  # ── APPROVAL GATE ──────────────────────────────────────────────
  - id: apply_gate
    command: >
      bash -c '
        FILES=$(find "$LOBSTER_ARG_WORKSPACE" -type f 2>/dev/null | wc -l)
        echo "{\"agent_id\":\"$LOBSTER_ARG_AGENT_ID\",\"files\":$FILES,\"ready\":true}"
      '
    approval: required

  # ── APPLY ──────────────────────────────────────────────────────
  - id: restart_gateway
    command: >
      bash -c '
        openclaw gateway stop 2>&1 || true
        sleep 3
        openclaw gateway start 2>&1 || true
        sleep 6
        STATUS=$(openclaw gateway status 2>&1 || true)
        if echo "$STATUS" | grep -q "probe: ok"; then echo "{\"ok\":true}"; else echo "{\"ok\":false}" >&2; exit 1; fi
      '
    condition: $apply_gate.approved

  - id: post_apply_smoke
    command: >
      bash -c '
        OUTPUT=$(timeout 60 openclaw agent --agent "$LOBSTER_ARG_AGENT_ID" --message "Confirm you are alive. List your commands." --json 2>&1 || true)
        if echo "$OUTPUT" | grep -q "payloads"; then echo "{\"ok\":true}"; else echo "{\"ok\":false}" >&2; exit 1; fi
      '
    condition: $apply_gate.approved

  - id: notify_done
    command: >
      bash -c '
        if [ -n "$LOBSTER_ARG_CHAT_ID" ] && [ -n "$LOBSTER_ARG_TOPIC_ID" ]; then
          openclaw message send --channel telegram --target "$LOBSTER_ARG_CHAT_ID:topic:$LOBSTER_ARG_TOPIC_ID" -m "🚀 $LOBSTER_ARG_AGENT_ID is LIVE!" --json 2>/dev/null || true
        fi
        echo "{\"ok\":true,\"done\":true}"
      '
    condition: $apply_gate.approved
