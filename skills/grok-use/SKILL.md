---
name: grok-use
description: Drive this Mac with Grok Use, Grok's own desktop driver (not Cua, not Codex). Screenshot a window, click AX elements or pixels, type, and send hotkeys. Use when the user says grok use, /grok-use, computer use, click, type, or drive an app.
---

# Grok Use

Use the **grok-use** MCP tools (`grok_use_*`). Do **not** call `cua-driver`, Cua MCP tools, or Codex SkyComputerUse unless the user explicitly asks for Cua.

Binary: `<repo>/bin/grok-use-helper` (or `~/.grok/grok-use/bin/grok-use-helper` if installed there).  
If MCP tools are missing this session, call that CLI the same way.

## Loop

1. `grok_use_permissions` / `grok_use_doctor`. If Accessibility is false, stop and tell the user to grant it to `grok-use-helper` (or Grok) in System Settings → Privacy & Security.
2. `grok_use_list_windows` and pick the exact `pid` + `window_id`.
3. `grok_use_capture` every turn before an element-index action. Read `screenshot_path` with the file tool. Ground on both the image and `elements[]`.
4. Act:
   - Prefer `grok_use_click` with `element_index` from the latest capture (AX press, no cursor move).
   - If the control is canvas / ignored by AX, click `x,y` in **screenshot pixels** (hit-test AX first; mouse events restore the real cursor).
   - `grok_use_type` is AX-only. If it fails, do not try to "just type" — that steals the user keyboard.
   - Always stay in the background. Never pass `delivery_mode=foreground`. The helper ignores it anyway.
   - To move a dropdown/list, use `grok_use_scroll` with `direction=down` and `x,y` on the open menu (screenshot pixels), or `grok_use_press_key` `down` / `pagedown` after the menu is focused.
   - If the UI does not change, recapture and try the other background address (AX vs pixels). Do not raise the app or steal the user's keyboard.
5. Recapture and verify. Never assume a click worked.

## Rules

- Never type passwords, OTPs, card numbers, or API keys.
- Never click permission dialogs, payment UI, or "Show key" / "New secret API key".
- Do not drive Comet while another agent is using Cua on it, unless the user says that session is idle.
- Shell, git, and file edits stay on normal tools. Grok Use is for GUI apps.
- After any click, say what changed in the new screenshot.
