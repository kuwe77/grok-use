#!/usr/bin/env python3
"""Grok Use MCP server. Talks only to grok-use-helper, never Cua."""

from __future__ import annotations

import json
import os
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
HELPER = os.environ.get(
    "GROK_USE_HELPER",
    os.path.join(ROOT, "bin", "grok-use-helper"),
)
CAPTURE_DIR = os.environ.get(
    "GROK_USE_STATE",
    os.path.join(ROOT, "state"),
)


def helper(args: list[str]) -> dict:
    if not os.path.isfile(HELPER):
        return {"ok": False, "error": f"helper missing: {HELPER}. Run scripts/build.sh"}
    proc = subprocess.run(
        [HELPER, *args],
        capture_output=True,
        text=True,
    )
    raw = (proc.stdout or "").strip() or (proc.stderr or "").strip()
    try:
        data = json.loads(raw) if raw else {}
    except json.JSONDecodeError:
        data = {"ok": False, "error": raw or "empty helper output"}
    if proc.returncode != 0 and "ok" not in data:
        data = {"ok": False, "error": raw or f"exit {proc.returncode}"}
    data.setdefault("ok", proc.returncode == 0)
    return data


def ok_text(obj: dict) -> dict:
    return {"content": [{"type": "text", "text": json.dumps(obj, indent=2)}]}


TOOLS = [
    {
        "name": "grok_use_permissions",
        "description": "Check Accessibility and Screen Recording grants for Grok Use.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "grok_use_doctor",
        "description": "Driver health plus a short list of on-screen windows.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "grok_use_list_windows",
        "description": "List layer-0 macOS windows with pid, window_id, title, app, bounds.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "on_screen": {"type": "boolean", "description": "If true, only on-screen windows."}
            },
            "additionalProperties": False,
        },
    },
    {
        "name": "grok_use_capture",
        "description": "Screenshot a window and walk its accessibility tree. Always call this before click/type by element_index. Returns screenshot_path plus elements[].",
        "inputSchema": {
            "type": "object",
            "properties": {
                "pid": {"type": "integer"},
                "window_id": {"type": "integer"},
            },
            "required": ["pid", "window_id"],
            "additionalProperties": False,
        },
    },
    {
        "name": "grok_use_click",
        "description": "Click an AX element (index from last grok_use_capture) or screenshot pixel (x,y). Always background: posts to the target pid only. Never raises the app, never warps the user cursor, never injects into the session keyboard. delivery_mode=foreground is ignored.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "pid": {"type": "integer"},
                "window_id": {"type": "integer"},
                "element_index": {"type": "integer"},
                "x": {"type": "number"},
                "y": {"type": "number"},
                "delivery_mode": {"type": "string", "enum": ["background", "foreground"]},
            },
            "required": ["pid", "window_id"],
            "additionalProperties": False,
        },
    },
    {
        "name": "grok_use_type",
        "description": "Insert text into a field of the target pid via AX, else unicode events posted only to that pid. Never raises the app or uses the user's keyboard stream.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "pid": {"type": "integer"},
                "text": {"type": "string"},
                "window_id": {"type": "integer"},
                "element_index": {"type": "integer"},
                "delivery_mode": {"type": "string", "enum": ["background", "foreground"]},
            },
            "required": ["pid", "text"],
            "additionalProperties": False,
        },
    },
    {
        "name": "grok_use_hotkey",
        "description": "Send a modifier chord such as cmd+l to a pid only. Never uses the session HID tap.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "pid": {"type": "integer"},
                "keys": {"type": "string", "description": "Plus-separated, e.g. cmd+l"},
                "delivery_mode": {"type": "string", "enum": ["background", "foreground"]},
            },
            "required": ["pid", "keys"],
            "additionalProperties": False,
        },
    },
    {
        "name": "grok_use_scroll",
        "description": "Scroll a window in the background with a wheel event posted only to that pid. Pass x,y (screenshot pixels) or element_index so the wheel hits a dropdown/list. Never raises the app or moves the user cursor.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "pid": {"type": "integer"},
                "window_id": {"type": "integer"},
                "direction": {"type": "string", "enum": ["up", "down", "left", "right"]},
                "amount": {"type": "integer", "description": "Line ticks. Default 5."},
                "x": {"type": "number"},
                "y": {"type": "number"},
                "element_index": {"type": "integer"},
                "delivery_mode": {"type": "string", "enum": ["background", "foreground"]},
            },
            "required": ["pid", "window_id", "direction"],
            "additionalProperties": False,
        },
    },
    {
        "name": "grok_use_press_key",
        "description": "Press a single key (return, tab, escape, up, down, left, right, delete, space).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "pid": {"type": "integer"},
                "key": {"type": "string"},
                "delivery_mode": {"type": "string", "enum": ["background", "foreground"]},
            },
            "required": ["pid", "key"],
            "additionalProperties": False,
        },
    },
]


