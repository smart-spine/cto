#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def iso_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_env_file(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    if not path.exists():
        return data
    for raw in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = value.strip()
    return data


def normalize_cli(raw: str | None) -> str | None:
    if raw is None:
        return None
    val = str(raw).strip().lower()
    if val in {"codex", "claude"}:
        return val
    return None


def cli_available(name: str) -> bool:
    return shutil.which(name) is not None


def detect_code_agent(openclaw_root: Path) -> tuple[str | None, str, list[str]]:
    candidates: list[str] = []
    env_cli = normalize_cli(os.getenv("OPENCLAW_CODE_AGENT_CLI"))
    if env_cli:
        candidates.append(env_cli)

    env_file = parse_env_file(openclaw_root / ".env")
    file_cli = normalize_cli(env_file.get("OPENCLAW_CODE_AGENT_CLI"))
    if file_cli and file_cli not in candidates:
        candidates.append(file_cli)

    for fallback in ("codex", "claude"):
        if fallback not in candidates:
            candidates.append(fallback)

    for cli in candidates:
        if cli_available(cli):
            source = "runtime_env" if cli == env_cli else ("openclaw_env_file" if cli == file_cli else "binary_scan")
            return cli, source, candidates

    return None, "not_found", candidates


def memory_paths(openclaw_root: Path) -> dict[str, Path]:
    workspace = openclaw_root / "workspace-factory"
    brain = workspace / ".cto-brain"
    runtime = brain / "runtime"
    facts = brain / "facts"
    return {
        "workspace": workspace,
        "brain": brain,
        "runtime": runtime,
        "facts": facts,
        "memory_json": runtime / "code_agent_memory.json",
        "facts_md": facts / "code_agent.md",
        "protocol_file": workspace / "CODE_AGENT_PROTOCOLS.md",
    }


def ack_phrase_for(cli: str) -> str:
    return "codex remembered" if cli == "codex" else "claudecode remembered"


def resolve_openclaw_root(args: argparse.Namespace) -> Path:
    raw = getattr(args, "openclaw_root", None) or os.getenv("OPENCLAW_ROOT") or "~/.openclaw"
    return Path(raw).expanduser().resolve()


def write_memory(openclaw_root: Path, cli: str, detected_from: str, candidates: list[str]) -> dict[str, Any]:
    paths = memory_paths(openclaw_root)
    paths["runtime"].mkdir(parents=True, exist_ok=True)
    paths["facts"].mkdir(parents=True, exist_ok=True)

    protocol_key = f"{cli.upper()}_PROTOCOL"
    payload: dict[str, Any] = {
        "ok": True,
        "updatedAt": iso_now(),
        "openclawRoot": str(openclaw_root),
        "workspaceFactory": str(paths["workspace"]),
        "codeAgent": cli,
        "ackPhrase": ack_phrase_for(cli),
        "detectedFrom": detected_from,
        "candidateOrder": candidates,
        "protocolFile": str(paths["protocol_file"]),
        "protocolKey": protocol_key,
        "memoryFile": str(paths["memory_json"]),
        "factsFile": str(paths["facts_md"]),
    }
    paths["memory_json"].write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    facts_lines = [
        "# Code Agent Memory",
        "",
        f"- updatedAt: {payload['updatedAt']}",
        f"- codeAgent: `{cli}`",
        f"- ackPhrase: `{payload['ackPhrase']}`",
        f"- detectedFrom: `{detected_from}`",
        f"- protocolFile: `{payload['protocolFile']}`",
        f"- protocolKey: `{protocol_key}`",
        "",
        "Use this remembered code agent for all CODE/CONFIG mutation tasks.",
    ]
    paths["facts_md"].write_text("\n".join(facts_lines) + "\n", encoding="utf-8")
    return payload


def read_existing(openclaw_root: Path) -> tuple[dict[str, Any] | None, str | None]:
    path = memory_paths(openclaw_root)["memory_json"]
    if not path.exists():
        return None, "memory_not_found"
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001
        return None, f"memory_parse_error: {exc}"
    if not isinstance(payload, dict):
        return None, "memory_invalid_type"
    return payload, None


def cmd_ensure(args: argparse.Namespace) -> int:
    openclaw_root = resolve_openclaw_root(args)
    cli, detected_from, candidates = detect_code_agent(openclaw_root)
    if not cli:
        print(
            json.dumps(
                {
                    "ok": False,
                    "error": "no_supported_code_agent_found",
                    "supported": ["codex", "claude"],
                    "candidateOrder": candidates,
                    "openclawRoot": str(openclaw_root),
                },
                ensure_ascii=False,
            )
        )
        return 2
    payload = write_memory(openclaw_root, cli, detected_from, candidates)
    print(json.dumps(payload, ensure_ascii=False))
    return 0


def cmd_show(args: argparse.Namespace) -> int:
    openclaw_root = resolve_openclaw_root(args)
    payload, err = read_existing(openclaw_root)
    if payload is None:
        print(json.dumps({"ok": False, "error": err, "openclawRoot": str(openclaw_root)}, ensure_ascii=False))
        return 1
    print(json.dumps(payload, ensure_ascii=False))
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Detect and persist remembered local code agent (codex/claude) for CTO")
    p.add_argument("--openclaw-root", default=None)
    sub = p.add_subparsers(dest="cmd", required=True)
    s1 = sub.add_parser("ensure")
    s1.add_argument("--openclaw-root", default=None)
    s1.set_defaults(func=cmd_ensure)
    s2 = sub.add_parser("show")
    s2.add_argument("--openclaw-root", default=None)
    s2.set_defaults(func=cmd_show)
    return p


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
