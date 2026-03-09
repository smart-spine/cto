#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
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
    status = str(context.get("status", "")).strip().lower()
    if status == "running":
        default_template = (
            "ASYNC_TASK_HEARTBEAT "
            "task_id={task_id} status={status} elapsed={elapsed_seconds}s heartbeat={heartbeat_index}. "
            "Log: {log_file}. Continue the task and report progress to user."
        )
    else:
        default_template = (
            "ASYNC_TASK_COMPLETE "
            "task_id={task_id} status={status} exit_code={exit_code}. "
            "Log: {log_file}. Continue workflow; do not wait for user ping."
        )
    text = template or default_template
    try:
        rendered = text.format_map(_SafeFormatDict(context))
    except Exception:
        rendered = default_template.format_map(_SafeFormatDict(context))
    return rendered


def load_agent_sessions(agent_id: str) -> list[dict]:
    try:
        proc = subprocess.run(
            ["openclaw", "sessions", "--agent", agent_id, "--json"],
            text=True,
            capture_output=True,
            check=False,
            timeout=20,
        )
        if proc.returncode != 0:
            return []
        payload = json.loads(proc.stdout or "{}")
        sessions = payload.get("sessions") if isinstance(payload, dict) else None
        if not isinstance(sessions, list):
            return []
        return [item for item in sessions if isinstance(item, dict)]
    except Exception:
        return []


def session_record(agent_id: str, session_id: str) -> dict | None:
    sid = normalize_optional(session_id)
    if not sid:
        return None
    for item in load_agent_sessions(agent_id):
        if normalize_optional(item.get("sessionId")) == sid:
            return item
    return None


def session_exists(agent_id: str, session_id: str) -> bool:
    return session_record(agent_id, session_id) is not None


def latest_session_id(agent_id: str) -> str | None:
    agent = normalize_optional(agent_id)
    if not agent:
        return None
    sessions = load_agent_sessions(agent)
    if not sessions:
        return None
    ordered = sorted(
        sessions,
        key=lambda item: int(item.get("updatedAt") or 0),
        reverse=True,
    )
    for item in ordered:
        sid = normalize_optional(item.get("sessionId"))
        if sid:
            return sid
    return None


_KEY_GROUP_TOPIC = re.compile(r":telegram:group:([^:]+):topic:([0-9]+)$")
_KEY_GROUP = re.compile(r":telegram:group:([^:]+)$")
_KEY_DIRECT = re.compile(r":telegram:direct:([^:]+)$")
_KEY_SLASH = re.compile(r"^telegram:slash:([^:]+)$")


def parse_telegram_target_from_session_key(key: str) -> str | None:
    text = normalize_optional(key)
    if not text:
        return None
    for rx in (_KEY_GROUP_TOPIC, _KEY_GROUP, _KEY_DIRECT, _KEY_SLASH):
        match = rx.search(text)
        if not match:
            continue
        if rx is _KEY_GROUP_TOPIC:
            return f"{match.group(1)}:topic:{match.group(2)}"
        return match.group(1)
    return None


def resolve_callback_transport(agent_id: str, session_id: str) -> tuple[str | None, str | None]:
    item = session_record(agent_id, session_id)
    if not item:
        return None, None
    key = normalize_optional(item.get("key")) or ""
    target = parse_telegram_target_from_session_key(key)
    if target:
        return "telegram", target
    return None, None


