#!/usr/bin/env bash
# Puts the floor's private-lanes list where Tower's lane-cost recorder reads it
# (~/.floor/private-lanes.json), and reads it back so a missing or wrong file is loud.
#
#   install-private-lanes.sh --from <source.json> [--home <dir>]
#   install-private-lanes.sh --check [--home <dir>] [--expect <folder>]... [--against <source.json>]
#
# The file is a JSON object with a private_lanes list of folders (a leading ~ is the home
# directory); other keys are ignored. Install writes a temp file beside the target and
# moves it into place, then reads the DESTINATION back from disk (the install's own success
# is not the receipt). A copy of a privacy list goes stale, so --check --against <source>
# compares the installed list with its source.
#
# Exit codes: 0 ok, 2 usage or missing source, 3 installed file missing, 4 unreadable or
# wrongly shaped (installed file or source), 5 an --expect folder is not in the list,
# 6 the installed list differs from --against.
set -euo pipefail

home="$HOME"
mode=""
from=""
against=""
expect_list=""
nl=$'\n'

usage() {
  echo "usage: install-private-lanes.sh --from <source.json> [--home <dir>]" >&2
  echo "       install-private-lanes.sh --check [--home <dir>] [--expect <folder>]... [--against <source.json>]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --from) [ "$#" -ge 2 ] || usage; mode="install"; from="$2"; shift 2 ;;
    --check) mode="check"; shift ;;
    --home) [ "$#" -ge 2 ] || usage; home="$2"; shift 2 ;;
    --expect) [ "$#" -ge 2 ] || usage; expect_list="$expect_list$2$nl"; shift 2 ;;
    --against) [ "$#" -ge 2 ] || usage; against="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done
[ -n "$mode" ] || usage

dest_dir="$home/.floor"
dest="$dest_dir/private-lanes.json"

# Prints the folders of a policy file, one per line, with a leading ~ expanded to $home.
# Exit 4 when the file is not JSON or has no list of strings under private_lanes.
folders_of() {
  python3 -I -c '
import json, sys
path, home = sys.argv[1], sys.argv[2]
try:
    lanes = json.load(open(path))["private_lanes"]
    assert isinstance(lanes, list) and all(isinstance(x, str) for x in lanes)
except Exception as e:
    sys.stderr.write("%s is unreadable as a private-lanes policy: %s\n" % (path, e))
    sys.exit(4)
for x in lanes:
    print(home + x[1:] if x == "~" or x.startswith("~/") else x)
' "$1" "$home"
}

expand() {
  if [ "$1" = "~" ]; then
    echo "$home"
  elif [ "${1:0:2}" = "~/" ]; then
    echo "$home${1:1}"
  else
    echo "$1"
  fi
}

# Whether the exact line given second is one of the lines given first.
in_list() {
  local item
  local saved_ifs="$IFS"
  IFS="$nl"
  set -f
  for item in $1; do
    if [ "$item" = "$2" ]; then
      set +f
      IFS="$saved_ifs"
      return 0
    fi
  done
  set +f
  IFS="$saved_ifs"
  return 1
}

# One read of the destination, separate from whatever wrote it. Sets the variable installed.
readback() {
  if [ ! -e "$dest" ]; then
    echo "private-lanes policy MISSING: $dest does not exist." >&2
    echo "Tower's lane-cost recorder records nothing until it does. Install it with:" >&2
    echo "  scripts/install-private-lanes.sh --from <the floor's private-lanes.json>" >&2
    return 3
  fi
  installed="$(folders_of "$dest")" || return 4
  local want full f drift source_folders old_ifs count
  old_ifs="$IFS"
  IFS="$nl"
  set -f
  for want in $expect_list; do
    full="$(expand "$want")"
    if ! in_list "$installed" "$full"; then
      echo "private-lanes policy does not name $full: $dest has no such folder." >&2
      return 5
    fi
  done
  set +f
  IFS="$old_ifs"
  if [ -n "$against" ]; then
    source_folders="$(folders_of "$against")" || return 4
    drift=0
    old_ifs="$IFS"
    IFS=$'\n'
    set -f
    for f in $source_folders; do
      if ! in_list "$installed" "$f"; then
        echo "private-lanes policy DRIFT: $f is in $against but not in the installed copy $dest." >&2
        drift=1
      fi
    done
    for f in $installed; do
      if ! in_list "$source_folders" "$f"; then
        echo "private-lanes policy DRIFT: $f is in the installed copy but not in $against." >&2
        drift=1
      fi
    done
    set +f
    IFS="$old_ifs"
    [ "$drift" -eq 0 ] || return 6
  fi
  count=0
  if [ -n "$installed" ]; then
    count="$(printf '%s\n' "$installed" | wc -l | tr -d ' ')"
  fi
  echo "private-lanes policy OK: $dest names $count folder(s):"
  printf '%s\n' "$installed"
  return 0
}

if [ "$mode" = "check" ]; then
  status=0
  readback || status=$?
  exit "$status"
fi

# install
if [ ! -r "$from" ]; then
  echo "install-private-lanes: source $from is not readable" >&2
  exit 2
fi
folders_of "$from" >/dev/null
mkdir -p "$dest_dir"
tmp="$(mktemp "$dest_dir/.private-lanes.tmp.XXXXXX")"
cp "$from" "$tmp"
chmod 644 "$tmp"
mv -f "$tmp" "$dest"
echo "installed $dest from $from"
status=0
readback || status=$?
exit "$status"
