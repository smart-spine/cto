#!/usr/bin/env python3
"""Compare baseline/candidate CTO run outputs and emit a compact QA delta report."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


def extract_text(path: Path) -> str:
    obj = json.loads(path.read_text(encoding="utf-8"))
    parts = []
    for payload in obj.get("payloads", []):
        text = payload.get("text")
        if text:
            parts.append(text)
    return "\n\n".join(parts)


def cyrillic_ratio(text: str) -> float:
    if not text:
        return 0.0
    cyr = len(re.findall(r"[А-Яа-яЁё]", text))
    return cyr / max(len(text), 1)


def score_text(text: str) -> dict:
    score = 0
    checks = {}

    checks["has_intake_options"] = bool(re.search(r"\b1\)|\*\*1\)", text))
    checks["has_ready_for_apply"] = "READY_FOR_APPLY" in text
    checks["has_codex_evidence"] = "codex exec" in text.lower() or "sessions_spawn" in text.lower()
    checks["has_test_evidence"] = "node --test" in text.lower() or "tests" in text.lower()
    checks["has_config_validate"] = "config validate" in text.lower()
    checks["has_apply_options"] = bool(re.search(r"\bA\b.*\bB\b.*\bC\b", text, flags=re.S))
    checks["english_like"] = cyrillic_ratio(text) < 0.02

    for key, val in checks.items():
        if val:
            score += 1

    return {"score": score, "checks": checks, "cyrillic_ratio": round(cyrillic_ratio(text), 4)}


def count_workspace(path: Path) -> dict:
    if not path.exists():
        return {"exists": False, "files": 0, "tests": 0, "tools": 0, "config": 0}
    files = [p for p in path.rglob("*") if p.is_file()]
    return {
        "exists": True,
        "files": len(files),
        "tests": len([p for p in files if ".test." in p.name or "/tests/" in str(p)]),
        "tools": len([p for p in files if "/tools/" in str(p)]),
        "config": len([p for p in files if "/config/" in str(p)]),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline-response", required=True)
    ap.add_argument("--candidate-response", required=True)
    ap.add_argument("--old-workspace")
    ap.add_argument("--new-workspace")
    args = ap.parse_args()

    baseline_text = extract_text(Path(args.baseline_response))
    candidate_text = extract_text(Path(args.candidate_response))

    b = score_text(baseline_text)
    c = score_text(candidate_text)

    report = {
        "baseline": b,
        "candidate": c,
        "dialog_delta": c["score"] - b["score"],
        "classification": "IMPROVED" if c["score"] > b["score"] else ("NO_CHANGE" if c["score"] == b["score"] else "REGRESSION"),
    }

    if args.old_workspace:
        report["old_workspace"] = count_workspace(Path(args.old_workspace))
    if args.new_workspace:
        report["new_workspace"] = count_workspace(Path(args.new_workspace))

    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
