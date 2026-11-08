# MCP playbook

`tower mcp` is a stdio MCP server inside the Tower binary. Any agent that speaks
MCP (Claude Code, Codex, Cursor and others) can read the same numbers from it.
The full tool list is [docs/mcp-surface.md](../mcp-surface.md).

## 1. Register it

Install the app and the `~/.local/bin/tower` link first
([setup playbook](setup.md)).

Claude Code, for one project (`.mcp.json` at the repo root):

```json
{
  "mcpServers": {
    "tower": { "command": "${HOME}/.local/bin/tower", "args": ["mcp"] }
  }
}
```

Claude Code, for every project:

```bash
claude mcp add --scope user tower -- ~/.local/bin/tower mcp
```

Codex (`~/.codex/config.toml`):

```toml
[mcp_servers.tower]
command = "/Users/<you>/.local/bin/tower"
args = ["mcp"]
```

Cursor (`~/.cursor/mcp.json`): the same JSON block as Claude Code, with the
full path in place of `${HOME}`.

## 2. Check it

```bash
tower mcp --self-test
```

It lists the tools and reads one account; a non zero exit means the server is
broken. Reads never touch the Keychain, so no dialog can appear while an agent
asks.

## 3. Ask it

Plain prompts that work, and the tool each one lands on:

| Ask your agent | Tool |
| --- | --- |
| "How much is left on each of my accounts?" | `tower_room` |
| "Should I stay on this account or switch?" | `tower_advice` |
| "When does my weekly window reset?" | `tower_resets` |
| "Is any reading stale? How fresh is each one?" | `tower_freshness` |
| "Give me a rotation plan for the next login." | `tower_rotate` |
| "Show me the Tower panel." | `tower_panelshot` (an image) |

Three built in prompts carry the questions a multi-agent setup asks:
`pick_account_for_lane`, `promote_room_check` and `rotation_brief`.

## 4. Use it in an agent's instructions

A line for a `CLAUDE.md` or `AGENTS.md`:

```
Before a long task, call tower_room. If the active seat has under 20 percent
room on its binding window, stop and tell me which seat tower_advice names.
```

## What it will not do

- Log you in to any account. That is always your `/login`.
- Send anything off your Mac except the providers' own usage calls.
- Write without saying so: the four write tools (`tower_refresh`,
  `tower_forget_seats`, `tower_config_set`, `tower_alert_ack`) are annotated,
  and refused with a named code when a precondition fails.
