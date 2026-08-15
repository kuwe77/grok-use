# Grok Use

Background computer-use for [Grok Build](https://docs.x.ai/): screenshot a macOS window, click, type, hotkey, and scroll without stealing the user’s cursor or keyboard.

Not Cua. Not Codex Computer Use. Same *job* as Codex Computer Use (eyes + hands), not JavaScript injection.

## How it works

```
You → Grok → grok-use MCP → grok-use-helper → one app window
```

Input is posted only to that process (`AXPress` or `CGEventPostToPid` with a private event source). The helper never activates the target app and never posts to the session HID tap. `--mode foreground` is ignored (`steal_refused`).

## Requirements

- macOS 14+
- Xcode / `xcrun swiftc`
- Accessibility (and Screen Recording for captures)
- Grok Build CLI (`grok`)

## Build

```bash
git clone https://github.com/kuwe77/grok-use.git
cd grok-use
./scripts/build.sh
```

Grant **Accessibility** and **Screen Recording** to `bin/grok-use-helper` (or the Grok/Terminal parent) in System Settings → Privacy & Security.

## Register with Grok

```bash
grok mcp add grok-use -- /usr/bin/python3 "$(pwd)/mcp/server.py"
mkdir -p ~/.grok/skills/grok-use
cp skills/grok-use/SKILL.md ~/.grok/skills/grok-use/SKILL.md
```

Start a **new** Grok session so the `grok_use_*` tools load.

## Tools

| Tool | Purpose |
|---|---|
| `grok_use_permissions` | Accessibility / Screen Recording |
| `grok_use_doctor` | Health + on-screen windows |
| `grok_use_list_windows` | `pid`, `window_id`, title, bounds |
| `grok_use_capture` | Screenshot + AX tree |
| `grok_use_click` | AX `element_index` or screenshot `x,y` |
| `grok_use_type` | AX set-value, else unicode to that pid |
| `grok_use_hotkey` | e.g. `cmd+l` |
| `grok_use_press_key` | `return`, `down`, `pagedown`, … |
| `grok_use_scroll` | Wheel on a list/dropdown (`x,y` or index) |

CLI: `./bin/grok-use list-windows`

## Safety

Do not type passwords, OTPs, card numbers, or API keys. Do not click payment or “Show key” UI. Recapture after every action.
