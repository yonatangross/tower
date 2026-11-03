#!/usr/bin/env python3
"""Write an invented account store for screenshots and demos.

Usage:
  python3 scripts/demo-store.py <dir> [--pi]
  TOWER_SUPPORT_DIR=<dir> .build/debug/Tower panelshot docs/panel.png

--pi also writes an invented Pi directory at <dir>/pi (settings on openrouter, three
session files with costs this month) and an OpenRouter balance row, so
  TOWER_SUPPORT_DIR=<dir> TOWER_PI_DIR=<dir>/pi .build/debug/Tower panelshot pi.png
renders the Pi lane with its share of the OpenRouter budget. No auth.json is written:
Tower never reads Pi's secrets file, so a demo has no reason to have one.

Every account, number and email here is made up. Nothing is read from this Mac.
"""
import datetime
import json
import os
import pathlib
import sys
import time

APPLE_EPOCH_OFFSET = 978307200  # Swift's default Date coding counts from 2001-01-01


def ref(seconds_from_now: float) -> float:
    return time.time() - APPLE_EPOCH_OFFSET + seconds_from_now


def claude(nick: str, five: float, week: float, five_reset_h: float, week_reset_h: float) -> dict:
    return {
        "email": f"{nick}@example.com",
        "nickname": nick,
        "plan": "max",
        "tier": "default_claude_max_20x",
        "fiveHourPct": five,
        "weeklyPct": week,
        "fiveHourResetsAt": ref(five_reset_h * 3600),
        "weeklyResetsAt": ref(week_reset_h * 3600),
        "capturedAt": ref(-120),
        "notified": {},
        "scoped": [],
    }


def pi_turn(entry_id: str, at: datetime.datetime, usd: float) -> str:
    """One assistant entry in the shape pi-coding-agent 1.5.0 writes."""
    iso = at.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    return json.dumps({
        "type": "message", "id": entry_id, "parentId": None, "timestamp": iso,
        "message": {
            "role": "assistant", "provider": "openrouter", "model": "demo/coder-large",
            "usage": {
                "input": 1200, "output": 300, "cacheRead": 0, "cacheWrite": 0, "reasoning": 0,
                "totalTokens": 1500,
                "cost": {"input": usd * 0.6, "output": usd * 0.4, "cacheRead": 0, "cacheWrite": 0,
                         "total": usd, "totalFromProvider": usd},
            },
            "timestamp": int(at.timestamp() * 1000),
        },
    })


def write_pi(root: pathlib.Path) -> None:
    """Invented Pi data: dated inside the current local month, so the row has spend."""
    now = datetime.datetime.now().astimezone()
    month_start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    root.mkdir(parents=True, exist_ok=True)
    (root / "settings.json").write_text(json.dumps(
        {"defaultProvider": "openrouter", "defaultModel": "demo/coder-large"}, indent=2))
    sessions = {
        "--demo-app--/2026-demo-a.jsonl": [(month_start, 3.40), (month_start, 1.15)],
        "--demo-app--/2026-demo-b.jsonl": [(now - datetime.timedelta(hours=3), 0.82)],
        "--demo-site--/2026-demo-c.jsonl": [(now - datetime.timedelta(minutes=20), 0.47)],
    }
    for n, (rel, turns) in enumerate(sessions.items()):
        path = root / "sessions" / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        lines = [pi_turn(f"demo-{n}-{i}", max(at, month_start), usd)
                 for i, (at, usd) in enumerate(turns)]
        path.write_text("\n".join(lines) + "\n")
        # Modified now, so the month filter reads it.
        os.utime(path, None)


def main() -> int:
    args = sys.argv[1:]
    with_pi = "--pi" in args
    args = [a for a in args if a != "--pi"]
    if len(args) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    out = pathlib.Path(args[0])
    out.mkdir(parents=True, exist_ok=True)
    accounts = {
        "work@example.com": claude("work", 22, 41, 3.5, 70),
        "side@example.com": claude("side", 0, 12, 5, 110),
        "lab@example.com": claude("lab", 81, 88, 1.2, 30),
    }
    codex = {
        "email": "work@example.com", "nickname": "work", "plan": "pro", "provider": "codex",
        "weeklyPct": 35, "weeklyResetsAt": ref(52 * 3600), "capturedAt": ref(-300), "notified": {}, "scoped": [],
    }
    accounts["codex:work@example.com"] = codex
    if with_pi:
        # $25 + $25 added, $31.60 left: the MONEY band and Pi's share both read this row.
        accounts["openrouter:openrouter@local"] = {
            "email": "openrouter@local", "nickname": "openrouter", "plan": "balance",
            "provider": "openrouter", "balanceUSD": 31.60, "availablePct": 63.2,
            "capturedAt": ref(-60), "notified": {}, "scoped": [],
        }
        write_pi(out / "pi")
    (out / "accounts.json").write_text(json.dumps(accounts, indent=2))
    (out / "known-accounts.json").write_text(json.dumps(sorted(
        a["email"] for k, a in accounts.items() if ":" not in k), indent=2))
    print(f"demo store written to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