def dispatch(name: str, args: dict) -> dict:
    if name == "grok_use_permissions":
        return helper(["permissions"])
    if name == "grok_use_doctor":
        return helper(["doctor"])
    if name == "grok_use_list_windows":
        cmd = ["list-windows"]
        if args.get("on_screen"):
            cmd.append("--on-screen")
        return helper(cmd)
    if name == "grok_use_capture":
        os.makedirs(CAPTURE_DIR, exist_ok=True)
        out = os.path.join(CAPTURE_DIR, f"capture-{args['window_id']}.png")
        shot_ok = False
        try:
            shot = subprocess.run(
                ["/usr/sbin/screencapture", f"-l{args['window_id']}", "-x", "-o", out],
                capture_output=True,
                text=True,
            )
            shot_ok = shot.returncode == 0 and os.path.isfile(out) and os.path.getsize(out) > 0
        except OSError:
            shot_ok = False
        data = helper(
            [
                "ax-tree",
                "--pid",
                str(args["pid"]),
                "--window-id",
                str(args["window_id"]),
                "--out",
                out,
            ]
        )
        data["screenshot_path"] = out if shot_ok else None
        data["screenshot_ok"] = shot_ok
        if shot_ok:
            try:
                from struct import unpack

                with open(out, "rb") as fh:
                    raw = fh.read(32)
                # PNG IHDR is at byte 16
                if raw.startswith(b"\x89PNG"):
                    with open(out, "rb") as fh:
                        fh.seek(16)
                        w, h = unpack(">II", fh.read(8))
                    data["screenshot_width"] = w
                    data["screenshot_height"] = h
            except Exception:
                pass
        return data
    if name == "grok_use_click":
        cmd = [
            "click",
            "--pid",
            str(args["pid"]),
            "--window-id",
            str(args["window_id"]),
            "--mode",
            args.get("delivery_mode") or "background",
        ]
        if "element_index" in args and args["element_index"] is not None:
            cmd += ["--index", str(int(args["element_index"]))]
        elif "x" in args and "y" in args:
            cmd += ["--x", str(args["x"]), "--y", str(args["y"])]
        else:
            return {"ok": False, "error": "grok_use_click needs element_index or x,y"}
        return helper(cmd)
    if name == "grok_use_type":
        cmd = [
            "type",
            "--pid",
            str(args["pid"]),
            "--text",
            str(args["text"]),
            "--mode",
            args.get("delivery_mode") or "background",
        ]
        if args.get("window_id") is not None:
            cmd += ["--window-id", str(args["window_id"])]
        if args.get("element_index") is not None:
            cmd += ["--index", str(int(args["element_index"]))]
        return helper(cmd)
    if name == "grok_use_hotkey":
        return helper(
            [
                "hotkey",
                "--pid",
                str(args["pid"]),
                "--keys",
                str(args["keys"]),
                "--mode",
                args.get("delivery_mode") or "background",
            ]
        )
    if name == "grok_use_scroll":
        cmd = [
            "scroll",
            "--pid",
            str(args["pid"]),
            "--window-id",
            str(args["window_id"]),
            "--direction",
            str(args.get("direction") or "down"),
            "--amount",
            str(int(args.get("amount") or 5)),
            "--mode",
            args.get("delivery_mode") or "background",
        ]
        if args.get("element_index") is not None:
            cmd += ["--index", str(int(args["element_index"]))]
        elif args.get("x") is not None and args.get("y") is not None:
            cmd += ["--x", str(args["x"]), "--y", str(args["y"])]
        return helper(cmd)
    if name == "grok_use_press_key":
        return helper(
            [
                "press-key",
                "--pid",
                str(args["pid"]),
                "--key",
                str(args["key"]),
                "--mode",
                args.get("delivery_mode") or "background",
            ]
        )
    return {"ok": False, "error": f"unknown tool {name}"}


REPLY_FRAMING = "ndjson"


def write_message(payload: dict) -> None:
    raw = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    if REPLY_FRAMING == "content-length":
        sys.stdout.buffer.write(f"Content-Length: {len(raw)}\r\n\r\n".encode("ascii"))
        sys.stdout.buffer.write(raw)
    else:
        sys.stdout.buffer.write(raw + b"\n")
    sys.stdout.buffer.flush()


def read_message():
    """Accept MCP Content-Length framing or newline-delimited JSON."""
    global REPLY_FRAMING
    line = sys.stdin.buffer.readline()
    if not line:
        return None
    stripped = line.lstrip()
    if stripped.startswith(b"{") or stripped.startswith(b"["):
        REPLY_FRAMING = "ndjson"
        return json.loads(line.decode("utf-8"))
    REPLY_FRAMING = "content-length"
    headers = {}
    while True:
        if line in (b"\r\n", b"\n"):
            break
        if b":" in line:
            key, value = line.decode("ascii", errors="replace").split(":", 1)
            headers[key.strip().lower()] = value.strip()
        line = sys.stdin.buffer.readline()
        if not line:
            return None
    length = int(headers.get("content-length") or "0")
    if length <= 0:
        return None
    body = sys.stdin.buffer.read(length)
    return json.loads(body.decode("utf-8"))


def respond(msg_id, result=None, error=None):
    body = {"jsonrpc": "2.0", "id": msg_id}
    if error is not None:
        body["error"] = error
    else:
        body["result"] = result
    write_message(body)


def main() -> None:
    while True:
        try:
            msg = read_message()
        except Exception:
            continue
        if msg is None:
            return
        method = msg.get("method")
        msg_id = msg.get("id")
        if method == "initialize":
            params = msg.get("params") or {}
            version = params.get("protocolVersion") or "2024-11-05"
            respond(
                msg_id,
                {
                    "protocolVersion": version,
                    "capabilities": {"tools": {"listChanged": False}},
                    "serverInfo": {"name": "grok-use", "version": "0.1.0"},
                },
            )
            continue
        if method == "notifications/initialized":
            continue
        if method == "ping":
            respond(msg_id, {})
            continue
        if method == "tools/list":
            respond(msg_id, {"tools": TOOLS})
            continue
        if method == "tools/call":
            params = msg.get("params") or {}
            name = params.get("name")
            args = params.get("arguments") or {}
            try:
                result = dispatch(name, args)
                respond(msg_id, ok_text(result))
            except Exception as exc:  # noqa: BLE001
                respond(msg_id, ok_text({"ok": False, "error": str(exc)}))
            continue
        if msg_id is not None:
            respond(msg_id, error={"code": -32601, "message": f"unknown method {method}"})


if __name__ == "__main__":
    main()
