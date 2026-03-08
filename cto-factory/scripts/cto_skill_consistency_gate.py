#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


FRONTMATTER_RE = re.compile(r"^---\n(.*?)\n---\n", re.DOTALL)
TABLE_ROW_RE = re.compile(r"^\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|(?:\s*([^|]*?)\s*\|)?\s*$")


def nonempty(path: Path) -> bool:
    return path.is_file() and path.stat().st_size > 0


def parse_frontmatter(text: str) -> dict[str, str]:
    match = FRONTMATTER_RE.match(text)
    if not match:
        return {}
    body = match.group(1)
    parsed: dict[str, str] = {}
    for raw_line in body.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or ":" not in line:
            continue
        key, value = line.split(":", 1)
        parsed[key.strip()] = value.strip().strip('"').strip("'")
    return parsed


def normalize_cell(value: str) -> str:
    return re.sub(r"`", "", value).strip().lower()


def parse_routing_rows(index_text: str) -> list[tuple[str, str]]:
    rows: list[tuple[str, str]] = []
    for raw_line in index_text.splitlines():
        line = raw_line.strip()
        if not line.startswith("|"):
            continue
        row_match = TABLE_ROW_RE.match(line)
        if not row_match:
            continue
        col_a = normalize_cell(row_match.group(1))
        col_b = normalize_cell(row_match.group(2))
        if not col_a or not col_b:
            continue
        if col_a in {"intent", "---"}:
            continue
        if set(col_a) <= {"-"}:
            continue
        rows.append((col_a, col_b))
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate generated agent skill package consistency.")
    parser.add_argument("--workspace", required=True, help="Path to workspace-<agent_id>")
    args = parser.parse_args()

    workspace = Path(args.workspace).resolve()
    skills_dir = workspace / "skills"
    index_file = skills_dir / "SKILL_INDEX.md"

    failures: list[str] = []
    warnings: list[str] = []
    discovered_skill_dirs: list[str] = []
    discovered_skill_names: list[str] = []

    if not workspace.exists():
        failures.append(f"workspace does not exist: {workspace}")
    if not skills_dir.exists():
        failures.append(f"skills directory does not exist: {skills_dir}")
    if not nonempty(index_file):
        failures.append(f"missing or empty skill index: {index_file}")

    skill_md_files: list[Path] = []
    if skills_dir.exists():
        skill_md_files = sorted(
            p for p in skills_dir.glob("*/SKILL.md") if p.is_file()
        )
    if not skill_md_files:
        failures.append(f"no skill files found under: {skills_dir} (expected skills/<skill-name>/SKILL.md)")

    name_to_dirs: dict[str, set[str]] = {}
    for skill_file in skill_md_files:
        skill_dir_name = skill_file.parent.name
        discovered_skill_dirs.append(skill_dir_name)
        text = skill_file.read_text(encoding="utf-8")
        frontmatter = parse_frontmatter(text)
        skill_name = frontmatter.get("name", "").strip()
        skill_desc = frontmatter.get("description", "").strip()
        if not skill_name:
            failures.append(f"missing frontmatter 'name' in {skill_file}")
        if not skill_desc:
            failures.append(f"missing frontmatter 'description' in {skill_file}")
        if skill_name:
            discovered_skill_names.append(skill_name)
            name_to_dirs.setdefault(skill_name, set()).add(skill_dir_name)

    for skill_name, dirs in name_to_dirs.items():
        if len(dirs) > 1:
            failures.append(
                f"duplicate skill frontmatter name '{skill_name}' across directories: {sorted(dirs)}"
            )

    routing_rows: list[tuple[str, str]] = []
    if nonempty(index_file):
        index_text = index_file.read_text(encoding="utf-8")
        routing_rows = parse_routing_rows(index_text)
        if not routing_rows:
            failures.append(
                "no routing matrix rows found in SKILL_INDEX.md (expected markdown table with intent and primary skill)"
            )
        else:
            intent_to_primary: dict[str, set[str]] = {}
            for intent, primary in routing_rows:
                intent_to_primary.setdefault(intent, set()).add(primary)
                if primary and primary not in {x.lower() for x in discovered_skill_dirs}:
                    warnings.append(
                        f"routing primary skill '{primary}' is not a local skill directory name"
                    )
            for intent, primary_set in intent_to_primary.items():
                if len(primary_set) > 1:
                    failures.append(
                        f"contradictory routing for intent '{intent}': multiple primary skills {sorted(primary_set)}"
                    )

        for dir_name in discovered_skill_dirs:
            if re.search(rf"\b{re.escape(dir_name)}\b", index_text, flags=re.IGNORECASE) is None:
                warnings.append(
                    f"skill directory '{dir_name}' is not explicitly referenced in SKILL_INDEX.md"
                )

    result = {
        "ok": len(failures) == 0,
        "workspace": str(workspace),
        "checked": {
            "skills_dir": str(skills_dir),
            "skill_index": str(index_file),
            "skill_files_count": len(skill_md_files),
            "routing_rows_count": len(routing_rows),
        },
        "skills": {
            "directories": sorted(discovered_skill_dirs),
            "frontmatter_names": sorted(discovered_skill_names),
        },
        "failures": failures,
        "warnings": warnings,
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["ok"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
