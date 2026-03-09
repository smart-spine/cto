#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


PLAN_BEGIN = "CODEX_PLAN_JSON_BEGIN"
PLAN_END = "CODEX_PLAN_JSON_END"
REPORT_BEGIN = "CODEX_EXEC_REPORT_JSON_BEGIN"
REPORT_END = "CODEX_EXEC_REPORT_JSON_END"


def load_requirements(path: Path) -> list[dict[str, str]]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001
        raise ValueError(f"requirements file parse failed: {exc}") from exc

    items: list[Any]
    if isinstance(payload, dict) and isinstance(payload.get("requirements"), list):
        items = payload["requirements"]
    elif isinstance(payload, list):
        items = payload
    else:
        raise ValueError("requirements file must be a JSON list or object with 'requirements' list")

    out: list[dict[str, str]] = []
    for idx, item in enumerate(items, start=1):
        if isinstance(item, dict):
            rid = str(item.get("id", f"R{idx}")).strip() or f"R{idx}"
            text = str(item.get("text", item.get("requirement", ""))).strip()
        else:
            rid = f"R{idx}"
            text = str(item).strip()
        out.append({"id": rid, "text": text})
    if not out:
        raise ValueError("requirements list is empty")
    return out


def extract_json_block(text: str, begin: str, end: str) -> tuple[dict[str, Any] | None, str | None]:
    b = text.find(begin)
    e = text.find(end)
    if b == -1 or e == -1 or e <= b:
        return None, f"missing marker block {begin} ... {end}"
    raw = text[b + len(begin):e].strip()
    if raw.startswith("```"):
        parts = raw.split("\n", 1)
        raw = parts[1] if len(parts) > 1 else ""
        if raw.endswith("```"):
            raw = raw[:-3].strip()
    try:
        data = json.loads(raw)
    except Exception as exc:  # noqa: BLE001
        return None, f"json parse error in block {begin}/{end}: {exc}"
    if not isinstance(data, dict):
        return None, "json block must be an object"
    return data, None


def normalize_text(value: str) -> str:
    return " ".join(str(value).strip().lower().split())


def resolve_requirement_id(item: Any, req_by_text: dict[str, str]) -> str | None:
    if not isinstance(item, dict):
        return None
    rid = item.get("id") or item.get("requirement_id")
    if rid:
        return str(rid).strip()
    text = item.get("text") or item.get("requirement")
    if text:
        return req_by_text.get(normalize_text(str(text)))
    return None


def validate_plan(data: dict[str, Any], requirements: list[dict[str, str]]) -> dict[str, Any]:
    errors: list[str] = []
    warnings: list[str] = []

    plan_rows = data.get("requirements")
    if not isinstance(plan_rows, list):
        errors.append("plan json missing list field: requirements")
        plan_rows = []

    req_by_text = {normalize_text(item["text"]): item["id"] for item in requirements if item.get("text")}
    covered: set[str] = set()
    bad_status: list[str] = []
    for row in plan_rows:
        rid = resolve_requirement_id(row, req_by_text)
        if not rid:
            continue
        covered.add(rid)
        status = str((row or {}).get("status", "")).strip().lower() if isinstance(row, dict) else ""
        if status and status not in {"planned", "covered", "queued"}:
            bad_status.append(f"{rid}:{status}")

    missing = [item["id"] for item in requirements if item["id"] not in covered]
    if missing:
        errors.append(f"missing requirements in PLAN: {', '.join(missing)}")

    if bad_status:
        warnings.append("unexpected PLAN status values: " + ", ".join(bad_status))

    for key in ("files_to_create", "files_to_modify", "test_plan"):
        if key not in data:
            warnings.append(f"plan json missing recommended field: {key}")

    return {
        "ok": len(errors) == 0,
        "mode": "plan",
        "missing_requirements": missing,
        "errors": errors,
        "warnings": warnings,
        "covered_requirements": sorted(covered),
    }


