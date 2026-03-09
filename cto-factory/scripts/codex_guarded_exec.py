#!/usr/bin/env python3
"""Guarded wrapper around `codex exec` with retry and long-running timeout support."""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_MODEL = "gpt-5.3-codex"
MODEL_TOKEN_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def parse_args() -> argparse.Namespace:
    default_state = (
        Path(__file__).resolve().parent.parent / ".cto-brain" / "runtime" / "codex_failure_guard.json"
    )
    p = argparse.ArgumentParser(description="Run codex exec with retries and long-running timeout support")
    p.add_argument("--workdir", required=True, help="Project root passed to codex --cd")
    p.add_argument("--model", default=DEFAULT_MODEL, help="Codex model")
    p.add_argument("--prompt-file", help="Path to file with prompt text")
    p.add_argument("--prompt", help="Inline prompt text")
    p.add_argument("--retries", type=int, default=5, help="Max attempts")
    p.add_argument("--timeout", type=int, default=10800, help="Per-attempt timeout (seconds)")
    p.add_argument("--backoff", type=float, default=2.0, help="Base backoff seconds")
    p.add_argument(
        "--heartbeat-interval",
        type=int,
        default=75,
        help="Emit 'still running' heartbeat every N seconds while codex exec is active",
    )
    p.add_argument("--reasoning-effort", choices=["none", "minimal", "low", "medium", "high"], default=None)
    p.add_argument("--failure-budget", type=int, default=3, help="Consecutive failed runs allowed per session")
    p.add_argument("--session-id", default=os.getenv("CTO_SESSION_ID", "default"), help="Session key for failure budget")
    p.add_argument("--state-file", default=str(default_state), help="Path to persistent failure counter JSON")
    p.add_argument("--callback-agent-id", help="Agent id to wake after command completion")
    p.add_argument("--callback-session-id", help="Session id to wake after command completion")
    p.add_argument("--callback-timeout", type=int, default=120, help="Timeout for callback command (seconds)")
    p.add_argument(
        "--callback-message",
        help="Optional callback message template. Supports {status}, {exit_code}, {used_attempts}, {session_id}.",
    )
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


def normalize_model_id(requested_model: str) -> tuple[str, str | None]:
    requested = (requested_model or "").strip()
    if not requested:
        return DEFAULT_MODEL, f"Model id is empty; falling back to '{DEFAULT_MODEL}'."

    normalized = requested.split("/")[-1].strip()
    warning_parts: list[str] = []

    if normalized != requested:
        warning_parts.append(f"normalized '{requested}' -> '{normalized}'")

    if not normalized or not MODEL_TOKEN_RE.match(normalized):
        warning_parts.append(f"invalid model token '{normalized}'")
        normalized = DEFAULT_MODEL
        warning_parts.append(f"fallback to '{DEFAULT_MODEL}'")

    if normalized != requested and not warning_parts:
        warning_parts.append(f"normalized '{requested}' -> '{normalized}'")
    warning = "; ".join(warning_parts) if warning_parts else None
    return normalized, warning


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


def normalize_optional(value: str | None) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


class _SafeFormatDict(dict):
    def __missing__(self, key: str) -> str:
        return "{" + key + "}"


def render_callback_message(template: str | None, context: dict) -> str:
    default_template = (
        "CODEX_GUARD_COMPLETE status={status} exit_code={exit_code} used_attempts={used_attempts}. "
        "session_id={session_id}"
    )
    text = template or default_template
    try:
        return text.format_map(_SafeFormatDict(context))
    except Exception:
        return default_template.format_map(_SafeFormatDict(context))


def session_exists(agent_id: str, session_id: str) -> bool:
    try:
        proc = subprocess.run(
            ["openclaw", "sessions", "--agent", agent_id, "--json"],
            text=True,
            capture_output=True,
            check=False,
        )
        if proc.returncode != 0:
            return False
        payload = json.loads(proc.stdout or "{}")
        sessions = payload.get("sessions") if isinstance(payload, dict) else None
        if not isinstance(sessions, list):
            return False
        for item in sessions:
            if isinstance(item, dict) and str(item.get("sessionId", "")).strip() == session_id:
                return True
        return False
    except Exception:
        return False


