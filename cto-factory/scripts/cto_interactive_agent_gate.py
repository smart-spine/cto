#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

RUNTIME_SUFFIXES = {".py", ".js", ".ts"}


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except Exception:
        return ""


def has_any(text: str, patterns: list[str]) -> bool:
    low = text.lower()
    return any(p.lower() in low for p in patterns)


def main() -> int:
    p = argparse.ArgumentParser(description="Validate interactive runtime UX implementation (menu/buttons/callback handlers)")
    p.add_argument("--workspace", required=True)
    p.add_argument("--menu-command", default="/menu")
    p.add_argument("--callback-namespace", default="ux:")
    p.add_argument("--allow-menu-alias", action="store_true", help="Allow generic 'menu' match when exact command is not found")
    args = p.parse_args()

    ws = Path(args.workspace).resolve()
    tools_dir = ws / "tools"
    tests_dir = ws / "tests"

    result = {
        "ok": False,
        "workspace": str(ws),
        "menu_command": args.menu_command,
        "callback_namespace": args.callback_namespace,
        "runtime_files_checked": [],
        "test_files_checked": [],
        "failures": [],
        "warnings": [],
        "evidence": {},
    }

    if not tools_dir.exists():
        result["failures"].append(f"missing tools directory: {tools_dir}")
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 2

    runtime_files = [
        p for p in tools_dir.rglob("*") if p.is_file() and p.suffix.lower() in RUNTIME_SUFFIXES
    ]
    result["runtime_files_checked"] = [str(p) for p in runtime_files]

    if not runtime_files:
        result["failures"].append("no runtime tool files (.py/.js/.ts) found")
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 2

    menu_handler_files: list[str] = []
    callback_handler_files: list[str] = []
    button_send_files: list[str] = []
    menu_catalog_suspects: list[str] = []

    for f in runtime_files:
        txt = read_text(f)
        has_menu_exact = has_any(txt, [args.menu_command])
        has_menu_alias = has_any(txt, ["menu"])
        has_menu = has_menu_exact or (args.allow_menu_alias and has_menu_alias)
        has_callback = has_any(txt, [args.callback_namespace, "callback_data", "callback_query", "callback"])
        has_button_payload = has_any(txt, ["inline_keyboard", "reply_markup", "buttons", "callback_data"])
        has_send_transport = has_any(
            txt,
            ["message.send", "message send", "sendmessage", "send_message(", "openclaw message send"],
        )
        has_button_send = has_button_payload and has_send_transport

        if has_menu and has_button_send and has_callback:
            menu_handler_files.append(str(f))
        if has_callback:
            callback_handler_files.append(str(f))
        if has_button_send:
            button_send_files.append(str(f))
        if has_menu:
            has_catalog_marker = has_any(txt, ["commands:", "command list", "quick help", "menu help"])
            has_fallback_words = has_any(txt, ["fallback", "button send fails", "send failed", "tool error", "except"])
            if has_catalog_marker and not has_button_payload and not has_fallback_words:
                menu_catalog_suspects.append(str(f))

    if not menu_handler_files:
        result["failures"].append("no runtime file proves /menu -> inline-button-send -> callback path")
    if not callback_handler_files:
        result["failures"].append("no runtime file proves callback handling path")
    if not button_send_files:
        result["failures"].append("no runtime file with inline-button payload + send transport logic found")
    if menu_catalog_suspects:
        result["failures"].append(
            "menu handler appears to be command-catalog text instead of keyboard-first runtime path"
        )

    result["evidence"]["menu_handler_files"] = menu_handler_files
    result["evidence"]["callback_handler_files"] = callback_handler_files
    result["evidence"]["button_send_files"] = button_send_files
    result["evidence"]["menu_catalog_suspects"] = menu_catalog_suspects

    test_files = []
    if tests_dir.exists():
        test_files = [p for p in tests_dir.rglob("*") if p.is_file()]
    result["test_files_checked"] = [str(p) for p in test_files]

    ux_test_files: list[str] = []
    callback_test_files: list[str] = []
    fallback_test_files: list[str] = []
    for f in test_files:
        txt = read_text(f)
        has_menu_test = has_any(txt, [args.menu_command, "menu"])
        if has_menu_test and has_any(
            txt, ["inline_keyboard", "reply_markup", "buttons", "callback_data", args.callback_namespace]
        ):
            ux_test_files.append(str(f))
        if has_any(txt, [args.callback_namespace, "callback_data", "callback_query"]):
            callback_test_files.append(str(f))
        if has_any(txt, ["fallback", "send failed", "tool error", "button send", "exception"]):
            fallback_test_files.append(str(f))

    if not ux_test_files:
        result["failures"].append("no tests proving interactive menu/button behavior")
    if not callback_test_files:
        result["failures"].append("no tests proving callback routing behavior")
    if not fallback_test_files:
        result["warnings"].append("no tests proving menu fallback behavior on button-send failure")
    result["evidence"]["ux_test_files"] = ux_test_files
    result["evidence"]["callback_test_files"] = callback_test_files
    result["evidence"]["fallback_test_files"] = fallback_test_files

    prompts_md = ws / "PROMPTS.md"
    if prompts_md.exists():
        txt = read_text(prompts_md)
        if not has_any(txt, [args.menu_command, "fallback", "button", "menu"]):
            result["warnings"].append("PROMPTS.md exists but lacks clear menu/button fallback contract")
    else:
        result["warnings"].append("PROMPTS.md missing")

    result["ok"] = len(result["failures"]) == 0
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["ok"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
