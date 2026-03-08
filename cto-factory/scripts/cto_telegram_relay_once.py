#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import subprocess
import time
from typing import List


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
        return subprocess.CompletedProcess(
            cmd,
            124,
            stdout,
            f"[TIMEOUT] command exceeded {timeout}s\n{stderr}",
        )


def tg_send_message(token: str, chat_id: str, topic_id: str, text: str) -> tuple[bool, dict, str]:
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
    payload: dict = {}
    try:
        payload = json.loads(proc.stdout) if proc.stdout else {}
    except json.JSONDecodeError:
        payload = {}
    ok = proc.returncode == 0 and bool(payload.get("ok", False))
    return ok, payload, raw


def ask_cto(agent: str, session_id: str, message: str, timeout: int = 240) -> tuple[bool, str]:
    cmd = [
        "openclaw",
        "agent",
        "--local",
        "--agent",
        agent,
        "--session-id",
        session_id,
        "--message",
        message,
        "--json",
    ]
    proc = sh(cmd, timeout=timeout)
    if proc.returncode != 0:
        return False, f"[CLIENT_ERROR] exit={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        return False, f"[CLIENT_ERROR] invalid JSON: {exc}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
    texts: List[str] = []
    for item in payload.get("payloads", []):
        text = item.get("text")
        if text:
            texts.append(text)
    return True, "\n\n".join(texts).strip()


def main() -> int:
    parser = argparse.ArgumentParser(description="Send one tester message and relay CTO answer into Telegram topic.")
    parser.add_argument("--agent", default="cto-factory")
    parser.add_argument("--tester-token", required=True)
    parser.add_argument("--cto-token", required=True)
    parser.add_argument("--chat-id", required=True)
    parser.add_argument("--topic-id", required=True)
    parser.add_argument("--prompt", required=True)
    parser.add_argument("--session-id", default="")
    args = parser.parse_args()

    session_id = args.session_id or f"relay-{int(time.time())}"
    ok_send, send_payload, send_raw = tg_send_message(
        args.tester_token, args.chat_id, args.topic_id, args.prompt
    )
    ok_cto, cto_reply = ask_cto(args.agent, session_id, args.prompt)
    ok_relay, relay_payload, relay_raw = tg_send_message(
        args.cto_token, args.chat_id, args.topic_id, cto_reply if cto_reply else "[empty CTO reply]"
    )

    result = {
        "ok": ok_send and ok_cto and ok_relay,
        "session_id": session_id,
        "tester_send": {
            "ok": ok_send,
            "message_id": send_payload.get("result", {}).get("message_id"),
            "raw": send_raw,
        },
        "cto_local": {
            "ok": ok_cto,
            "reply_preview": cto_reply[:1000],
        },
        "cto_relay_send": {
            "ok": ok_relay,
            "message_id": relay_payload.get("result", {}).get("message_id"),
            "raw": relay_raw,
        },
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