def send_callback(
    *,
    callback_agent_id: str | None,
    callback_session_id: str | None,
    callback_timeout: int,
    callback_message_template: str | None,
    context: dict,
) -> dict:
    agent_id = normalize_optional(callback_agent_id)
    session_id = normalize_optional(callback_session_id)
    if not agent_id or not session_id:
        return {"enabled": False, "sent": False, "reason": "callback_not_configured"}
    if not session_exists(agent_id, session_id):
        return {
            "enabled": True,
            "sent": False,
            "reason": "callback_session_not_found",
            "agent_id": agent_id,
            "session_id": session_id,
        }

    message = render_callback_message(callback_message_template, context)
    cmd = [
        "openclaw",
        "agent",
        "--agent",
        agent_id,
        "--session-id",
        session_id,
        "--message",
        message,
        "--json",
        "--timeout",
        str(max(15, callback_timeout)),
    ]
    try:
        proc = subprocess.run(cmd, text=True, capture_output=True, check=False)
        return {
            "enabled": True,
            "sent": proc.returncode == 0,
            "agent_id": agent_id,
            "session_id": session_id,
            "timeout_seconds": max(15, callback_timeout),
            "exit_code": proc.returncode,
            "stdout_preview": (proc.stdout or "")[:800],
            "stderr_preview": (proc.stderr or "")[:800],
            "message": message,
            "sent_at": utc_now(),
        }
    except Exception as exc:  # pragma: no cover - defensive branch
        return {
            "enabled": True,
            "sent": False,
            "agent_id": agent_id,
            "session_id": session_id,
            "timeout_seconds": max(15, callback_timeout),
            "exit_code": 1,
            "stdout_preview": "",
            "stderr_preview": str(exc),
            "message": message,
            "sent_at": utc_now(),
        }


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


def _pipe_reader(pipe, sink: list[str]) -> None:
    try:
        for chunk in iter(lambda: pipe.read(4096), ""):
            if not chunk:
                break
            sink.append(chunk)
    finally:
        try:
            pipe.close()
        except Exception:
            pass


def run_with_heartbeat(
    cmd: list[str],
    prompt: str,
    timeout: int,
    heartbeat_interval: int,
    attempt_index: int,
) -> dict:
    started = time.time()
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )

    out_chunks: list[str] = []
    err_chunks: list[str] = []
    out_thread = threading.Thread(target=_pipe_reader, args=(proc.stdout, out_chunks), daemon=True)
    err_thread = threading.Thread(target=_pipe_reader, args=(proc.stderr, err_chunks), daemon=True)
    out_thread.start()
    err_thread.start()

    if proc.stdin is not None:
        proc.stdin.write(prompt)
        proc.stdin.close()

    heartbeats = 0
    next_heartbeat_at = started + max(1, heartbeat_interval)
    timed_out = False

    while proc.poll() is None:
        now = time.time()
        if now - started >= timeout:
            timed_out = True
            proc.kill()
            break
        if now >= next_heartbeat_at:
            elapsed = int(now - started)
            heartbeats += 1
            print(
                f"[codex-guard] still running attempt={attempt_index} elapsed={elapsed}s",
                file=sys.stderr,
                flush=True,
            )
            next_heartbeat_at = now + max(1, heartbeat_interval)
        time.sleep(1)

    returncode = 124 if timed_out else proc.wait()
    out_thread.join(timeout=2)
    err_thread.join(timeout=2)
    stdout = "".join(out_chunks)
    stderr = "".join(err_chunks)
    if timed_out:
        stderr = f"{stderr}\nTIMEOUT".strip()

    return {
        "exit_code": returncode,
        "duration_seconds": round(time.time() - started, 3),
        "stdout": stdout,
        "stderr": stderr,
        "heartbeats": heartbeats,
        "timed_out": timed_out,
    }


