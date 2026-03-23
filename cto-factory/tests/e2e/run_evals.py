#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import textwrap
from dataclasses import dataclass
from pathlib import Path
from typing import Callable


ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).resolve().parent / "fixtures"
ENGINE = ROOT / "scripts" / "cto_factory_runner.py"
SANDBOX_ROOT = Path(__file__).resolve().parent / ".sandboxes"


class EvalFailure(RuntimeError):
    pass


@dataclass
class CaseContext:
    case_id: str
    sandbox_dir: Path
    copied_workspace: Path
    project_dir: Path
    trace_file: Path
    run_log_file: Path
    prompt: str
    setup_state: dict
    return_code: int = -1
    trace: dict | None = None


@dataclass
class EvalCase:
    case_id: str
    title: str
    prompt: str
    setup: Callable[[CaseContext], None]
    assertions: Callable[[CaseContext], None]


def _read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def _write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _assert(cond: bool, message: str) -> None:
    if not cond:
        raise EvalFailure(message)


def _copy_workspace_for_case(dst: Path) -> Path:
    copied = dst / "workspace-factory"
    shutil.copytree(
        ROOT,
        copied,
        ignore=shutil.ignore_patterns(
            ".git",
            "__pycache__",
            "*.pyc",
            ".sandboxes",
        ),
    )
    return copied


