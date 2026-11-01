#!/usr/bin/env bash
# Read-only pre-flight check for the live demo. Run it the day before, 30 minutes before, and during the break.
# It changes nothing. Each line is ✓ ready, ! check by hand, or ✗ fix before the demo.
#
# Needs: the GitHub CLI signed in (as a repository admin to see every check), and curl.
# Azure: if the Azure CLI is signed in (az login, or Azure Cloud Shell), the script finds everything by itself, so there
# is nothing to pass: the web app named in the AZURE_WEBAPP_NAME variable (or the resource group that azure-setup.sh
# tags workload=contoso-order-desk), its subscription (the current one first, then the others you can see), resource
# group, plan, host name, and the identity GitHub Actions signs in as. Without the Azure CLI it only checks /health.
# GitHub never shows secret values, so the latest production deployment is the evidence that AZURE_CLIENT_ID and the
# federated credential work together.
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
azq() { az "$@" 2>/dev/null | tr -d '\r'; }
# Rows of fields split on \037, so empty values keep their place. The Azure CLI prints a flat list one value per line
# and a list of lists one row per line, so row queries are written [[a, b]] (one object) or [0:1].[a, b] / [].[a, b].
azf() { azq "$@" -o tsv | tr '\t' '\037'; }
none() { [ "$1" = "None" ] && echo '' || echo "$1"; }   # the Azure CLI prints a missing value inside a row as None
find_app() { # subscription -> "resource-group<US>web-app"
  local rg
  if [ -n "$APP" ]; then
    azf resource list --subscription "$1" --resource-type Microsoft.Web/sites --name "$APP" --query "[0:1].[resourceGroup, name]"
  else
    for rg in $(azq group list --subscription "$1" --tag workload=contoso-order-desk --query "[].name" -o tsv); do
      azf webapp list --subscription "$1" -g "$rg" --query "[0:1].[resourceGroup, name]" | grep . && return 0
    done
  fi
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
  SUB=$CUR_SUB
  FOUND=$(find_app "$SUB")
  if [ -z "$FOUND" ]; then
    OTHER_SUBS=$(azq account list --query "[?state=='Enabled' && id!='$CUR_SUB'].id" -o tsv)
    [ -z "$OTHER_SUBS" ] || info "Not in the current subscription; looking in $(printf '%s\n' "$OTHER_SUBS" | grep -c .) other enabled subscription(s)"
    for s in $OTHER_SUBS; do
      FOUND=$(find_app "$s")
      if [ -n "$FOUND" ]; then SUB=$s; break; fi
    done
  fi

  if [ -z "$FOUND" ]; then
    if [ -n "$APP" ]; then bad "Web app $APP not found in any subscription you can see -> az login with the account that ran scripts/azure-setup.sh"
    else bad "No web app found (no AZURE_WEBAPP_NAME variable, no resource group tagged workload=contoso-order-desk) -> scripts/azure-setup.sh"; fi
  else
    IFS=$'\037' read -r RG FOUND_APP <<< "$FOUND"
    [ -n "$APP" ] || { APP=$FOUND_APP; info "Found through the resource group tag workload=contoso-order-desk"; }
    SUB_NAME=$(azq account show --subscription "$SUB" --query name -o tsv)
    [ "$SUB" = "$CUR_SUB" ] || warn "The web app is in subscription $SUB_NAME, not your current one: checked there (az account set --subscription \"$SUB_NAME\" makes it current)"
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

      IFS=$'\037' read -r FX TLS FTPS HC <<< "$(azf webapp config show "${AZA[@]}" --query "[[linuxFxVersion, minTlsVersion, ftpsState, healthCheckPath]]")"
      FX=$(none "$FX"); TLS=$(none "$TLS"); FTPS=$(none "$FTPS"); HC=$(none "$HC")
      PROBLEMS=''
      [ "$STATE" = "Running" ] || PROBLEMS="$PROBLEMS state ${STATE:-unknown};"
      is_true "$HTTPS" || PROBLEMS="$PROBLEMS HTTPS only is off;"
      case "$TLS" in 1.2|1.3) ;; *) PROBLEMS="$PROBLEMS minimum TLS ${TLS:-unknown};" ;; esac
      [ "$FTPS" = "Disabled" ] || PROBLEMS="$PROBLEMS FTP state ${FTPS:-unknown};"
      [ "$HC" = "/health" ] || PROBLEMS="$PROBLEMS health check path ${HC:-not set};"
      [[ "$FX" == NODE* ]] || PROBLEMS="$PROBLEMS runtime ${FX:-unknown};"
      if [ -z "$PROBLEMS" ]; then ok "Running, HTTPS only, TLS $TLS+, FTP off, $FX, health check $HC"
      else bad "Web app settings:${PROBLEMS%;} -> scripts/azure-setup.sh (safe to run again)"; fi

      ALLOWED=''; UNKNOWN=''
      for p in scm ftp; do
        v=$(azq resource show --subscription "$SUB" -g "$RG" --namespace Microsoft.Web --resource-type basicPublishingCredentialsPolicies \
              --parent "sites/$APP" -n "$p" --query properties.allow -o tsv)
        case "$v" in false|False) ;; true|True) ALLOWED="$ALLOWED $p" ;; *) UNKNOWN="$UNKNOWN $p" ;; esac
      done
      if [ -n "$ALLOWED" ]; then bad "Basic authentication still allowed for:$ALLOWED -> scripts/azure-setup.sh"
      elif [ -n "$UNKNOWN" ]; then warn "Could not read the basic authentication setting for:$UNKNOWN"
      else ok "Basic authentication off (scm and ftp): deployments sign in with Microsoft Entra ID"; fi

      AI=$(azq webapp config appsettings list "${AZA[@]}" --query "[?name=='APPLICATIONINSIGHTS_CONNECTION_STRING'] | length(@)" -o tsv)
      case "$AI" in
        1) ok "Application Insights connected" ;;
        0) warn "Application Insights not connected (optional) -> APPINSIGHTS=1 scripts/azure-setup.sh" ;;
        *) warn "Could not read the app settings to check Application Insights (needs Contributor or Website Contributor on the web app)" ;;
      esac

      # Who can deploy: the managed identities with Website Contributor on this web app.
      IDS=''; N_SP=0
      for p in $(azq role assignment list --subscription "$SUB" --scope "$WEBAPP_ID" --role "Website Contributor" --query "[?principalType=='ServicePrincipal'].principalId" -o tsv); do
        N_SP=$((N_SP + 1))
        row=$(azf identity list --subscription "$SUB" --query "[?principalId=='$p'] | [0:1].[resourceGroup, name, clientId, principalId]")
        [ -z "$row" ] || IDS="$IDS$row"$'\n'
      done
      N_IDS=$(printf '%s' "$IDS" | grep -c .)
      if [ "$N_IDS" = "0" ]; then
        bad "No managed identity in subscription $SUB_NAME has Website Contributor on $APP ($N_SP other service principal(s) have it) -> scripts/azure-setup.sh"
      else
        if [ "$N_IDS" != "1" ]; then
          warn "$N_IDS managed identities can deploy to $APP: $(printf '%s' "$IDS" | awk -F$'\037' '{printf "%s%s (client ID %s)", (NR>1?", ":""), $2, $3}'). GitHub does not show the AZURE_CLIENT_ID value: check it is the client ID of the one this repository should use"
        fi
        TRUSTED=
        # The subject GitHub sends (GitHub Docs, OpenID Connect reference): the immutable format for repositories created
        # after 15 July 2026, and for repositories renamed or transferred after that date.
        read -r REPO_ID OWNER_ID CREATED <<< "$(gh api "repos/$REPO" --jq '"\(.id) \(.owner.id) \(.created_at)"')"
        LEGACY="repo:$OWNER/$NAME:environment:production"
        IMMUTABLE="repo:$OWNER@$OWNER_ID/$NAME@$REPO_ID:environment:production"
        if [[ "$CREATED" > "2026-07-16" ]]; then WANT=$IMMUTABLE; WFMT=immutable; ALT=$LEGACY; AFMT=legacy
        else WANT=$LEGACY; WFMT=legacy; ALT=$IMMUTABLE; AFMT=immutable; fi
        GH_ISSUER=https://token.actions.githubusercontent.com
        while IFS=$'\037' read -r IRG IDENTITY CLIENT PRINCIPAL; do
          [ -n "$IDENTITY" ] || continue
          N=$(azq role assignment list --subscription "$SUB" --assignee "$PRINCIPAL" --all --query "length(@)" -o tsv)
          if [ "${N:-0}" = "1" ]; then ok "Identity $IDENTITY (client ID $CLIENT): Website Contributor on this web app, no other role in subscription $SUB_NAME (other subscriptions not checked)"
          else warn "Identity $IDENTITY (client ID $CLIENT) has ${N:-?} role assignments in subscription $SUB_NAME; the demo needs only Website Contributor on $APP"; fi

          F_WANT=''; F_WANT_AUD=''; F_ALT=''; F_ALT_AUD=''; F_OTHER=''
          while IFS=$'\037' read -r fname fiss fsub faud; do
            [ -n "$fname" ] || continue
            if [ "$fiss" = "$GH_ISSUER" ] && [ "$fsub" = "$WANT" ]; then F_WANT=$fname; F_WANT_AUD=$faud
            elif [ "$fiss" = "$GH_ISSUER" ] && [ "$fsub" = "$ALT" ]; then F_ALT=$fname; F_ALT_AUD=$faud
            else F_OTHER="$F_OTHER $fname ($fiss $fsub);"; fi
          done <<< "$(azf identity federated-credential list --subscription "$SUB" -g "$IRG" --identity-name "$IDENTITY" --query "[].[name, issuer, subject, join(',', audiences)]")"
          aud_ok() { [[ ",$1," == *",api://AzureADTokenExchange,"* ]]; }
          [ -z "$F_WANT$F_ALT" ] || TRUSTED=$IDENTITY
          if [ -n "$F_WANT" ]; then
            if aud_ok "$F_WANT_AUD"; then ok "Federated credential $F_WANT trusts $WANT, the $WFMT subject GitHub sends for this repository"
            else bad "Federated credential $F_WANT: audience '$F_WANT_AUD', expected api://AzureADTokenExchange -> scripts/azure-setup.sh"; fi
            [ -z "$F_ALT" ] || info "Federated credential $F_ALT also trusts the $AFMT subject; it is not needed"
          elif [ -n "$F_ALT" ] && [ "$DEPLOY_STATE" = "success" ] && aud_ok "$F_ALT_AUD"; then
            ok "Federated credential $F_ALT trusts $ALT; the last production deployment signed in with it"
          elif [ -n "$F_ALT" ]; then
            bad "Federated credential $F_ALT trusts the $AFMT subject $ALT, but GitHub sends $WANT for a repository created on ${CREATED%%T*} -> SUBJECT_FORMAT=$WFMT scripts/azure-setup.sh (a repository renamed or transferred after 15 July 2026 also sends the immutable one)"
          elif [ "$N_IDS" = "1" ]; then
            bad "No federated credential on $IDENTITY trusts the production environment of $REPO -> scripts/azure-setup.sh"
          else
            info "Identity $IDENTITY has no federated credential for $REPO: GitHub Actions in this repository cannot sign in as it"
          fi
          [ -z "$F_OTHER" ] || warn "Identity $IDENTITY also trusts:${F_OTHER%;}. Anyone those match can deploy to $APP -> remove what you do not need"
        done <<< "$IDS"
        [ "$N_IDS" = "1" ] || [ -n "$TRUSTED" ] || bad "None of the $N_IDS identities trusts the production environment of $REPO -> scripts/azure-setup.sh"
      fi
      info "Values for the guide: web app $APP, resource group $RG"
    fi
  fi