def main() -> int:
    args = parse_args()
    # Allow long-running Codex jobs (multi-hour) without clamping upper bounds.
    # Some legacy callers still pass --timeout 900; treat that as too small and lift to a long floor.
    args.retries = max(1, args.retries)
    args.timeout = max(10800, args.timeout)
    prompt = load_prompt(args)
    requested_model = args.model
    resolved_model, model_warning = normalize_model_id(requested_model)
    args.model = resolved_model
    if model_warning:
        print(f"[codex-guard] model fallback: {model_warning}", file=sys.stderr, flush=True)
    cmd = build_cmd(args)
    attempts: list[dict] = []
    state_path = Path(args.state_file).resolve()
    state = load_state(state_path)
    session_id = str(args.session_id or "default")
    previous_failures = int(get_session_record(state, session_id).get("consecutive_failures", 0))
    if previous_failures >= max(args.failure_budget, 1):
        callback_context = {
            "status": "blocked",
            "exit_code": 2,
            "used_attempts": 0,
            "session_id": session_id,
            "consecutive_failures": previous_failures,
            "failure_budget": max(args.failure_budget, 1),
        }
        callback = send_callback(
            callback_agent_id=args.callback_agent_id,
            callback_session_id=args.callback_session_id,
            callback_timeout=args.callback_timeout,
            callback_message_template=args.callback_message,
            context=callback_context,
        )
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
                    "callback": callback,
                },
                ensure_ascii=False,
            )
        )
        return 2

    for idx in range(1, max(args.retries, 1) + 1):
        attempt = {
            "attempt": idx,
            "command": " ".join(shlex.quote(part) for part in cmd),
            "timeout_seconds": args.timeout,
            "model_requested": requested_model,
            "model_resolved": resolved_model,
            "model_warning": model_warning,
        }
        try:
            run_result = run_with_heartbeat(
                cmd=cmd,
                prompt=prompt,
                timeout=args.timeout,
                heartbeat_interval=max(1, args.heartbeat_interval),
                attempt_index=idx,
            )
            attempt.update(run_result)
            attempts.append(attempt)

            if int(run_result["exit_code"]) == 0:
                mark_success(state_path, state, session_id)
                callback_context = {
                    "status": "completed",
                    "exit_code": 0,
                    "used_attempts": idx,
                    "session_id": session_id,
                    "consecutive_failures_before": previous_failures,
                    "model_requested": requested_model,
                    "model_resolved": resolved_model,
                }
                callback = send_callback(
                    callback_agent_id=args.callback_agent_id,
                    callback_session_id=args.callback_session_id,
                    callback_timeout=args.callback_timeout,
                    callback_message_template=args.callback_message,
                    context=callback_context,
                )
                print(
                    json.dumps(
                        {
                            "ok": True,
                            "attempts": attempts,
                            "used_attempts": idx,
                            "session_id": session_id,
                            "consecutive_failures_before": previous_failures,
                            "model_requested": requested_model,
                            "model_resolved": resolved_model,
                            "model_warning": model_warning,
                            "callback": callback,
                        },
                        ensure_ascii=False,
                    )
                )
                return 0

            if idx < args.retries and is_retryable(
                str(run_result["stderr"]), str(run_result["stdout"]), int(run_result["exit_code"])
            ):
                time.sleep(args.backoff * idx)
                continue

            break
        except Exception as exc:
            attempt["exit_code"] = 1
            attempt["duration_seconds"] = 0
            attempt["stdout"] = ""
            attempt["stderr"] = str(exc)
            attempt["heartbeats"] = 0
            attempt["timed_out"] = False
            attempts.append(attempt)
            break

    consecutive_failures = mark_failure(state_path, state, session_id)
    callback_context = {
        "status": "failed",
        "exit_code": 1,
        "used_attempts": len(attempts),
        "session_id": session_id,
        "consecutive_failures": consecutive_failures,
        "failure_budget": max(args.failure_budget, 1),
        "model_requested": requested_model,
        "model_resolved": resolved_model,
    }
    callback = send_callback(
        callback_agent_id=args.callback_agent_id,
        callback_session_id=args.callback_session_id,
        callback_timeout=args.callback_timeout,
        callback_message_template=args.callback_message,
        context=callback_context,
    )
    print(
        json.dumps(
            {
                "ok": False,
                "attempts": attempts,
                "used_attempts": len(attempts),
                "session_id": session_id,
                "consecutive_failures": consecutive_failures,
                "failure_budget": max(args.failure_budget, 1),
                "model_requested": requested_model,
                "model_resolved": resolved_model,
                "model_warning": model_warning,
                "callback": callback,
            },
            ensure_ascii=False,
        )
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
