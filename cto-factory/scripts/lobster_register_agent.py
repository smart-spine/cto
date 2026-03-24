#!/usr/bin/env python3
"""Register an agent in openclaw.json. Used by full-agent-build.lobster."""
import json
import pathlib
import sys


def main():
    if len(sys.argv) < 4:
        print('Usage: lobster_register_agent.py <config_path> <agent_id> <workspace>', file=sys.stderr)
        sys.exit(1)

    config_path = pathlib.Path(sys.argv[1])
    agent_id = sys.argv[2]
    workspace = sys.argv[3]

    d = json.loads(config_path.read_text())
    agents = d.setdefault("agents", {}).setdefault("list", [])

    found = False
    for a in agents:
        if a.get("id") == agent_id:
            a["workspace"] = workspace
            a["agentDir"] = workspace
            found = True
            break

    if not found:
        agents.append({
            "id": agent_id,
            "default": False,
            "name": agent_id.replace("-", " ").title(),
            "workspace": workspace,
            "agentDir": workspace,
            "model": {"primary": "openai-codex/gpt-5.4"},
            "identity": {"name": agent_id.replace("-", " ").title()},
        })

    config_path.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({"ok": True, "registered": agent_id, "found_existing": found}))


if __name__ == "__main__":
    main()
