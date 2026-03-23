---
read_when:
  - Before running FUNCTIONAL_SMOKE or POST_APPLY_SMOKE
  - When assessing whether smoke evidence is sufficient
  - Before entering COHERENCE_REVIEW
---

# Smoke and Coherence Review Rules

## Functional Smoke Rules (PRE-APPLY, MANDATORY)

- Functional smoke before `READY_FOR_APPLY` is MANDATORY.
- Smoke MUST verify requested behavior end-to-end: input → processing → expected output/delivery.
- Smoke evidence MUST include real command output or delivery confirmation — self-reported success without command evidence is a protocol violation.
- If smoke runs a network-dependent or external-API script, include the raw stdout/stderr excerpt (or message delivery ID) as proof.
- If intake selected `buttons`, smoke MUST prove real inline-button delivery evidence.
- If intake selected `COMPLEX_INTERACTIVE=YES`, smoke MUST prove button-led operation.
- If smoke cannot run due to missing prerequisite (e.g. network, missing dependency), return `BLOCKED` with exact prerequisite and do NOT claim success.
- If pre-apply smoke fails, return `RETURN_TO_CODE` or `BLOCKED`; do NOT roll back un-applied work.
- If the task created or modified any agent skills: smoke MUST include a per-skill invocation test — send a message that specifically triggers each new/modified skill and verify the response demonstrates the skill's intended behavior. A generic successful response without skill execution evidence is a smoke failure. See `skills/factory-smoke/SKILL.md` step 6a for the full protocol.

## Post-Apply Smoke Rules

- Post-apply smoke MUST verify live health and expected delivery/runtime path.
- If post-apply smoke fails: classify failure, report blast radius, recommend `ROLLBACK` when live system is unsafe.

## Coherence Review Rules

→ Full procedure, issue types, and report format in `skills/factory-coherence-review/SKILL.md`.

- Trigger: any task where agent profile files were created or modified.
- Canonical skill: `factory-coherence-review` — invoke it, do not re-implement inline.
- Max 3 iterations. Report MUST be included in the final handoff packet.
- Self-reported "CLEAN" without having read all files is a protocol violation.
