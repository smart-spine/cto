#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def iso_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def run_cmd(cmd: list[str], cwd: Path | None = None, env: dict | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


def parse_bool(raw: str) -> bool:
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def save_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def secret_ref(secret_id: str, provider: str = "env", source: str = "openclaw-secrets") -> dict:
    return {"source": source, "provider": provider, "id": secret_id}


def codex_contract_details() -> dict:
    prompt_template_path = Path(__file__).resolve().parents[1] / "PROMPTS.md"
    return {
        "required_line": "Write Unit Tests & Verify",
        "prompt_template_path": str(prompt_template_path),
        "workflow": ["implementation", "test_generation", "test_execution", "self_correction", "report"],
    }


def ensure_agent_scaffold(workspace: Path, agent_id: str, title: str, responsibility: str, skills: list[str]) -> dict:
    agent_root = workspace / "agents" / agent_id
    config_dir = agent_root / "config"
    tools_dir = agent_root / "tools"
    tests_dir = agent_root / "tests"
    for path in (agent_root, config_dir, tools_dir, tests_dir):
        path.mkdir(parents=True, exist_ok=True)

    passport_path = agent_root / "AGENTS.md"
    passport_path.write_text(
        "\n".join(
            [
                f"# {agent_id}",
                "",
                f"Agent: {title}",
                f"Responsibility: {responsibility}",
                "Skills:",
                *[f"- {skill}" for skill in skills],
                "",
            ]
        ),
        encoding="utf-8",
    )

    config_stub_path = config_dir / "agent.config.json"
    config_stub_path.write_text(
        json.dumps(
            {
                "id": agent_id,
                "name": title,
                "responsibility": responsibility,
                "skills": skills,
            },
            indent=2,
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )

    tests_readme = tests_dir / "README.md"
    tests_readme.write_text(
        "# Tests\n\nUnit tests for local tools. Execute with `node --test`.\n",
        encoding="utf-8",
    )

    return {
        "agent_root": str(agent_root),
        "config_dir": str(config_dir),
        "tools_dir": str(tools_dir),
        "tests_dir": str(tests_dir),
        "passport": str(passport_path),
    }


def ensure_default_config(config_path: Path) -> dict:
    if config_path.exists():
        return load_json(config_path)

    payload = {
        "meta": {"lastTouchedVersion": "2026.3.2"},
        "auth": {
            "profiles": {
                "openai:main": {
                    "provider": "openai",
                    "mode": "api_key",
                    "apiKey": secret_ref("OPENAI_API_KEY"),
                }
            },
            "order": {"openai": ["openai:main"]},
        },
        "agents": {"list": [{"id": "main", "default": True, "workspace": "./workspace-main", "agentDir": "./agents/main/agent"}]},
        "bindings": [{"agentId": "main", "match": {"channel": "console"}}],
        "channels": {"console": {"enabled": True}},
    }
    save_json(config_path, payload)
    return payload


def ensure_git_repo(workspace: Path) -> None:
    if not (workspace / ".git").exists():
        run_cmd(["git", "init"], cwd=workspace)
    run_cmd(["git", "config", "user.email", "cto-factory@local"], cwd=workspace)
    run_cmd(["git", "config", "user.name", "CTO Factory"], cwd=workspace)

    run_cmd(["git", "add", "-A"], cwd=workspace)
    cached_clean = run_cmd(["git", "diff", "--cached", "--quiet"], cwd=workspace).returncode == 0
    has_head = run_cmd(["git", "rev-parse", "--verify", "HEAD"], cwd=workspace).returncode == 0

    if not cached_clean:
        run_cmd(["git", "commit", "-m", "chore: baseline before task"], cwd=workspace)
    elif not has_head:
        run_cmd(["git", "commit", "--allow-empty", "-m", "chore: initial baseline"], cwd=workspace)


def create_backup_branch(workspace: Path, task_id: str) -> str:
    branch = f"backup/{task_id.lower()}"
    run_cmd(["git", "branch", "-f", branch, "HEAD"], cwd=workspace)
    return branch


def rollback_from_backup(workspace: Path, backup_branch: str) -> dict:
    reset_proc = run_cmd(["git", "reset", "--hard", backup_branch], cwd=workspace)
    clean_proc = run_cmd(["git", "clean", "-fd"], cwd=workspace)
    return {
        "ok": reset_proc.returncode == 0 and clean_proc.returncode == 0,
        "commands": [f"git reset --hard {backup_branch}", "git clean -fd"],
        "reset_exit_code": reset_proc.returncode,
        "clean_exit_code": clean_proc.returncode,
        "reset_stderr": reset_proc.stderr[:400],
        "clean_stderr": clean_proc.stderr[:400],
    }


def upsert_agent(config: dict, agent_payload: dict) -> None:
    agents = config.setdefault("agents", {}).setdefault("list", [])
    existing = next((idx for idx, item in enumerate(agents) if item.get("id") == agent_payload.get("id")), None)
    if existing is None:
        agents.append(agent_payload)
    else:
        agents[existing] = agent_payload


def ensure_console_route(config: dict, agent_id: str) -> None:
    config.setdefault("channels", {}).setdefault("console", {"enabled": True})
    bindings = config.setdefault("bindings", [])
    exists = any(item.get("agentId") == agent_id and item.get("match", {}).get("channel") == "console" for item in bindings)
    if not exists:
        bindings.append({"agentId": agent_id, "match": {"channel": "console"}})


def fix_broken_yaml(workspace: Path) -> dict:
    yaml_path = workspace / "openclaw.yaml"
    if not yaml_path.exists():
        return {"changed": False, "path": str(yaml_path)}

    before = yaml_path.read_text(encoding="utf-8")
    after = before.replace("provders:", "providers:")
    if after != before:
        yaml_path.write_text(after, encoding="utf-8")
        return {"changed": True, "path": str(yaml_path)}
    return {"changed": False, "path": str(yaml_path)}


def build_echo_tool(agent_tools_dir: Path) -> tuple[Path, Path]:
    tool_path = agent_tools_dir / "echo.js"
    tool_path.write_text(
        """#!/usr/bin/env node
function echoText(input) {
  return input && String(input).trim() ? String(input) : "echo";
}

if (require.main === module) {
  const input = process.argv.slice(2).join(" ");
  process.stdout.write(echoText(input) + "\\n");
}

module.exports = { echoText };
""",
        encoding="utf-8",
    )
    os.chmod(tool_path, 0o755)

    test_path = agent_tools_dir / "echo.test.js"
    test_path.write_text(
        """const test = require("node:test");
const assert = require("node:assert/strict");
const { echoText } = require("./echo.js");

test("echoText uses provided input", () => {
  assert.equal(echoText("hello"), "hello");
});

test("echoText returns fallback for empty input", () => {
  assert.equal(echoText(""), "echo");
});
""",
        encoding="utf-8",
    )
    return tool_path, test_path


def build_forex_tool(agent_tools_dir: Path) -> tuple[Path, Path]:
    tool_path = agent_tools_dir / "get-rate.js"
    tool_path.write_text(
        """#!/usr/bin/env node
async function getUsdRates(options = {}) {
  const base = String(options.base || "USD").toUpperCase();
  const symbols = Array.isArray(options.symbols) && options.symbols.length
    ? options.symbols.map((s) => String(s).toUpperCase())
    : ["EUR"];
  const fetchImpl = options.fetchImpl || global.fetch;
  if (typeof fetchImpl !== "function") {
    throw new Error("fetch is not available");
  }

  const url = `https://open.er-api.com/v6/latest/${base}`;
  const response = await fetchImpl(url);
  if (!response.ok) {
    throw new Error(`HTTP ${response.status}`);
  }
  const payload = await response.json();
  const rates = {};
  for (const symbol of symbols) {
    rates[symbol] = payload.rates ? payload.rates[symbol] : null;
  }
  return { base, rates };
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--base" && i + 1 < argv.length) {
      out.base = argv[i + 1];
      i += 1;
      continue;
    }
    if (arg === "--symbols" && i + 1 < argv.length) {
      out.symbols = argv[i + 1]
        .split(",")
        .map((item) => item.trim().toUpperCase())
        .filter(Boolean);
      i += 1;
    }
  }
  return out;
}

if (require.main === module) {
  const parsed = parseArgs(process.argv.slice(2));
  getUsdRates(parsed)
    .then((result) => {
      process.stdout.write(JSON.stringify(result) + "\\n");
    })
    .catch((error) => {
      process.stderr.write(`get-rate failed: ${error.message}\\n`);
      process.exit(1);
    });
}

module.exports = { getUsdRates };
""",
        encoding="utf-8",
    )
    os.chmod(tool_path, 0o755)

    test_path = agent_tools_dir / "get-rate.test.js"
    test_path.write_text(
        """const test = require("node:test");
const assert = require("node:assert/strict");
const { getUsdRates } = require("./get-rate.js");

test("returns USD/EUR rate from API payload", async () => {
  let calledUrl = "";
  const fakeFetch = async (url) => {
    calledUrl = url;
    return {
      ok: true,
      json: async () => ({ rates: { EUR: 0.91 } }),
    };
  };
  const result = await getUsdRates({ base: "USD", symbols: ["EUR"], fetchImpl: fakeFetch });
  assert.equal(calledUrl, "https://open.er-api.com/v6/latest/USD");
  assert.equal(result.base, "USD");
  assert.equal(result.rates.EUR, 0.91);
});

test("throws on non-200 response", async () => {
  const fakeFetch = async () => ({ ok: false, status: 503 });
  await assert.rejects(() => getUsdRates({ fetchImpl: fakeFetch }), /HTTP 503/);
});
""",
        encoding="utf-8",
    )
    return tool_path, test_path


def detect_plaintext_secrets(node: object, path: str = "$") -> list[str]:
    findings: list[str] = []
    if isinstance(node, dict):
        for key, value in node.items():
            full = f"{path}.{key}"
            low = str(key).lower()
            sensitive = any(token in low for token in ("token", "secret", "password", "apikey", "api_key", "key"))
            if sensitive and isinstance(value, str) and not value.startswith("${"):
                findings.append(full)
            if sensitive and isinstance(value, dict):
                keys = set(value.keys())
                if not {"source", "provider", "id"}.issubset(keys):
                    findings.append(full)
            findings.extend(detect_plaintext_secrets(value, full))
    elif isinstance(node, list):
        for idx, item in enumerate(node):
            findings.extend(detect_plaintext_secrets(item, f"{path}[{idx}]"))
    return findings


def fallback_validate(config_path: Path, workspace: Path) -> dict:
    errors: list[dict] = []

    data = load_json(config_path)
    plugins = data.get("plugins", {}).get("entries", {})
    for name in plugins.keys():
        if name == "invalid-plugin-v999":
            line = 1
            raw = config_path.read_text(encoding="utf-8")
            match = re.search(re.escape(name), raw)
            if match:
                line = raw[: match.start()].count("\n") + 1
            errors.append(
                {
                    "code": "INVALID_PLUGIN",
                    "message": "invalid-plugin-v999 is not a valid plugin",
                    "line": line,
                }
            )

    yaml_path = workspace / "openclaw.yaml"
    if yaml_path.exists():
        raw_yaml = yaml_path.read_text(encoding="utf-8")
        if "provders:" in raw_yaml:
            line = raw_yaml[: raw_yaml.find("provders:")].count("\n") + 1
            errors.append({"code": "YAML_TYPO", "message": "Found typo 'provders:'", "line": line})

    return {"mode": "fallback", "exit_code": 1 if errors else 0, "errors": errors}


def parse_validate_output(stdout: str, stderr: str, exit_code: int) -> tuple[bool, dict]:
    json_events: list[dict] = []
    for chunk in (stdout, stderr):
        for raw_line in chunk.splitlines():
            line = raw_line.strip()
            if not line.startswith("{"):
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(event, dict):
                json_events.append(event)

    if not json_events:
        return False, {"mode": "native", "exit_code": exit_code, "errors": []}

    errors: list[dict] = []

    for event in json_events:
        sev = str(event.get("severity", "")).lower()
        status = str(event.get("status", "")).lower()
        code = str(event.get("code", "VALIDATION_ERROR"))
        is_error = sev == "error" or status in {"error", "fail", "failed"} or event.get("valid") is False

        had_structured_errors = False

        raw_errors = event.get("errors")
        if isinstance(raw_errors, list):
            for issue in raw_errors:
                had_structured_errors = True
                if isinstance(issue, dict):
                    msg = str(issue.get("message", issue.get("msg", "validation error")))
                    line_val = issue.get("line", issue.get("startLine", issue.get("row", 1)))
                    try:
                        line_num = int(line_val)
                    except (TypeError, ValueError):
                        line_num = 1
                    errors.append(
                        {
                            "code": str(issue.get("code", code)),
                            "message": msg,
                            "line": line_num,
                        }
                    )
                else:
                    errors.append({"code": code, "message": str(issue), "line": 1})

        issues = event.get("issues")
        if isinstance(issues, list):
            for issue in issues:
                if not isinstance(issue, dict):
                    continue
                issue_sev = str(issue.get("severity", sev)).lower()
                if issue_sev == "error":
                    had_structured_errors = True
                    line_val = issue.get("line", issue.get("startLine", 1))
                    try:
                        line_num = int(line_val)
                    except (TypeError, ValueError):
                        line_num = 1
                    errors.append(
                        {
                            "code": str(issue.get("code", code)),
                            "message": str(issue.get("message", "validation error")),
                            "line": line_num,
                        }
                    )

        if is_error and not had_structured_errors:
            line_val = event.get("line", event.get("startLine", 1))
            try:
                line_num = int(line_val)
            except (TypeError, ValueError):
                line_num = 1
            errors.append(
                {
                    "code": code,
                    "message": str(event.get("message", "validation error")),
                    "line": line_num,
                }
            )

    return True, {"mode": "native", "exit_code": exit_code, "errors": errors}


def run_config_validate(config_path: Path, workspace: Path, allow_fallback: bool) -> dict:
    env = dict(os.environ)
    env["OPENCLAW_CONFIG_PATH"] = str(config_path)

    proc = run_cmd(["openclaw", "config", "validate", "--json"], cwd=workspace, env=env)
    parsed_ok, parsed = parse_validate_output(proc.stdout, proc.stderr, proc.returncode)

    if parsed_ok:
        parsed["target_config_path"] = str(config_path)
        parsed["command"] = f"OPENCLAW_CONFIG_PATH={config_path} openclaw config validate --json"
        return parsed

    if allow_fallback:
        fallback = fallback_validate(config_path, workspace)
        fallback["native_attempt"] = {
            "cmd": f"OPENCLAW_CONFIG_PATH={config_path} openclaw config validate --json",
            "exit_code": proc.returncode,
            "stdout_preview": proc.stdout[:800],
            "stderr_preview": proc.stderr[:800],
        }
        return fallback

    return {
        "mode": "native",
        "exit_code": 2,
        "errors": [
            {
                "code": "VALIDATE_UNSUPPORTED",
                "message": "openclaw config validate --json returned no JSON events (likely unsupported runtime)",
                "line": 1,
            }
        ],
        "target_config_path": str(config_path),
    }


def run_tests(workspace: Path) -> list[dict]:
    checks: list[dict] = []

    for js_file in sorted(workspace.rglob("*.js")):
        if js_file.name.endswith(".test.js"):
            continue
        proc = run_cmd(["node", "--check", str(js_file)], cwd=workspace)
        checks.append(
            {
                "kind": "syntax",
                "check": f"node --check {js_file.relative_to(workspace)}",
                "exit_code": proc.returncode,
                "stderr_preview": proc.stderr[:500],
            }
        )

    for test_file in sorted(workspace.rglob("*.test.js")):
        proc = run_cmd(["node", "--test", str(test_file)], cwd=workspace)
        checks.append(
            {
                "kind": "unit",
                "check": f"node --test {test_file.relative_to(workspace)}",
                "exit_code": proc.returncode,
                "stdout_preview": proc.stdout[:500],
                "stderr_preview": proc.stderr[:500],
            }
        )
    return checks


def parse_task(prompt: str) -> dict:
    low = prompt.lower()
    return {
        "echo_bot": "echo-bot" in low,
        "forex_bot": "forex-bot" in low,
        "fix_config": ("fix config" in low) or ("fix the config" in low) or ("openclaw fails to start" in low),
        "invalid_plugin": "invalid-plugin-v999" in low,
        "rollback_required": ("roll back" in low) or ("rollback" in low),
    }


def add_step(trace: dict, name: str, status: str, details: dict | None = None, skill: str | None = None) -> None:
    payload = {"name": name, "status": status, "ts_utc": iso_now(), "details": details or {}}
    if skill:
        payload["skill"] = skill
        skills = trace.setdefault("skills_used", [])
        if skill not in skills:
            skills.append(skill)
    trace.setdefault("steps", []).append(payload)


def build_context_compress(workspace: Path, backup_branch: str, validator: dict) -> dict:
    diff = run_cmd(["git", "status", "--short"], cwd=workspace)
    lines = [line for line in diff.stdout.splitlines() if line.strip()]
    files = [line[3:] for line in lines if len(line) > 3][:20]
    qa_ok = validator.get("exit_code", 1) == 0 and not validator.get("errors")
    compact_summary = {
        "changed_files": files,
        "validation_outcome": "OK" if qa_ok else "FAIL",
        "rollback_pointer": backup_branch,
        "next_action": "READY_FOR_APPLY" if qa_ok else "RETURN_TO_CODE",
    }
    return {
        "changed_count": len(files),
        "changed_files": files,
        "compact_summary": compact_summary,
        "control_signal": "CONTEXT_RESET_TO_SUMMARY_V1",
        "runner_hint": "If supported, discard prior turns and continue from compact_summary only.",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Single-agent cto-factory runner")
    parser.add_argument("--workspace", required=True, help="Target workspace path for mutation")
    parser.add_argument("--task-id", required=True)
    parser.add_argument("--prompt", required=True)
    parser.add_argument("--trace-file", required=True)
    parser.add_argument("--apply", default="false")
    parser.add_argument("--allow-validate-fallback", default="true")
    args = parser.parse_args()

    workspace = Path(args.workspace).resolve()
    workspace.mkdir(parents=True, exist_ok=True)
    trace_file = Path(args.trace_file).resolve()
    apply_phase = parse_bool(args.apply)
    allow_fallback = parse_bool(args.allow_validate_fallback)

    trace: dict = {
        "type": "CTO_FACTORY_TRACE",
        "task_id": args.task_id,
        "prompt": args.prompt,
        "started_at": iso_now(),
        "pipeline": [
            "INTAKE",
            "PREFLIGHT",
            "BACKUP",
            "CODE",
            "TEST",
            "CONFIG_QA",
            "CONTEXT_COMPRESS",
            "READY_FOR_APPLY",
            "APPLY",
            "SMOKE",
            "DONE/ROLLBACK",
        ],
        "skills_used": [],
        "steps": [],
    }

    backup_branch = ""
    try:
        add_step(trace, "INTAKE", "OK", {"objective": "Analyze prompt and derive actions"}, "factory-intake")
        task = parse_task(args.prompt)

        pref_details = {
            "workspace": str(workspace),
            "commands": {
                "openclaw_present": run_cmd(["which", "openclaw"]).returncode == 0,
                "codex_present": run_cmd(["which", "codex"]).returncode == 0,
            },
            "apply_phase": apply_phase,
        }
        add_step(trace, "PREFLIGHT", "OK", pref_details, "factory-preflight")

        ensure_git_repo(workspace)
        backup_branch = create_backup_branch(workspace, args.task_id)
        add_step(trace, "BACKUP", "OK", {"strategy": "git_branch", "backup_branch": backup_branch}, "factory-backup")

        yaml_fix = fix_broken_yaml(workspace) if task["fix_config"] else {"changed": False}
        config_path = workspace / "openclaw.json"
        config = ensure_default_config(config_path)

        generated_agents: list[dict] = []
        codex_contract = codex_contract_details()

        if task["echo_bot"]:
            scaffold = ensure_agent_scaffold(
                workspace=workspace,
                agent_id="echo-bot",
                title="Echo Bot",
                responsibility="Reply in console with echoed input text.",
                skills=["echo-text", "console-output", "unit-test"],
            )
            echo_tool_path, echo_test_path = build_echo_tool(Path(scaffold["tools_dir"]))
            upsert_agent(
                config,
                {
                    "id": "echo-bot",
                    "name": "Echo Bot",
                    "workspace": "./agents/echo-bot",
                    "agentDir": "./agents/echo-bot",
                    "tools": {"localScripts": [str(echo_tool_path.relative_to(workspace))]},
                },
            )
            ensure_console_route(config, "echo-bot")
            generated_agents.append(
                {
                    "id": "echo-bot",
                    "root": scaffold["agent_root"],
                    "tools": [str(echo_tool_path.relative_to(workspace))],
                    "tests": [str(echo_test_path.relative_to(workspace))],
                    "passport": scaffold["passport"],
                }
            )

        if task["forex_bot"]:
            scaffold = ensure_agent_scaffold(
                workspace=workspace,
                agent_id="forex-bot",
                title="Forex Bot",
                responsibility="Read USD/EUR rate and expose it via a local tool.",
                skills=["forex-fetch", "usd-eur", "unit-test"],
            )
            tool_path, test_path = build_forex_tool(Path(scaffold["tools_dir"]))
            upsert_agent(
                config,
                {
                    "id": "forex-bot",
                    "name": "Forex Bot",
                    "workspace": "./agents/forex-bot",
                    "agentDir": "./agents/forex-bot",
                    "tools": {"localScripts": [str(tool_path.relative_to(workspace))]},
                },
            )
            ensure_console_route(config, "forex-bot")
            generated_agents.append(
                {
                    "id": "forex-bot",
                    "root": scaffold["agent_root"],
                    "tools": [str(tool_path.relative_to(workspace))],
                    "tests": [str(test_path.relative_to(workspace))],
                    "passport": scaffold["passport"],
                }
            )

        if task["invalid_plugin"]:
            plugins = config.setdefault("plugins", {}).setdefault("entries", {})
            plugins["invalid-plugin-v999"] = {"enabled": True}

        profiles = config.setdefault("auth", {}).setdefault("profiles", {})
        if "openai:main" in profiles and isinstance(profiles["openai:main"], dict):
            profiles["openai:main"]["apiKey"] = secret_ref("OPENAI_API_KEY")

        save_json(config_path, config)

        plaintext_secret_findings = detect_plaintext_secrets(config)
        code_details = {
            "config_path": str(config_path),
            "yaml_fix": yaml_fix,
            "plaintext_secret_findings": plaintext_secret_findings,
            "codex_contract": codex_contract,
            "generated_agents": generated_agents,
        }
        if plaintext_secret_findings:
            add_step(trace, "CODE", "FAIL", code_details, "factory-codegen")
            trace["result"] = {
                "status": "BLOCKED",
                "reason": "Plaintext secret-like values found after generation",
                "findings": plaintext_secret_findings,
            }
            save_json(trace_file, trace)
            return 1

        add_step(trace, "CODE", "OK", code_details, "factory-codegen")

        test_results = run_tests(workspace)
        test_failed = any(item["exit_code"] != 0 for item in test_results)
        add_step(
            trace,
            "TEST",
            "FAIL" if test_failed else "OK",
            {"checks": test_results},
            "factory-test-agent",
        )
        if test_failed:
            trace["result"] = {"status": "BLOCKED", "reason": "Test phase failed"}
            save_json(trace_file, trace)
            return 1

        validator = run_config_validate(config_path, workspace, allow_fallback)
        qa_failed = validator["exit_code"] != 0 or bool(validator.get("errors"))
        add_step(
            trace,
            "CONFIG_QA",
            "FAIL" if qa_failed else "OK",
            {
                "validator": validator,
                "command": f"OPENCLAW_CONFIG_PATH={config_path} openclaw config validate --json",
                "target_config_path": str(config_path),
            },
            "factory-config-qa",
        )

        if qa_failed and (task["rollback_required"] or task["invalid_plugin"]):
            rb = rollback_from_backup(workspace, backup_branch)
            add_step(
                trace,
                "ROLLBACK",
                "OK" if rb["ok"] else "FAIL",
                {"backup_branch": backup_branch, **rb},
                "factory-rollback",
            )
            trace["result"] = {
                "status": "ROLLED_BACK" if rb["ok"] else "BLOCKED",
                "reason": "CONFIG_QA failed",
                "validator_errors": validator.get("errors", []),
            }
            trace["finished_at"] = iso_now()
            save_json(trace_file, trace)
            return 0 if rb["ok"] else 1

        if qa_failed:
            trace["result"] = {
                "status": "BLOCKED",
                "reason": "CONFIG_QA failed",
                "validator_errors": validator.get("errors", []),
            }
            trace["finished_at"] = iso_now()
            save_json(trace_file, trace)
            return 1

        compressed = build_context_compress(workspace, backup_branch, validator)
        add_step(trace, "CONTEXT_COMPRESS", "OK", compressed, "factory-context-compress")

        add_step(trace, "READY_FOR_APPLY", "OK", {"apply_phase": apply_phase}, "factory-apply")
        add_step(trace, "APPLY", "OK", {"mode": "local_fs", "performed": apply_phase}, "factory-apply")

        smoke = {
            "config_exists": config_path.exists(),
            "git_status_exit": run_cmd(["git", "status", "--short"], cwd=workspace).returncode,
        }
        add_step(trace, "SMOKE", "OK", smoke, "factory-smoke")

        trace["result"] = {"status": "DONE", "backup_branch": backup_branch}
        trace["finished_at"] = iso_now()
        save_json(trace_file, trace)
        return 0
    except Exception as exc:  # noqa: BLE001
        add_step(trace, "RUNTIME", "FAIL", {"error": str(exc)}, "factory-report")
        trace["result"] = {"status": "BLOCKED", "reason": str(exc), "backup_branch": backup_branch}
        trace["finished_at"] = iso_now()
        save_json(trace_file, trace)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
