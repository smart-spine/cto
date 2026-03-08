#!/usr/bin/env python3
"""Structured JSON diff helper for openclaw.json changes."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, Dict


HIGH_RISK_PREFIXES = (
    "agents.list",
    "bindings",
    "tools.sessions",
    "tools.agentToAgent",
    "channels.telegram",
    "model",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Compare two JSON config files.")
    parser.add_argument("--before", required=True, help="Baseline JSON path")
    parser.add_argument("--after", required=True, help="Current JSON path")
    parser.add_argument(
        "--max-items",
        type=int,
        default=120,
        help="Max paths emitted in each added/removed/changed list",
    )
    return parser.parse_args()


def load_json(path: str) -> Any:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def flatten(obj: Any, prefix: str = "") -> Dict[str, Any]:
    out: Dict[str, Any] = {}
    if isinstance(obj, dict):
        if not obj and prefix:
            out[prefix] = {}
        for key, value in obj.items():
            next_prefix = f"{prefix}.{key}" if prefix else str(key)
            out.update(flatten(value, next_prefix))
        return out
    if isinstance(obj, list):
        if not obj and prefix:
            out[prefix] = []
        for idx, value in enumerate(obj):
            next_prefix = f"{prefix}[{idx}]"
            out.update(flatten(value, next_prefix))
        return out
    out[prefix] = obj
    return out


def truncate(items: list[str], limit: int) -> list[str]:
    if len(items) <= limit:
        return items
    return items[:limit] + [f"... ({len(items) - limit} more)"]


def collect_high_risk(paths: list[str]) -> list[str]:
    selected: list[str] = []
    for path in paths:
        if path.startswith(HIGH_RISK_PREFIXES):
            selected.append(path)
    return selected


def main() -> int:
    args = parse_args()
    before_obj = load_json(args.before)
    after_obj = load_json(args.after)

    before_flat = flatten(before_obj)
    after_flat = flatten(after_obj)

    before_keys = set(before_flat.keys())
    after_keys = set(after_flat.keys())

    added = sorted(after_keys - before_keys)
    removed = sorted(before_keys - after_keys)

    changed = sorted(
        key
        for key in (before_keys & after_keys)
        if before_flat[key] != after_flat[key]
    )

    all_changed = sorted(set(added + removed + changed))
    high_risk = collect_high_risk(all_changed)

    result = {
        "ok": True,
        "before": str(Path(args.before).resolve()),
        "after": str(Path(args.after).resolve()),
        "counts": {
            "added": len(added),
            "removed": len(removed),
            "changed": len(changed),
            "total": len(all_changed),
            "high_risk": len(high_risk),
        },
        "added": truncate(added, args.max_items),
        "removed": truncate(removed, args.max_items),
        "changed": truncate(changed, args.max_items),
        "high_risk_paths": truncate(high_risk, args.max_items),
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
