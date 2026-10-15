# AI tools and the command line

Clarishot can be driven by AI assistants (through an MCP server), by scripts (through the `clarishot`
command) and by launchers (through `clarishot://` links). All three talk to the Clarishot app that's
already running, so captures use its Screen Recording permission.

- [Turning it on](#turning-it-on)
- [MCP server for AI tools](#mcp-server-for-ai-tools)
- [The `clarishot` command](#the-clarishot-command)
- [`clarishot://` links](#clarishot-links)
- [How it works](#how-it-works)
- [Security](#security)

## Turning it on

Open **Preferences → Advanced → AI Tools & Command Line** and switch on
**Allow AI tools & command line**. It's off by default.

The command-line tool ships inside the app at:

```
/Applications/Clarishot.app/Contents/Helpers/clarishot
```

**Install "clarishot" Command** in the same section links it into `~/.local/bin`, so you can type
`clarishot` in Terminal (add `~/.local/bin` to your `PATH` if it isn't already).

## MCP server for AI tools

[MCP](https://modelcontextprotocol.io) is the standard way AI apps connect to local tools.
`clarishot mcp` runs an MCP server over standard input/output.

### Claude Code

```bash
claude mcp add --scope user clarishot -- /Applications/Clarishot.app/Contents/Helpers/clarishot mcp
```

Start a new Claude Code session afterwards. **Copy Command** in Preferences copies this line for you.

### ChatGPT Codex (app and command line)

```bash
codex mcp add clarishot -- /Applications/Clarishot.app/Contents/Helpers/clarishot mcp
```

The Codex app and the `codex` command-line tool share this setting. Start a new session afterwards.
The ChatGPT chat app itself only connects to online MCP servers, so it can't use Clarishot directly.

### Claude Desktop, Cursor and other MCP apps

Add this to the app's MCP configuration (**Copy JSON** in Preferences copies it):

```json
{
  "mcpServers": {
    "clarishot": {
      "command": "/Applications/Clarishot.app/Contents/Helpers/clarishot",
      "args": ["mcp"]
    }
  }
}
```

### Tools

| Tool | What it does |
|---|---|
| `clarishot_status` | Checks Clarishot is running and allowed to capture |
| `list_displays` | Screens with index, size and position |
| `list_windows` | Visible windows with id, app, title and frame (optional `app` filter) |
| `take_screenshot` | Takes a screenshot and returns the saved PNG path **and the image** |
| `read_text` | Text and QR codes from an image file, a screen area, or an area the user selects |
| `recent_captures` | Recent screenshots and recordings from Capture History |
| `open_capture` | Opens an image in Annotate, as a pin, or as a preview card |
| `start_recording` / `stop_recording` | Starts the recording flow; stopping returns the saved file |

`take_screenshot` modes:

| `mode` | Uses | Notes |
|---|---|---|
| `fullscreen` (default) | `display` | Screen index from `list_displays` |
| `area` | `x`, `y`, `width`, `height` | Points, top-left origin, like `list_windows` |
| `window` | `window_id` or `app` | `app` matches the name or bundle id |
| `interactive` | | The user drags an area |
| `smart` | | The user clicks one UI element |
| `cutout` | optional area | The subject of an area with its background removed |

Set `show: true` to also show the capture in Clarishot (preview card and after-capture actions), and
`include_image: false` to return only the path.

Example prompts:
- *"List my open windows with Clarishot."*
- *"Take a screenshot of the Safari window and summarise it."*
- *"Read the text in the top-left 600 × 400 of my screen."*

## The `clarishot` command

```
clarishot status                       Is Clarishot reachable, and is screen recording allowed?
clarishot displays                     List screens (index, size, position)
clarishot windows [APP]                List visible windows (id, app, title, frame)
clarishot screenshot [options]         Take a screenshot; prints the PNG path
    --fullscreen [--display N]         Whole screen (default)
    --area X,Y,W,H                     Points, top-left origin
    --window ID | --app NAME           One window
    --interactive                      Let you drag an area
    --smart                            Let you click one element of an app
    --cutout                           Cut out the subject of an area (with --area, or drag)
    --show                             Also show it in Clarishot
clarishot ocr [--path FILE | --area X,Y,W,H | --interactive]
clarishot history [--limit N] [--kind screenshot|recording|gif]
clarishot open FILE [--pin | --preview]
clarishot record start | stop
clarishot mcp                          Run as an MCP server over stdio
```

Add `--json` to any command for machine-readable output.

Examples:

```bash
# Screenshot Safari and open it in the editor
clarishot open "$(clarishot screenshot --app Safari)"

# Copy the text of an area
clarishot ocr --area 100,100,800,400 | pbcopy

# The five newest screenshots as JSON
clarishot history --limit 5 --kind screenshot --json
```

Screenshots taken this way are saved to
`~/Library/Application Support/Clarishot/Agent Captures/` and added to Capture History. Each one shows a
short "Screenshot taken by an AI tool" message on screen.

## `clarishot://` links

Turn on **Preferences → Advanced → API → Allow URL scheme API**. Then any app can open links such as:

| Link | Action |
|---|---|
| `clarishot://capture-area` | Capture Area |
| `clarishot://capture-window` | Capture Window |
| `clarishot://capture-fullscreen` | Capture Fullscreen |
| `clarishot://capture-previous-area` | Capture Previous Area |
| `clarishot://smart-capture` | Smart Capture |
| `clarishot://all-in-one` | All-In-One |
| `clarishot://scrolling-capture` | Scrolling Capture |
| `clarishot://capture-text` | Capture Text (OCR) |
| `clarishot://self-timer` | Self-Timer |
| `clarishot://record-screen` | Start / stop recording |
| `clarishot://open-history` | Capture History |
| `clarishot://open-settings` | Preferences |

Any shortcut action name works, with or without dashes (`capture-area` and `capturearea` are the same).

## How it works

The app listens on a Unix socket at `~/Library/Application Support/Clarishot/agent.sock`.
Each connection sends one line of JSON and gets one line back:

```json
{"method": "screenshot", "params": {"mode": "window", "app": "Safari"}}
{"ok": true, "result": {"path": "…/Clarishot 2026-10-14 at 09.41.07.png", "width": 2560, "height": 1410, "scale": 2, "mode": "window"}}
```

Methods: `status`, `displays`, `windows`, `screenshot`, `ocr`, `history`, `open`, `record_start`,
`record_stop`. Errors come back as `{"ok": false, "error": "…"}`. The `clarishot` command and the MCP
server are thin wrappers around these calls; see `Sources/ClarishotCLI/main.swift` and
`Sources/Clarishot/Agent/`.

## Security

- **Off by default.** Nothing listens until you switch it on.
- **Only your user account** can connect: the socket's folder and file are private to you, and other
  users' connections are refused.
- **Files are read by the caller.** When you pass a file (`ocr --path`, `open`), the `clarishot` command
  reads it with its own permissions and sends the image. Clarishot never opens paths it's given, so it
  can't be used to read files the caller couldn't.
- **Visible.** Every capture made this way shows a message and appears in Capture History.

While it's on, any program you run could ask for a screenshot. Turn it off when you don't need it.
