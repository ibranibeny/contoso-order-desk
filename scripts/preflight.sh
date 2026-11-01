#!/usr/bin/env bash
# Read-only pre-flight check for the live demo. Run it the day before, 30 minutes before, and during the break.
# It changes nothing. Each line is ✓ ready, ! check by hand, or ✗ fix before the demo.
#
#   scripts/preflight.sh
#   WEBAPP_URL=https://<your-app>.azurewebsites.net scripts/preflight.sh   # if the app has a custom domain
set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
source scripts/lib.sh
set +e
need gh
resolve_repo
FAILS=0
bad() { printf '  %s✗%s %s\n' "$RED" "$RESET" "$*"; FAILS=$((FAILS + 1)); }
check() { if [ "$1" = "true" ]; then ok "$2"; else bad "$2 -> $3"; fi; }

step "Repository $REPO"
check "$(gh api "repos/$REPO" --jq .permissions.admin)" "You have admin rights" "some checks below need an admin"
for wf in ci-cd.yml dependency-review.yml copilot-setup-steps.yml; do
  gh api "repos/$REPO/contents/.github/workflows/$wf?ref=main" --silent >/dev/null 2>&1 \
    && ok "Workflow $wf on main" || bad "Workflow $wf missing on main -> add it from the repository's README instructions"
done
gh api "repos/$REPO/contents/.github/CODEOWNERS?ref=main" --jq .content 2>/dev/null | base64 -d 2>/dev/null | grep -q '^\*' \
  && ok "CODEOWNERS names an owner" || bad "CODEOWNERS has no owner -> run scripts/github-setup.sh"

START=$(gh api "repos/$REPO/git/ref/tags/demo-start" --jq .object.sha 2>/dev/null)
MAIN=$(gh api "repos/$REPO/git/ref/heads/main" --jq .object.sha 2>/dev/null)
if [ -z "$START" ]; then bad "Tag demo-start missing -> run scripts/github-setup.sh"
elif [ "$START" = "$MAIN" ]; then ok "main is at demo-start (${START:0:7})"
else warn "main (${MAIN:0:7}) is not at demo-start (${START:0:7}) -> scripts/reset-demo.sh if this is not intended"; fi

for b in fallback/order-lookup-api fallback/agent-lookup-page solution; do
  gh api "repos/$REPO/branches/$b" --silent >/dev/null 2>&1 && ok "Branch $b" \
    || bad "Branch $b missing -> create the repository with 'Include all branches', or push it from the template"
done
OPEN_ISSUES=$(gh issue list -R "$REPO" --state open --json number --jq 'length')
[ "$OPEN_ISSUES" = "0" ] && ok "No open issues (the demo creates them)" || warn "$OPEN_ISSUES open issue(s) -> close rehearsal issues (scripts/reset-demo.sh)"

step "Rules, security and environment"
RULESET=$(ruleset_id)
if [ -z "$RULESET" ]; then bad "Ruleset 'Protect main' missing -> scripts/github-setup.sh"
else
  check "$(gh api "repos/$REPO/rulesets/$RULESET" --jq '.enforcement == "active"')" "Ruleset 'Protect main' is active" "turn it on in Settings > Rules > Rulesets"
  RULES=$(gh api "repos/$REPO/rulesets/$RULESET" --jq '[.rules[].type] | join(", ")')
  info "Rules: $RULES"
  [[ "$RULES" == *copilot_code_review* ]] || warn "No automatic Copilot code review rule -> request Copilot as a reviewer by hand in Act 3"
fi
check "$(gh api "repos/$REPO/code-scanning/default-setup" --jq '.state == "configured"' 2>/dev/null || echo false)" \
  "CodeQL default setup" "Settings > Advanced Security > Code scanning"
check "$(gh api "repos/$REPO" --jq '.security_and_analysis.secret_scanning_push_protection.status == "enabled"' 2>/dev/null || echo false)" \
  "Push protection" "Settings > Advanced Security > Secret Protection"
if ! gh api "repos/$REPO/environments/production" --silent >/dev/null 2>&1; then bad "Environment 'production' missing -> scripts/github-setup.sh"
else
  REVIEWERS=$(gh api "repos/$REPO/environments/production" --jq '[.protection_rules[]? | select(.type == "required_reviewers") | .reviewers[].reviewer | (.login // .slug)] | join(", ")' 2>/dev/null)
  [ -n "$REVIEWERS" ] && ok "Environment 'production' needs approval from: $REVIEWERS" || bad "Environment 'production' has no required reviewer -> scripts/github-setup.sh"