def validate_report(data: dict[str, Any], requirements: list[dict[str, str]]) -> dict[str, Any]:
    errors: list[str] = []
    warnings: list[str] = []

    report_rows = data.get("implemented_requirements")
    if not isinstance(report_rows, list):
        errors.append("report json missing list field: implemented_requirements")
        report_rows = []

    req_by_text = {normalize_text(item["text"]): item["id"] for item in requirements if item.get("text")}
    covered_done: set[str] = set()
    not_done: list[str] = []

    for row in report_rows:
        rid = resolve_requirement_id(row, req_by_text)
        if not rid:
            continue
        status = str((row or {}).get("status", "")).strip().lower() if isinstance(row, dict) else ""
        if status in {"done", "implemented", "pass", "passed", "complete", "completed"}:
            covered_done.add(rid)
        else:
            not_done.append(f"{rid}:{status or 'missing_status'}")

    missing = [item["id"] for item in requirements if item["id"] not in covered_done]
    if missing:
        errors.append(f"missing/unfinished requirements in EXEC report: {', '.join(missing)}")
    if not_done:
        warnings.append("requirements with non-done status: " + ", ".join(not_done))

    tests = data.get("tests_executed")
    if not isinstance(tests, list) or not tests:
        errors.append("report json must include non-empty tests_executed list")
        tests = []

    failing_tests: list[str] = []
    for idx, test in enumerate(tests, start=1):
        if not isinstance(test, dict):
            failing_tests.append(f"row{idx}:invalid")
            continue
        cmd = str(test.get("command", "")).strip()
        exit_code = test.get("exit_code")
        if not cmd:
            failing_tests.append(f"row{idx}:missing_command")
            continue
        if exit_code is None:
            failing_tests.append(f"row{idx}:missing_exit_code")
            continue
        try:
            code = int(exit_code)
        except (TypeError, ValueError):
            failing_tests.append(f"row{idx}:non_numeric_exit_code")
            continue
        if code != 0:
            failing_tests.append(f"row{idx}:exit_code={code}")

    if failing_tests:
        errors.append("tests_executed contains failures: " + ", ".join(failing_tests))

    open_items = data.get("open_items")
    if isinstance(open_items, list) and open_items:
        errors.append("open_items is non-empty")

    return {
        "ok": len(errors) == 0,
        "mode": "report",
        "missing_requirements": missing,
        "errors": errors,
        "warnings": warnings,
        "covered_requirements": sorted(covered_done),
    }


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Validate Codex plan/report output against intake requirements")
    p.add_argument("--mode", choices=["plan", "report"], required=True)
    p.add_argument("--requirements-file", required=True)
    p.add_argument("--codex-output-file", required=True)
    return p.parse_args()


def main() -> int:
    args = parse_args()
    req_path = Path(args.requirements_file).resolve()
    out_path = Path(args.codex_output_file).resolve()

    result: dict[str, Any] = {
        "ok": False,
        "mode": args.mode,
        "requirements_file": str(req_path),
        "codex_output_file": str(out_path),
        "errors": [],
        "warnings": [],
    }

    try:
        requirements = load_requirements(req_path)
    except Exception as exc:  # noqa: BLE001
        result["errors"].append(str(exc))
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 2

    text = out_path.read_text(encoding="utf-8", errors="replace") if out_path.exists() else ""
    if not text.strip():
        result["errors"].append("codex output file is empty or missing")
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 2

    if args.mode == "plan":
        data, err = extract_json_block(text, PLAN_BEGIN, PLAN_END)
        if err:
            result["errors"].append(err)
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return 2
        validated = validate_plan(data or {}, requirements)
    else:
        data, err = extract_json_block(text, REPORT_BEGIN, REPORT_END)
        if err:
            result["errors"].append(err)
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return 2
        validated = validate_report(data or {}, requirements)

    result.update(validated)
    result["required_ids"] = [item["id"] for item in requirements]
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result.get("ok") else 2


if __name__ == "__main__":
    raise SystemExit(main())
