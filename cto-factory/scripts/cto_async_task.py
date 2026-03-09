#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

OPENCLAW_ROOT = Path(os.getenv("OPENCLAW_ROOT", str(Path.home() / ".openclaw"))).expanduser().resolve()
RUNTIME_DIR = OPENCLAW_ROOT / "workspace-factory" / ".cto-brain" / "runtime" / "async-tasks"


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def state_path(task_id: str) -> Path:
    return RUNTIME_DIR / f"{task_id}.json"


def log_path(task_id: str) -> Path:
    return RUNTIME_DIR / f"{task_id}.log"


def read_state(task_id: str) -> dict | None:
    p = state_path(task_id)
    if not p.exists():
        return None
    return json.loads(p.read_text(encoding="utf-8"))


def write_state(task_id: str, payload: dict) -> None:
    RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
    p = state_path(task_id)
    p.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


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
        "ASYNC_TASK_COMPLETE "
        "task_id={task_id} status={status} exit_code={exit_code}. "
        "Log: {log_file}"
    )
    text = template or default_template
    try:
        rendered = text.format_map(_SafeFormatDict(context))
    except Exception:
        rendered = default_template.format_map(_SafeFormatDict(context))
    return rendered


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


def send_session_callback(task: dict) -> dict:
    callback_agent_id = normalize_optional(task.get("callback_agent_id"))
    callback_session_id = normalize_optional(task.get("callback_session_id"))
    callback_message_template = normalize_optional(task.get("callback_message"))
    callback_timeout = int(task.get("callback_timeout") or 120)
    callback_timeout = max(15, callback_timeout)

    if not callback_agent_id or not callback_session_id:
        return {
            "enabled": False,
            "sent": False,
            "reason": "callback_not_configured",
        }
    if not session_exists(callback_agent_id, callback_session_id):
        return {
            "enabled": True,
            "sent": False,
            "reason": "callback_session_not_found",
            "agent_id": callback_agent_id,
            "session_id": callback_session_id,
        }

    context = {
        "task_id": str(task.get("task_id", "")),
        "status": str(task.get("status", "")),
        "exit_code": task.get("exit_code"),
        "log_file": str(task.get("log_file", "")),
        "finished_at": str(task.get("finished_at", "")),
    }
    message = render_callback_message(callback_message_template, context)
    cmd = [
        "openclaw",
        "agent",
        "--agent",
        callback_agent_id,
        "--session-id",
        callback_session_id,
        "--message",
        message,
        "--json",
        "--timeout",
        str(callback_timeout),
    ]

    try:
        proc = subprocess.run(
            cmd,
            text=True,
            capture_output=True,
            check=False,
        )
        return {
            "enabled": True,
            "sent": proc.returncode == 0,
            "agent_id": callback_agent_id,
            "session_id": callback_session_id,
            "timeout_seconds": callback_timeout,
            "exit_code": proc.returncode,
            "stdout_preview": (proc.stdout or "")[:800],
            "stderr_preview": (proc.stderr or "")[:800],
            "message": message,
            "sent_at": now_iso(),
        }
    except Exception as exc:  # pragma: no cover - defensive branch
        return {
            "enabled": True,
            "sent": False,
            "agent_id": callback_agent_id,
            "session_id": callback_session_id,
            "timeout_seconds": callback_timeout,
            "exit_code": 1,
            "stdout_preview": "",
            "stderr_preview": str(exc),
            "message": message,
            "sent_at": now_iso(),
        }