def send_session_callback(task: dict, template_override: str | None = None) -> dict:
    callback_agent_id = normalize_optional(task.get("callback_agent_id"))
    callback_session_id = normalize_optional(task.get("callback_session_id"))
    callback_channel = normalize_optional(task.get("callback_channel"))
    callback_target = normalize_optional(task.get("callback_target"))
    callback_message_template = normalize_optional(template_override) or normalize_optional(task.get("callback_message"))
    callback_timeout = int(task.get("callback_timeout") or 3600)
    callback_timeout = max(30, callback_timeout)

    agent_id = callback_agent_id or "cto-factory"
    session_id = callback_session_id
    explicit_session = bool(callback_session_id)
    auto_resolved = False
    auto_reason = None

    if not session_id:
        session_id = (
            normalize_optional(os.getenv("CTO_SESSION_ID"))
            or normalize_optional(os.getenv("OPENCLAW_SESSION_ID"))
            or latest_session_id(agent_id)
        )
        if session_id:
            auto_resolved = True
            auto_reason = "env_or_latest_session"

    if not agent_id or not session_id:
        return {
            "enabled": False,
            "sent": False,
            "reason": "callback_not_configured",
            "agent_id": agent_id,
            "session_id": session_id,
            "callback_channel": callback_channel,
            "callback_target": callback_target,
        }

    if not callback_target:
        resolved_channel, resolved_target = resolve_callback_transport(agent_id, session_id)
        callback_channel = callback_channel or resolved_channel
        callback_target = callback_target or resolved_target

    if not session_exists(agent_id, session_id):
        if explicit_session:
            return {
                "enabled": True,
                "sent": False,
                "reason": "callback_session_not_found_strict",
                "agent_id": agent_id,
                "session_id": session_id,
                "strict_session_affinity": True,
                "callback_channel": callback_channel,
                "callback_target": callback_target,
            }
        fallback_session = latest_session_id(agent_id)
        if fallback_session and fallback_session != session_id and session_exists(agent_id, fallback_session):
            session_id = fallback_session
            auto_resolved = True
            auto_reason = "latest_session_fallback"
        else:
            return {
                "enabled": True,
                "sent": False,
                "reason": "callback_session_not_found",
                "agent_id": agent_id,
                "session_id": session_id,
                "callback_channel": callback_channel,
                "callback_target": callback_target,
            }

    context = {
        "task_id": str(task.get("task_id", "")),
        "status": str(task.get("status", "")),
        "exit_code": task.get("exit_code"),
        "log_file": str(task.get("log_file", "")),
        "finished_at": str(task.get("finished_at", "")),
        "heartbeat_index": task.get("heartbeat_index"),
        "elapsed_seconds": task.get("elapsed_seconds"),
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
        str(callback_timeout),
    ]

    try:
        exec_timeout = max(35, callback_timeout + 15)
        proc = subprocess.run(
            cmd,
            text=True,
            capture_output=True,
            check=False,
            timeout=exec_timeout,
        )
        return {
            "enabled": True,
            "sent": proc.returncode == 0,
            "agent_id": agent_id,
            "session_id": session_id,
            "timeout_seconds": callback_timeout,
            "exit_code": proc.returncode,
            "stdout_preview": (proc.stdout or "")[:800],
            "stderr_preview": (proc.stderr or "")[:800],
            "message": message,
            "sent_at": now_iso(),
            "auto_resolved_session": auto_resolved,
            "auto_resolve_reason": auto_reason,
            "callback_channel": callback_channel,
            "callback_target": callback_target,
        }
    except subprocess.TimeoutExpired as exc:
        return {
            "enabled": True,
            "sent": False,
            "agent_id": agent_id,
            "session_id": session_id,
            "timeout_seconds": callback_timeout,
            "exit_code": 124,
            "stdout_preview": (exc.stdout or "")[:800],
            "stderr_preview": "callback_timeout_expired",
            "message": message,
            "sent_at": now_iso(),
            "reason": "callback_timeout_expired",
            "auto_resolved_session": auto_resolved,
            "auto_resolve_reason": auto_reason,
            "callback_channel": callback_channel,
            "callback_target": callback_target,
        }
    except Exception as exc:  # pragma: no cover - defensive branch
        return {
            "enabled": True,
            "sent": False,
            "agent_id": agent_id,
            "session_id": session_id,
            "timeout_seconds": callback_timeout,
            "exit_code": 1,
            "stdout_preview": "",
            "stderr_preview": str(exc),
            "message": message,
            "sent_at": now_iso(),
            "auto_resolved_session": auto_resolved,
            "auto_resolve_reason": auto_reason,
            "callback_channel": callback_channel,
            "callback_target": callback_target,
        }


def send_transport_callback(task: dict, template_override: str | None = None) -> dict:
    callback_channel = normalize_optional(task.get("callback_channel"))
    callback_target = normalize_optional(task.get("callback_target"))
    callback_timeout = int(task.get("callback_timeout") or 3600)
    callback_timeout = max(30, callback_timeout)
    if callback_target and not callback_channel:
        callback_channel = "telegram"
    if not callback_channel or not callback_target:
        return {
            "enabled": False,
            "sent": False,
            "reason": "transport_callback_not_configured",
            "callback_channel": callback_channel,
            "callback_target": callback_target,
        }

    context = {
        "task_id": str(task.get("task_id", "")),
        "status": str(task.get("status", "")),
        "exit_code": task.get("exit_code"),
        "log_file": str(task.get("log_file", "")),
        "finished_at": str(task.get("finished_at", "")),
        "heartbeat_index": task.get("heartbeat_index"),
        "elapsed_seconds": task.get("elapsed_seconds"),
    }
    message = render_callback_message(template_override or normalize_optional(task.get("callback_message")), context)
    cmd = [
        "openclaw",
        "message",
        "send",
        "--channel",
        callback_channel,
        "--target",
        callback_target,
        "--message",
        message,
        "--json",
    ]
    try:
        exec_timeout = max(35, callback_timeout + 15)
        proc = subprocess.run(
            cmd,
            text=True,
            capture_output=True,
            check=False,
            timeout=exec_timeout,
        )
        return {
            "enabled": True,
            "sent": proc.returncode == 0,
            "exit_code": proc.returncode,
            "stdout_preview": (proc.stdout or "")[:800],
            "stderr_preview": (proc.stderr or "")[:800],
            "sent_at": now_iso(),
            "callback_channel": callback_channel,
            "callback_target": callback_target,
        }
    except subprocess.TimeoutExpired as exc:
        return {
            "enabled": True,
            "sent": False,
            "exit_code": 124,
            "stdout_preview": (exc.stdout or "")[:800],
            "stderr_preview": "transport_callback_timeout_expired",
            "reason": "transport_callback_timeout_expired",
            "sent_at": now_iso(),
            "callback_channel": callback_channel,
            "callback_target": callback_target,
        }
    except Exception as exc:  # pragma: no cover - defensive branch
        return {
            "enabled": True,
            "sent": False,
            "exit_code": 1,
            "stdout_preview": "",
            "stderr_preview": str(exc),
            "sent_at": now_iso(),
            "callback_channel": callback_channel,
            "callback_target": callback_target,
        }


