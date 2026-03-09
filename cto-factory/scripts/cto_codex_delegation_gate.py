#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

CODE_SUFFIXES = {".py", ".js", ".ts"}


def parse_args() -> argparse.Namespace:
    default_evidence = Path(__file__).resolve().parent.parent / "tmp" / "codex-last-run.json"
    p = argparse.ArgumentParser(description="Verify that code/config mutations were performed via successful Codex delegation.")
    p.add_argument("--workspace", required=True, help="Workspace to validate (for freshness checks)")
    p.add_argument("--evidence-file", default=str(default_evidence), help="Path to codex_guarded_exec evidence JSON")
    p.add_argument("--max-age-seconds", type=int, default=21600, help="Maximum age for evidence file")
    p.add_argument("--grace-seconds", type=int, default=0, help="Allowed mtime skew between evidence and source files")
    p.add_argument("--require-code-files", action="store_true", help="Fail if no source code files are present")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    ws = Path(args.workspace).resolve()
    evidence_path = Path(args.evidence_file).resolve()
    now = time.time()

    failures: list[str] = []
    warnings: list[str] = []
    evidence_payload: dict = {}

    if not ws.exists():
        failures.append(f"workspace does not exist: {ws}")
    if not evidence_path.is_file():
        failures.append(f"missing codex evidence file: {evidence_path}")
    else:
        try:
            evidence_payload = json.loads(evidence_path.read_text(encoding="utf-8"))
        except Exception as exc:  # noqa: BLE001
            failures.append(f"failed to parse evidence file: {exc}")

    source_files: list[Path] = []
    if ws.exists():
        for p in ws.rglob("*"):
            if p.is_file() and p.suffix.lower() in CODE_SUFFIXES:
                source_files.append(p)

    if args.require_code_files and not source_files:
        failures.append(f"no source files with suffixes {sorted(CODE_SUFFIXES)} found in {ws}")
    if not source_files:
        warnings.append("no source code files found; freshness check skipped")

    if evidence_payload:
        ok = bool(evidence_payload.get("ok"))
        used_attempts = int(evidence_payload.get("used_attempts", 0) or 0)
        attempts = evidence_payload.get("attempts") if isinstance(evidence_payload.get("attempts"), list) else []
        has_codex_exec = False
        for attempt in attempts:
            if not isinstance(attempt, dict):
                continue
            cmd = str(attempt.get("command", ""))
            if "codex exec" in cmd:
                has_codex_exec = True
                break

        if not ok:
            failures.append("codex evidence indicates failed run (ok=false)")
        if used_attempts < 1:
            failures.append("codex evidence has invalid used_attempts (<1)")
        if not has_codex_exec:
            failures.append("codex evidence does not contain a codex exec command")

        age_seconds = max(0, int(now - evidence_path.stat().st_mtime))
        if age_seconds > max(60, int(args.max_age_seconds)):
            failures.append(
                f"codex evidence is stale: age={age_seconds}s > max_age={int(args.max_age_seconds)}s"
            )

        if source_files:
            cutoff = evidence_path.stat().st_mtime + max(0, int(args.grace_seconds))
            newer = [str(p) for p in source_files if p.stat().st_mtime > cutoff]
            if newer:
                failures.append(
                    "source files were modified after latest successful codex evidence (possible direct mutation): "
                    + ", ".join(sorted(newer)[:20])
                )

    result = {
        "ok": len(failures) == 0,
        "workspace": str(ws),
        "evidence_file": str(evidence_path),
        "source_file_count": len(source_files),
        "code_suffixes": sorted(CODE_SUFFIXES),
        "checked": {
            "require_code_files": bool(args.require_code_files),
            "max_age_seconds": int(args.max_age_seconds),
            "grace_seconds": int(args.grace_seconds),
        },
        "failures": failures,
        "warnings": warnings,
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["ok"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