def cmd_start(args: argparse.Namespace) -> int:
    existing = read_state(args.task_id)
    if existing and existing.get("status") in {"queued", "running"}:
        print(json.dumps({"ok": False, "error": "task_already_running", "task": existing}, ensure_ascii=False))
        return 1

    callback_session_id = (
        normalize_optional(args.callback_session_id)
        or normalize_optional(os.getenv("CTO_SESSION_ID"))
        or normalize_optional(os.getenv("OPENCLAW_SESSION_ID"))
    )
    callback_agent_id = normalize_optional(args.callback_agent_id)
    if callback_session_id and not callback_agent_id:
        callback_agent_id = normalize_optional(os.getenv("CTO_AGENT_ID")) or "cto-factory"

    payload = {
        "task_id": args.task_id,
        "status": "queued",
        "command": args.command,
        "cwd": args.cwd,
        "created_at": now_iso(),
        "updated_at": now_iso(),
        "started_at": None,
        "finished_at": None,
        "pid": None,
        "exit_code": None,
        "log_file": str(log_path(args.task_id)),
        "callback_agent_id": callback_agent_id,
        "callback_session_id": callback_session_id,
        "callback_message": normalize_optional(args.callback_message),
        "callback_timeout": max(15, int(args.callback_timeout)),
        "callback": None,
    }
    write_state(args.task_id, payload)

    spawn_cmd = [
        sys.executable,
        __file__,
        "_run",
        "--task-id",
        args.task_id,
        "--cmd",
        args.command,
        "--cwd",
        args.cwd,
        "--callback-timeout",
        str(max(15, int(args.callback_timeout))),
    ]
    if callback_agent_id:
        spawn_cmd.extend(["--callback-agent-id", callback_agent_id])
    if callback_session_id:
        spawn_cmd.extend(["--callback-session-id", callback_session_id])
    if normalize_optional(args.callback_message):
        spawn_cmd.extend(["--callback-message", normalize_optional(args.callback_message)])

    proc = subprocess.Popen(
        spawn_cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
    )

    payload["status"] = "running"
    payload["pid"] = proc.pid
    payload["started_at"] = now_iso()
    payload["updated_at"] = now_iso()
    write_state(args.task_id, payload)

    print(json.dumps({"ok": True, "task": payload}, ensure_ascii=False))
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    current = read_state(args.task_id) or {}
    current.update(
        {
            "task_id": args.task_id,
            "status": "running",
            "command": args.command,
            "cwd": args.cwd,
            "started_at": current.get("started_at") or now_iso(),
            "updated_at": now_iso(),
            "pid": os.getpid(),
            "log_file": str(log_path(args.task_id)),
            "callback_agent_id": normalize_optional(args.callback_agent_id) or current.get("callback_agent_id"),
            "callback_session_id": normalize_optional(args.callback_session_id) or current.get("callback_session_id"),
            "callback_message": normalize_optional(args.callback_message) or current.get("callback_message"),
            "callback_timeout": max(15, int(args.callback_timeout or current.get("callback_timeout") or 120)),
        }
    )
    write_state(args.task_id, current)

    RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
    with log_path(args.task_id).open("a", encoding="utf-8") as logf:
        logf.write(f"[{now_iso()}] START cmd={args.command} cwd={args.cwd}\n")
        run = subprocess.run(
            ["/bin/zsh", "-lc", args.command],
            cwd=args.cwd,
            text=True,
            stdout=logf,
            stderr=logf,
            check=False,
        )
        logf.write(f"[{now_iso()}] END exit={run.returncode}\n")

    final = read_state(args.task_id) or {}
    final.update(
        {
            "status": "completed" if run.returncode == 0 else "failed",
            "exit_code": run.returncode,
            "finished_at": now_iso(),
            "updated_at": now_iso(),
        }
    )
    callback_result = send_session_callback(final)
    final["callback"] = callback_result
    final["updated_at"] = now_iso()
    with log_path(args.task_id).open("a", encoding="utf-8") as logf:
        logf.write(
            f"[{now_iso()}] CALLBACK sent={callback_result.get('sent')} "
            f"enabled={callback_result.get('enabled')} "
            f"rc={callback_result.get('exit_code')}\n"
        )
        if callback_result.get("stderr_preview"):
            logf.write(f"[{now_iso()}] CALLBACK_STDERR {callback_result.get('stderr_preview')}\n")
    write_state(args.task_id, final)
    return run.returncode


