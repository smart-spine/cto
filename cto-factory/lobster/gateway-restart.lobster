name: gateway-restart
# Safe gateway restart pipeline.
# Enforces: detect-runtime → pre-check → restart → health-check pattern.
# Use instead of direct `openclaw gateway restart` calls.
#
# Args (pass via argsJson):
#   openclaw_root      — absolute path to OPENCLAW_ROOT
#   callback_session   — CTO session ID for restart callback (optional)

args:
  openclaw_root:
    default: ""
  callback_session:
    default: ""

steps:
  - id: detect_runtime
    command: >
      bash -c '
        bash "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/gateway-runtime-detect.sh" 12 2>&1
      '

  - id: pre_check
    command: >
      bash -c '
        openclaw gateway status 2>&1 | head -5 &&
        echo "{\"ok\":true,\"pre_check\":\"done\"}"
      '

  - id: restart_gate
    command: >
      bash -c '
        echo "{\"runtime_info\":\"see detect_runtime step\",\"action\":\"restart openclaw gateway\"}"
      '
    approval: required

  - id: restart
    command: >
      bash -c '
        OPENCLAW_ROOT="$LOBSTER_ARG_OPENCLAW_ROOT" nohup /usr/bin/env bash \
          "$LOBSTER_ARG_OPENCLAW_ROOT/workspace-factory/scripts/gateway-restart-callback.sh" \
          --agent-id cto-factory \
          --callback-session-id "$LOBSTER_ARG_CALLBACK_SESSION" \
          >/dev/null 2>&1 &
        sleep 2 &&
        echo "{\"ok\":true,\"dispatched\":true}"
      '
    condition: $restart_gate.approved

  - id: health_check
    command: >
      bash -c '
        sleep 10 &&
        openclaw gateway status 2>&1 | head -5 &&
        echo "{\"ok\":true,\"health\":\"checked\"}"
      '
    condition: $restart_gate.approved
