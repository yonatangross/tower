#!/usr/bin/env bash
# strict-mode: opt-out sourced library; both callers (build-app.sh, install.sh) set -euo pipefail
# TOWER_SIGNED is this library's result, read by the sourcing script.
# shellcheck disable=SC2034
# Sourced, not run: build-app.sh and install.sh share this signing rule (#121).
#
# Prefer a self-signed code-signing identity named "Tower Dev" when this machine has one
# (README "Signing" has the one-time steps to create it). A stable identity gives every
# build the same designated requirement, so a Tower-owned Keychain item written by one
# build stays readable by the next and never prompts (#68). Ad-hoc is the fallback, and
# what CI and every release artifact carry: an ad-hoc signature is new per build, so an
# owned item's ACL refuses the next build.
#
# #121: build-app.sh already signed with Tower Dev, but install.sh --from-artifact and
# update.sh copied the ad-hoc CI bundle into ~/Applications as it came, so every update
# changed the designated requirement and orphaned the owned seat items. install.sh now
# re-signs a downloaded bundle through this same function.
#
# The identity is picked by SHA-1 so two certificates with the same name cannot make
# codesign ambiguous. Errors are printed, never swallowed.
#
# tower_sign_app <app-path> [adhoc-fallback: yes|no]
#   Sets TOWER_SIGNED to "Tower Dev", "ad-hoc" or "" (unsigned or left as it was).
#   With the fallback "no", a machine without the identity leaves the bundle's existing
#   signature untouched (install.sh: the artifact is already ad-hoc signed).

TOWER_SIGN_IDENTITY_NAME="Tower Dev"

tower_sign_identity_hash() {
  local identities
  if identities="$(security find-identity -v -p codesigning 2>&1)"; then
    printf '%s\n' "$identities" |
      awk -v want="\"$TOWER_SIGN_IDENTITY_NAME\"" 'index($0, want) { print $2; exit }'
  else
    echo "   NOTE: security find-identity failed: $identities" >&2
  fi
}

tower_sign_app() {
  local app="$1" adhoc_fallback="${2:-yes}" sign_hash
  TOWER_SIGNED=""
  sign_hash="$(tower_sign_identity_hash)"
  if [ -n "$sign_hash" ]; then
    echo "==> codesign with \"$TOWER_SIGN_IDENTITY_NAME\" ($sign_hash)"
    if codesign --force --timestamp=none --sign "$sign_hash" "$app"; then
      TOWER_SIGNED="$TOWER_SIGN_IDENTITY_NAME"
      return 0
    fi
    echo "   WARNING: codesign with \"$TOWER_SIGN_IDENTITY_NAME\" failed (see error above)," >&2
    echo "   so Tower-owned Keychain items will refuse this build once" >&2
  fi
  if [ "$adhoc_fallback" != "yes" ]; then
    echo "==> keeping the bundle's own signature (no valid \"$TOWER_SIGN_IDENTITY_NAME\" identity, see README \"Signing\")"
    return 0
  fi
  echo "==> ad-hoc codesign (no valid \"$TOWER_SIGN_IDENTITY_NAME\" code-signing identity, see README \"Signing\")"
  if codesign --force --sign - "$app"; then
    TOWER_SIGNED="ad-hoc"
  else
    echo "   WARNING: codesign failed (see error above). The app still runs unsigned." >&2
  fi
}