fi
SECRETS=$(gh secret list --env production -R "$REPO" --json name --jq '[.[].name] | join(" ")' 2>/dev/null)
for s in AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID; do
  [[ " $SECRETS " == *" $s "* ]] && ok "Environment secret $s" || bad "Environment secret $s missing -> scripts/azure-setup.sh"
done
APP=$(gh variable get AZURE_WEBAPP_NAME -R "$REPO" 2>/dev/null)
[ -n "$APP" ] && ok "Variable AZURE_WEBAPP_NAME=$APP" || bad "Variable AZURE_WEBAPP_NAME missing -> scripts/azure-setup.sh"

step "Actions"
last_run() { gh run list -R "$REPO" --workflow "$1" --branch main --limit 1 --json conclusion,status,url --jq '.[0] | "\(.status) \(.conclusion) \(.url)"' 2>/dev/null; }
read -r STATUS CONCLUSION URL <<< "$(last_run ci-cd.yml)"
[ "$CONCLUSION" = "success" ] && ok "Last CI/CD run on main succeeded" || bad "Last CI/CD run on main: ${STATUS:-none} ${CONCLUSION:-} ${URL:-} -> fix before the demo"
read -r STATUS CONCLUSION URL <<< "$(last_run copilot-setup-steps.yml)"
[ "$CONCLUSION" = "success" ] && ok "Copilot Setup Steps succeeded" || warn "Copilot Setup Steps: ${STATUS:-not run} ${CONCLUSION:-} -> run it once from the Actions tab"

step "Security pull requests (open them 30+ minutes before the demo)"
pr_state() { # branch expected-failing-check-substring label
  local number failing pending
  number=$(gh pr list -R "$REPO" --head "$1" --state open --json number --jq '.[0].number // empty' 2>/dev/null)
  if [ -z "$number" ]; then bad "No open pull request from $1 -> scripts/prepare-security-prs.sh"; return; fi
  failing=$(gh pr checks "$number" -R "$REPO" --json name,bucket --jq '[.[] | select(.bucket == "fail") | .name] | join(", ")' 2>/dev/null)
  pending=$(gh pr checks "$number" -R "$REPO" --json name,bucket --jq '[.[] | select(.bucket == "pending") | .name] | join(", ")' 2>/dev/null)
  if [[ "$failing" == *"$2"* ]]; then ok "#$number $3: '$2' fails as expected"
  elif [ -n "$pending" ]; then warn "#$number $3: checks still running ($pending)"
  else bad "#$number $3: '$2' is not failing (failing: ${failing:-none}) -> see Troubleshooting in docs/LIVE-DEMO-GUIDE.md"; fi
}
pr_state demo/not-found-message CodeQL "cross-site scripting"
pr_state demo/add-date-helper dependency-review "vulnerable dependency"

step "Azure web app"
URL=${WEBAPP_URL:-${APP:+https://$APP.azurewebsites.net}}
if [ -z "$URL" ]; then bad "No web app URL"
elif command -v curl >/dev/null 2>&1; then
  BODY=$(curl -fsS --max-time 20 "$URL/health" 2>/dev/null)
  [[ "$BODY" == *'"ok"'* ]] && ok "$URL/health answers: $BODY" || bad "$URL/health does not answer -> check the last deployment and the App Service log stream"
else
  warn "curl not found; open $URL/health in a browser"
fi

step "Check by hand"
cat <<'MANUAL'
  - Presenter signed in to GitHub (browser profile A) and VS Code; approver signed in on a second laptop or profile B
  - Copilot: cloud agent enabled for this repository; Copilot code review available; Agent and Plan modes visible in VS Code
  - VS Code: font size 18+, npm ci done, terminal open in the repository, notifications off
  - Tabs: repository, project board, Actions, Settings > Rules, Security tab, Azure portal (web app), the web app itself
  - Backup: the rehearsal recording and the simulated replay downloaded for offline use
MANUAL

if [ "$FAILS" = 0 ]; then step "Ready${WARNINGS:+ (check $WARNINGS warning(s))}"; else step "$FAILS item(s) to fix before the demo"; exit 1; fi
