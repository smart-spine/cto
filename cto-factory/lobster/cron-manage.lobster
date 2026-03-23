name: cron-manage
# Use for any cron add / edit / remove operation.
# Enforces: audit-before → mutate → verify-after pattern.
# CTO MUST NOT manage cron jobs without running this pipeline.
#
# Args (pass via argsJson):
#   openclaw_root  — absolute path to OPENCLAW_ROOT
#   agent_id       — agent the cron belongs to
#   action         — "add" | "edit" | "rm"
#   cron_cmd       — the full `openclaw cron <action> ...` command to run (without the binary prefix)
#   description    — human-readable description of the change

args:
  openclaw_root:
    default: ""
  agent_id:
    default: ""
  action:
    default: "add"
  cron_cmd:
    default: ""
  description:
    default: "Cron change"

steps:
  - id: list_before
    command: >
      bash -c '
        openclaw cron list --agent "$LOBSTER_ARG_AGENT_ID" --json 2>&1
      '

  - id: confirm_gate
    command: >
      bash -c '
        echo "{\"action\":\"$LOBSTER_ARG_ACTION\",\"agent\":\"$LOBSTER_ARG_AGENT_ID\",\"description\":\"$LOBSTER_ARG_DESCRIPTION\",\"cmd\":\"openclaw $LOBSTER_ARG_CRON_CMD\"}"
      '
    approval: required

  - id: mutate
    command: >
      bash -c '
        openclaw $LOBSTER_ARG_CRON_CMD 2>&1 &&
        echo "{\"ok\":true}"
      '
    condition: $confirm_gate.approved

  - id: list_after
    command: >
      bash -c '
        openclaw cron list --agent "$LOBSTER_ARG_AGENT_ID" --json 2>&1
      '
    condition: $confirm_gate.approved

  - id: verify
    command: >
      bash -c '
        echo "{\"ok\":true,\"message\":\"Cron $LOBSTER_ARG_ACTION completed for $LOBSTER_ARG_AGENT_ID\"}"
      '
    stdin: $list_after.stdout
    condition: $confirm_gate.approved
