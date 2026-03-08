#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path


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
    args = parser.parse_args()

    root = Path(args.root).resolve()
    workspace = root / f"workspace-{args.agent_id}"
    config_path = root / "openclaw.json"

    failures: list[str] = []
    warnings: list[str] = []

    required_dirs = [
        workspace,
        workspace / "config",
        workspace / "tools",
        workspace / "tests",
        workspace / "skills",
        workspace / "agent",
    ]
    for p in required_dirs:
        if not p.exists():
            failures.append(f"missing required directory: {p}")

    required_files = [
        workspace / "agent" / "IDENTITY.md",
        workspace / "agent" / "TOOLS.md",
        workspace / "agent" / "PROMPTS.md",
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
        expected_agent_dir = str(workspace / "agent")
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

    bindings = cfg.get("bindings", [])
    has_binding = any(b.get("agentId") == args.agent_id for b in bindings)
    if args.require_binding and not has_binding:
        failures.append(f"no bindings found for agent '{args.agent_id}'")
    if not args.require_binding and not has_binding:
        warnings.append(f"no bindings found for agent '{args.agent_id}'")

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
            "has_binding": has_binding,
        },
        "failures": failures,
        "warnings": warnings,
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["ok"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
