#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def default_openclaw_home() -> Path:
    return Path(os.environ.get("OPENCLAW_STATE_DIR", str(Path.home() / ".openclaw")))


OPENCLAW_HOME = default_openclaw_home()
RUNTIME_DIR = OPENCLAW_HOME / "workspace-factory/.cto-brain/runtime/async-tasks"


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


def cmd_start(args: argparse.Namespace) -> int:
    existing = read_state(args.task_id)
    if existing and existing.get("status") in {"queued", "running"}:
        print(json.dumps({"ok": False, "error": "task_already_running", "task": existing}, ensure_ascii=False))
        return 1

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
    }
    write_state(args.task_id, payload)

    proc = subprocess.Popen(
        [
            sys.executable,
            __file__,
            "_run",
            "--task-id",
            args.task_id,
            "--cmd",
            args.command,
            "--cwd",
            args.cwd,
        ],
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
    write_state(args.task_id, final)
    return run.returncode


def cmd_status(args: argparse.Namespace) -> int:
    payload = read_state(args.task_id)
    if not payload:
        print(json.dumps({"ok": False, "error": "task_not_found", "task_id": args.task_id}, ensure_ascii=False))
        return 1
    print(json.dumps({"ok": True, "task": payload}, ensure_ascii=False))
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
    p_start.add_argument("--cwd", default=str(OPENCLAW_HOME))

    p_run = sp.add_parser("_run")
    p_run.add_argument("--task-id", required=True)
    p_run.add_argument("--cmd", dest="command", required=True)
    p_run.add_argument("--cwd", default=str(OPENCLAW_HOME))

    p_status = sp.add_parser("status")
    p_status.add_argument("--task-id", required=True)

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
