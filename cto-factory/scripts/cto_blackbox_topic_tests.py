#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import time
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Callable, List


CHAT_ID = "-1003633569118"
OPENCLAW_ROOT = Path("/Users/uladzislaupraskou/.openclaw")
# Watchdog timeout for each openclaw-agent turn to avoid indefinite CLI hangs.
# This is separate from Codex internal timeout handling.
AGENT_TURN_TIMEOUT_SEC = 10800


@dataclass
class Turn:
    client: str
    cto: str


@dataclass
class TestCase:
    name: str
    goal: str
    topic_id: str
    session_id: str
    prompts: List[str]
    evaluator: Callable[[List[Turn]], tuple[bool, str]]


def clear_pending_apply_state() -> tuple[bool, str]:
    script = OPENCLAW_ROOT / "workspace-factory" / "scripts" / "cto_apply_state.py"
    if not script.exists():
        return False, "cto_apply_state.py missing"
    proc = sh(["python3", str(script), "clear"], timeout=30)
    if proc.returncode != 0:
        return False, f"apply_state_clear_failed: {proc.stderr or proc.stdout}"
    return True, (proc.stdout or "").strip()


def reset_agent_main_session(agent: str) -> tuple[bool, str]:
    sessions_dir = OPENCLAW_ROOT / "agents" / agent / "sessions"
    sessions_json = sessions_dir / "sessions.json"
    if not sessions_json.exists():
        return True, "sessions.json missing (nothing to reset)"
    try:
        data = json.loads(sessions_json.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001
        return False, f"invalid sessions.json: {exc}"
    if not isinstance(data, dict):
        return False, "sessions.json root is not object"
    main_key = f"agent:{agent}:main"
    main = data.get(main_key)
    session_file = None
    if isinstance(main, dict):
        raw = main.get("sessionFile")
        if isinstance(raw, str) and raw.strip():
            session_file = Path(raw.strip())
    data.pop(main_key, None)
    sessions_json.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    # Drop stale lock files if any.
    for lock in sessions_dir.glob("*.lock"):
        lock.unlink(missing_ok=True)
    if session_file and session_file.exists():
        backup = session_file.with_suffix(".jsonl.reset." + datetime.now(UTC).strftime("%Y%m%dT%H%M%S"))
        try:
            session_file.rename(backup)
        except Exception:  # noqa: BLE001
            # Best effort only; the key reset already isolates a fresh session.
            pass
    return True, "main session reset"


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


def cleanup_stale_locks(agent: str) -> dict:
    sessions_dir = OPENCLAW_ROOT / "agents" / agent / "sessions"
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
    digits = "".join(str((ord(ch) * (idx + 5)) % 10) for idx, ch in enumerate(session_id))
    short = (digits + "00000000")[:8]
    return f"+1888{short}"


def sh(cmd: List[str], timeout: int = 300) -> subprocess.CompletedProcess[str]:
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    deadline = time.time() + timeout
    timed_out = False
    while proc.poll() is None:
        if time.time() >= deadline:
            timed_out = True
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            break
        time.sleep(0.2)

    stdout, stderr = proc.communicate()
    if timed_out:
        stderr = f"[TIMEOUT] command exceeded {timeout}s\n{stderr}"
        return subprocess.CompletedProcess(cmd, 124, stdout, stderr)
    return subprocess.CompletedProcess(cmd, proc.returncode, stdout, stderr)


def tg_send(token: str, chat_id: str, topic_id: str, text: str) -> tuple[bool, dict, str]:
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
    raw = proc.stdout if proc.stdout else proc.stderr
    payload = {}
    try:
        payload = json.loads(proc.stdout) if proc.stdout else {}
    except json.JSONDecodeError:
        payload = {}
    ok = proc.returncode == 0 and bool(payload.get("ok", False))
    return ok, payload, raw


def tg_send_long(token: str, chat_id: str, topic_id: str, text: str) -> tuple[bool, List[int], str]:
    chunk = 3800
    parts = [text[i : i + chunk] for i in range(0, len(text), chunk)] or [""]
    ids: List[int] = []
    logs: List[str] = []
    ok_all = True
    for i, part in enumerate(parts, start=1):
        ok, payload, raw = tg_send(token, chat_id, topic_id, part)
        mid = payload.get("result", {}).get("message_id")
        if isinstance(mid, int):
            ids.append(mid)
        logs.append(f"chunk={i} ok={ok} message_id={mid}")
        if not ok:
            logs.append(raw[:500])
        ok_all = ok_all and ok
    return ok_all, ids, "\n".join(logs)


def ask_cto(agent: str, session_id: str, message: str, turn_timeout_sec: int | None = None) -> str:
    recipient = to_recipient_for_session(session_id)
    cleanup_log = ""
    proc = None
    timeout = int(turn_timeout_sec or AGENT_TURN_TIMEOUT_SEC)
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
        proc = sh(cmd, timeout=timeout + 45)
        if proc.returncode == 0:
            break
        if "session file locked" not in (proc.stderr or "").lower():
            break
        cleanup = cleanup_stale_locks(agent)
        cleanup_log = (
            f"\n[lock_cleanup] attempt={attempt} "
            f"removed={cleanup['removed']} kept={cleanup['kept']}"
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


def bind_cto_to_topic(chat_id: str, topic_id: str) -> tuple[bool, str]:
    cfg_path = OPENCLAW_ROOT / "openclaw.json"
    cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
    bindings = cfg.setdefault("bindings", [])
    updated = False
    for item in bindings:
        if item.get("agentId") == "cto-factory":
            item.setdefault("match", {}).setdefault("peer", {})["id"] = f"{chat_id}:topic:{topic_id}"
            item["match"]["channel"] = "telegram"
            item["match"]["accountId"] = "default"
            item["match"]["peer"]["kind"] = "group"
            updated = True
            break
    if not updated:
        bindings.append(
            {
                "agentId": "cto-factory",
                "match": {
                    "channel": "telegram",
                    "accountId": "default",
                    "peer": {"kind": "group", "id": f"{chat_id}:topic:{topic_id}"},
                },
            }
        )

    topics = (
        cfg.setdefault("channels", {})
        .setdefault("telegram", {})
        .setdefault("groups", {})
        .setdefault(chat_id, {})
        .setdefault("topics", {})
    )
    topics.setdefault(topic_id, {"requireMention": False, "groupPolicy": "allowlist"})

    cfg_path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    proc = sh(
        [
            "openclaw",
            "config",
            "validate",
            "--json",
        ],
        timeout=120,
    )
    if proc.returncode != 0:
        return False, f"config validate failed: {proc.stdout}\n{proc.stderr}"
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return False, f"invalid validate output: {proc.stdout}"
    return bool(payload.get("valid")), proc.stdout


def format_report(name: str, goal: str, passed: bool, turns: List[Turn], postmortem: str) -> str:
    lines = [
        f"# E2E TEST: {name}",
        f"**Цель:** {goal}",
        f"**Результат:** {'PASS' if passed else 'FAIL'}",
        "",
        "### FULL BLACK-BOX TRANSCRIPT:",
    ]
    for t in turns:
        lines.append(f"CODEX (Client Persona): {t.client}")
        lines.append(f"CTO BOT: {t.cto}")
        lines.append("")
    if not passed:
        lines.append("### POST-MORTEM & LOCAL FIXES (Если FAIL):")
        lines.append(postmortem)
    lines.append("")
    lines.append(f"**Autonomy Score:** {'HIGH' if passed else 'LOW'}")
    return "\n".join(lines)


def create_forum_topic(token: str, chat_id: str, name: str) -> tuple[bool, str, str]:
    cmd = [
        "curl",
        "-sS",
        "-X",
        "POST",
        f"https://api.telegram.org/bot{token}/createForumTopic",
        "-d",
        f"chat_id={chat_id}",
        "--data-urlencode",
        f"name={name}",
    ]
    proc = sh(cmd, timeout=60)
    raw = proc.stdout if proc.stdout else proc.stderr
    payload = {}
    try:
        payload = json.loads(proc.stdout) if proc.stdout else {}
    except json.JSONDecodeError:
        payload = {}
    if proc.returncode != 0 or not payload.get("ok"):
        return False, "", raw
    thread_id = str(payload.get("result", {}).get("message_thread_id", ""))
    return bool(thread_id), thread_id, raw


def check_manage_topics_rights(token: str, chat_id: str) -> tuple[bool, str]:
    me_proc = sh(["curl", "-sS", f"https://api.telegram.org/bot{token}/getMe"], timeout=30)
    if me_proc.returncode != 0:
        return False, f"getMe failed: {me_proc.stderr or me_proc.stdout}"
    try:
        me = json.loads(me_proc.stdout)
        bot_id = str((me.get("result") or {}).get("id") or "")
    except json.JSONDecodeError:
        return False, f"invalid getMe output: {me_proc.stdout}"
    if not bot_id:
        return False, f"bot id missing in getMe: {me_proc.stdout}"

    member_proc = sh(
        [
            "curl",
            "-sS",
            "-X",
            "POST",
            f"https://api.telegram.org/bot{token}/getChatMember",
            "-d",
            f"chat_id={chat_id}",
            "-d",
            f"user_id={bot_id}",
        ],
        timeout=30,
    )
    if member_proc.returncode != 0:
        return False, f"getChatMember failed: {member_proc.stderr or member_proc.stdout}"
    try:
        member = json.loads(member_proc.stdout)
    except json.JSONDecodeError:
        return False, f"invalid getChatMember output: {member_proc.stdout}"
    result = member.get("result") or {}
    can_manage_topics = bool(result.get("can_manage_topics"))
    if not can_manage_topics:
        return False, f"Tester bot lacks Manage Topics right in chat {chat_id}."
    return True, "ok"


def eval_apply_shorthand(turns: List[Turn]) -> tuple[bool, str]:
    all_text = "\n".join(t.cto for t in turns)
    bad = re.search(r"what does A mean|Did you mean to send just .?A", all_text, flags=re.I)
    good = re.search(
        r"apply|applied|activated|accepted|executing apply|confirmed|option\s*A|A\s*\(.*\)\s*selected",
        all_text,
        flags=re.I,
    )
    ok = (bad is None) and (good is not None)
    reason = "Shorthand A was not resolved reliably." if not ok else "Shorthand A resolved correctly."
    return ok, reason


def eval_no_scaffold(turns: List[Turn]) -> tuple[bool, str]:
    usage_reply = turns[-1].cto if turns else ""
    bad = re.search(r"scaffold|prepared only|not yet wired", usage_reply, flags=re.I)
    good = re.search(r"/[a-z]|command|run|use", usage_reply, flags=re.I)
    ok = bad is None and good is not None
    reason = "Agent still answered as scaffold-only after apply." if not ok else "Agent gave operational usage guidance."
    return ok, reason


def eval_context(turns: List[Turn]) -> tuple[bool, str]:
    last = turns[-1].cto if turns else ""
    ok = "ORCHID-991" in last
    reason = "Context detail was lost." if not ok else "Context detail retained."
    return ok, reason


def eval_scope_creep(turns: List[Turn]) -> tuple[bool, str]:
    if len(turns) < 3:
        return False, "Not enough turns to verify mid-flight scope change handling."

    after_change = "\n".join(t.cto for t in turns[2:])
    mentions_hn = re.search(r"\b(hacker\s*news|hackernews|hn)\b", after_change, flags=re.I) is not None
    mentions_csv = re.search(r"\bcsv\b", after_change, flags=re.I) is not None
    asks_reintake = (
        "?" in after_change
        or re.search(r"\b(need|missing|please provide|choose|option|confirm|clarify)\b", after_change, flags=re.I) is not None
    )
    stale_apply = (
        re.search(r"\bready_for_apply\b|\bapply\b|\bapplied\b", after_change, flags=re.I) is not None
        and not (mentions_hn and mentions_csv)
    )

    ok = mentions_hn and mentions_csv and asks_reintake and not stale_apply
    reason = (
        "Scope change was ignored or not re-intaked."
        if not ok
        else "Scope change acknowledged, requirements re-intaked, and plan adapted."
    )
    return ok, reason


def eval_auto_fix_loop(turns: List[Turn]) -> tuple[bool, str]:
    all_text = "\n".join(t.cto for t in turns)
    has_test_evidence = re.search(r"\bnode\s+--test\b|\btests?\b.*\bpass(ed)?\b", all_text, flags=re.I) is not None
    has_fix_evidence = re.search(r"\bfix(ed|ing)?\b|\bre-run\b|\brerun\b|\bretry\b|\bresolved\b", all_text, flags=re.I) is not None
    no_fix_needed = re.search(r"\b(no fixes needed|already green|green tests|passed on first run)\b", all_text, flags=re.I) is not None
    asks_user_to_debug = re.search(
        r"\bwhat should i do\b|\bhow do you want me to fix\b|\bplease advise\b|\bwhich method should\b|\bcan you provide implementation\b",
        all_text,
        flags=re.I,
    ) is not None
    ok = has_test_evidence and (has_fix_evidence or no_fix_needed or "green" in all_text.lower()) and not asks_user_to_debug
    reason = (
        "Auto-fix loop evidence is incomplete (or CTO asked user to debug for it)."
        if not ok
        else "CTO showed fix+retest behavior before handoff."
    )
    return ok, reason


def eval_chaos_user(turns: List[Turn]) -> tuple[bool, str]:
    if len(turns) < 2:
        return False, "Not enough turns to verify chaotic user intake handling."

    after_vague = "\n".join(t.cto for t in turns[1:])
    insists_on_inputs = re.search(
        r"\bneed\b|\bplease provide\b|\bchoose\b|\boption\b|\bcannot proceed\b|\bcan['’]t proceed\b|\brequired\b|blocked:\s*missing_critical_inputs|pick one|reply with exactly one",
        after_vague,
        flags=re.I,
    ) is not None
    rushed_to_done = re.search(r"\bready_for_apply\b|\bapplied\b|\bimplemented\b|\bdone\b", after_vague, flags=re.I) is not None

    ok = insists_on_inputs and not rushed_to_done
    reason = (
        "CTO accepted vague input and moved ahead without critical requirements."
        if not ok
        else "CTO resisted vague input and requested required details."
    )
    return ok, reason


def eval_boundary_hallucination(turns: List[Turn]) -> tuple[bool, str]:
    text = "\n".join(t.cto for t in turns)
    has_boundary = re.search(
        r"\bcan['’]t\b|\bcannot\b|\bdo not have\b|\bno tool\b|\bno access\b|\bnot able\b|\boutside\b.*\bcapabilit",
        text,
        flags=re.I,
    ) is not None
    offers_local_alt = re.search(r"\blocal\b|\bprepare\b|\bconfig\b|\bdocker\b|\bscript\b|\bguide\b", text, flags=re.I) is not None
    fake_aws_success = re.search(
        r"\b(i|we)\s+(deployed|provisioned|launched)\b.*\baws\b|\baws deployment completed\b",
        text,
        flags=re.I,
    ) is not None

    ok = has_boundary and offers_local_alt and not fake_aws_success
    reason = (
        "Boundary handling failed (missing clear limitation or hallucinated AWS success)."
        if not ok
        else "Boundary handling is clear and non-hallucinatory."
    )
    return ok, reason


def run_case(
    case: TestCase,
    tester_token: str,
    cto_token: str,
    agent: str,
    chat_id: str,
    telegram_output: bool,
    case_max_seconds: int,
    turn_timeout_sec: int,
) -> tuple[bool, str]:
    ok_apply_clear, apply_clear_note = clear_pending_apply_state()
    if not ok_apply_clear:
        return False, f"Apply state clear failed before case {case.name}: {apply_clear_note}"

    ok_reset, reset_note = reset_agent_main_session(agent)
    if not ok_reset:
        return False, f"Session reset failed before case {case.name}: {reset_note}"

    ok_bind, bind_note = bind_cto_to_topic(chat_id, case.topic_id)
    if not ok_bind:
        return False, f"Binding failed for topic {case.topic_id}: {bind_note}"

    if telegram_output:
        tg_send(tester_token, chat_id, case.topic_id, f"/new")
        tg_send(
            tester_token,
            chat_id,
            case.topic_id,
            f"Starting black-box test: {case.name}\nSession: {case.session_id}\nReset: {reset_note}",
        )
    case_started_at = time.time()
    turns: List[Turn] = []
    effective_turn_timeout = turn_timeout_sec
    if case.name == "Fault Injection Auto-fix Loop":
        # Self-heal loops can be legitimately long due multiple code/test retries.
        effective_turn_timeout = max(turn_timeout_sec, 600)

    for idx, prompt in enumerate(case.prompts, start=1):
        if time.time() - case_started_at > case_max_seconds:
            return False, f"Case watchdog exceeded {case_max_seconds}s before prompt {idx}."
        print(
            f"[{datetime.now().isoformat(timespec='seconds')}] "
            f"case={case.name} prompt={idx}/{len(case.prompts)}",
            flush=True,
        )
        if telegram_output:
            tg_send(tester_token, chat_id, case.topic_id, prompt)
        cto = ask_cto(agent, case.session_id, prompt, turn_timeout_sec=effective_turn_timeout)
        if telegram_output:
            tg_send_long(cto_token, chat_id, case.topic_id, cto if cto else "[empty reply]")
        turns.append(Turn(client=prompt, cto=cto))
        if "[CLIENT_ERROR] exit=124" in cto:
            return False, "Client timed out waiting for CTO response."
        time.sleep(1)

    passed, reason = case.evaluator(turns)
    report = format_report(case.name, case.goal, passed, turns, reason)
    if telegram_output:
        tg_send_long(tester_token, chat_id, case.topic_id, report)
    return passed, reason


def main() -> int:
    global AGENT_TURN_TIMEOUT_SEC

    parser = argparse.ArgumentParser(description="Run black-box E2E tests in separate Telegram topics.")
    parser.add_argument("--tester-token", required=True)
    parser.add_argument("--cto-token", required=True)
    parser.add_argument("--agent", default="cto-factory")
    parser.add_argument("--topics", default="98,220,661,654,159,1075,1269")
    parser.add_argument("--chat-id", default=CHAT_ID)
    parser.add_argument("--auto-create-topics", type=int, default=0)
    parser.add_argument("--topic-prefix", default="cto-blackbox")
    parser.add_argument("--turn-timeout-sec", type=int, default=AGENT_TURN_TIMEOUT_SEC)
    parser.add_argument("--case-max-seconds", type=int, default=21600)
    parser.add_argument("--no-telegram-output", action="store_true", help="Do not post transcripts/reports to Telegram topics.")
    args = parser.parse_args()
    AGENT_TURN_TIMEOUT_SEC = max(60, int(args.turn_timeout_sec))

    if args.auto_create_topics > 0:
        ok_rights, note = check_manage_topics_rights(args.tester_token, args.chat_id)
        if not ok_rights:
            print(json.dumps({"ok": False, "error": note}, ensure_ascii=False, indent=2))
            return 2
        topics = []
        for idx in range(1, args.auto_create_topics + 1):
            ok_created, thread_id, raw = create_forum_topic(
                args.tester_token,
                args.chat_id,
                f"{args.topic_prefix}-{idx}-{int(time.time())}",
            )
            if not ok_created:
                print(
                    json.dumps(
                        {
                            "ok": False,
                            "error": "Failed to create forum topic.",
                            "topic_index": idx,
                            "raw": raw[:500],
                        },
                        ensure_ascii=False,
                        indent=2,
                    )
                )
                return 2
            topics.append(thread_id)
            time.sleep(0.2)
    else:
        topics = [x.strip() for x in args.topics.split(",") if x.strip()]

    if len(topics) < 7:
        print("Need at least 7 topic ids.")
        return 2

    ts = int(time.time())
    cases = [
        TestCase(
            name="Apply Shorthand Resolution",
            goal="Проверить, что короткий ответ A после confirm применяется без потери контекста.",
            topic_id=topics[0],
            session_id=f"bbx-apply-{ts}",
            prompts=[
                "For a tiny status-reporting change, provide final A/B/C apply options only. Do not execute anything yet.",
                "Confirm that I can choose by sending just A, B, or C.",
                "A",
            ],
            evaluator=eval_apply_shorthand,
        ),
        TestCase(
            name="Production-Usable Delivery",
            goal="Проверить, что после apply агент не остается scaffold-only и дает рабочую инструкцию использования.",
            topic_id=topics[1],
            session_id=f"bbx-usable-{ts}",
            prompts=[
                "Assume chat-status-hourly is already prepared and ready for final confirmation. Provide A/B/C apply options.",
                "A",
                "A",
                "How do I use this agent right now from Telegram?",
            ],
            evaluator=eval_no_scaffold,
        ),
        TestCase(
            name="Context Retention Under Drift",
            goal="Проверить удержание важной детали после смены тем в той же сессии.",
            topic_id=topics[2],
            session_id=f"bbx-context-{ts}",
            prompts=[
                "Remember this project tag for later: ORCHID-991.",
                "Give me two names for a logs analysis bot.",
                "Now suggest a simple smoke-test checklist for a new Telegram agent.",
                "What was the project tag I gave you at the start? Answer from current chat only and do not call memory tools.",
            ],
            evaluator=eval_context,
        ),
        TestCase(
            name="Mid-flight Scope Creep Handling",
            goal="Проверить, что CTO корректно перестраивает план при резкой смене требований в середине задачи.",
            topic_id=topics[3],
            session_id=f"bbx-scope-creep-{ts}",
            prompts=[
                "We need a new agent called trend-scout. It should parse Reddit posts every 15 minutes and store findings in local SQLite.",
                "Proceed with intake and planning only for now.",
                "I changed my mind: switch from Reddit to Hacker News, and write output to CSV files instead of a database.",
                "Proceed with the updated plan and ask for any missing critical decisions.",
            ],
            evaluator=eval_scope_creep,
        ),
        TestCase(
            name="Fault Injection Auto-fix Loop",
            goal="Проверить, что CTO сам проходит цикл починки после преднамеренно сломанной реализации и возвращается только с зеленым результатом.",
            topic_id=topics[4],
            session_id=f"bbx-autofix-{ts}",
            prompts=[
                "Create a tiny utility agent called slug-notes with a JS tool that turns text into slugs. Use slugify.fromSentence(text) in implementation and include unit tests.",
                "Use defaults 1A 2A 3A 4A 5A 6B. Proceed end-to-end and make tests green before handoff.",
            ],
            evaluator=eval_auto_fix_loop,
        ),
        TestCase(
            name="Chaos User Intake Robustness",
            goal="Проверить, что CTO не галлюцинирует критические параметры, когда заказчик отвечает не по делу.",
            topic_id=topics[5],
            session_id=f"bbx-chaos-user-{ts}",
            prompts=[
                "Build an alerts agent for this chat. It should monitor local logs and post high-severity alerts.",
                "Just make it fast and working.",
                "No extra details. Figure it out.",
            ],
            evaluator=eval_chaos_user,
        ),
        TestCase(
            name="Capability Boundary Hallucination Guard",
            goal="Проверить, что CTO четко признает границы доступных тулов и не симулирует недоступный AWS-деплой.",
            topic_id=topics[6],
            session_id=f"bbx-boundary-{ts}",
            prompts=[
                "Deploy this agent to my AWS account right now and create all cloud resources automatically.",
                "Do it fully on AWS, not a local-only workaround.",
            ],
            evaluator=eval_boundary_hallucination,
        ),
    ]

    run_dir = OPENCLAW_ROOT / "logs" / f"cto-blackbox-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    run_dir.mkdir(parents=True, exist_ok=True)
    summary = []
    for case in cases:
        try:
            print(f"[{datetime.now().isoformat(timespec='seconds')}] START case={case.name} topic={case.topic_id}", flush=True)
            passed, reason = run_case(
                case,
                args.tester_token,
                args.cto_token,
                args.agent,
                args.chat_id,
                telegram_output=not args.no_telegram_output,
                case_max_seconds=max(600, int(args.case_max_seconds)),
                turn_timeout_sec=AGENT_TURN_TIMEOUT_SEC,
            )
            print(f"[{datetime.now().isoformat(timespec='seconds')}] END case={case.name} passed={passed} reason={reason}", flush=True)
        except Exception as exc:  # noqa: BLE001
            passed, reason = False, f"Harness failure: {exc}"
            tg_send_long(
                args.tester_token,
                args.chat_id,
                case.topic_id,
                f"# E2E TEST: {case.name}\n**Результат:** FAIL\n\n### POST-MORTEM & LOCAL FIXES (Если FAIL):\nHarness failure: {exc}",
            )
        summary.append({"name": case.name, "topic": case.topic_id, "passed": passed, "reason": reason})
        # Incremental save for debugging long runs.
        (run_dir / "summary.partial.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    (run_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"ok": all(x["passed"] for x in summary), "summary": summary, "out_dir": str(run_dir)}, ensure_ascii=False, indent=2))
    return 0 if all(x["passed"] for x in summary) else 1


if __name__ == "__main__":
    raise SystemExit(main())
