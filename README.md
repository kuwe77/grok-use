# Grok Use

A **background computer-use** driver for [Grok Build](https://docs.x.ai/) on macOS.

Grok looks at a window, then clicks, types, presses keys, or scrolls **inside that app** — without taking your cursor, keyboard, or frontmost Space.

It is **not** Cua and **not** Codex Computer Use. It does the same *kind* of job as Codex Computer Use (screenshot + hands). It does **not** inject JavaScript into a browser.

## Why it exists

Coding agents often fail on real GUIs: login walls, React dropdowns, native apps with no API. Codex Computer Use handles that with a privileged helper. Cua does it as a general driver, including a JS/DOM path that many Chromium forks (for example Comet) refuse.

Grok Use is a small stack Grok owns:

1. See one window (screenshot + Accessibility tree)
2. Act on that process only
3. See again and check the result

## Architecture

```
You
 └─ Grok Build (the brain)
     └─ grok-use MCP  (mcp/server.py)
         └─ grok-use-helper  (Swift)
             └─ one macOS window (pid + window_id)
```

| Layer | Role |
|---|---|
| **Skill** `skills/grok-use/SKILL.md` | Tells Grok the capture → act → verify loop |
| **MCP** `mcp/server.py` | stdio tools Grok calls (`grok_use_*`) |
| **Helper** `Sources/main.swift` | Lists windows, walks AX, posts input |

Input is either:

- **AX** — `AXPress` / set `AXValue` on a named control
- **Process events** — `CGEventPostToPid` with a **private** event source

The helper **never**:

- activates or raises the target app
- posts to the session HID tap (`.cghidEventTap`)
- warps the real cursor

`delivery_mode=foreground` is accepted so old agents do not crash, then **ignored** (`steal_refused: true`).

## Requirements

- macOS 14 or later
- Xcode command line tools (`xcrun swiftc`)
- [Grok Build](https://docs.x.ai/) CLI (`grok`) to register MCP
- **Accessibility** for clicks, type, keys, scroll
- **Screen Recording** for window screenshots

## Install

```bash
git clone https://github.com/kuwe77/grok-use.git
cd grok-use
./scripts/build.sh
```

That compiles `bin/grok-use-helper`.

### Permissions

System Settings → Privacy & Security:

1. **Accessibility** — enable `grok-use-helper` (or the Grok / Terminal app that launches it)
2. **Screen Recording** — same identity, or captures come back empty

Then:

```bash
./bin/grok-use permissions
./bin/grok-use doctor
```

### Register with Grok

```bash
grok mcp add grok-use -- /usr/bin/python3 "$(pwd)/mcp/server.py"
mkdir -p ~/.grok/skills/grok-use
cp skills/grok-use/SKILL.md ~/.grok/skills/grok-use/SKILL.md
```

Start a **new** Grok session. MCP tools load at session start.

Ask Grok to use **Grok Use**, not Cua.

## Tools

| MCP tool | What it does |
|---|---|
| `grok_use_permissions` | Accessibility + Screen Recording status |
| `grok_use_doctor` | Health check + a few on-screen windows |
| `grok_use_list_windows` | `pid`, `window_id`, app, title, bounds |
| `grok_use_capture` | PNG of that window + AX `elements[]` |
| `grok_use_click` | `element_index` from the last capture, or screenshot `x,y` |
| `grok_use_type` | AX set-value, else unicode events to that pid only |
| `grok_use_hotkey` | Chord such as `cmd+l` |
| `grok_use_press_key` | `return`, `tab`, `escape`, arrows, `pagedown`, … |
| `grok_use_scroll` | Wheel. Pass `x,y` or `element_index` so it hits a dropdown |

Same actions on the CLI:

```bash
./bin/grok-use list-windows
./bin/grok-use capture --pid <pid> --window-id <id> --out /tmp/win.png
./bin/grok-use click --pid <pid> --window-id <id> --index 8
./bin/grok-use scroll --pid <pid> --window-id <id> --direction down --amount 8 --x 400 --y 360
```

## Agent loop

1. `grok_use_permissions` — stop if Accessibility is false
2. `grok_use_list_windows` — pick **one** `pid` + `window_id`
3. `grok_use_capture` — read the PNG **and** `elements[]`
4. Act in the **background**
   - Prefer `element_index`
   - Use `x,y` for canvas / unlabeled controls
   - Scroll a menu with `grok_use_scroll` aimed at the open list, or `press-key down`
5. Capture again. Do not assume the click worked.

## Layout

```
Sources/main.swift          native helper
mcp/server.py               Grok MCP (stdio)
scripts/build.sh            compile helper
bin/grok-use                CLI wrapper
skills/grok-use/SKILL.md    agent instructions
```

`bin/grok-use-helper` is built locally and gitignored.

## What this is not

| | Grok Use | Codex Computer Use | Cua |
|---|---|---|---|
| Owner | This repo | OpenAI (`SkyComputerUse`) | trycua |
| Drive a GUI | Screenshot + AX + pid events | Screenshot + AX + privileged input | That, plus JS/DOM/CDP |
| Inject JS into Chrome / Comet | No | No | Yes, when the browser is recognized |
| Steal your cursor / keyboard | No (by design) | No | Optional foreground path |

Web apps that ignore Accessibility still need a pixel click or scroll **on the control**. They do not need JavaScript.

## Safety

This process can click anything the Mac user can click.

- Never type passwords, OTPs, card numbers, or API keys
- Never click payment UI, permission dialogs, or “Show key”
- Recapture after every action
- Do not point two agents at the same window

MIT — see [LICENSE](LICENSE).
