#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import List


LONG_TURN_TIMEOUT_SEC = 10800


@dataclass
class Turn:
    codex: str
    cto: str


@dataclass
class Report:
    title: str
    goal: str
    passed: bool
    transcript: List[Turn]
    postmortem: str


def pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def cleanup_stale_locks(root: Path, agent: str) -> dict:
    sessions_dir = root / "agents" / agent / "sessions"
    report = {"found": 0, "removed": 0, "kept": 0}
    if not sessions_dir.exists():
        return report
    for lock_path in sessions_dir.glob("*.lock"):
        report["found"] += 1
        pid = -1
        try:
            payload = json.loads(lock_path.read_text(encoding="utf-8"))
            raw_pid = payload.get("pid")
            pid = int(raw_pid) if raw_pid is not None else -1
        except Exception:  # noqa: BLE001
            pid = -1
        if pid > 0 and pid_alive(pid):
            report["kept"] += 1
            continue
        lock_path.unlink(missing_ok=True)
        report["removed"] += 1
    return report


def to_recipient_for_session(session_id: str) -> str:
    digits = "".join(str((ord(ch) * (idx + 7)) % 10) for idx, ch in enumerate(session_id))
    short = (digits + "00000000")[:8]
    return f"+1777{short}"


def sh(cmd: List[str], timeout: int = 180) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout if isinstance(exc.stdout, str) else (exc.stdout or b"").decode("utf-8", errors="replace")
        stderr = exc.stderr if isinstance(exc.stderr, str) else (exc.stderr or b"").decode("utf-8", errors="replace")
        timeout_note = f"[TIMEOUT] command exceeded {timeout}s\n"
        return subprocess.CompletedProcess(
            cmd,
            124,
            stdout,
            timeout_note + stderr,
        )


def ask_cto(agent: str, session_id: str, message: str, root: Path, timeout: int = LONG_TURN_TIMEOUT_SEC) -> str:
    recipient = to_recipient_for_session(session_id)
    cleanup_log = ""
    proc = None
    for attempt in range(1, 4):
        cmd = [
            "openclaw",
            "agent",
            "--local",
            "--agent",
            agent,
            "--to",
            recipient,
            "--session-id",
            session_id,
            "--message",
            message,
            "--timeout",
            str(timeout),
            "--json",
        ]
        proc = sh(cmd, timeout=timeout + 180)
        if proc.returncode == 0:
            break
        if "session file locked" not in (proc.stderr or "").lower():
            break
        cleanup = cleanup_stale_locks(root, agent)
        cleanup_log = (
            f"\n[lock_cleanup] attempt={attempt} removed={cleanup['removed']} kept={cleanup['kept']}"
        )
        if attempt < 3:
            time.sleep(0.6 * attempt)
    assert proc is not None
    if proc.returncode != 0:
        return f"[CLIENT_ERROR] exit={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}{cleanup_log}"
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        return f"[CLIENT_ERROR] invalid JSON: {exc}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
    texts: List[str] = []
    for item in payload.get("payloads", []):
        text = item.get("text")
        if text:
            texts.append(text)
    return "\n\n".join(texts).strip()


def tg_send_message(token: str, chat_id: str, topic_id: str, text: str) -> tuple[bool, str]:
    cmd = [
        "curl",
        "-sS",
        "-X",
        "POST",
        f"https://api.telegram.org/bot{token}/sendMessage",
        "-d",
        f"chat_id={chat_id}",
        "-d",
        f"message_thread_id={topic_id}",
        "--data-urlencode",
        f"text={text}",
    ]
    proc = sh(cmd, timeout=60)
    return proc.returncode == 0, proc.stdout if proc.stdout else proc.stderr


