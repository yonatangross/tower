# Multi-account playbook

How Tower sees several Claude Code seats, plus Codex and Cursor, and how to
switch between seats quickly.

Check first that running several subscriptions fits each provider's terms.
Tower does not decide that for you.

## Claude Code seats

Claude Code keeps exactly one live credential at a time. Tower works with that:

- It reads usage for the seat you are signed into now, every 5 minutes, on
  wake, and when you open the panel.
- When it verifies a seat, it keeps that seat's access token in its own
  Keychain item, so it can still read the seat after you switch away, until the
  token expires.
- A seat it has never seen shows as **never captured** (or as an empty slot if
  you listed it in `known-accounts.json`). Sign into it once with `/login`.

| Row says | Meaning | Do |
| --- | --- | --- |
| a percent, green to red | live reading, at most 15 minutes old | nothing |
| `unknown since <age>` | the last reading is older than 15 minutes | open the panel, or switch into it |
| `needs login` | the stored token expired | `/login` into that account once |
| `active seat unknown` | Tower cannot prove which seat the CLI holds | open the panel after a `/login`, or run `tower status` |

### Switching in two clicks

1. Add a passkey to each account (in the account's security settings).
2. Keep one browser profile per account.
3. When Tower says switch, run `/login` in Claude Code, pick that browser
   profile, confirm the passkey.

`tower rotate` prints which seat to sign into next and, when it knows it, the
browser profile. It never logs in for you.

### Short names

```bash
echo '{"work@example.com": "work"}' > ~/Library/Application\ Support/Tower/nicknames.json
```

Without it, each seat is named by the first 6 characters of its email.

## Codex

Tower reads the Codex account you are signed into from `~/.codex/auth.json`
(email and plan) and its rate limits from Codex's own session logs. No setup.
Only the signed in Codex account shows; switching Codex accounts is done in
Codex.

## Cursor

Cursor needs a one-time **Connect Cursor** in Tower. Open the Cursor row and click
**Connect Cursor**: Cursor's sign-in page opens in your browser, and when you finish
there Tower stores its own sign-in in its own Keychain item. Tower then reads the two
monthly model pools (**Cursor Models** and **Other Models**) with that sign-in and
renews it about a week before it expires.

Tower never uses or touches the Cursor app's own sign-in, so connecting Tower can never
sign you out of Cursor. Signing in again in the Cursor app does not change Tower's row.
When Tower's sign-in ends or is refused, the row reads `Connect Cursor in Tower` and the
same button fixes it.

## How Tower ranks

Only live readings compete. The seat with the most room on its binding window
(the fuller of the 5 hour and weekly windows) ranks first; ties break by
nickname. Codex is never suggested for a Claude Code lane. Money rows
(OpenRouter) never compete for a seat.
