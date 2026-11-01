#!/usr/bin/env bash
# One-time GitHub setup for the Order Desk live demo. Safe to run again.
#
# Run it inside a clone of YOUR copy of the repository (created with "Use this template"),
# on an up-to-date main branch with no uncommitted changes:
#
#   scripts/github-setup.sh                                              # one account (the default)
#   APPROVER=<github-username-of-the-approver> scripts/github-setup.sh   # two people
#
# Optional settings (environment variables):
#   APPROVER         A second person: code owner, pull request reviewer and production approver. Not set, or set to
#                    your own user name: one account runs the whole demo. Pull requests then need no approving review
#                    (GitHub does not count an approval of your own pull request, or of one you asked Copilot for);
#                    the checks, CodeQL, Copilot code review and resolved conversations still gate the merge. You are
#                    the code owner and approve the production deployment yourself (Prevent self-review off).
#   CODEOWNERS_TEAM  Organization repositories only: a team such as @contoso/order-desk-maintainers to use in
#                    CODEOWNERS instead of the approver.
#   PROJECT          "new" (default) creates or reuses a project called "Order Desk"; "OWNER/NUMBER" uses an
#                    existing project; "skip" sets up no project.
#   ISSUE_TYPE       Organization repositories with issue types: the type for the feature form, e.g. "feature".
#   DEMO_DATE        YYYY-MM-DD: regenerate data/orders.json so the demo orders are relative to that day
#                    (ORD-100232 arrives "today"). Default: keep the committed data (demo day 3 November 2026).
#   SKIP_RULESET=1   Do not create the ruleset (create it in the UI instead).
#   YES=1            Do not ask for confirmation.
#
# Needs: GitHub CLI (gh) signed in as a repository admin, git and node.
# For projects, the GitHub CLI also needs the project scope:  gh auth refresh -s project
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
source scripts/lib.sh

need gh "Install it from https://cli.github.com/ and run: gh auth login"
need git
need node

