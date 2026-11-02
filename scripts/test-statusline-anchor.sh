#!/usr/bin/env bash

# Tests scripts/install-statusline-anchor.sh and the block it installs, against
# a synthetic statusline that carries only the patch's context lines. The real
# statusline lives in the operator's ~/.claude and never enters this repo.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
installer="$here/install-statusline-anchor.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
check() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$3] got [$2]"; fail=1; fi
}

target="$work/statusline-command.sh"
cat >"$target" <<'EOF'
#!/usr/bin/env bash
CFG="$FIXTURE_CFG"; sid="$FIXTURE_SID"; r5="$FIXTURE_R5"; r7="$FIXTURE_R7"; now=1790000000
nick="x"; acct=""; amark=""; acol=""; DIM=""
case "" in
  *) : ;;
esac
[ -n "$nick" ] || { acct="?"; amark=""; acol="$DIM"; }

# ── dirty count, 10s cache per repo root ───────────────────────────────────
# `git status --porcelain` measured at 62-90ms on a large repo (an earlier comment
# here claimed ~33ms; that was wrong and understated the cost this cache exists to
echo rendered
EOF
original="$(cat "$target")"
export STATUSLINE_TARGET="$target"

check "check reports applicable" "$(bash "$installer")" "applicable: run with --apply to patch $target"
bash "$installer" --apply >/dev/null
check "apply adds the block" "$(grep -c HQ_STATUSLINE_SESSION_ANCHOR "$target")" "2"
check "apply keeps a backup" "$(cat "$target.pre-session-anchor")" "$original"
check "apply is idempotent" "$(bash "$installer" --apply)" "already applied: $target"

run() {
  FIXTURE_CFG="$work/cfg" FIXTURE_SID="$1" FIXTURE_R5="$2" FIXTURE_R7="$3" bash "$target"
}
check "render output unchanged" "$(run sess-1 2000010800 2000500000)" "rendered"
check "anchor record" "$(cat "$work/cfg/session-anchors/sess-1")" "2000010800|2000500000|1790000000"
run sess-2 "" "" >/dev/null
check "no anchor before rate limits" "$([ -e "$work/cfg/session-anchors/sess-2" ] && echo yes || echo no)" "no"
run "../escape" 2000010800 "" >/dev/null
check "unsafe session id refused" "$([ -e "$work/cfg/escape" ] && echo yes || echo no)" "no"
run sess-1 2000028800 2000500000 >/dev/null
check "a new pair rewrites the record" "$(cat "$work/cfg/session-anchors/sess-1")" "2000028800|2000500000|1790000000"
HQ_STATUSLINE_SESSION_ANCHOR=0 FIXTURE_CFG="$work/cfg" FIXTURE_SID=sess-3 FIXTURE_R5=1 FIXTURE_R7="" bash "$target" >/dev/null
check "opt out writes nothing" "$([ -e "$work/cfg/session-anchors/sess-3" ] && echo yes || echo no)" "no"

bash "$installer" --restore >/dev/null
check "restore reverses the patch" "$(cat "$target")" "$original"
check "restore drops the backup" "$([ -e "$target.pre-session-anchor" ] && echo yes || echo no)" "no"
check "restore twice is a no-op" "$(bash "$installer" --restore)" "not applied: $target has no session anchor block"

printf 'unrelated\n' >"$target"
if bash "$installer" --apply >/dev/null 2>&1; then r=0; else r=$?; fi
check "a conflicting statusline is refused" "$r" "1"
check "a refused apply changes nothing" "$(cat "$target")" "unrelated"

exit "$fail"
