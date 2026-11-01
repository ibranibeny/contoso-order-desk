#!/usr/bin/env bash
# Optional: push protection blocks a made-up "Contoso demo token" (Session 4, or Act 4 of the live demo).
#
# Works only when a custom secret pattern exists, which needs an organization-owned repository with
# GitHub Secret Protection. Create it first (Settings > Advanced Security > Custom patterns > New pattern):
#   Pattern name:   Contoso demo token
#   Secret format:  contoso_demo_[a-z0-9]{32}
#   Save and dry run, publish the pattern, then turn on push protection for it.
#
# The token below is invented. Never use a real credential for this demo, not even a revoked one.
# On stage you can also type the same commands yourself; this script runs them in a throwaway worktree.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
source scripts/lib.sh
need gh; need git
resolve_repo
confirm "Is the 'Contoso demo token' custom pattern published, with push protection on, for $REPO?"

WORK=$(mktemp -d)
cleanup() { git worktree remove --force "$WORK" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT
git fetch -q origin main
git worktree add -q --detach "$WORK" origin/main
cd "$WORK"
git switch -q -c demo/push-protection
printf 'ORDER_DESK_API_KEY=contoso_demo_%s\n' 0123456789abcdef0123456789abcdef > config.env
git add -f config.env
git commit -q -m "Add Order Desk configuration"

step "Pushing a commit that contains the made-up token"
if git push -u origin demo/push-protection; then
  git push -q origin --delete demo/push-protection || true
  die "The push was NOT blocked, so the custom pattern or push protection is not active. The branch was deleted again."
fi
ok "Push protection blocked the push. The message above names the secret type, the file and the line."
info "Do not bypass. The fix is to remove the secret from the commit: git rm --cached config.env && git commit --amend"