def _run(cmd: list[str], cwd: Path | None = None, env: dict | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


def setup_case_a(ctx: CaseContext) -> None:
    shutil.copy(FIXTURES / "base_openclaw.json", ctx.project_dir / "openclaw.json")


def assert_case_a(ctx: CaseContext) -> None:
    _assert(ctx.return_code == 0, "Case A: runner exited with non-zero code")
    _assert((ctx.project_dir / "agents" / "echo-bot" / "AGENTS.md").exists(), "Case A: echo-bot AGENTS.md was not created")

    config = _read_json(ctx.project_dir / "openclaw.json")
    console_enabled = bool(config.get("channels", {}).get("console", {}).get("enabled"))
    _assert(console_enabled, "Case A: console channel is not enabled in config")

    qa_step = _get_step(ctx.trace, "CONFIG_QA")
    _assert(int(qa_step["details"]["validator"]["exit_code"]) == 0, "Case A: CONFIG_QA validator did not return exit_code=0")


def setup_case_b(ctx: CaseContext) -> None:
    shutil.copy(FIXTURES / "broken_openclaw.yaml", ctx.project_dir / "openclaw.yaml")


def assert_case_b(ctx: CaseContext) -> None:
    _assert(ctx.return_code == 0, "Case B: runner exited with non-zero code")
    yaml_path = ctx.project_dir / "openclaw.yaml"
    _assert(yaml_path.exists(), "Case B: openclaw.yaml not found after run")
    yaml_text = yaml_path.read_text(encoding="utf-8")
    _assert("provders:" not in yaml_text, "Case B: typo 'provders' was not fixed")
    _assert("providers:" in yaml_text, "Case B: expected 'providers:' after repair")

    qa_step = _get_step(ctx.trace, "CONFIG_QA")
    _assert(int(qa_step["details"]["validator"]["exit_code"]) == 0, "Case B: CONFIG_QA validator did not return exit_code=0")
    _assert("factory-config-qa" in ctx.trace.get("skills_used", []), "Case B: skill 'factory-config-qa' was not recorded as used")


def setup_case_c(ctx: CaseContext) -> None:
    shutil.copy(FIXTURES / "base_openclaw.json", ctx.project_dir / "openclaw.json")
    ctx.setup_state["baseline_hash"] = _sha256(ctx.project_dir / "openclaw.json")


def assert_case_c(ctx: CaseContext) -> None:
    _assert(ctx.return_code == 0, "Case C: runner exited with non-zero code")
    _assert(ctx.trace["result"]["status"] == "ROLLED_BACK", "Case C: expected final status ROLLED_BACK")

    current_hash = _sha256(ctx.project_dir / "openclaw.json")
    _assert(current_hash == ctx.setup_state["baseline_hash"], "Case C: openclaw.json mismatch after rollback")

    diff = _run(["git", "diff", "--exit-code", "--", "openclaw.json"], cwd=ctx.project_dir)
    _assert(diff.returncode == 0, "Case C: git diff detected remaining changes in openclaw.json after rollback")


def setup_case_d(ctx: CaseContext) -> None:
    shutil.copy(FIXTURES / "base_openclaw.json", ctx.project_dir / "openclaw.json")


def assert_case_d(ctx: CaseContext) -> None:
    _assert(ctx.return_code == 0, "Case D: runner exited with non-zero code")
    agent_dir = ctx.project_dir / "agents" / "forex-bot"
    _assert(agent_dir.exists(), "Case D: agents/forex-bot directory is missing")
    _assert((agent_dir / "config").is_dir(), "Case D: agents/forex-bot/config is missing")
    _assert((agent_dir / "tools").is_dir(), "Case D: agents/forex-bot/tools is missing")
    _assert((agent_dir / "tests").is_dir(), "Case D: agents/forex-bot/tests is missing")
    _assert(
        (agent_dir / "AGENTS.md").exists() or (agent_dir / "README.md").exists(),
        "Case D: passport file (AGENTS.md or README.md) is missing",
    )

    tool_path = agent_dir / "tools" / "get-rate.js"
    test_path = agent_dir / "tools" / "get-rate.test.js"
    _assert(tool_path.exists(), "Case D: agents/forex-bot/tools/get-rate.js is missing")
    _assert(test_path.exists(), "Case D: agents/forex-bot/tools/get-rate.test.js is missing")
    _assert("fetch" in tool_path.read_text(encoding="utf-8"), "Case D: get-rate.js does not contain fetch logic")

    config = _read_json(ctx.project_dir / "openclaw.json")
    agents = config.get("agents", {}).get("list", [])
    forex = next((a for a in agents if a.get("id") == "forex-bot"), None)
    _assert(forex is not None, "Case D: forex-bot is missing in config")

    scripts = forex.get("tools", {}).get("localScripts", [])
    _assert("agents/forex-bot/tools/get-rate.js" in scripts, "Case D: config does not reference agents/forex-bot/tools/get-rate.js")

    test_step = _get_step(ctx.trace, "TEST")
    checks = test_step.get("details", {}).get("checks", [])
    unit_check = next((c for c in checks if c.get("check") == "node --test agents/forex-bot/tools/get-rate.test.js"), None)
    _assert(unit_check is not None, "Case D: TEST step does not include node --test for forex tool")
    _assert(int(unit_check.get("exit_code", 1)) == 0, "Case D: forex unit test did not pass in TEST step")

    node_test = _run(["node", "--test", str(test_path)], cwd=ctx.project_dir)
    _assert(node_test.returncode == 0, "Case D: direct node --test execution failed")

    node_check = _run(["node", str(tool_path), "--base", "USD", "--symbols", "EUR"], cwd=ctx.project_dir)
    if node_check.returncode == 0:
        data = json.loads(node_check.stdout)
        rates = data.get("rates", {})
        _assert(isinstance(rates.get("EUR"), (int, float)), "Case D: EUR rate is not numeric")


def _get_step(trace: dict, name: str) -> dict:
    for step in trace.get("steps", []):
        if step.get("name") == name:
            return step
    raise EvalFailure(f"Trace does not contain step '{name}'")


def _build_cases() -> list[EvalCase]:
    return [
        EvalCase(
            case_id="A",
            title="Greenfield Deployment (Hello World)",
            prompt="Create a new agent 'echo-bot' that replies in console.",
            setup=setup_case_a,
            assertions=assert_case_a,
        ),
        EvalCase(
            case_id="B",
            title="Fix & Validate (Self-Healing)",
            prompt="OpenClaw fails to start, fix the config.",
            setup=setup_case_b,
            assertions=assert_case_b,
        ),
        EvalCase(
            case_id="C",
            title="Rollback Safety (Safety Net)",
            prompt="Add a nonexistent plugin 'invalid-plugin-v999'. If validation fails, roll back.",
            setup=setup_case_c,
            assertions=assert_case_c,
        ),
        EvalCase(
            case_id="D",
            title="Real World Logic (Currency Agent)",
            prompt=(
                "Create agent 'forex-bot' in a separate folder agents/forex-bot. "
                "It must have a skill that fetches the USD/EUR rate. "
                "Write a test for this skill and ensure it passes."
            ),
            setup=setup_case_d,
            assertions=assert_case_d,
        ),
    ]


def _run_case(case: EvalCase, keep_sandbox: bool) -> tuple[bool, str]:
    sandbox_parent = SANDBOX_ROOT / f"case-{case.case_id.lower()}"
    sandbox_parent.mkdir(parents=True, exist_ok=True)
    sandbox_dir = Path(tempfile.mkdtemp(prefix="run-", dir=sandbox_parent))

    copied_workspace = _copy_workspace_for_case(sandbox_dir)
    project_dir = sandbox_dir / "project"
    project_dir.mkdir(parents=True, exist_ok=True)

    trace_file = project_dir / ".factory-trace.json"
    run_log_file = sandbox_dir / "runner.log"
    ctx = CaseContext(
        case_id=case.case_id,
        sandbox_dir=sandbox_dir,
        copied_workspace=copied_workspace,
        project_dir=project_dir,
        trace_file=trace_file,
        run_log_file=run_log_file,
        prompt=case.prompt,
        setup_state={},
    )

    try:
        case.setup(ctx)
        cmd = [
            sys.executable,
            str(copied_workspace / "scripts" / "cto_factory_runner.py"),
            "--workspace",
            str(project_dir),
            "--task-id",
            f"EVAL-{case.case_id}",
            "--prompt",
            case.prompt,
            "--trace-file",
            str(trace_file),
            "--apply",
            "true",
            "--allow-validate-fallback",
            "true",
        ]

        proc = _run(cmd, cwd=project_dir)
        ctx.return_code = proc.returncode
        run_log_file.write_text(
            textwrap.dedent(
                f"""
                CMD: {" ".join(cmd)}
                EXIT: {proc.returncode}
                --- STDOUT ---
                {proc.stdout}
                --- STDERR ---
                {proc.stderr}
                """
            ).strip()
            + "\n",
            encoding="utf-8",
        )

        _assert(trace_file.exists(), f"Case {case.case_id}: trace file was not created")
        ctx.trace = _read_json(trace_file)
        case.assertions(ctx)
        return True, f"[PASS] Case {case.case_id}: {case.title}"
    except Exception as exc:  # noqa: BLE001
        return False, f"[FAIL] Case {case.case_id}: {case.title}\n  Reason: {exc}\n  Log: {run_log_file}"
    finally:
        if not keep_sandbox:
            shutil.rmtree(sandbox_dir, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Run cto-factory e2e eval cases (A-D)")
    parser.add_argument("--case", choices=["A", "B", "C", "D", "ALL"], default="ALL")
    parser.add_argument("--keep-sandboxes", choices=["true", "false"], default="false")
    args = parser.parse_args()

    if not ENGINE.exists():
        print(f"Runner not found: {ENGINE}", file=sys.stderr)
        return 2

    selected = _build_cases()
    if args.case != "ALL":
        selected = [c for c in selected if c.case_id == args.case]

    keep = args.keep_sandboxes == "true"
    failures = 0
    for case in selected:
        ok, message = _run_case(case, keep_sandbox=keep)
        print(message)
        if not ok:
            failures += 1

    print(f"\nSummary: {len(selected) - failures}/{len(selected)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
