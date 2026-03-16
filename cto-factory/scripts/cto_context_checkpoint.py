#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
from datetime import datetime, timezone
from pathlib import Path


def _resolve_openclaw_root() -> Path:
    raw = os.getenv("OPENCLAW_ROOT") or "~/.openclaw"
    return Path(raw).expanduser().resolve()


CHECKPOINT_DIR = _resolve_openclaw_root() / "workspace-factory" / ".cto-brain" / "runtime" / "context-checkpoints"


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def cp_path(session_id: str) -> Path:
    safe = "".join(ch if ch.isalnum() or ch in "-_" else "_" for ch in session_id)
    return CHECKPOINT_DIR / f"{safe}.json"


def cmd_save(args: argparse.Namespace) -> int:
    CHECKPOINT_DIR.mkdir(parents=True, exist_ok=True)
    p = cp_path(args.session_id)
    existing = {}
    if p.exists():
        try:
            existing = json.loads(p.read_text(encoding="utf-8"))
        except Exception:
            existing = {}

    payload = {
        "session_id": args.session_id,
        "updated_at": now_iso(),
        "summary": args.summary,
        "hard_constraints": args.hard_constraints,
        "decisions": args.decisions,
        "next_action": args.next_action,
        "blockers": args.blockers,
        "history": existing.get("history", [])[-9:] + [
            {
                "ts": now_iso(),
                "summary": args.summary,
                "next_action": args.next_action,
            }
        ],
    }
    p.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"ok": True, "checkpoint": payload}, ensure_ascii=False))
    return 0


def cmd_get(args: argparse.Namespace) -> int:
    p = cp_path(args.session_id)
    if not p.exists():
        print(json.dumps({"ok": False, "error": "checkpoint_not_found", "session_id": args.session_id}, ensure_ascii=False))
        return 1
    payload = json.loads(p.read_text(encoding="utf-8"))
    print(json.dumps({"ok": True, "checkpoint": payload}, ensure_ascii=False))
    return 0


def cmd_list(_: argparse.Namespace) -> int:
    CHECKPOINT_DIR.mkdir(parents=True, exist_ok=True)
    rows = []
    for p in sorted(CHECKPOINT_DIR.glob("*.json")):
        try:
            payload = json.loads(p.read_text(encoding="utf-8"))
        except Exception:
            continue
        rows.append(
            {
                "session_id": payload.get("session_id"),
                "updated_at": payload.get("updated_at"),
                "next_action": payload.get("next_action"),
                "path": str(p),
            }
        )
    print(json.dumps({"ok": True, "count": len(rows), "items": rows}, ensure_ascii=False))
    return 0


def parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description="CTO context checkpoint helper")
    sp = ap.add_subparsers(dest="cmd", required=True)

    s = sp.add_parser("save")
    s.add_argument("--session-id", required=True)
    s.add_argument("--summary", required=True)
    s.add_argument("--hard-constraints", default="")
    s.add_argument("--decisions", default="")
    s.add_argument("--next-action", default="")
    s.add_argument("--blockers", default="")

    g = sp.add_parser("get")
    g.add_argument("--session-id", required=True)

    sp.add_parser("list")
    return ap


def main() -> int:
    args = parser().parse_args()
    if args.cmd == "save":
        return cmd_save(args)
    if args.cmd == "get":
        return cmd_get(args)
    if args.cmd == "list":
        return cmd_list(args)
    print(json.dumps({"ok": False, "error": "unknown_command"}, ensure_ascii=False))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
