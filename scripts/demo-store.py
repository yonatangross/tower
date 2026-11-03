#!/usr/bin/env python3
"""Write an invented account store for screenshots and demos.

Usage:
  python3 scripts/demo-store.py <dir> [--active <nick>]
  TOWER_DEMO=1 TOWER_SUPPORT_DIR=<dir> .build/debug/Tower panelshot docs/panel.png
  TOWER_DEMO=1 TOWER_SUPPORT_DIR=<dir> .build/debug/Tower mcp

--active names the seat the demo is logged in as (default: work). The store gets an
invented credential (demo-credential.json) and an active-seat.json bound to it by the
SHA-256 of that token, so Tower shows a verified active seat. TOWER_DEMO=1 makes Tower
read the credential from that file and never from the Keychain or the network; without
TOWER_DEMO, Tower would compare the record with this Mac's real login and call the
seat unverified.

Every account, number, email and token here is made up. Nothing is read from this Mac.
"""
import argparse
import hashlib
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
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("dir")
    parser.add_argument("--active", default="work", help="nickname of the demo's logged-in seat")
    args = parser.parse_args()
    out = pathlib.Path(args.dir)
    out.mkdir(parents=True, exist_ok=True)
    accounts = {
        "work@example.com": claude("work", 22, 41, 3.5, 70),
        "side@example.com": claude("side", 0, 12, 5, 110),
        "lab@example.com": claude("lab", 81, 88, 1.2, 30),
    }
    active_email = f"{args.active}@example.com"
    if active_email not in accounts:
        print(f"--active must be one of: {', '.join(a['nickname'] for a in accounts.values())}", file=sys.stderr)
        return 2
    codex = {
        "email": "work@example.com", "nickname": "work", "plan": "pro", "provider": "codex",
        "weeklyPct": 35, "weeklyResetsAt": ref(52 * 3600), "capturedAt": ref(-300), "notified": {}, "scoped": [],
    }
    accounts["codex:work@example.com"] = codex
    (out / "accounts.json").write_text(json.dumps(accounts, indent=2))
    (out / "known-accounts.json").write_text(json.dumps(sorted(
        a["email"] for k, a in accounts.items() if ":" not in k), indent=2))

    # The invented login and the verification record bound to it, the way a real
    # profile fetch writes active-seat.json (VerifiedActiveSeat in Core.swift).
    token = f"demo-token-{args.active}"
    (out / "demo-credential.json").write_text(json.dumps(
        {"accessToken": token, "emailHint": active_email}, indent=2))
    (out / "active-seat.json").write_text(json.dumps({
        "email": active_email,
        "verifiedAt": ref(0),
        "tokenDigest": hashlib.sha256(token.encode()).hexdigest(),
    }, indent=2))
    print(f"demo store written to {out} (active seat: {args.active})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
