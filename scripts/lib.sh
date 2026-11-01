# shellcheck shell=bash
# Shared helpers for the Order Desk demo scripts. Sourced, not run.
set -euo pipefail

if [ -t 1 ]; then
  BOLD=$'\e[1m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RED=$'\e[31m'; DIM=$'\e[2m'; RESET=$'\e[0m'
else
  BOLD=''; GREEN=''; YELLOW=''; RED=''; DIM=''; RESET=''
fi

step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RESET"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*"; WARNINGS=$((${WARNINGS:-0} + 1)); }
info() { printf '  %s%s%s\n' "$DIM" "$*" "$RESET"; }
die()  { printf '  %s✗ %s%s\n' "$RED" "$*" "$RESET" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required. ${2:-}"
}

# Sets REPO (owner/name, as GitHub spells it), OWNER and NAME.
resolve_repo() {
  if [ -z "${REPO:-}" ]; then
    REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) \
      || die "Run this inside a clone of your demo repository, or set REPO=owner/name."
  fi
  REPO=$(gh api "repos/$REPO" --jq .full_name 2>/dev/null) || die "Cannot read repository $REPO with the signed-in GitHub CLI account."
  OWNER=${REPO%%/*}
  NAME=${REPO#*/}
}

require_admin() {
  [ "$(gh api "repos/$REPO" --jq .permissions.admin)" = "true" ] \
    || die "The signed-in GitHub CLI account ($(gh api user --jq .login)) needs admin rights on $REPO."
}

confirm() {
  [ "${YES:-0}" = "1" ] && return 0
  printf '%s [y/N] ' "$1"
  read -r answer
  [ "$answer" = "y" ] || [ "$answer" = "Y" ] || die "Stopped. Nothing else was changed."
}

ruleset_id() {
  gh api "repos/$REPO/rulesets" --jq '.[] | select(.name == "Protect main") | .id' 2>/dev/null | head -n 1
}

# Runs a command with the "Protect main" ruleset temporarily disabled, then turns it back on.
with_ruleset_paused() {
  local id
  id=$(ruleset_id)
  if [ -z "$id" ]; then
    "$@"
    return
  fi
  gh api -X PUT "repos/$REPO/rulesets/$id" -f enforcement=disabled --silent
  info "Ruleset \"Protect main\" paused"
  # shellcheck disable=SC2064
  trap "gh api -X PUT 'repos/$REPO/rulesets/$id' -f enforcement=active --silent && echo '  Ruleset \"Protect main\" active again'" EXIT
  "$@"
  gh api -X PUT "repos/$REPO/rulesets/$id" -f enforcement=active --silent
  trap - EXIT
  info "Ruleset \"Protect main\" active again"
}