resolve_repo
require_admin
APPROVER=${APPROVER:-}
APPROVER=${APPROVER#@}
PROJECT=${PROJECT:-new}
ME=$(gh api user --jq .login)
APPROVER=${APPROVER:-$ME}
# One account when APPROVER is you (GitHub user names are not case-sensitive).
SOLO=''
[ "$(printf '%s' "$APPROVER" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$ME" | tr '[:upper:]' '[:lower:]')" ] || { SOLO=1; APPROVER=$ME; }
OWNER_TYPE=$(gh api "repos/$REPO" --jq .owner.type)
VISIBILITY=$(gh api "repos/$REPO" --jq .visibility)
APPROVER_ID=$(gh api "users/$APPROVER" --jq .id 2>/dev/null) || die "GitHub user '$APPROVER' was not found."

git remote get-url origin | grep -qi "$REPO" || die "This clone's origin is not $REPO. Run the script inside a clone of $REPO."

if [ -n "$SOLO" ]; then
  step "Setting up $REPO ($VISIBILITY, owned by a $OWNER_TYPE) for one account: @$ME is code owner and production approver"
else
  step "Setting up $REPO ($VISIBILITY, owned by a $OWNER_TYPE) with approver @$APPROVER"
fi
confirm "This changes repository settings, security features, the production environment and the main branch. Continue?"

# --------------------------------------------------------------------------------------------
step "1/9 Repository settings: squash merge only, delete branches after merge"
gh repo edit "$REPO" --enable-issues --enable-squash-merge --enable-merge-commit=false \
  --enable-rebase-merge=false --delete-branch-on-merge >/dev/null
ok "Pull requests merge with squash; merged branches are deleted"

# --------------------------------------------------------------------------------------------
step "2/9 Write access for the approver"
if [ -n "$SOLO" ]; then
  ok "One account: nobody to invite"
elif gh api "repos/$REPO/collaborators/$APPROVER" --silent >/dev/null 2>&1; then
  ok "@$APPROVER already has access"
else
  gh api -X PUT "repos/$REPO/collaborators/$APPROVER" -f permission=push --silent \
    && warn "Invited @$APPROVER with write access. They must accept the invitation (github.com/notifications), then run this script again." \
    || warn "Could not invite @$APPROVER. Add them under Settings > Collaborators and teams, with write access."
fi

# --------------------------------------------------------------------------------------------
step "3/9 Labels and project"
gh label create enhancement --color a2eeef --description "New feature or request" --force -R "$REPO" >/dev/null
ok "Label 'enhancement' (used by the feature request form)"

PROJECT_REF=''
if [ "$PROJECT" = "skip" ]; then
  info "No project (PROJECT=skip)"
elif ! gh project list --owner "$OWNER" --limit 1 >/dev/null 2>&1; then
  warn "Skipped the project: the GitHub CLI needs the project scope. Run 'gh auth refresh -s project' and run this script again."
else
  if [ "$PROJECT" = "new" ]; then
    NUMBER=$(gh project list --owner "$OWNER" --format json --limit 100 \
      --jq '[.projects[] | select(.title == "Order Desk")][0].number // empty')
    if [ -z "$NUMBER" ]; then
      NUMBER=$(gh project create --owner "$OWNER" --title "Order Desk" --format json --jq .number)
      ok "Created project 'Order Desk' (#$NUMBER)"
    else
      ok "Reusing project 'Order Desk' (#$NUMBER)"
    fi
    PROJECT_REF="$OWNER/$NUMBER"
  else
    PROJECT_REF=$PROJECT
    NUMBER=${PROJECT##*/}
  fi
  gh project link "$NUMBER" --owner "${PROJECT_REF%%/*}" --repo "$NAME" >/dev/null 2>&1 || true
  ok "Project $PROJECT_REF is linked to $REPO"
  info "In the project, add a Board view and turn on the 'Auto-add to project' workflow for this repository (UI only)."
fi

# --------------------------------------------------------------------------------------------
step "4/9 Code owners, the feature request form and the demo data"
CODE_OWNER=${CODEOWNERS_TEAM:-@$APPROVER}
if [ -n "$SOLO" ]; then
  OWNERS_RULE='# One account: pull requests need no approving review; checks, CodeQL, Copilot code review and resolved conversations gate the merge (see the "Protect main" ruleset).'
else
  OWNERS_RULE='# Every pull request to main needs a review from a code owner (see the "Protect main" ruleset).'
fi
cat > .github/CODEOWNERS <<CODEOWNERS
# Code owners for Contoso Order Desk (written by scripts/github-setup.sh).
$OWNERS_RULE
*                     $CODE_OWNER
/.github/             $CODE_OWNER
/.github/CODEOWNERS   $CODE_OWNER
CODEOWNERS
FORM=.github/ISSUE_TEMPLATE/feature-request.yml
FORM=$FORM ISSUE_TYPE=${ISSUE_TYPE:-} PROJECT_REF=$PROJECT_REF node -e '
  const fs = require("fs");
  let text = fs.readFileSync(process.env.FORM, "utf8");
  if (process.env.ISSUE_TYPE) text = text.replace(/^#?[ \t]*type:[ \t].*$/m, "type: " + process.env.ISSUE_TYPE);
  if (process.env.PROJECT_REF) text = text.replace(/^#?[ \t]*projects:[ \t].*$/m, "projects: [\"" + process.env.PROJECT_REF + "\"]");
  fs.writeFileSync(process.env.FORM, text);'
git add .github/CODEOWNERS "$FORM"
if [ -n "${DEMO_DATE:-}" ]; then
  node scripts/seed-orders.mjs --date "$DEMO_DATE" >/dev/null || die "DEMO_DATE must look like 2026-11-20."
  git add data/orders.json
fi
if git diff --cached --quiet; then
  ok "Already configured"
else
  git fetch -q origin main
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "Your local main is not the same as origin/main. Run 'git switch main && git pull', then run this script again."
  git commit -q -m "Configure code owners, the feature request form${DEMO_DATE:+ and demo data for $DEMO_DATE}"
  with_ruleset_paused git push -q origin HEAD:main
  ok "Committed to main: CODEOWNERS ($CODE_OWNER), the feature form${PROJECT_REF:+ (project $PROJECT_REF)}${ISSUE_TYPE:+ (type $ISSUE_TYPE)}${DEMO_DATE:+, orders for $DEMO_DATE}"
fi

# --------------------------------------------------------------------------------------------
step "5/9 Security features"
gh api -X PUT "repos/$REPO/vulnerability-alerts" --silent && ok "Dependabot alerts" || warn "Could not turn on Dependabot alerts"
gh api -X PUT "repos/$REPO/automated-security-fixes" --silent && ok "Dependabot security updates" || warn "Could not turn on Dependabot security updates"
if [ "$VISIBILITY" != "public" ]; then
  echo '{"security_and_analysis":{"advanced_security":{"status":"enabled"}}}' \
    | gh api -X PATCH "repos/$REPO" --input - --silent 2>/dev/null \
    && ok "GitHub Advanced Security (code security and secret protection)" \
    || warn "Could not enable GitHub Code Security / Secret Protection on this private repository. An organization owner enables them under Settings > Advanced Security (licences needed)."
fi
echo '{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}' \
  | gh api -X PATCH "repos/$REPO" --input - --silent 2>/dev/null \
  && ok "Secret scanning and push protection" \
  || warn "Could not turn on secret scanning and push protection (Settings > Advanced Security)."
gh api -X PATCH "repos/$REPO/code-scanning/default-setup" -f state=configured -f query_suite=default --silent 2>/dev/null \
  && ok "CodeQL default setup requested (the first analysis takes a few minutes)" \
  || warn "Could not turn on CodeQL default setup (Settings > Advanced Security > Code scanning > Default setup)."

# --------------------------------------------------------------------------------------------
step "6/9 Environment 'production': approval by @$APPROVER, main branch only"
# Prevent self-review stops whoever triggered a run from approving its deployment: with one account that is you, so it is off.
if [ -n "$SOLO" ]; then SELF_REVIEW=false; else SELF_REVIEW=true; fi
ENV_BODY=$(printf '{"wait_timer":0,"prevent_self_review":%s,"reviewers":[{"type":"User","id":%s}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' "$SELF_REVIEW" "$APPROVER_ID")
if echo "$ENV_BODY" | gh api -X PUT "repos/$REPO/environments/production" --input - --silent 2>/tmp/order-desk-env.err; then
  if [ -n "$SOLO" ]; then ok "Required reviewer @$APPROVER (you), prevent self-review off: you approve your own deployments"
  else ok "Required reviewer @$APPROVER, prevent self-review on"; fi
else
  warn "Could not set the required reviewer: $(head -c 300 /tmp/order-desk-env.err)"
  info "Private repositories need GitHub Enterprise (or Team for organizations) for required reviewers; on Free and Pro they work only in public repositories."
  [ -n "$SOLO" ] || info "The approver must also have accepted the invitation."
  echo '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' \
    | gh api -X PUT "repos/$REPO/environments/production" --input - --silent
fi
if gh api "repos/$REPO/environments/production/deployment-branch-policies" --jq '.branch_policies[].name' | grep -qx main; then
  ok "Deployment branches: main"
else
  gh api -X POST "repos/$REPO/environments/production/deployment-branch-policies" -f name=main -f type=branch --silent
  ok "Deployment branches: main"
fi

# --------------------------------------------------------------------------------------------
step "7/9 Ruleset 'Protect main'"
if [ "${SKIP_RULESET:-0}" = "1" ]; then
  info "Skipped (SKIP_RULESET=1)"
else
  # Tries the full ruleset first, then without the rules an account may not support.
  # One account: no approving review and no code-owner review, because nobody else could give them.
  make_ruleset() {
    SOLO="$SOLO" DROP="$1" node -e '
      const r = JSON.parse(require("fs").readFileSync("scripts/rulesets/protect-main.json", "utf8"));
      const drop = (process.env.DROP || "").split(",").filter(Boolean);
      r.rules = r.rules.filter((rule) => !drop.includes(rule.type));
      if (process.env.SOLO) for (const rule of r.rules) if (rule.type === "pull_request") {
        rule.parameters.required_approving_review_count = 0;
        rule.parameters.require_code_owner_review = false;
      }
      if (drop.includes("allowed_merge_methods")) {
        for (const rule of r.rules) if (rule.parameters) delete rule.parameters.allowed_merge_methods;
      }
      process.stdout.write(JSON.stringify(r));'
  }
  EXISTING=$(ruleset_id)
  APPLIED=''
  for DROP in '' 'copilot_code_review' 'copilot_code_review,allowed_merge_methods' 'copilot_code_review,allowed_merge_methods,code_scanning'; do
    if [ -n "$EXISTING" ]; then
      make_ruleset "$DROP" | gh api -X PUT "repos/$REPO/rulesets/$EXISTING" --input - --silent 2>/tmp/order-desk-ruleset.err && APPLIED=yes
    else
      make_ruleset "$DROP" | gh api -X POST "repos/$REPO/rulesets" --input - --silent 2>/tmp/order-desk-ruleset.err && APPLIED=yes
    fi
    if [ -n "$APPLIED" ]; then
      if [ -z "$DROP" ]; then
        if [ -n "$SOLO" ]; then ok "Pull request without approval (one account), checks 'build' and 'dependency-review', CodeQL results, automatic Copilot code review"
        else ok "Pull request with 1 code-owner approval, checks 'build' and 'dependency-review', CodeQL results, automatic Copilot code review"; fi
      else
        ok "Ruleset created without: $DROP"
        warn "Add the missing rule(s) in Settings > Rules > Rulesets > Protect main (for example 'Automatically request Copilot code review')."
      fi
      break
    fi
  done
  [ -n "$APPLIED" ] || warn "Could not create the ruleset: $(head -c 300 /tmp/order-desk-ruleset.err). Create it in the UI as described in docs/LIVE-DEMO-GUIDE.md."
fi

# --------------------------------------------------------------------------------------------
step "8/9 Copilot setup steps"
gh workflow run copilot-setup-steps.yml -R "$REPO" --ref main >/dev/null 2>&1 \
  && ok "Started 'Copilot Setup Steps' once to check the cloud agent's environment (see the Actions tab)" \
  || warn "Could not start 'Copilot Setup Steps'. Run it from the Actions tab."

# --------------------------------------------------------------------------------------------
step "9/9 Tag the clean starting point"
git fetch -q origin main
git tag -f demo-start origin/main >/dev/null
git push -q -f origin refs/tags/demo-start
ok "demo-start -> $(git rev-parse --short origin/main) (scripts/reset-demo.sh returns main to this commit)"

step "Done${WARNINGS:+ with $WARNINGS warning(s)}"
cat <<NEXT
  Still to do in the browser (no API for these):
  - Copilot: make sure the cloud agent and Copilot code review are enabled for $REPO
    (organization: Settings > Copilot > Policies and Cloud agent > Repository access).
  - Project: add a Board view and the 'Auto-add to project' workflow.
  - Organization repositories: optional custom pattern 'Contoso demo token' for the push protection demo.
  Next: scripts/azure-setup.sh (in Azure Cloud Shell), then scripts/preflight.sh.
NEXT