fi

case "$DEPLOY_STATE" in
  success) ok "Last production deployment (${DEPLOY_AT%%T*}) succeeded: GitHub signed in to Azure with the AZURE_* secrets and the federated credential" ;;
  failure|error) bad "Last production deployment (${DEPLOY_AT%%T*}) failed -> open the deploy job log in Actions" ;;
  '') warn "No production deployment yet: GitHub does not show secret values, so the first deployment is the real test of AZURE_CLIENT_ID and the federated credential" ;;
  *) warn "Last production deployment (${DEPLOY_AT%%T*}) is $DEPLOY_STATE" ;;
esac

URL=${WEBAPP_URL:-${HOST:+https://$HOST}}
URL=${URL:-${APP:+https://$APP.azurewebsites.net}}
if [ -z "$URL" ]; then bad "No web app URL -> scripts/azure-setup.sh"
elif command -v curl >/dev/null 2>&1; then
  BODY=$(curl -fsS --max-time 20 "$URL/health" 2>/dev/null)
  [[ "$BODY" == *'"ok"'* ]] && ok "$URL/health answers: $BODY" || bad "$URL/health does not answer -> check the last deployment and the App Service log stream"
else
  warn "curl not found; open $URL/health in a browser"
fi

step "Check by hand"
cat <<'MANUAL'
  - Presenter signed in to GitHub and VS Code; Approver signed in with the second account in another browser or on a second laptop
  - Copilot: cloud agent enabled for this repository; Copilot code review available; Agent and Plan modes visible in VS Code
  - VS Code: font size 18+, npm ci done, terminal open in the repository, notifications off
  - Tabs: repository, project board, Actions, Settings > Rules, Security tab, Azure portal (web app), the web app itself
  - Backup: the rehearsal recording and the simulated replay downloaded for offline use
MANUAL

if [ "$FAILS" = 0 ]; then step "Ready${WARNINGS:+ (check $WARNINGS warning(s))}"; else step "$FAILS item(s) to fix before the demo"; exit 1; fi
