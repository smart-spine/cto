---
read_when:
  - Before first CODE step in a session
  - When unsure which state to enter next
  - When an auto-transition rule is unclear
---

# Execution State Machine — Full Reference

## States

- **INTAKE**: Collect REQUIRED business inputs.
- **SKILL_ROUTING**: Select minimal skill set from `SKILL_ROUTING.md`. Record primary/secondary skills before planning.
- **RESEARCH**: See `skills/factory-research/SKILL.md`. Step 0 (clawhub) is mandatory first — decompose task into external dependencies and search each component separately.
- **REQUIREMENTS_SIGNOFF**: Present final requirements + architecture. Request explicit `YES` before any implementation.
- **PREFLIGHT**: Check workspace, provider/model alignment, risk, and blast radius.
- **BACKUP**: Create rollback point (`backup/<task-id>`).
- **CODE**: Implement via delegation rules → `CODE_AGENT_PROTOCOLS.md`.
- **TEST**: Run deterministic tests.
- **CONFIG_QA**: Run `openclaw config validate --json` and parse errors.
- **COHERENCE_REVIEW** (PRE-APPLY, MANDATORY when agent files created/modified): Read ALL agent profile files as a system and fix contradictions, dead refs, duplicates, bloat. Max 3 iterations. → `skills/factory-coherence-review/SKILL.md`
- **FUNCTIONAL_SMOKE** (PRE-APPLY, MANDATORY): Real end-to-end scenario with command evidence.
- **USAGE_PREVIEW** (PRE-APPLY, MANDATORY): Show exactly how the user will use the result.
- **CONTEXT_COMPRESS** (reactive only): Triggered by `factory-keepalive` or user. Not scheduled.
- **READY_FOR_APPLY**: Ask for explicit approval only after green functional smoke.
- **APPLY**: Apply live mutations.
- **POST_APPLY_SMOKE**: Re-check runtime health and delivery path after apply.
- **MEMORY_WRITE** (MANDATORY before DONE/ROLLBACK): Scan session for write triggers. Write `.cto-brain/<type>/YYYY-MM-DD--<slug>.md` and update `INDEX.md`. Cannot be skipped. Use `exec` directly.
- **DONE** or **ROLLBACK**.

## Auto-transitions (no user input required)

- **SKILL_ROUTING complete** → immediately run RESEARCH (if not SKIP).
- **RESEARCH complete** → immediately proceed to REQUIREMENTS_SIGNOFF.
- **CODE exit 0** → immediately run TEST.
- **CODE exit non-0** → diagnose, fix, re-run CODE (max 2 reworks), then TEST.
- **TEST pass** → immediately run CONFIG_QA and FUNCTIONAL_SMOKE.
- **TEST fail** → immediately route back to CODE with exact failure evidence (max 2 reworks).
- **Diagnostic result received** → immediately patch and re-verify. Do NOT report "I diagnosed X, I'll fix it next."
- **FUNCTIONAL_SMOKE pass** → immediately write MEMORY_WRITE checkpoint, then USAGE_PREVIEW and READY_FOR_APPLY.
- **FUNCTIONAL_SMOKE fail** → immediately diagnose and route back to CODE (max 2 reworks).

## Stopping points (user input required)

- `REQUIREMENTS_SIGNOFF` — needs explicit `YES`.
- `READY_FOR_APPLY` — needs explicit apply approval.
- True external blocker (missing credentials, disk full, `BLOCKED` state).

## Lean path rules

- You MAY skip non-critical states in lean paths.
- For any CODE/CONFIG mutation you MUST NEVER skip: `REQUIREMENTS_SIGNOFF`, `BACKUP`, `TEST`, `CONFIG_QA`, `COHERENCE_REVIEW`, `FUNCTIONAL_SMOKE`, `USAGE_PREVIEW`, `MEMORY_WRITE`.
- `MICRO_SCRATCH_FASTPATH` is NOT a delegation exception — execution must still go through remembered code agent.
- ALL code/config/file/cron mutations MUST go through remembered code agent, no matter how small.
- `gateway` patch calls that modify `openclaw.json` ARE config mutations — not exempt from delegation.
- **Config validation failure stop rule**: after ONE config mutation attempt returns a validation error → `BLOCKED: CONFIG_VALIDATION_FAILED`. Show the error, stop. Do NOT retry with different format/endpoint/file-edit. ONE attempt, then BLOCKED.
