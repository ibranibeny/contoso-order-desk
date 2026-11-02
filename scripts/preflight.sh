#!/usr/bin/env bash
# Read-only pre-flight check for the live demo. Run it the day before, 30 minutes before, and during the break.
# It changes nothing. Each line is ✓ ready, ! check by hand, or ✗ fix before the demo.
#
# Needs: the GitHub CLI signed in (as a repository admin to see every check), and curl.
# Azure: if the Azure CLI is signed in (az login, or Azure Cloud Shell), the script finds everything by itself, so there
# is nothing to pass: the web app named in the AZURE_WEBAPP_NAME variable (or the resource group that azure-setup.sh
# tags workload=contoso-order-desk), its subscription (the current one first; only if it is not there, up to 30 other
# enabled ones you can see), resource group, plan, host name, and the identity GitHub Actions signs in as. Without the
# Azure CLI it only checks /health.
# GitHub never shows secret values: the script lists every identity that can deploy and every credential it trusts, and
# reports the latest production deployment, which shows that sign-in worked at that time.
#
#   scripts/preflight.sh
#   WEBAPP_URL=https://<custom-domain> scripts/preflight.sh   # check a custom domain instead of the default host name
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
  if ! gh api "repos/$REPO/branches/$b" --silent >/dev/null 2>&1; then
    bad "Branch $b missing -> scripts/github-setup.sh takes it from the template and puts it on top of main"
  elif ! gh api "repos/$REPO/compare/main...$b" --silent >/dev/null 2>&1; then
    # A repository created from a template starts every branch with its own first commit (unrelated histories): the
    # compare API answers 404 "No common ancestor", and gh api exits with an error.
    bad "Branch $b has no history in common with main, so no pull request can be opened from it -> scripts/github-setup.sh rebuilds it on top of main"
  else ok "Branch $b"; fi
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
  [[ "$RULES" == *copilot_code_review* ]] || warn "No automatic Copilot code review rule -> request Copilot as a reviewer by hand in chapter 3"
fi
check "$(gh api "repos/$REPO/code-scanning/default-setup" --jq '.state == "configured"' 2>/dev/null || echo false)" \
  "CodeQL default setup" "Settings > Advanced Security > Code scanning"
check "$(gh api "repos/$REPO" --jq '.security_and_analysis.secret_scanning_push_protection.status == "enabled"' 2>/dev/null || echo false)" \
  "Push protection" "Settings > Advanced Security > Secret Protection"
