name: create-agent-build
# Full agent BUILD pipeline — runs immediately after REQUIREMENTS_SIGNOFF (user YES on intake).
# CTO writes T1.txt..TN.txt to prompts_dir BEFORE invoking this pipeline.
# Each Tx step calls codex_guarded_exec.py with that task's prompt file.
# Steps T2-T6 are skipped if the corresponding prompt file is absent (allows 1-6 task agents).
#
# After this pipeline completes: CTO reviews results, runs VALIDATION/SMOKE, then
# invokes create-agent-execute.lobster for test → config_qa → apply gate.
#
# Args:
#   agent_id      — workspace name suffix, e.g. "reddit-pain-finder"
#   openclaw_root — absolute path to OPENCLAW_ROOT
#   prompts_dir   — directory containing T1.txt, T2.txt, ..., TN.txt (max T6)
#   workspace     — absolute path to workspace-<agent_id>

args:
  agent_id:
    default: ""
  openclaw_root:
    default: ""
  prompts_dir:
    default: ""
  workspace:
    default: ""

steps:
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

  - id: t1
    command: >
      bash -c '
        PFILE="$LOBSTER_ARG_PROMPTS_DIR/T1.txt"
        if [ ! -f "$PFILE" ]; then
          echo "BLOCKED: T1.txt is required but missing in $LOBSTER_ARG_PROMPTS_DIR" >&2
          exit 1
        fi
        python3 "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/codex_guarded_exec.py" \
          --workdir "$LOBSTER_ARG_OPENCLAW_ROOT" \
          --prompt-file "$PFILE" \
          --timeout 3600
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
          --timeout 3600
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
          --timeout 3600
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
          --timeout 3600
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
          --timeout 3600
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
          --timeout 3600
      '

  - id: validate_config
    command: >
      bash -c '
        RESULT=$(openclaw config validate --json 2>&1 | tail -1)
        echo "$RESULT"
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