def tg_send_message_ex(
    token: str,
    chat_id: str,
    topic_id: str,
    text: str,
    reply_to_message_id: int | None = None,
) -> tuple[bool, str, dict]:
    cmd = [
        "curl",
        "-sS",
        "-X",
        "POST",
        f"https://api.telegram.org/bot{token}/sendMessage",
        "-d",
        f"chat_id={chat_id}",
        "-d",
        f"message_thread_id={topic_id}",
    ]
    if reply_to_message_id is not None:
        cmd += ["-d", f"reply_to_message_id={reply_to_message_id}"]
    cmd += ["--data-urlencode", f"text={text}"]
    proc = sh(cmd, timeout=60)
    raw = proc.stdout if proc.stdout else proc.stderr
    payload: dict = {}
    try:
        payload = json.loads(proc.stdout) if proc.stdout else {}
    except json.JSONDecodeError:
        payload = {}
    ok = proc.returncode == 0 and bool(payload.get("ok", False))
    return ok, raw, payload


def tg_send_long_message(
    token: str,
    chat_id: str,
    topic_id: str,
    text: str,
    reply_to_message_id: int | None = None,
) -> tuple[bool, List[int], str]:
    chunk_size = 3800
    chunks = [text[i : i + chunk_size] for i in range(0, len(text), chunk_size)] or [""]
    all_ids: List[int] = []
    logs: List[str] = []
    ok_all = True
    current_reply = reply_to_message_id
    for idx, chunk in enumerate(chunks, start=1):
        ok, raw, payload = tg_send_message_ex(
            token, chat_id, topic_id, chunk, reply_to_message_id=current_reply
        )
        msg_id = payload.get("result", {}).get("message_id")
        if isinstance(msg_id, int):
            all_ids.append(msg_id)
        logs.append(f"chunk={idx} ok={ok} message_id={msg_id} raw={raw}")
        ok_all = ok_all and ok
        current_reply = None
    return ok_all, all_ids, "\n".join(logs)


def tg_send_document(token: str, chat_id: str, topic_id: str, path: Path, caption: str) -> tuple[bool, str]:
    cmd = [
        "curl",
        "-sS",
        "-X",
        "POST",
        f"https://api.telegram.org/bot{token}/sendDocument",
        "-F",
        f"chat_id={chat_id}",
        "-F",
        f"message_thread_id={topic_id}",
        "-F",
        f"caption={caption}",
        "-F",
        f"document=@{path}",
    ]
    proc = sh(cmd, timeout=120)
    return proc.returncode == 0, proc.stdout if proc.stdout else proc.stderr


def channels_status() -> dict:
    proc = sh(["openclaw", "channels", "status", "--probe", "--json"], timeout=120)
    if proc.returncode != 0:
        return {}
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {}


def find_marker_in_sessions(marker: str, sessions_glob: str) -> bool:
    cmd = ["zsh", "-lc", f"rg -n {json.dumps(marker)} {sessions_glob} >/dev/null 2>&1"]
    proc = sh(cmd, timeout=60)
    return proc.returncode == 0


def write_report(path: Path, report: Report) -> None:
    lines = [
        f"# TEST REPORT: {report.title}",
        f"**Цель теста:** {report.goal}",
        f"**Результат:** {'PASS' if report.passed else 'FAIL'}",
        "",
        "### FULL TRANSCRIPT:",
    ]
    for turn in report.transcript:
        lines.append("CODEX:")
        lines.append(turn.codex)
        lines.append("")
        lines.append("CTO:")
        lines.append(turn.cto)
        lines.append("")
    if not report.passed:
        lines.append("### POST-MORTEM (если FAIL):")
        lines.append(report.postmortem)
        lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8")


def is_ready(text: str) -> bool:
    return re.search(
        r"(?mi)(?:^\s*(?:#+\s*)?(?:REACT:\s*)?READY_FOR_APPLY\b|\bat\s+\*{0,2}READY_FOR_APPLY\b)",
        text,
    ) is not None


def is_blocked(text: str) -> bool:
    return re.search(r"(?mi)^BLOCKED:", text) is not None


def is_timeout_error(text: str) -> bool:
    return "[CLIENT_ERROR] exit=124" in text


