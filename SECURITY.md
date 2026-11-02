# Security

## Reporting a vulnerability

Please report security problems privately through GitHub's
**Report a vulnerability** button on this repository (Security tab), not in a
public issue. Expect a first answer within a week.

## What Tower touches

Tower handles credentials, so it helps to know exactly what it reads and writes:

| Item | Access |
| --- | --- |
| Claude Code credential (`Claude Code-credentials` in the login Keychain) | read, through Apple's `/usr/bin/security` |
| Tower seat items in the login Keychain | read and write, only while **Remember Claude seats** is on; **Forget** deletes them |
| `~/.claude.json`, Claude Code settings and transcripts | read |
| Codex and Cursor local auth state | read |
| `~/Library/Application Support/HQClaudeLimits/` | read and write (usage store, settings) |
| `$CLAUDE_CONFIG_DIR/quota-cache.json` (default `~/.claude`) | write (a copy of the usage store) |
| Network | the providers' own APIs only: Anthropic, OpenAI, Cursor, OpenRouter |

Tower never stores or presents a Claude refresh token and never renews a token.
It never stores the OpenRouter key; it runs your configured command or reads
`OPENROUTER_API_KEY` on each poll.

## Supported versions

Only the latest release gets fixes.