def cmd_status(args: argparse.Namespace) -> int:
    payload = read_state(args.task_id)
    if not payload:
        print(json.dumps({"ok": False, "error": "task_not_found", "task_id": args.task_id}, ensure_ascii=False))
        return 1

    task = dict(payload)
    status = str(task.get("status", "")).lower()
    lp = Path(task.get("log_file", ""))
    if status in {"queued", "running"}:
        threshold = max(1, int(args.stuck_threshold))
        task["stuck_threshold_seconds"] = threshold
        if lp.exists():
            mtime = lp.stat().st_mtime
            age = max(0, int(time.time() - mtime))
            task["last_log_update_at"] = (
                datetime.fromtimestamp(mtime, timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
            )
            task["log_idle_seconds"] = age
            task["stuck"] = age >= threshold
            task["watchdog_hint"] = (
                "no log progress for threshold window: send keepalive warning to user"
                if task["stuck"]
                else "log activity is recent"
            )
        else:
            task["last_log_update_at"] = None
            task["log_idle_seconds"] = None
            task["stuck"] = False
            task["watchdog_hint"] = "log file missing; verify command and cwd"

    print(json.dumps({"ok": True, "task": task}, ensure_ascii=False))
    return 0


def cmd_list(_: argparse.Namespace) -> int:
    RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
    items = []
    for p in sorted(RUNTIME_DIR.glob("*.json")):
        try:
            items.append(json.loads(p.read_text(encoding="utf-8")))
        except Exception:
            continue
    print(json.dumps({"ok": True, "count": len(items), "tasks": items}, ensure_ascii=False))
    return 0


def cmd_tail(args: argparse.Namespace) -> int:
    lp = log_path(args.task_id)
    if not lp.exists():
        print(json.dumps({"ok": False, "error": "log_not_found", "task_id": args.task_id}, ensure_ascii=False))
        return 1
    lines = lp.read_text(encoding="utf-8", errors="ignore").splitlines()
    tail_lines = lines[-max(1, args.lines) :]
    print(json.dumps({"ok": True, "task_id": args.task_id, "lines": tail_lines}, ensure_ascii=False))
    return 0


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description="Async task helper for CTO keep-alive")
    sp = ap.add_subparsers(dest="action", required=True)

    p_start = sp.add_parser("start")
    p_start.add_argument("--task-id", required=True)
    p_start.add_argument("--cmd", dest="command", required=True)
    p_start.add_argument("--cwd", default=str(OPENCLAW_ROOT))
    p_start.add_argument("--callback-agent-id")
    p_start.add_argument("--callback-session-id")
    p_start.add_argument("--callback-message")
    p_start.add_argument("--callback-timeout", type=int, default=120)

    p_run = sp.add_parser("_run")
    p_run.add_argument("--task-id", required=True)
    p_run.add_argument("--cmd", dest="command", required=True)
    p_run.add_argument("--cwd", default=str(OPENCLAW_ROOT))
    p_run.add_argument("--callback-agent-id")
    p_run.add_argument("--callback-session-id")
    p_run.add_argument("--callback-message")
    p_run.add_argument("--callback-timeout", type=int, default=120)

    p_status = sp.add_parser("status")
    p_status.add_argument("--task-id", required=True)
    p_status.add_argument("--stuck-threshold", type=int, default=300)

    sp.add_parser("list")

    p_tail = sp.add_parser("tail")
    p_tail.add_argument("--task-id", required=True)
    p_tail.add_argument("--lines", type=int, default=40)

    return ap


def main() -> int:
    args = build_parser().parse_args()
    if args.action == "start":
        return cmd_start(args)
    if args.action == "_run":
        return cmd_run(args)
    if args.action == "status":
        return cmd_status(args)
    if args.action == "list":
        return cmd_list(args)
    if args.action == "tail":
        return cmd_tail(args)
    print(json.dumps({"ok": False, "error": "unknown_command"}, ensure_ascii=False))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