def architecture_ok(root: Path, agent_id: str) -> tuple[bool, str]:
    workspace = root / f"workspace-{agent_id}"
    checks = [
        workspace.exists(),
        (workspace / "config").exists(),
        (workspace / "tools").exists(),
        (workspace / "tests").exists(),
        (workspace / "agent").exists(),
        (workspace / "agent" / "IDENTITY.md").is_file(),
        (workspace / "agent" / "TOOLS.md").is_file(),
        (workspace / "agent" / "PROMPTS.md").is_file(),
        (workspace / "AGENTS.md").is_file() or (workspace / "README.md").is_file(),
    ]
    tools = list((workspace / "tools").glob("*.js")) if (workspace / "tools").exists() else []
    tests = list((workspace / "tests").glob("*.js")) if (workspace / "tests").exists() else []
    checks.append(len(tools) > 0)
    checks.append(len(tests) > 0)

    config_path = root / "openclaw.json"
    cfg = json.loads(config_path.read_text(encoding="utf-8"))
    found = None
    for agent in cfg.get("agents", {}).get("list", []):
        if agent.get("id") == agent_id:
            found = agent
            break
    if not found:
        return False, "agent entry not found in openclaw.json"
    expected_workspace = str(workspace)
    expected_agent_dir = str(workspace / "agent")
    checks.append(found.get("workspace") == expected_workspace)
    checks.append(found.get("agentDir") == expected_agent_dir)

    if all(checks):
        return True, "architecture file matrix present"
    return False, "missing required files/paths in generated architecture"


def run_transport_test(
    root: Path,
    agent: str,
    tester_token: str,
    cto_token: str,
    chat_id: str,
    topic_id: str,
) -> Report:
    transcript: List[Turn] = []
    marker = f"TRANSPORT-{int(time.time())}"
    session = f"stress-transport-{int(time.time())}"
    msg = (
        f"@openclaw_smartspine_bot transport probe {marker}. "
        f"Reply with exactly {marker}-ACK in first line."
    )
    ok_send, raw_send, send_payload = tg_send_message_ex(tester_token, chat_id, topic_id, msg)
    tester_message_id = send_payload.get("result", {}).get("message_id")

    cto_reply = ask_cto(agent, session, msg, root, timeout=LONG_TURN_TIMEOUT_SEC)
    transcript.append(
        Turn(
            codex=msg,
            cto=(
                f"[tester_send ok={ok_send} message_id={tester_message_id}]\n{raw_send}\n\n"
                f"[cto_local_reply]\n{cto_reply}"
            ),
        )
    )
    if f"{marker}-ACK" not in cto_reply:
        fix_prompt = f"Reply with exactly {marker}-ACK in first line, then one short sentence."
        cto_reply = ask_cto(agent, session, fix_prompt, root, timeout=LONG_TURN_TIMEOUT_SEC)
        transcript.append(Turn(codex=fix_prompt, cto=cto_reply))

    relay_text = cto_reply if cto_reply.strip() else f"{marker}-ACK"
    ok_relay, relay_ids, relay_log = tg_send_long_message(
        cto_token,
        chat_id,
        topic_id,
        relay_text,
        reply_to_message_id=None,
    )
    transcript.append(
        Turn(
            codex="[relay] publish CTO reply to Telegram via CTO bot token",
            cto=f"[relay ok={ok_relay} message_ids={relay_ids}]\n{relay_log}",
        )
    )

    seen = find_marker_in_sessions(
        marker,
        str(root / "agents" / agent / "sessions" / "*.jsonl"),
    )
    passed = ok_send and ok_relay and (f"{marker}-ACK" in cto_reply) and seen
    postmortem = (
        "Bridge transport failed (tester send, local CTO execution, or CTO relay publish). "
        "Direct bot-to-bot inbound is restricted in Telegram for this setup, so this test uses relay mode."
    )
    return Report(
        title="Telegram Bot-to-Bot Transport Test",
        goal="Проверка, что Tester Bot публикует запрос в topic, а CTO reply возвращается в topic через relay-механику.",
        passed=passed,
        transcript=transcript,
        postmortem=postmortem,
    )


