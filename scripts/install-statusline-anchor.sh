#!/usr/bin/env bash

# Opt-in installer for the statusline session anchor Tower reads to name a
# session's account (scripts/statusline-session-anchor.patch).
#
# Why this exists: `claude agents`, the ~/.claude/sessions registry and, on
# Claude Code 2.1.283, the transcript carry no account for a session. The
# statusline payload is the one place that pairs session_id with the
# rate_limits reset anchors. The patch makes the statusline publish that pair to
# <config>/session-anchors/<session_id>, and Tower matches it to an account the
# same way the statusline's own label does. Until this is applied, every
# session in Tower's SESSIONS list stays "account unknown", by design.
#
# Usage:
#   scripts/install-statusline-anchor.sh            report state, change nothing
#   scripts/install-statusline-anchor.sh --apply    patch, keeping a backup
#   scripts/install-statusline-anchor.sh --restore  undo the patch
#
# Target: $STATUSLINE_TARGET, else ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/statusline-command.sh.
# Run it from a normal terminal: Claude Code denies writes under ~/.claude.
set -euo pipefail

mode="check"
case "${1:-}" in
  "") ;;
  --check) ;;
  --apply) mode="apply" ;;
  --restore) mode="restore" ;;
  *) echo "Usage: scripts/install-statusline-anchor.sh [--check|--apply|--restore]" >&2; exit 2 ;;
esac

here="$(cd "$(dirname "$0")" && pwd)"
patch_file="$here/statusline-session-anchor.patch"
target="${STATUSLINE_TARGET:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/statusline-command.sh}"
backup="$target.pre-session-anchor"
marker="HQ_STATUSLINE_SESSION_ANCHOR"

[ -f "$patch_file" ] || { echo "missing patch: $patch_file" >&2; exit 1; }
[ -f "$target" ] || { echo "no statusline at $target" >&2; exit 1; }

applied=0
grep -q "$marker" "$target" && applied=1

applies() {
  patch --dry-run --silent "$@" "$target" <"$patch_file" >/dev/null 2>&1
}

case "$mode" in
  check)
    if [ "$applied" -eq 1 ]; then
      echo "applied: $target already writes session anchors"
    elif applies; then
      echo "applicable: run with --apply to patch $target"
    else
      echo "conflict: the patch does not apply cleanly to $target" >&2
      exit 1
    fi
    ;;
  apply)
    if [ "$applied" -eq 1 ]; then
      echo "already applied: $target"
      exit 0
    fi
    applies || { echo "conflict: the patch does not apply cleanly to $target, nothing changed" >&2; exit 1; }
    [ -e "$backup" ] && { echo "refusing: $backup already exists, move it aside first" >&2; exit 1; }
    tmp="$target.anchor.$$"
    trap 'rm -f "$tmp"' EXIT
    cp -p "$target" "$backup"
    cp -p "$target" "$tmp"
    patch --silent "$tmp" <"$patch_file" >/dev/null
    bash -n "$tmp" || { echo "patched statusline fails bash -n, nothing changed" >&2; exit 1; }
    mv -f "$tmp" "$target"
    echo "applied: $target (backup at $backup)"
    ;;
  restore)
    if [ "$applied" -eq 0 ]; then
      echo "not applied: $target has no session anchor block"
      exit 0
    fi
    # Reverse the patch when it still applies, so edits made since survive;
    # fall back to the backup taken by --apply.
    if applies -R; then
      tmp="$target.anchor.$$"
      trap 'rm -f "$tmp"' EXIT
      cp -p "$target" "$tmp"
      patch -R --silent "$tmp" <"$patch_file" >/dev/null
      mv -f "$tmp" "$target"
      rm -f "$backup"
      echo "restored: reversed the patch in $target"
    elif [ -f "$backup" ]; then
      mv -f "$backup" "$target"
      echo "restored: $target from $backup"
    else
      echo "cannot restore: the patch does not reverse cleanly and $backup is missing" >&2
      exit 1
    fi
    ;;
esac
