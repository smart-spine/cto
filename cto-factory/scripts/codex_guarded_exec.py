#!/usr/bin/env python3
"""Guarded wrapper around `codex exec` with retry and long-running timeout support."""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


def parse_args() -> argparse.Namespace:
    default_state = (
        Path(__file__).resolve().parent.parent / ".cto-brain" / "runtime" / "codex_failure_guard.json"
    )
    p = argparse.ArgumentParser(description="Run codex exec with retries and long-running timeout support")
    p.add_argument("--workdir", required=True, help="Project root passed to codex --cd")
    p.add_argument("--model", default="gpt-5.3-codex", help="Codex model")
    p.add_argument("--prompt-file", help="Path to file with prompt text")
    p.add_argument("--prompt", help="Inline prompt text")
    p.add_argument("--retries", type=int, default=5, help="Max attempts")
    p.add_argument("--timeout", type=int, default=10800, help="Per-attempt timeout (seconds)")
    p.add_argument("--backoff", type=float, default=2.0, help="Base backoff seconds")
    p.add_argument("--reasoning-effort", choices=["none", "minimal", "low", "medium", "high"], default=None)
    p.add_argument("--failure-budget", type=int, default=3, help="Consecutive failed runs allowed per session")
    p.add_argument("--session-id", default=os.getenv("CTO_SESSION_ID", "default"), help="Session key for failure budget")
    p.add_argument("--state-file", default=str(default_state), help="Path to persistent failure counter JSON")
    return p.parse_args()


def load_prompt(args: argparse.Namespace) -> str:
    if args.prompt_file:
        return Path(args.prompt_file).read_text(encoding="utf-8")
    if args.prompt:
        return args.prompt
    data = sys.stdin.read()
    if data.strip():
        return data
    raise SystemExit("No prompt provided. Use --prompt, --prompt-file, or stdin.")


def build_cmd(args: argparse.Namespace) -> list[str]:
    cmd = [
        "codex",
        "exec",
        "--ephemeral",
        "--skip-git-repo-check",
        "--sandbox",
        "workspace-write",
        "--cd",
        args.workdir,
        "--model",
        args.model,
    ]
    if args.reasoning_effort:
        cmd.extend(["-c", f"reasoning_effort=\"{args.reasoning_effort}\""])
    cmd.append("-")
    return cmd


def is_retryable(stderr: str, stdout: str, returncode: int) -> bool:
    text = f"{stdout}\n{stderr}".lower()
    retry_markers = [
        "stream disconnected before completion",
        "error sending request for url",
        "connection reset",
        "timed out",
        "temporarily unavailable",
        "429",
    ]
    return returncode != 0 and any(m in text for m in retry_markers)


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def load_state(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}


def save_state(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def get_session_record(state: dict, session_id: str) -> dict:
    return state.get(session_id, {"consecutive_failures": 0})


def mark_success(path: Path, state: dict, session_id: str) -> None:
    state[session_id] = {
        "consecutive_failures": 0,
        "last_success_at": utc_now(),
        "last_failure_at": state.get(session_id, {}).get("last_failure_at"),
    }
    save_state(path, state)


def mark_failure(path: Path, state: dict, session_id: str) -> int:
    prev = int(state.get(session_id, {}).get("consecutive_failures", 0))
    current = prev + 1
    state[session_id] = {
        "consecutive_failures": current,
        "last_failure_at": utc_now(),
        "last_success_at": state.get(session_id, {}).get("last_success_at"),
    }
    save_state(path, state)
    return current


def main() -> int:
    args = parse_args()
    # Allow long-running Codex jobs (multi-hour) without clamping upper bounds.
    # Some legacy callers still pass --timeout 900; treat that as too small and lift to a long floor.
    args.retries = max(1, args.retries)
    args.timeout = max(10800, args.timeout)
    prompt = load_prompt(args)
    cmd = build_cmd(args)
    attempts: list[dict] = []
    state_path = Path(args.state_file).resolve()
    state = load_state(state_path)
    session_id = str(args.session_id or "default")
    previous_failures = int(get_session_record(state, session_id).get("consecutive_failures", 0))
    if previous_failures >= max(args.failure_budget, 1):
        print(
            json.dumps(
                {
                    "ok": False,
                    "blocked": True,
                    "reason": "failure_budget_exceeded",
                    "session_id": session_id,
                    "consecutive_failures": previous_failures,
                    "failure_budget": max(args.failure_budget, 1),
                    "hint": "Repeated Codex transport failures reached budget. Ask user whether to continue retry burn.",
                },
                ensure_ascii=False,
            )
        )
        return 2

    for idx in range(1, max(args.retries, 1) + 1):
        started = time.time()
        attempt = {
            "attempt": idx,
            "command": " ".join(shlex.quote(part) for part in cmd),
            "timeout_seconds": args.timeout,
        }
        try:
            proc = subprocess.run(
                cmd,
                input=prompt,
                text=True,
                capture_output=True,
                timeout=args.timeout,
                check=False,
            )
            attempt["exit_code"] = proc.returncode
            attempt["duration_seconds"] = round(time.time() - started, 3)
            attempt["stdout"] = proc.stdout
            attempt["stderr"] = proc.stderr
            attempts.append(attempt)

            if proc.returncode == 0:
                mark_success(state_path, state, session_id)
                print(
                    json.dumps(
                        {
                            "ok": True,
                            "attempts": attempts,
                            "used_attempts": idx,
                            "session_id": session_id,
                            "consecutive_failures_before": previous_failures,
                        },
                        ensure_ascii=False,
                    )
                )
                return 0

            if idx < args.retries and is_retryable(proc.stderr, proc.stdout, proc.returncode):
                time.sleep(args.backoff * idx)
                continue

            break
        except subprocess.TimeoutExpired as exc:
            attempt["exit_code"] = 124
            attempt["duration_seconds"] = round(time.time() - started, 3)
            attempt["stdout"] = exc.stdout or ""
            attempt["stderr"] = (exc.stderr or "") + "\nTIMEOUT"
            attempts.append(attempt)
            if idx < args.retries:
                time.sleep(args.backoff * idx)
                continue
            break

    consecutive_failures = mark_failure(state_path, state, session_id)
    print(
        json.dumps(
            {
                "ok": False,
                "attempts": attempts,
                "used_attempts": len(attempts),
                "session_id": session_id,
                "consecutive_failures": consecutive_failures,
                "failure_budget": max(args.failure_budget, 1),
            },
            ensure_ascii=False,
        )
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