def run_creation_test(root: Path, agent: str) -> Report:
    transcript: List[Turn] = []
    session = f"stress-create-{int(time.time())}"
    agent_id = f"market-signal-radar-{int(time.time())}"
    prompts = [
        (
            f"Build a new agent called {agent_id}. It should monitor r/openclaw and r/selfhosted via RSS every 30 minutes, "
            "post each item to Telegram topic -1003633569118:topic:654, then post one short summary for that run. "
            "Use SecretRef placeholders for secrets. Start with your intake survey and stop at READY_FOR_APPLY."
        ),
        "1A,2B,3A,4B,5A,6B,7B,8B,9C,10B\nsubreddits: r/openclaw, r/selfhosted\ntelegram target: -1003633569118:topic:654\nN failures before alert: 3\nSecretRef: placeholder now, bind later",
        "A",
    ]
    cto_last = ""
    for msg in prompts:
        cto_last = ask_cto(agent, session, msg, root, timeout=LONG_TURN_TIMEOUT_SEC)
        transcript.append(Turn(codex=msg, cto=cto_last))
        if is_timeout_error(cto_last):
            status_msg = "Status check only: if build is ready, reply with READY_FOR_APPLY. If not, reply NOT_READY with one-line reason."
            cto_last = ask_cto(agent, session, status_msg, root, timeout=LONG_TURN_TIMEOUT_SEC)
            transcript.append(Turn(codex=status_msg, cto=cto_last))
        if is_ready(cto_last) or is_blocked(cto_last):
            break
    loop_guard = 0
    while not is_ready(cto_last) and not is_blocked(cto_last) and loop_guard < 1:
        msg = "Proceed with implementation and stop at READY_FOR_APPLY."
        cto_last = ask_cto(agent, session, msg, root, timeout=LONG_TURN_TIMEOUT_SEC)
        transcript.append(Turn(codex=msg, cto=cto_last))
        loop_guard += 1

    arch_ok, arch_detail = architecture_ok(root, agent_id)
    passed = is_ready(cto_last) and arch_ok
    postmortem = (
        f"Creation flow failed readiness or architecture gate. Detail: {arch_detail}. "
        "Fix focus: strengthen create-agent artifact gate and codex prompt file matrix."
    )
    return Report(
        title="Agent Architecture Creation Test",
        goal="Проверка, что CTO создает полноценную архитектуру нового агента (не только markdown) и доходит до READY_FOR_APPLY.",
        passed=passed,
        transcript=transcript,
        postmortem=postmortem,
    )


def run_memory_test(root: Path, agent: str) -> Report:
    transcript: List[Turn] = []
    session = f"stress-memory-{int(time.time())}"
    prompts = [
        "Remember this exact key for later in this session: ALPHA-SEED-442.",
        "Quickly explain what retry backoff means in one sentence.",
        "Give two short names for a weather alert bot.",
        "What is the difference between smoke test and unit test in one line?",
        "What exact key did I ask you to remember at the start?",
    ]
    answers: List[str] = []
    for msg in prompts:
        ans = ask_cto(agent, session, msg, root, timeout=LONG_TURN_TIMEOUT_SEC)
        answers.append(ans)
        transcript.append(Turn(codex=msg, cto=ans))
    last = answers[-1] if answers else ""
    passed = (
        "ALPHA-SEED-442" in last
        and "As an AI" not in last
        and len(last) < 1200
    )
    postmortem = (
        "Context retention or concise style failed. "
        "Fix focus: long-context checkpoint usage + response-style contract enforcement."
    )
    return Report(
        title="Communication and Memory Stress Test",
        goal="Проверка удержания контекста на длинной беседе и качества короткой живой коммуникации.",
        passed=passed,
        transcript=transcript,
        postmortem=postmortem,
    )


def run_self_testing_test(root: Path, agent: str) -> Report:
    transcript: List[Turn] = []
    session = f"stress-selftest-{int(time.time())}"
    prompt = (
        "For market-signal-radar, run the local test suite now and return exact commands, full result lines, and exit codes."
    )
    ans = ask_cto(agent, session, prompt, root, timeout=LONG_TURN_TIMEOUT_SEC)
    transcript.append(Turn(codex=prompt, cto=ans))
    passed = (
        ("node --test" in ans or "pytest" in ans)
        and ("exit" in ans.lower() or "exit code" in ans.lower())
    )
    postmortem = (
        "CTO did not provide deterministic self-test evidence. "
        "Fix focus: enforce test evidence contract in report skill and prompts."
    )
    return Report(
        title="Self-Testing Validation Test",
        goal="Проверка, что CTO сам запускает локальные тесты созданного агента и дает детерминированные доказательства.",
        passed=passed,
        transcript=transcript,
        postmortem=postmortem,
    )


