#!/usr/bin/env python3
"""
cto_dispatch_agent.py — dispatch openclaw sub-agent via async supervisor.

Usage:
    python3 cto_dispatch_agent.py --agent <id> --message <text>
                                  [--session-id <sid>]
                                  [--heartbeat-seconds <n>]

Wraps `openclaw agent --message` in cto_async_task.py so CTO receives
heartbeat callbacks instead of blocking silently for minutes.
Returns JSON with task_id immediately; completion fires an async callback
back to the CTO session.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

OPENCLAW_ROOT = Path(os.getenv("OPENCLAW_ROOT", str(Path.home() / ".openclaw"))).expanduser().resolve()
SCRIPT_DIR = Path(__file__).parent
ASYNC_TASK_PY = SCRIPT_DIR / "cto_async_task.py"


def main() -> int:
    ap = argparse.ArgumentParser(description="Dispatch sub-agent call via async supervisor")
    ap.add_argument("--agent", required=True, help="Target agent id")
    ap.add_argument("--message", required=True, help="Message to send to the agent")
    ap.add_argument("--session-id", default="", help="CTO callback session id")
    ap.add_argument("--heartbeat-seconds", type=int, default=60,
                    help="Heartbeat interval in seconds (default: 60)")
    args = ap.parse_args()

    session_id = (
        args.session_id.strip()
        or os.getenv("CTO_SESSION_ID", "").strip()
        or os.getenv("OPENCLAW_SESSION_ID", "").strip()
    )

    task_id = f"dispatch-{args.agent}-{int(time.time())}"

    # Write message to a temp file to avoid all shell quoting issues.
    msg_fd, msg_file = tempfile.mkstemp(prefix="cto-msg-", suffix=".txt")
    try:
        with os.fdopen(msg_fd, "w", encoding="utf-8") as f:
            f.write(args.message)
    except Exception:
        os.close(msg_fd)
        raise

    # Write a disposable wrapper script that reads message from file.
    script_fd, script_file = tempfile.mkstemp(prefix="cto-dispatch-", suffix=".sh")
    try:
        with os.fdopen(script_fd, "w", encoding="utf-8") as f:
            f.write("#!/usr/bin/env bash\n")
            f.write(f"openclaw agent --agent {json.dumps(args.agent)} "
                    f'--message "$(cat {json.dumps(msg_file)})" --json\n')
            f.write(f"rm -f {json.dumps(msg_file)}\n")
            f.write(f"rm -f {json.dumps(script_file)}\n")
    except Exception:
        os.close(script_fd)
        raise

    os.chmod(script_file, 0o755)

    cmd = f"bash {script_file}"

    progress_template = (
        f"ASYNC_TASK_HEARTBEAT task_id={{task_id}} status={{status}} "
        f"elapsed={{elapsed_seconds}}s heartbeat={{heartbeat_index}}. "
        f"Sub-agent [{args.agent}] still running. Log: {{log_file}}. "
        f"Send brief progress note to user."
    )

    async_cmd = [
        sys.executable, str(ASYNC_TASK_PY), "start",
        "--task-id", task_id,
        "--cmd", cmd,
        "--cwd", str(OPENCLAW_ROOT),
        "--heartbeat-seconds", str(max(30, args.heartbeat_seconds)),
        "--callback-timeout", "120",
        "--callback-progress-message", progress_template,
    ]
    if session_id:
        async_cmd += [
            "--callback-agent-id", "cto-factory",
            "--callback-session-id", session_id,
        ]

    result = subprocess.run(async_cmd, text=True, capture_output=True)

    if result.stdout:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, file=sys.stderr, end="")

    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