if ! gh api "repos/$REPO/environments/production" --silent >/dev/null 2>&1; then bad "Environment 'production' missing -> scripts/github-setup.sh"
else
  REVIEWERS=$(gh api "repos/$REPO/environments/production" --jq '[.protection_rules[]? | select(.type == "required_reviewers") | .reviewers[].reviewer | (.login // .slug)] | join(", ")' 2>/dev/null)
  [ -n "$REVIEWERS" ] && ok "Environment 'production' needs approval from: $REVIEWERS" || bad "Environment 'production' has no required reviewer -> scripts/github-setup.sh"
  # One account (you are the only reviewer): two settings would leave nobody able to approve.
  ME=$(gh api user --jq .login 2>/dev/null)
  if [ -n "$ME" ] && [ "$(printf '%s' "$REVIEWERS" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$ME" | tr '[:upper:]' '[:lower:]')" ]; then
    [ "$(gh api "repos/$REPO/environments/production" --jq '[.protection_rules[]? | select(.type == "required_reviewers") | .prevent_self_review] | any' 2>/dev/null)" != "true" ] \
      || warn "You are the only reviewer of 'production' and Prevent self-review is on: GitHub does not let you approve a deployment you started -> scripts/github-setup.sh without APPROVER (one account)"
    if [ -n "$RULESET" ]; then
      # An approving review is needed when the count is above 0, and also with a count of 0 when the ruleset requires
      # review from Code Owners or approval of the most recent push.
      read -r N_APPROVALS CODE_OWNER_REVIEW LAST_PUSH_APPROVAL <<< "$(gh api "repos/$REPO/rulesets/$RULESET" \
        --jq '[.rules[] | select(.type == "pull_request") | .parameters][0] // {} | "\(.required_approving_review_count // 0) \(.require_code_owner_review // false) \(.require_last_push_approval // false)"' 2>/dev/null)"
      NEEDS=''
      [ "${N_APPROVALS:-0}" = "0" ] || NEEDS="$N_APPROVALS approval(s)"
      [ "$CODE_OWNER_REVIEW" != "true" ] || NEEDS="${NEEDS:+$NEEDS, }review from Code Owners"
      [ "$LAST_PUSH_APPROVAL" != "true" ] || NEEDS="${NEEDS:+$NEEDS, }approval of the most recent push"
      [ -z "$NEEDS" ] || warn "Pull requests need $NEEDS, but GitHub does not count your approval of your own pull request or of one you asked Copilot for -> a second person approves, or scripts/github-setup.sh without APPROVER (one account)"
    fi
  fi
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

# ----------------------------------------------------------------------------------------------------------------
# Azure: every value comes from the signed-in Azure CLI and from GitHub. Nothing to pass.
step "Azure"
HOST=''
is_true() { case "$1" in true|True|TRUE) return 0 ;; *) return 1 ;; esac; }
azq() { az "$@" 2>/dev/null </dev/null | tr -d '\r'; }   # no stdin: the Windows CLI under WSL would eat a while-read loop's input
# Rows of fields split on \037, so empty values keep their place. The Azure CLI prints a flat list one value per line
# and a list of lists one row per line, so row queries are written [[a, b]] (one object) or [].[a, b] (lists).
azf() { azq "$@" -o tsv | tr '\t' '\037'; }   # pipefail is on: a failed az call fails the pipeline, not an empty answer
none() { [ "$1" = "None" ] && echo '' || echo "$1"; }   # the Azure CLI prints a missing value inside a row as None
aud_ok() { [[ ",$1," == *",api://AzureADTokenExchange,"* ]]; }
# find_apps <subscription>: one "subscription<US>resource-group<US>web-app" row per candidate. Returns 1 if an Azure
# lookup failed (permissions, network), so a failed search is never mistaken for "not found".
find_apps() {
  local s=$1 rg rgs out rc=0
  if [ -n "$APP" ]; then
    out=$(az resource list --subscription "$s" --resource-type Microsoft.Web/sites --name "$APP" --query "[].[resourceGroup, name]" -o tsv 2>/dev/null) || return 1
    printf '%s\n' "$out" | tr -d '\r' | grep . | sed "s|^|$s$(printf '\t')|" | tr '\t' '\037'
  else
    rgs=$(az group list --subscription "$s" --tag workload=contoso-order-desk --query "[].name" -o tsv 2>/dev/null) || return 1
    for rg in $(printf '%s' "$rgs" | tr -d '\r'); do
      out=$(az webapp list --subscription "$s" -g "$rg" --query "[].[resourceGroup, name]" -o tsv 2>/dev/null) || { rc=1; continue; }
      printf '%s\n' "$out" | tr -d '\r' | grep . | sed "s|^|$s$(printf '\t')|" | tr '\t' '\037'
    done
  fi
  return $rc
}

# Evidence from GitHub: the latest deployment to the production environment.
DEPLOY_STATE=''; DEPLOY_AT=''
read -r DEP_ID DEPLOY_AT <<< "$(gh api "repos/$REPO/deployments?environment=production&per_page=1" --jq '.[0] | "\(.id) \(.created_at)"' 2>/dev/null)"
if [ -n "$DEP_ID" ] && [ "$DEP_ID" != "null" ]; then
  DEPLOY_STATE=$(gh api "repos/$REPO/deployments/$DEP_ID/statuses?per_page=1" --jq '.[0].state // empty' 2>/dev/null)
fi