def run_execution_test(root: Path, agent: str) -> Report:
    transcript: List[Turn] = []
    session = f"stress-exec-{int(time.time())}"
    prompt = (
        "Run one real local smoke execution for market-signal-radar now. "
        "Return exact command, exit code, and a final operational statement."
    )
    ans = ask_cto(agent, session, prompt, root, timeout=LONG_TURN_TIMEOUT_SEC)
    transcript.append(Turn(codex=prompt, cto=ans))
    passed = (
        ("exit" in ans.lower() or "exit code" in ans.lower())
        and ("operational" in ans.lower() or "blocked" in ans.lower() or "failed" in ans.lower())
    )
    postmortem = (
        "CTO did not run or report a real smoke execution clearly. "
        "Fix focus: factory-smoke and reporting contract."
    )
    return Report(
        title="Real Execution Smoke Test",
        goal="Проверка, что созданный саб-агент реально запускается локально и CTO сообщает проверяемый результат выполнения.",
        passed=passed,
        transcript=transcript,
        postmortem=postmortem,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Run CTO stress tests and generate strict markdown reports.")
    parser.add_argument("--root", default="/Users/uladzislaupraskou/.openclaw")
    parser.add_argument("--agent", default="cto-factory")
    parser.add_argument("--tester-token", required=True)
    parser.add_argument("--cto-token", required=True)
    parser.add_argument("--chat-id", default="-1003633569118")
    parser.add_argument("--topic-id", default="654")
    parser.add_argument(
        "--only",
        default="all",
        help="Comma-separated subset: transport,creation,memory,selftest,execution or all",
    )
    args = parser.parse_args()

    root = Path(args.root).resolve()
    out_dir = root / "logs" / f"cto-stress-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    out_dir.mkdir(parents=True, exist_ok=True)

    selected = {item.strip().lower() for item in args.only.split(",")} if args.only != "all" else {"all"}
    reports: List[Report] = []
    if "all" in selected or "transport" in selected:
        reports.append(run_transport_test(root, args.agent, args.tester_token, args.cto_token, args.chat_id, args.topic_id))
    if "all" in selected or "creation" in selected:
        reports.append(run_creation_test(root, args.agent))
    if "all" in selected or "memory" in selected:
        reports.append(run_memory_test(root, args.agent))
    if "all" in selected or "selftest" in selected:
        reports.append(run_self_testing_test(root, args.agent))
    if "all" in selected or "execution" in selected:
        reports.append(run_execution_test(root, args.agent))

    paths: List[Path] = []
    for idx, report in enumerate(reports, start=1):
        path = out_dir / f"{idx:02d}-{report.title.lower().replace(' ', '-').replace('/', '-')}.md"
        write_report(path, report)
        paths.append(path)

    summary_lines = ["CTO stress suite finished.", f"Report directory: {out_dir}"]
    for report, path in zip(reports, paths):
        summary_lines.append(f"- {'PASS' if report.passed else 'FAIL'} | {report.title} | {path.name}")
    summary = "\n".join(summary_lines)
    (out_dir / "SUMMARY.txt").write_text(summary + "\n", encoding="utf-8")

    tg_send_message(
        args.tester_token,
        args.chat_id,
        args.topic_id,
        "CTO stress suite completed. Uploading full markdown reports.",
    )
    for path in paths:
        tg_send_document(
            args.tester_token,
            args.chat_id,
            args.topic_id,
            path,
            f"Report: {path.name}",
        )
    tg_send_document(
        args.tester_token,
        args.chat_id,
        args.topic_id,
        out_dir / "SUMMARY.txt",
        "Stress suite summary",
    )

    print(summary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
