#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

CODE_SUFFIXES = {".py", ".js", ".ts"}


def nonempty(path: Path) -> bool:
    return path.is_file() and path.stat().st_size > 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate required generated agent architecture."
    )
    parser.add_argument("--root", required=True, help="Path to .openclaw root")
    parser.add_argument("--agent-id", required=True, help="Agent id")
    parser.add_argument(
        "--require-binding",
        action="store_true",
        help="Require at least one binding for this agent",
    )
    parser.add_argument(
        "--skip-codex-evidence-check",
        action="store_true",
        help="Disable codex evidence enforcement (not recommended)",
    )
    parser.add_argument(
        "--codex-evidence-file",
        default=None,
        help="Path to codex_guarded_exec evidence JSON (default: <root>/workspace-factory/tmp/codex-last-run.json)",
    )
    parser.add_argument(
        "--max-codex-age-seconds",
        type=int,
        default=21600,
        help="Maximum allowed age for codex evidence",
    )
    parser.add_argument(
        "--codex-grace-seconds",
        type=int,
        default=0,
        help="Allowed source/evidence mtime skew",
    )
    args = parser.parse_args()

    root = Path(args.root).resolve()
    workspace = root / f"workspace-{args.agent_id}"
    nested_workspace = root / "workspace-factory" / f"workspace-{args.agent_id}"
    config_path = root / "openclaw.json"

    failures: list[str] = []
    warnings: list[str] = []

    required_dirs = [
        workspace,
        workspace / "config",
        workspace / "tools",
        workspace / "tests",
        workspace / "skills",
    ]
    for p in required_dirs:
        if not p.exists():
            failures.append(f"missing required directory: {p}")

    required_files = [
        workspace / "IDENTITY.md",
        workspace / "TOOLS.md",
        workspace / "PROMPTS.md",
    ]
    for p in required_files:
        if not nonempty(p):
            failures.append(f"missing or empty required file: {p}")

    passport_a = workspace / "AGENTS.md"
    passport_b = workspace / "README.md"
    if not (nonempty(passport_a) or nonempty(passport_b)):
        failures.append(
            f"missing or empty agent passport file: {passport_a} or {passport_b}"
        )

    tool_files = []
    test_files = []
    skill_files = []
    if (workspace / "tools").exists():
        tool_files = [
            p for p in (workspace / "tools").iterdir() if p.is_file() and p.stat().st_size > 0
        ]
    if (workspace / "tests").exists():
        test_files = [
            p for p in (workspace / "tests").iterdir() if p.is_file() and p.stat().st_size > 0
        ]
    if (workspace / "skills").exists():
        skill_files = [
            p for p in (workspace / "skills").glob("*/SKILL.md") if p.is_file() and p.stat().st_size > 0
        ]
    if not tool_files:
        failures.append(f"no runnable tool files found in {workspace / 'tools'}")
    if not test_files:
        failures.append(f"no test files found in {workspace / 'tests'}")
    if not skill_files:
        failures.append(
            f"no concrete skill files found in {workspace / 'skills'} (expected skills/<skill-name>/SKILL.md)"
        )
    if not nonempty(workspace / "skills" / "SKILL_INDEX.md"):
        failures.append(
            f"missing or empty required file: {workspace / 'skills' / 'SKILL_INDEX.md'}"
        )

    code_files: list[Path] = []
    if workspace.exists():
        for p in workspace.rglob("*"):
            if p.is_file() and p.suffix.lower() in CODE_SUFFIXES:
                code_files.append(p)

    if not config_path.is_file():
        failures.append(f"missing config file: {config_path}")
        cfg = {}
    else:
        try:
            cfg = json.loads(config_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            failures.append(f"openclaw.json parse error: {exc}")
            cfg = {}

    agent_entry = None
    for item in cfg.get("agents", {}).get("list", []):
        if item.get("id") == args.agent_id:
            agent_entry = item
            break
    if not agent_entry:
        failures.append(f"agent '{args.agent_id}' not found in openclaw.json agents.list")
    else:
        expected_workspace = str(workspace)
        expected_agent_dir = str(workspace)
        if agent_entry.get("workspace") != expected_workspace:
            failures.append(
                "workspace mismatch for agent entry: "
                f"expected '{expected_workspace}', got '{agent_entry.get('workspace')}'"
            )
        if agent_entry.get("agentDir") != expected_agent_dir:
            failures.append(
                "agentDir mismatch for agent entry: "
                f"expected '{expected_agent_dir}', got '{agent_entry.get('agentDir')}'"
            )

    if nested_workspace.exists():
        failures.append(
            "nested workspace detected under cto workspace: "
            f"{nested_workspace} (must be {workspace})"
        )

    bindings = cfg.get("bindings", [])
    has_binding = any(b.get("agentId") == args.agent_id for b in bindings)
    if args.require_binding and not has_binding:
        failures.append(f"no bindings found for agent '{args.agent_id}'")
    if not args.require_binding and not has_binding:
        warnings.append(f"no bindings found for agent '{args.agent_id}'")

    codex_evidence_file = (
        Path(args.codex_evidence_file).resolve()
        if args.codex_evidence_file
        else (root / "workspace-factory" / "tmp" / "codex-last-run.json").resolve()
    )
    codex_evidence_ok = True
    codex_evidence_details: dict = {"file": str(codex_evidence_file), "checked": False}
    if not args.skip_codex_evidence_check and code_files:
        codex_evidence_details["checked"] = True
        if not codex_evidence_file.is_file():
            failures.append(f"missing codex evidence file: {codex_evidence_file}")
            codex_evidence_ok = False
        else:
            try:
                evidence = json.loads(codex_evidence_file.read_text(encoding="utf-8"))
            except Exception as exc:  # noqa: BLE001
                failures.append(f"failed to parse codex evidence file: {exc}")
                codex_evidence_ok = False
                evidence = {}

            if evidence:
                if not bool(evidence.get("ok")):
                    failures.append("codex evidence indicates non-successful run (ok=false)")
                    codex_evidence_ok = False
                used_attempts = int(evidence.get("used_attempts", 0) or 0)
                if used_attempts < 1:
                    failures.append("codex evidence has invalid used_attempts (<1)")
                    codex_evidence_ok = False
                attempts = evidence.get("attempts") if isinstance(evidence.get("attempts"), list) else []
                has_codex_exec = False
                for item in attempts:
                    if not isinstance(item, dict):
                        continue
                    cmd = str(item.get("command", ""))
                    if "codex exec" in cmd:
                        has_codex_exec = True
                        break
                if not has_codex_exec:
                    failures.append("codex evidence does not include codex exec command")
                    codex_evidence_ok = False

                age_seconds = max(0, int(time.time() - codex_evidence_file.stat().st_mtime))
                if age_seconds > max(60, int(args.max_codex_age_seconds)):
                    failures.append(
                        f"codex evidence is stale: age={age_seconds}s > max_age={int(args.max_codex_age_seconds)}s"
                    )
                    codex_evidence_ok = False

                cutoff = codex_evidence_file.stat().st_mtime + max(0, int(args.codex_grace_seconds))
                newer = [str(p) for p in code_files if p.stat().st_mtime > cutoff]
                if newer:
                    failures.append(
                        "source code files were modified after codex evidence timestamp (possible direct mutation): "
                        + ", ".join(sorted(newer)[:20])
                    )
                    codex_evidence_ok = False

                codex_evidence_details.update(
                    {
                        "ok": codex_evidence_ok,
                        "used_attempts": used_attempts,
                        "attempts_count": len(attempts),
                    }
                )
    elif args.skip_codex_evidence_check:
        warnings.append("codex evidence enforcement was explicitly skipped")
    else:
        warnings.append("no source code files found for codex evidence enforcement")

    result = {
        "ok": len(failures) == 0,
        "agent_id": args.agent_id,
        "root": str(root),
        "workspace": str(workspace),
        "checked": {
            "required_dirs": [str(p) for p in required_dirs],
            "required_files": [str(p) for p in required_files],
            "passport_candidates": [str(passport_a), str(passport_b)],
            "tool_files_count": len(tool_files),
            "test_files_count": len(test_files),
            "skill_files_count": len(skill_files),
            "code_files_count": len(code_files),
            "code_suffixes": sorted(CODE_SUFFIXES),
            "has_binding": has_binding,
            "codex_evidence": codex_evidence_details,
        },
        "failures": failures,
        "warnings": warnings,
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["ok"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