if ! command -v az >/dev/null 2>&1; then
  warn "Azure CLI not found: Azure resources not checked -> install it, or run this script in Azure Cloud Shell"
elif ! az account show -o none >/dev/null 2>&1; then
  warn "Not signed in to Azure: Azure resources not checked -> az login (Azure Cloud Shell is already signed in)"
else
  CUR_SUB=$(azq account show --query id -o tsv)
  info "Signed in to Azure as $(azq account show --query user.name -o tsv) · current subscription $(azq account show --query name -o tsv)"
  # The current subscription first: azure-setup.sh created the web app there. Only if it is not found there are the
  # other enabled subscriptions searched, up to MAX_SUBS of them, 6 at a time. An az profile can hold many accounts and
  # tenants (one with 85 subscriptions took minutes per batch), so they are not searched while the answer is at hand.
  MAX_SUBS=30
  LIST_FAILED=''
  SUBMAP=$(azf account list --query "[?state=='Enabled'].[id, name]") || { SUBMAP=''; LIST_FAILED=1; }
  sub_name() { printf '%s\n' "$SUBMAP" | awk -F$'\037' -v id="$1" '$1 == id { print $2; exit }'; }
  ALL_OTHER=$(printf '%s\n' "$SUBMAP" | cut -d$'\037' -f1 | grep . | grep -v -x -F "$CUR_SUB")
  N_OTHER=$(printf '%s' "$ALL_OTHER" | grep -c .)
  OTHER_SUBS=$(printf '%s\n' "$ALL_OTHER" | head -n "$MAX_SUBS")
  SEARCH_DIR=$(mktemp -d); trap 'rm -rf "$SEARCH_DIR"' EXIT
  search_subs() { # subscription IDs -> $SEARCH_DIR/<id>.out (rows) and .rc (0 = searched)
    local s i=0
    for s in "$@"; do
      ( find_apps "$s" > "$SEARCH_DIR/$s.out"; echo $? > "$SEARCH_DIR/$s.rc" ) &
      i=$((i + 1)); [ $((i % 6)) -ne 0 ] || wait
    done
    wait
  }
  SUBS=$CUR_SUB
  search_subs "$CUR_SUB"
  if ! grep -q . "$SEARCH_DIR/$CUR_SUB.out" 2>/dev/null && [ "$N_OTHER" -gt 0 ]; then
    if [ "$N_OTHER" -gt "$MAX_SUBS" ]; then info "Not in the current subscription; looking in the first $MAX_SUBS of $N_OTHER other enabled subscriptions"
    else info "Not in the current subscription; looking in $N_OTHER other enabled subscription(s)"; fi
    # shellcheck disable=SC2086
    search_subs $OTHER_SUBS
    SUBS=$(printf '%s\n%s\n' "$CUR_SUB" "$OTHER_SUBS" | grep .)
  fi
  FOUND=$(cat "$SEARCH_DIR"/*.out 2>/dev/null | grep .)
  FAILED=''
  for s in $SUBS; do [ "$(cat "$SEARCH_DIR/$s.rc" 2>/dev/null)" = "0" ] || FAILED="$FAILED, $(sub_name "$s")"; done
  # Without the subscription list the others were never searched: not finding the web app is then not "not found".
  [ -n "$FOUND" ] || [ -z "$LIST_FAILED" ] || FAILED="$FAILED, your other subscriptions (az account list failed)"
  [ -z "$FAILED" ] || warn "Could not search subscription(s) ${FAILED#, } (permissions or network): the result below may be incomplete"
  N_APPS=$(printf '%s' "$FOUND" | grep -c .); AMBIGUOUS=''

  if [ -z "$FOUND" ] && [ -n "$FAILED" ]; then
    bad "Web app not found, but some subscriptions could not be searched -> fix access and run the check again before creating anything"
  elif [ -z "$FOUND" ]; then
    if [ -n "$APP" ]; then bad "Web app $APP not found in any subscription you can see -> az login with the account that ran scripts/azure-setup.sh"
    else bad "No web app found (no AZURE_WEBAPP_NAME variable, no resource group tagged workload=contoso-order-desk) -> scripts/azure-setup.sh"; fi
  elif [ "$N_APPS" != "1" ]; then
    AMBIGUOUS=1
    LIST=$(printf '%s\n' "$FOUND" | while IFS=$'\037' read -r fs frg fapp; do printf '%s (resource group %s, subscription %s); ' "$fapp" "$frg" "$(sub_name "$fs")"; done)
    if [ -n "$APP" ]; then bad "$N_APPS web apps are named $APP: ${LIST%; }. Not checking a guess -> delete the one you do not use; the deployment goes to the subscription in the AZURE_SUBSCRIPTION_ID secret"
    else bad "$N_APPS web apps match: ${LIST%; }. Not checking a guess -> set the AZURE_WEBAPP_NAME variable to the demo web app (scripts/azure-setup.sh sets it)"; fi
  else
    IFS=$'\037' read -r SUB RG FOUND_APP <<< "$FOUND"
    [ -n "$APP" ] || { APP=$FOUND_APP; info "Found through the resource group tag workload=contoso-order-desk"; }
    SUB_NAME=$(sub_name "$SUB"); SUB_NAME=${SUB_NAME:-$SUB}
    [ "$SUB" = "$CUR_SUB" ] || warn "The web app is in subscription $SUB_NAME, not your current one: checked there. Run az account set --subscription \"$SUB\" before any scripts/azure-setup.sh fix below"
    AZA=(--subscription "$SUB" -g "$RG" -n "$APP")

    IFS=$'\037' read -r WEBAPP_ID STATE HOST HTTPS LOC PLAN_ID <<< "$(azf webapp show "${AZA[@]}" --query "[[id, state, defaultHostName, httpsOnly, location, appServicePlanId || serverFarmId]]")"
    if [ -z "$WEBAPP_ID" ]; then
      bad "Could not read web app $APP in resource group $RG -> check your role on the resource group"
    else
      case "$PLAN_ID" in
        /subscriptions/*) PLAN_ROW=$(azf appservice plan show --ids "$PLAN_ID" --query "[[name, sku.name]]") ;;
        *) PLAN_ROW=$(azf appservice plan list --subscription "$SUB" -g "$RG" --query "[0:1].[name, sku.name]") ;;
      esac
      IFS=$'\037' read -r PLAN_NAME PLAN_SKU <<< "$PLAN_ROW"
      ok "Web app $APP · resource group $RG · $LOC · plan ${PLAN_NAME:-?} (${PLAN_SKU:-?}) · subscription $SUB_NAME"
      case "$PLAN_SKU" in
        F1|FREE|D1|SHARED)
          # The plan can live in another resource group than the web app: address it by its resource ID.
          case "$PLAN_ID" in /subscriptions/*) PLAN_REF="--ids \"$PLAN_ID\"" ;; *) PLAN_REF="--subscription \"$SUB\" -g $RG -n ${PLAN_NAME:-?}" ;; esac
          warn "Plan ${PLAN_NAME:-?} is on the $PLAN_SKU tier: no Always On, so the first request after about 20 idle minutes is slow (Free also allows 60 CPU minutes a day) -> before the session: az appservice plan update $PLAN_REF --sku B1 && az webapp config set --subscription \"$SUB\" -g $RG -n $APP --always-on true" ;;
      esac

      if ! CFG=$(azf webapp config show "${AZA[@]}" --query "[[linuxFxVersion, minTlsVersion, ftpsState, healthCheckPath]]"); then
        warn "Could not read the web app configuration (runtime, TLS, FTP, health check) -> check your role on resource group $RG"; CFG=''
      fi
      IFS=$'\037' read -r FX TLS FTPS HC <<< "$CFG"
      FX=$(none "$FX"); TLS=$(none "$TLS"); FTPS=$(none "$FTPS"); HC=$(none "$HC")
      PROBLEMS=''
      [ "$STATE" = "Running" ] || bad "Web app state ${STATE:-unknown} -> az webapp start --subscription \"$SUB\" -g $RG -n $APP"
      is_true "$HTTPS" || PROBLEMS="$PROBLEMS HTTPS only is off;"
      case "$TLS" in 1.2|1.3) ;; *) PROBLEMS="$PROBLEMS minimum TLS ${TLS:-unknown};" ;; esac
      [ "$FTPS" = "Disabled" ] || PROBLEMS="$PROBLEMS FTP state ${FTPS:-unknown};"
      [ "$HC" = "/health" ] || PROBLEMS="$PROBLEMS health check path ${HC:-not set};"
      # azure-setup.sh creates Node.js 24 (NODE|24-lts), or Node.js 22 where 24 is not offered. A rerun does not change the
      # runtime of an existing web app, so the fix is a direct command.
      FX_OK=''; case "$FX" in NODE\|24*|NODE\|22*|node\|24*|node\|22*) FX_OK=1 ;; esac
      if [ -z "$CFG" ]; then PROBLEMS=''; FX_OK=1; fi   # not read: reported above, no verdict on the settings
      [ -n "$FX_OK" ] || bad "Runtime ${FX:-unknown}: the app needs Node.js 24 or 22 -> az webapp config set --subscription \"$SUB\" -g $RG -n $APP --linux-fx-version \"NODE|24-lts\""
      if [ -n "$PROBLEMS" ]; then bad "Web app settings:${PROBLEMS%;} -> scripts/azure-setup.sh (safe to run again; it reapplies these settings)"
      elif [ -z "$CFG" ]; then :
      elif [ "$STATE" = "Running" ] && [ -n "$FX_OK" ]; then ok "Running, HTTPS only, TLS $TLS+, FTP off, $FX, health check $HC"
      else ok "HTTPS only, TLS $TLS+, FTP off, health check $HC"; fi

      ALLOWED=''; UNKNOWN=''
      for p in scm ftp; do
        v=$(azq resource show --subscription "$SUB" -g "$RG" --namespace Microsoft.Web --resource-type basicPublishingCredentialsPolicies \
              --parent "sites/$APP" -n "$p" --query properties.allow -o tsv)
        case "$v" in false|False) ;; true|True) ALLOWED="$ALLOWED $p" ;; *) UNKNOWN="$UNKNOWN $p" ;; esac
      done
      if [ -n "$ALLOWED" ]; then bad "Basic authentication still allowed for:$ALLOWED -> scripts/azure-setup.sh"
      elif [ -n "$UNKNOWN" ]; then warn "Could not read the basic authentication setting for:$UNKNOWN"
      else ok "Basic authentication off (scm and ftp): deployments sign in with Microsoft Entra ID"; fi

      # Application Insights as azure-setup.sh configures it: a non-empty connection string and auto-instrumentation (~3).
      # Values are tested inside the query and never printed, except the agent version.
      IFS=$'\037' read -r AI_CS AI_AGENT <<< "$(azf webapp config appsettings list "${AZA[@]}" \
        --query "[[length([?name=='APPLICATIONINSIGHTS_CONNECTION_STRING' && value]), [?name=='ApplicationInsightsAgent_EXTENSION_VERSION'].value | [0]]]")"
      AI_AGENT=$(none "$AI_AGENT")
      if [ -z "$AI_CS" ]; then warn "Could not read the app settings to check Application Insights (needs Contributor or Website Contributor on the web app)"
      elif [ "$AI_CS" = "0" ]; then warn "Application Insights not configured (optional) -> APPINSIGHTS=1 scripts/azure-setup.sh"
      elif [ "$AI_AGENT" != "~3" ]; then warn "Application Insights connection string set, but auto-instrumentation is ${AI_AGENT:-off} (ApplicationInsightsAgent_EXTENSION_VERSION, expected ~3 on Linux) -> APPINSIGHTS=1 scripts/azure-setup.sh"
      else ok "Application Insights configured: connection string set, auto-instrumentation $AI_AGENT (telemetry itself is not checked)"; fi

      # Who can deploy: managed identities with Website Contributor on this web app. An identity can live in another
      # subscription, so each principal is looked up in the web app's subscription first, then in the others.
      IDS=''; N_SP=0; UNMATCHED=''
      if ! DIRECT=$(azq role assignment list --subscription "$SUB" --scope "$WEBAPP_ID" --role "Website Contributor" --query "[?principalType=='ServicePrincipal'].principalId" -o tsv); then
        DIRECT=''; ROLES_UNREADABLE=1
      else ROLES_UNREADABLE=''; fi
      SEARCH="$SUB $(printf '%s\n%s\n' "$CUR_SUB" "$OTHER_SUBS" | grep . | grep -v -x -F "$SUB" | tr '\n' ' ')"
      for p in $DIRECT; do
        N_SP=$((N_SP + 1)); row=''
        for s in $SEARCH; do
          row=$(azf identity list --subscription "$s" --query "[?principalId=='$p'] | [0:1].[resourceGroup, name, clientId, principalId]")
          if [ -n "$row" ]; then IDS="$IDS$s"$'\037'"$row"$'\n'; break; fi
        done
        [ -n "$row" ] || UNMATCHED="$UNMATCHED $p"
      done
      [ -z "$UNMATCHED" ] || warn "Service principal(s) with Website Contributor on $APP that are not managed identities you can see:$UNMATCHED -> check them by hand (az ad sp show --id <id>)"
      # The list above covers Website Contributor granted on the web app itself. Owner, Contributor or Website Contributor
      # on the resource group, subscription or a management group also allow deployments: counted here, not inspected.
      if [ -z "$ROLES_UNREADABLE" ] && INHERITED=$(azq role assignment list --subscription "$SUB" --scope "$WEBAPP_ID" --include-inherited \
          --query "[?principalType=='ServicePrincipal' && (roleDefinitionName=='Owner' || roleDefinitionName=='Contributor' || roleDefinitionName=='Website Contributor')].principalId" -o tsv); then
        BROADER=$(printf '%s\n' "$INHERITED" | grep . | sort -u | grep -v -x -F "$(printf '%s\n' $DIRECT)" | grep -c .)
        # Information, not a warning: in shared or managed subscriptions these are platform identities the demo cannot change.
        if [ "${BROADER:-0}" != "0" ]; then info "$BROADER other service principal(s) can deploy through Owner, Contributor or Website Contributor on a broader scope (resource group, subscription or management group); not inspected here"
        else info "No other service principal has Owner, Contributor or Website Contributor on this web app or above (role grants to groups are not expanded)"; fi
      fi
      N_IDS=$(printf '%s' "$IDS" | grep -c .)
      if [ -n "$ROLES_UNREADABLE" ]; then
        warn "Could not list the role assignments on $APP, so who can deploy is not checked -> you need at least Reader on it"
      elif [ "$N_IDS" = "0" ]; then
        bad "No managed identity you can see has Website Contributor on $APP ($N_SP service principal(s) have it) -> scripts/azure-setup.sh"
      else
        if [ "$N_IDS" != "1" ]; then
          warn "$N_IDS managed identities can deploy to $APP: $(printf '%s' "$IDS" | awk -F$'\037' '{printf "%s%s (client ID %s)", (NR>1?", ":""), $3, $4}'). GitHub does not show the AZURE_CLIENT_ID value: check it is the client ID of the one this repository should use"
        fi
        # The subject GitHub sends (GitHub Docs, OpenID Connect reference): a repository created after 15 July 2026 always
        # sends the immutable format. An older one sends the legacy format, unless it was renamed or transferred after
        # that date or its owner opted in to immutable subjects; the script cannot see that, so only a deployment tells.
        read -r REPO_ID OWNER_ID CREATED <<< "$(gh api "repos/$REPO" --jq '"\(.id) \(.owner.id) \(.created_at)"')"
        LEGACY="repo:$OWNER/$NAME:environment:production"
        IMMUTABLE="repo:$OWNER@$OWNER_ID/$NAME@$REPO_ID:environment:production"
        NEW_REPO=0; [[ "$CREATED" > "2026-07-16" ]] && NEW_REPO=1
        GH_ISSUER=https://token.actions.githubusercontent.com
        # With one identity a problem is ✗. With several, a problem on one is ! and ✗ only if none can sign in.
        report() { # level message
          case "$1" in
            ok) ok "$2" ;;
            maybe) warn "$2" ;;
            bad) if [ "$N_IDS" = "1" ]; then bad "$2"; else warn "$2"; fi ;;
          esac
        }
        USABLE=''
        while IFS=$'\037' read -r ISUB IRG IDENTITY CLIENT PRINCIPAL; do
          [ -n "$IDENTITY" ] || continue
          [ "$ISUB" = "$SUB" ] || info "Identity $IDENTITY is in subscription $(azq account show --subscription "$ISUB" --query name -o tsv)"
          N=$(azq role assignment list --subscription "$SUB" --assignee "$PRINCIPAL" --all --include-groups --query "length(@)" -o tsv); NOTE='including through groups; other subscriptions not checked'
          if [ -z "$N" ]; then N=$(azq role assignment list --subscription "$SUB" --assignee "$PRINCIPAL" --all --query "length(@)" -o tsv); NOTE='group memberships and other subscriptions not checked'; fi
          if [ "${N:-0}" = "1" ]; then ok "Identity $IDENTITY (client ID $CLIENT): Website Contributor on this web app and no other role in subscription $SUB_NAME ($NOTE)"
          else warn "Identity $IDENTITY (client ID $CLIENT) has ${N:-?} role assignments in subscription $SUB_NAME; the demo needs only Website Contributor on $APP"; fi

          F_IMM=''; F_IMM_AUD=''; F_LEG=''; F_LEG_AUD=''; F_OTHER=''
          if ! FICS=$(azf identity federated-credential list --subscription "$ISUB" -g "$IRG" --identity-name "$IDENTITY" --query "[].[name, issuer, subject, join(',', audiences)]"); then
            report bad "Could not read the federated credentials of $IDENTITY -> check your role on resource group $IRG"; continue
          fi
          while IFS=$'\037' read -r fname fiss fsub faud; do
            [ -n "$fname" ] || continue
            if [ "$fiss" = "$GH_ISSUER" ] && [ "$fsub" = "$IMMUTABLE" ]; then F_IMM=$fname; F_IMM_AUD=$faud
            elif [ "$fiss" = "$GH_ISSUER" ] && [ "$fsub" = "$LEGACY" ]; then F_LEG=$fname; F_LEG_AUD=$faud
            else F_OTHER="$F_OTHER $fname ($fiss $fsub);"; fi
          done <<< "$FICS"
          AUD_BAD=''
          if [ -n "$F_IMM" ] && ! aud_ok "$F_IMM_AUD"; then AUD_BAD="$AUD_BAD $F_IMM ('$F_IMM_AUD')"; F_IMM=''; fi
          if [ -n "$F_LEG" ] && ! aud_ok "$F_LEG_AUD"; then AUD_BAD="$AUD_BAD $F_LEG ('$F_LEG_AUD')"; F_LEG=''; fi
          [ -z "$AUD_BAD" ] || report bad "Federated credential audience:$AUD_BAD, expected api://AzureADTokenExchange -> scripts/azure-setup.sh"

          if [ -z "$F_IMM$F_LEG" ]; then
            [ -n "$AUD_BAD" ] || { if [ "$N_IDS" = "1" ]; then bad "No federated credential on $IDENTITY trusts the production environment of $REPO -> scripts/azure-setup.sh"
                                   else info "Identity $IDENTITY has no federated credential for $REPO: GitHub Actions in this repository cannot sign in as it"; fi; }
          elif [ "$NEW_REPO" = "1" ]; then
            if [ -n "$F_IMM" ]; then report ok "Federated credential $F_IMM trusts $IMMUTABLE, the immutable subject a repository created after 15 July 2026 always sends"; USABLE=1
              [ -z "$F_LEG" ] || info "Federated credential $F_LEG trusts the legacy subject, which this repository never sends: it is not needed"
            else report bad "Federated credential $F_LEG trusts the legacy subject $LEGACY, but a repository created after 15 July 2026 always sends $IMMUTABLE -> SUBJECT_FORMAT=immutable scripts/azure-setup.sh"; fi
          elif [ -n "$F_IMM" ] && [ -n "$F_LEG" ]; then
            report ok "Federated credentials $F_LEG and $F_IMM trust both subject formats of $REPO"; USABLE=1
          elif [ -n "$F_LEG" ]; then
            report maybe "Federated credential $F_LEG trusts the legacy subject $LEGACY. GitHub sends it unless the repository was renamed or transferred after 15 July 2026, or its owner opted in to immutable subjects: the next deployment confirms"; USABLE=1
          else
            report maybe "Federated credential $F_IMM trusts the immutable subject $IMMUTABLE. GitHub sends it for this repository only if it was renamed or transferred after 15 July 2026, or its owner opted in to immutable subjects: the next deployment confirms"; USABLE=1
          fi
          [ -z "$F_OTHER" ] || warn "Identity $IDENTITY also trusts:${F_OTHER%;}. Anyone those match can deploy to $APP -> remove what you do not need"
        done <<< "$IDS"
        [ "$N_IDS" = "1" ] || [ -n "$USABLE" ] || bad "None of the $N_IDS identities can sign in from the production environment of $REPO -> scripts/azure-setup.sh"
      fi
      info "Values for the guide: web app $APP, resource group $RG"
    fi
  fi
fi

# A past deployment shows that sign-in worked then; changes made since are covered by the checks above, not by this.
case "$DEPLOY_STATE" in
  success) ok "Last production deployment (${DEPLOY_AT%%T*}) succeeded: Azure sign-in worked at that time" ;;
  failure|error) bad "Last production deployment (${DEPLOY_AT%%T*}) failed -> open the deploy job log in Actions" ;;
  '') warn "No production deployment yet: GitHub does not show secret values, so the first deployment is the real test of AZURE_CLIENT_ID and the federated credential" ;;
  *) warn "Last production deployment (${DEPLOY_AT%%T*}) is $DEPLOY_STATE" ;;
esac

URL=${WEBAPP_URL:-${HOST:+https://$HOST}}
URL=${URL:-${APP:+https://$APP.azurewebsites.net}}
if [ -z "$URL" ] && [ -n "${AMBIGUOUS:-}" ]; then info "/health not checked: no single web app (see above)"
elif [ -z "$URL" ]; then bad "No web app URL -> scripts/azure-setup.sh"
elif command -v curl >/dev/null 2>&1; then
  BODY=$(curl -fsS --max-time 20 "$URL/health" 2>/dev/null)
  [[ "$BODY" == *'"ok"'* ]] && ok "$URL/health answers: $BODY" || bad "$URL/health does not answer -> check the last deployment and the App Service log stream"
else
  warn "curl not found; open $URL/health in a browser"
fi

step "Check by hand"
cat <<'MANUAL'
  - Presenter signed in to GitHub and VS Code; with a second person, the Approver signed in with that account in another browser or on a second laptop
  - Copilot: cloud agent enabled for this repository; Copilot code review available; Agent and Plan modes visible in VS Code
  - VS Code: font size 18+, npm ci done, terminal open in the repository, notifications off
  - Tabs: repository, project board, Actions, Settings > Rules, Security tab, Azure portal (web app), the web app itself
  - Backup: the rehearsal recording and the simulated replay downloaded for offline use
MANUAL

if [ "$FAILS" = 0 ]; then step "Ready${WARNINGS:+ (check $WARNINGS warning(s))}"; else step "$FAILS item(s) to fix before the demo"; exit 1; fi
