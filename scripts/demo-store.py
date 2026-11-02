#!/usr/bin/env python3
"""Write an invented account store for screenshots and demos.

Usage:
  python3 scripts/demo-store.py <dir>
  TOWER_SUPPORT_DIR=<dir> .build/debug/Tower panelshot docs/panel.png

Every account, number and email here is made up. Nothing is read from this Mac.
"""
import json
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


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    out = pathlib.Path(sys.argv[1])
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
    (out / "accounts.json").write_text(json.dumps(accounts, indent=2))
    (out / "known-accounts.json").write_text(json.dumps(sorted(
        a["email"] for k, a in accounts.items() if ":" not in k), indent=2))
    print(f"demo store written to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
