#!/usr/bin/env bash
# Puts the repository back to the start of the demo, for the next rehearsal or session:
#   - closes open pull requests and issues (as "not planned"), except those labelled "keep"
#     (label a rehearsal Copilot pull request "keep" and convert it to a draft to keep it as a fallback)
#   - deletes branches created during the demo (keeps main, solution, fallback/* and demo/*)
#   - moves main back to the demo-start tag (the ruleset is paused for a moment and turned on again)
#
#   scripts/reset-demo.sh            # asks before changing anything
#   YES=1 scripts/reset-demo.sh      # no questions
#
# Afterwards: run scripts/prepare-security-prs.sh again, and optionally redeploy the starting point
# (Actions > CI/CD > Run workflow on main, then approve the deployment).
# Needs: gh signed in as a repository admin.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
source scripts/lib.sh
need gh
resolve_repo
require_admin

START=$(gh api "repos/$REPO/git/ref/tags/demo-start" --jq .object.sha 2>/dev/null) \
  || die "Tag demo-start not found. scripts/github-setup.sh creates it."
TYPE=$(gh api "repos/$REPO/git/ref/tags/demo-start" --jq .object.type)
[ "$TYPE" = "commit" ] || START=$(gh api "repos/$REPO/git/tags/$START" --jq .object.sha)
MAIN=$(gh api "repos/$REPO/git/ref/heads/main" --jq .object.sha)
KEEP='^(main|solution|fallback/.+|demo/.+)$'
# Head branches of pull requests labelled "keep" are kept too.
KEEP_HEADS=" $(gh pr list -R "$REPO" --state open --label keep --json headRefName --jq '[.[].headRefName] | join(" ")' 2>/dev/null) "

step "Reset $REPO to demo-start (${START:0:7})"
info "main is at ${MAIN:0:7}"
confirm "Close all open pull requests and issues, delete demo-time branches and move main back to demo-start?"

step "1/4 Pull requests"
for n in $(gh pr list -R "$REPO" --state open --limit 100 --json number,labels --jq '.[] | select([.labels[].name] | index("keep") | not) | .number'); do
  gh pr close "$n" -R "$REPO" --comment "Closed by scripts/reset-demo.sh after a rehearsal." >/dev/null && ok "Closed pull request #$n"
done

step "2/4 Issues"
for n in $(gh issue list -R "$REPO" --state open --limit 200 --json number,labels --jq '.[] | select([.labels[].name] | index("keep") | not) | .number'); do
  gh issue close "$n" -R "$REPO" --reason "not planned" --comment "Closed by scripts/reset-demo.sh after a rehearsal." >/dev/null && ok "Closed issue #$n"
done

step "3/4 Branches"
for b in $(gh api "repos/$REPO/branches" --paginate --jq '.[].name'); do
  if [[ ! "$b" =~ $KEEP ]] && [[ "$KEEP_HEADS" != *" $b "* ]]; then
    gh api -X DELETE "repos/$REPO/git/refs/heads/$b" --silent && ok "Deleted branch $b"
  fi
done

step "4/4 main"
if [ "$MAIN" = "$START" ]; then
  ok "main is already at demo-start"
else
  move_main() { gh api -X PATCH "repos/$REPO/git/refs/heads/main" -f sha="$START" -F force=true --silent; }
  with_ruleset_paused move_main
  ok "main moved back to demo-start (${START:0:7})"
fi

step "Done"
info "Project items stay on the board; archive them in the project if you want an empty board."
info "Next: scripts/prepare-security-prs.sh, then scripts/preflight.sh."
