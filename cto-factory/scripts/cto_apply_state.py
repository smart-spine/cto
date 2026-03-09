#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path


DEFAULT_STATE_PATH = Path("/Users/uladzislaupraskou/.openclaw/workspace-factory/.cto-brain/runtime/pending-apply.json")


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def iso(dt: datetime) -> str:
    return dt.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_iso(raw: str) -> datetime | None:
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def load_state(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        obj = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}
    return obj if isinstance(obj, dict) else {}


def save_state(path: Path, state: dict) -> None:
    ensure_parent(path)
    path.write_text(json.dumps(state, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")


def clear_state(path: Path) -> None:
    if path.exists():
        path.unlink()


def normalize_message(raw: str) -> str:
    low = raw.strip().lower()
    low = low.replace("ready_for_apply", " ")
    low = re.sub(r"[^a-z0-9]+", " ", low)
    return re.sub(r"\s+", " ", low).strip()


def resolve_option(message: str) -> str | None:
    norm = normalize_message(message)
    if not norm:
        return None
    if re.fullmatch(r"a", norm) or re.search(r"\boption a\b", norm):
        return "A"
    if re.fullmatch(r"b", norm) or re.search(r"\boption b\b", norm):
        return "B"
    if re.fullmatch(r"c", norm) or re.search(r"\boption c\b", norm):
        return "C"
    return None


def cmd_set(args: argparse.Namespace) -> int:
    created = now_utc()
    expires = created + timedelta(minutes=args.ttl_minutes)
    state = {
        "request_id": args.request_id,
        "created_at": iso(created),
        "expires_at": iso(expires),
        "summary": args.summary,
        "options": {
            "A": args.option_a,
            "B": args.option_b,
            "C": args.option_c,
        },
    }
    save_state(args.state_path, state)
    print(json.dumps({"ok": True, "state_path": str(args.state_path), "state": state}, ensure_ascii=True))
    return 0


def cmd_get(args: argparse.Namespace) -> int:
    state = load_state(args.state_path)
    print(json.dumps({"ok": bool(state), "state_path": str(args.state_path), "state": state}, ensure_ascii=True))
    return 0


def cmd_clear(args: argparse.Namespace) -> int:
    clear_state(args.state_path)
    print(json.dumps({"ok": True, "state_path": str(args.state_path), "cleared": True}, ensure_ascii=True))
    return 0


def cmd_resolve(args: argparse.Namespace) -> int:
    state = load_state(args.state_path)
    if not state:
        print(json.dumps({"ok": False, "reason": "no_pending_state", "match": None}, ensure_ascii=True))
        return 0

    expires_at = parse_iso(str(state.get("expires_at", "")))
    if expires_at is None or now_utc() > expires_at:
        print(json.dumps({"ok": False, "reason": "expired", "match": None}, ensure_ascii=True))
        return 0

    match = resolve_option(args.message)
    action = None
    if match:
        options = state.get("options", {})
        if isinstance(options, dict):
            raw = options.get(match)
            action = str(raw) if raw is not None else None

    print(
        json.dumps(
            {
                "ok": bool(match and action),
                "request_id": state.get("request_id"),
                "match": match,
                "action": action,
                "summary": state.get("summary"),
            },
            ensure_ascii=True,
        )
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Persist and resolve CTO apply approval state.")
    parser.add_argument("--state-path", type=Path, default=DEFAULT_STATE_PATH)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_set = sub.add_parser("set")
    p_set.add_argument("--request-id", required=True)
    p_set.add_argument("--summary", required=True)
    p_set.add_argument("--option-a", required=True)
    p_set.add_argument("--option-b", default="")
    p_set.add_argument("--option-c", default="")
    p_set.add_argument("--ttl-minutes", type=int, default=180)
    p_set.set_defaults(func=cmd_set)

    p_get = sub.add_parser("get")
    p_get.set_defaults(func=cmd_get)

    p_clear = sub.add_parser("clear")
    p_clear.set_defaults(func=cmd_clear)

    p_resolve = sub.add_parser("resolve")
    p_resolve.add_argument("--message", required=True)
    p_resolve.set_defaults(func=cmd_resolve)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