def send_session_callback_with_retry(
    task: dict,
    template_override: str | None = None,
    *,
    retries: int = 3,
    initial_backoff_seconds: float = 1.5,
) -> dict:
    attempts: list[dict] = []
    max_attempts = max(1, int(retries))
    backoff = max(0.5, float(initial_backoff_seconds))
    last: dict | None = None

    for idx in range(1, max_attempts + 1):
        result = send_session_callback(task, template_override=template_override)
        result["attempt"] = idx
        result["attempted_at"] = now_iso()
        attempts.append(result)
        last = result

        if result.get("sent"):
            break

        enabled = bool(result.get("enabled"))
        reason = str(result.get("reason", "")).strip().lower()
        if not enabled or reason == "callback_not_configured":
            break

        if idx < max_attempts:
            time.sleep(backoff)
            backoff = min(backoff * 2.0, 12.0)

    final = dict(last or {"enabled": False, "sent": False, "reason": "callback_not_attempted"})
    final["attempts"] = attempts
    final["attempts_count"] = len(attempts)
    final["sent"] = any(bool(item.get("sent")) for item in attempts)
    if not final["sent"]:
        transport = send_transport_callback(task, template_override=template_override)
        final["transport_fallback"] = transport
        if transport.get("sent"):
            final["sent"] = True
            final["reason"] = "transport_fallback_sent"
    return final


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
    callback_channel = normalize_optional(args.callback_channel) or normalize_optional(os.getenv("CTO_CALLBACK_CHANNEL"))
    callback_target = normalize_optional(args.callback_target) or normalize_optional(os.getenv("CTO_CALLBACK_TARGET"))
    if callback_session_id and not callback_target:
        resolved_channel, resolved_target = resolve_callback_transport(callback_agent_id or "cto-factory", callback_session_id)
        callback_channel = callback_channel or resolved_channel
        callback_target = callback_target or resolved_target

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
        "callback_channel": callback_channel,
        "callback_target": callback_target,
        "callback_message": normalize_optional(args.callback_message),
        "callback_timeout": max(30, int(args.callback_timeout)),
        "heartbeat_seconds": max(30, int(args.heartbeat_seconds)),
        "callback_retries": max(1, int(args.callback_retries)),
        "callback_progress_message": normalize_optional(args.callback_progress_message),
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
        str(max(30, int(args.callback_timeout))),
        "--heartbeat-seconds",
        str(max(30, int(args.heartbeat_seconds))),
        "--callback-retries",
        str(max(1, int(args.callback_retries))),
    ]
    if callback_agent_id:
        spawn_cmd.extend(["--callback-agent-id", callback_agent_id])
    if callback_session_id:
        spawn_cmd.extend(["--callback-session-id", callback_session_id])
    if callback_channel:
        spawn_cmd.extend(["--callback-channel", callback_channel])
    if callback_target:
        spawn_cmd.extend(["--callback-target", callback_target])
    if normalize_optional(args.callback_message):
        spawn_cmd.extend(["--callback-message", normalize_optional(args.callback_message)])
    if normalize_optional(args.callback_progress_message):
        spawn_cmd.extend(["--callback-progress-message", normalize_optional(args.callback_progress_message)])

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
            "callback_channel": normalize_optional(args.callback_channel) or current.get("callback_channel"),
            "callback_target": normalize_optional(args.callback_target) or current.get("callback_target"),
            "callback_message": normalize_optional(args.callback_message) or current.get("callback_message"),
            "callback_timeout": max(30, int(args.callback_timeout or current.get("callback_timeout") or 3600)),
            "heartbeat_seconds": max(30, int(args.heartbeat_seconds or current.get("heartbeat_seconds") or 90)),
            "callback_retries": max(1, int(args.callback_retries or current.get("callback_retries") or 3)),
            "callback_progress_message": normalize_optional(args.callback_progress_message)
            or current.get("callback_progress_message"),
        }
    )
    write_state(args.task_id, current)

    RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
    heartbeat_every = max(30, int(current.get("heartbeat_seconds") or 90))
    callback_retries = max(1, int(current.get("callback_retries") or 3))
    progress_template = normalize_optional(current.get("callback_progress_message"))
    started_epoch = time.time()
    heartbeat_index = 0
    with log_path(args.task_id).open("a", encoding="utf-8") as logf:
        logf.write(f"[{now_iso()}] START cmd={args.command} cwd={args.cwd}\n")
        proc = subprocess.Popen(
            ["/bin/zsh", "-lc", args.command],
            cwd=args.cwd,
            text=True,
            stdout=logf,
            stderr=logf,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
        current["pid"] = proc.pid
        current["updated_at"] = now_iso()
        write_state(args.task_id, current)

        # Send immediate start callback so the parent session confirms task is alive.
        start_task = dict(current)
        start_task.update({"status": "running", "elapsed_seconds": 0, "heartbeat_index": 0})
        start_cb = send_session_callback_with_retry(
            start_task,
            template_override=progress_template,
            retries=callback_retries,
        )
        logf.write(
            f"[{now_iso()}] CALLBACK_START sent={start_cb.get('sent')} enabled={start_cb.get('enabled')} "
            f"rc={start_cb.get('exit_code')} attempts={start_cb.get('attempts_count')}\n"
        )

        next_heartbeat = time.time() + heartbeat_every
        while True:
            rc = proc.poll()
            if rc is not None:
                run_return = int(rc)
                break
            now_ts = time.time()
            if now_ts >= next_heartbeat:
                heartbeat_index += 1
                elapsed = int(max(0, now_ts - started_epoch))
                hb_task = dict(current)
                hb_task.update(
                    {
                        "status": "running",
                        "elapsed_seconds": elapsed,
                        "heartbeat_index": heartbeat_index,
                        "updated_at": now_iso(),
                    }
                )
                hb_cb = send_session_callback_with_retry(
                    hb_task,
                    template_override=progress_template,
                    retries=callback_retries,
                )
                logf.write(
                    f"[{now_iso()}] CALLBACK_HEARTBEAT idx={heartbeat_index} elapsed={elapsed}s "
                    f"sent={hb_cb.get('sent')} enabled={hb_cb.get('enabled')} "
                    f"rc={hb_cb.get('exit_code')} attempts={hb_cb.get('attempts_count')}\n"
                )
                next_heartbeat = now_ts + heartbeat_every
            time.sleep(1)

        logf.write(f"[{now_iso()}] END exit={run_return}\n")

    final = read_state(args.task_id) or {}
    final.update(
        {
            "status": "completed" if run_return == 0 else "failed",
            "exit_code": run_return,
            "finished_at": now_iso(),
            "updated_at": now_iso(),
            "elapsed_seconds": int(max(0, time.time() - started_epoch)),
            "heartbeat_index": heartbeat_index,
        }
    )
    callback_result = send_session_callback_with_retry(
        final,
        retries=callback_retries,
    )
    final["callback"] = callback_result
    final["updated_at"] = now_iso()
    with log_path(args.task_id).open("a", encoding="utf-8") as logf:
        logf.write(
            f"[{now_iso()}] CALLBACK sent={callback_result.get('sent')} "
            f"enabled={callback_result.get('enabled')} "
            f"rc={callback_result.get('exit_code')} attempts={callback_result.get('attempts_count')}\n"
        )
        if callback_result.get("stderr_preview"):
            logf.write(f"[{now_iso()}] CALLBACK_STDERR {callback_result.get('stderr_preview')}\n")
    write_state(args.task_id, final)
    return run_return


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
    p_start.add_argument("--callback-channel")
    p_start.add_argument("--callback-target")
    p_start.add_argument("--callback-message")
    p_start.add_argument("--callback-timeout", type=int, default=3600)
    p_start.add_argument("--heartbeat-seconds", type=int, default=90)
    p_start.add_argument("--callback-retries", type=int, default=3)
    p_start.add_argument("--callback-progress-message")

    p_run = sp.add_parser("_run")
    p_run.add_argument("--task-id", required=True)
    p_run.add_argument("--cmd", dest="command", required=True)
    p_run.add_argument("--cwd", default=str(OPENCLAW_ROOT))
    p_run.add_argument("--callback-agent-id")
    p_run.add_argument("--callback-session-id")
    p_run.add_argument("--callback-channel")
    p_run.add_argument("--callback-target")
    p_run.add_argument("--callback-message")
    p_run.add_argument("--callback-timeout", type=int, default=3600)
    p_run.add_argument("--heartbeat-seconds", type=int, default=90)
    p_run.add_argument("--callback-retries", type=int, default=3)
    p_run.add_argument("--callback-progress-message")

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
